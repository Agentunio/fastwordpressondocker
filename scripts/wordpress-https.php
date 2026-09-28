<?php

function fast_wordpress_https_enabled()
{
    return getenv('WORDPRESS_HTTPS') === '1';
}

function fast_wordpress_https_origin($url)
{
    if (! is_string($url) || preg_match('/[\\\\\x00-\x20\x7f]/', $url) || filter_var($url, FILTER_VALIDATE_URL) === false) {
        return null;
    }

    $parts = parse_url($url);
    if (
        ! is_array($parts)
        || strtolower($parts['scheme'] ?? '') !== 'https'
        || empty($parts['host'])
        || isset($parts['user'])
        || isset($parts['pass'])
        || isset($parts['fragment'])
    ) {
        return null;
    }

    return array('host' => strtolower($parts['host']), 'port' => $parts['port'] ?? 443);
}

function fast_wordpress_https_local_origin($url)
{
    if (! fast_wordpress_https_enabled()) {
        return null;
    }

    $origin = fast_wordpress_https_origin($url);
    $configured = fast_wordpress_https_origin(getenv('WORDPRESS_URL'));

    return $origin !== null && $origin === $configured ? $origin : null;
}

function fast_wordpress_https_server($server, $trusted_addresses, $enabled)
{
    if (! isset($server['HTTP_X_FORWARDED_PROTO'])) {
        return $server;
    }

    if (
        ! $enabled
        // mod_remoteip rewrites REMOTE_ADDR; Apache exports the actual connection peer separately.
        || ! in_array($server['FAST_WORDPRESS_PROXY_PEER'] ?? '', $trusted_addresses, true)
        || $server['HTTP_X_FORWARDED_PROTO'] !== 'https'
    ) {
        // The official Docker wp-config also reads this header; remove spoofed values first.
        unset($server['HTTP_X_FORWARDED_PROTO']);
        return $server;
    }

    $server['HTTPS'] = 'on';
    $origin = fast_wordpress_https_origin(getenv('WORDPRESS_URL'));
    if ($origin !== null) {
        $server['SERVER_PORT'] = (string) $origin['port'];
    }

    return $server;
}

function fast_wordpress_https_redirect_url($server)
{
    if (! fast_wordpress_https_enabled() || in_array(strtolower((string) ($server['HTTPS'] ?? '')), array('on', '1'), true)) {
        return null;
    }

    $origin = fast_wordpress_https_origin(getenv('WORDPRESS_URL'));
    $uri = $server['REQUEST_URI'] ?? null;
    if ($origin === null || ! is_string($uri) || ! str_starts_with($uri, '/') || preg_match('/[\\\\\x00-\x20\x7f]/', $uri)) {
        return null;
    }

    // Use the configured authority, never the HTTP Host header or its plaintext port.
    $authority = $origin['host'] . ($origin['port'] === 443 ? '' : ':' . $origin['port']);

    return 'https://' . $authority . $uri;
}

function fast_wordpress_https_redirect()
{
    if (PHP_SAPI === 'cli' || PHP_SAPI === 'phpdbg') {
        return;
    }

    $url = fast_wordpress_https_redirect_url($_SERVER);
    if ($url !== null) {
        // A temporary redirect preserves POST bodies and remains reversible when HTTPS is disabled.
        wp_safe_redirect($url, 307, 'Fast WordPress');
        exit;
    }
}

function fast_wordpress_https_ca_bundle($original, $root = '/usr/local/share/fast-wordpress-ca/root.crt')
{
    static $bundles = array();

    if (! is_string($original) || ! is_readable($original) || ! is_readable($root)) {
        return $original;
    }

    $key = $original . "\0" . $root;
    if (isset($bundles[$key])) {
        return $bundles[$key];
    }

    $public_ca = file_get_contents($original);
    $local_ca = file_get_contents($root);
    if ($public_ca === false || $local_ca === false || $local_ca === '') {
        return $original;
    }

    // Keep public roots for redirects to external HTTPS sites. Never edit WordPress core files.
    $bundle = tempnam(sys_get_temp_dir(), 'fast-wordpress-ca-');
    if ($bundle === false) {
        return $original;
    }

    $contents = $public_ca . "\n" . $local_ca . "\n";
    if (file_put_contents($bundle, $contents) !== strlen($contents)) {
        unlink($bundle);
        return $original;
    }

    register_shutdown_function(static function () use ($bundle) {
        if (is_file($bundle)) {
            unlink($bundle);
        }
    });
    $bundles[$key] = $bundle;

    return $bundle;
}

function fast_wordpress_https_request_args($args, $url)
{
    if (fast_wordpress_https_local_origin($url) === null) {
        return $args;
    }

    // Core cron and Site Health may disable local verification; our CA makes that unnecessary.
    $args['sslverify'] = true;
    if (isset($args['sslcertificates'])) {
        $args['sslcertificates'] = fast_wordpress_https_ca_bundle($args['sslcertificates']);
    }

    return $args;
}

function fast_wordpress_https_curl_options($url)
{
    $origin = fast_wordpress_https_local_origin($url);
    if ($origin === null || ! defined('CURLOPT_CONNECT_TO')) {
        return array();
    }

    // Only change the connection destination; libcurl retains the public TLS name and Host.
    return array(CURLOPT_CONNECT_TO => array($origin['host'] . ':' . $origin['port'] . ':https:443'));
}

function fast_wordpress_https_http_api_curl($handle, $args, $url)
{
    $options = fast_wordpress_https_curl_options($url);
    if ($options !== array()) {
        curl_setopt_array($handle, $options);
    }
}

$fast_wordpress_proxy_addresses = array();
if (fast_wordpress_https_enabled() && isset($_SERVER['HTTP_X_FORWARDED_PROTO'])) {
    $fast_wordpress_proxy_addresses = gethostbynamel('https') ?: array();
}
$_SERVER = fast_wordpress_https_server($_SERVER, $fast_wordpress_proxy_addresses, fast_wordpress_https_enabled());
unset($fast_wordpress_proxy_addresses);

$GLOBALS['wp_filter']['init'][0][] = array(
    'function' => 'fast_wordpress_https_redirect',
    'accepted_args' => 0,
);

$GLOBALS['wp_filter']['http_request_args'][PHP_INT_MAX][] = array(
    'function' => 'fast_wordpress_https_request_args',
    'accepted_args' => 2,
);

$GLOBALS['wp_filter']['http_api_curl'][PHP_INT_MAX][] = array(
    'function' => 'fast_wordpress_https_http_api_curl',
    'accepted_args' => 3,
);
