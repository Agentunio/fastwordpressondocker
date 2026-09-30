<?php

$scenarios = array(
    'http' => array(),
    'custom-port' => array('url' => 'http://localhost:8181'),
    'ipv4' => array('url' => 'http://127.0.0.1:8181'),
    'ipv6' => array('url' => 'http://[::1]:8181'),
    'subdirectory' => array('url' => 'http://localhost:8181/wordpress'),
    'custom-cache-path' => array('path' => 'uploads/cache'),
    'forced-content-https' => array('content' => 'https://localhost/wp-content/'),
    'https-mode' => array('https' => '1', 'disabled' => true),
    'https-url' => array('url' => 'https://localhost', 'disabled' => true),
    'ssl-request' => array('ssl' => true, 'disabled' => true),
    'outside-docker' => array('url' => false, 'disabled' => true),
    'production' => array('url' => 'http://example.com', 'disabled' => true),
    'lookalike-host' => array('url' => 'http://localhost.example.com', 'disabled' => true),
    'credentials' => array('url' => 'http://user@localhost', 'disabled' => true),
    'query' => array('url' => 'http://localhost/?x=1', 'disabled' => true),
    'invalid-url' => array('url' => 'http://localhost:99999', 'disabled' => true),
    'untrusted-site' => array('site' => 'http://example.com', 'disabled' => true),
    'cdn-content' => array('content' => 'https://cdn.example.com/wp-content/', 'disabled' => true),
    'other-content-port' => array('content' => 'https://localhost:8443/wp-content/', 'disabled' => true),
    'existing-cache-url' => array('constant' => 'PERFMATTERS_CACHE_URL', 'disabled' => true),
    'existing-cache-dir' => array('constant' => 'PERFMATTERS_CACHE_DIR', 'disabled' => true),
    'without-perfmatters' => array('absent' => true),
);

if (! isset($argv[1])) {
    foreach ($scenarios as $name => $scenario) {
        $process = proc_open(array(PHP_BINARY, __FILE__, $name), array(0 => STDIN, 1 => STDOUT, 2 => STDERR), $pipes);
        if (! is_resource($process) || proc_close($process) !== 0) {
            throw new RuntimeException('Failed scenario: ' . $name);
        }
    }
    echo 'OK: ' . count($scenarios) . " Perfmatters HTTP scenarios\n";
    exit;
}

$scenario = $scenarios[$argv[1]];
$url = array_key_exists('url', $scenario) ? $scenario['url'] : 'http://localhost';
putenv($url === false ? 'WORDPRESS_URL' : 'WORDPRESS_URL=' . $url);
putenv('WORDPRESS_HTTPS=' . ($scenario['https'] ?? '0'));

function is_ssl()
{
    return $GLOBALS['scenario']['ssl'] ?? false;
}

function get_site_url()
{
    return $GLOBALS['scenario']['site'] ?? $GLOBALS['url'];
}

function content_url($path)
{
    return $GLOBALS['scenario']['content'] ?? $GLOBALS['url'] . '/wp-content' . $path;
}

function set_url_scheme($url, $scheme)
{
    return preg_replace('~^https?://~', $scheme . '://', $url);
}

function check($condition, $message)
{
    if (! $condition) {
        throw new RuntimeException($GLOBALS['argv'][1] . ': ' . $message);
    }
}

if (isset($scenario['constant'])) {
    define($scenario['constant'], 'custom-cache');
}

require __DIR__ . '/../scripts/perfmatters-http.php';
$hook = $GLOBALS['wp_filter']['perfmatters_cache_path'][PHP_INT_MAX][0];
check(is_callable($hook['function']), 'The early bootstrap registers a callable cache hook');

if (! empty($scenario['absent'])) {
    check(! defined('PERFMATTERS_CACHE_URL'), 'No cache constant without Perfmatters');
    exit;
}

$path = $scenario['path'] ?? 'cache';
$filtered = ($hook['function'])($path);
if (! empty($scenario['disabled'])) {
    check($path === $filtered, 'Unrelated environments preserve the cache path');
    check(
        ($scenario['constant'] ?? '') === 'PERFMATTERS_CACHE_URL'
            ? PERFMATTERS_CACHE_URL === 'custom-cache'
            : ! defined('PERFMATTERS_CACHE_URL'),
        'Do not define or overwrite the cache URL'
    );
    exit;
}

check(str_starts_with($filtered, $path . '/fast-wordpress-http-'), 'Isolate restored CSS without deleting it');
check((bool) preg_match('~/fast-wordpress-http-[a-f0-9]{12}$~', $filtered), 'Use a stable local cache namespace');
$site = parse_url(get_site_url());
$expected_url = set_url_scheme(content_url('/'), 'http') . $filtered . '/perfmatters/' . $site['host'] . ($site['path'] ?? '') . '/';
check(PERFMATTERS_CACHE_URL === $expected_url, 'HTTP cache URL preserves port, content path and site subdirectory');
check(($hook['function'])($filtered) === $filtered, 'A repeated hook call does not append another namespace');
