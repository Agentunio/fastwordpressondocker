<?php

// Run without WordPress: php tests/wordpress-https.php.
putenv('WORDPRESS_HTTPS=0');
putenv('WORDPRESS_URL=http://localhost');
require_once __DIR__ . '/../scripts/wordpress-https.php';

$assertions = 0;
$assert_same = static function ($expected, $actual, $label) use (&$assertions) {
    ++$assertions;
    if ($expected !== $actual) {
        throw new RuntimeException($label . ': expected ' . var_export($expected, true) . ', got ' . var_export($actual, true));
    }
};

$args = array('sslverify' => false, 'sslcertificates' => '/missing/public-ca.crt', 'blocking' => false, 'timeout' => 0.01);
$assert_same($args, fast_wordpress_https_request_args($args, 'https://localhost/wp-cron.php'), 'HTTP mode preserves request arguments');
$assert_same(array(), fast_wordpress_https_curl_options('https://localhost/'), 'HTTP mode does not route HTTPS');
$assert_same(null, fast_wordpress_https_redirect_url(array('REQUEST_URI' => '/wp-login.php')), 'HTTP mode does not redirect');

$server = array('REMOTE_ADDR' => '192.0.2.50', 'FAST_WORDPRESS_PROXY_PEER' => '172.20.0.5', 'HTTP_HOST' => 'localhost:8443', 'SERVER_PORT' => '80');
$assert_same($server, fast_wordpress_https_server($server, array('172.20.0.5'), true), 'No forwarded header preserves server');
$forwarded = $server + array('HTTP_X_FORWARDED_PROTO' => 'https');
$assert_same($server, fast_wordpress_https_server($forwarded, array('172.20.0.5'), false), 'HTTP mode strips forged forwarded header');
$assert_same($server, fast_wordpress_https_server($forwarded, array('172.20.0.6'), true), 'Untrusted peer cannot enable HTTPS');
$assert_same($server, fast_wordpress_https_server($forwarded, array(), true), 'Failed proxy DNS lookup does not grant trust');
$spoofed_peer = $forwarded;
unset($spoofed_peer['FAST_WORDPRESS_PROXY_PEER']);
$spoofed_peer['REMOTE_ADDR'] = '172.20.0.5';
$spoofed_peer['HTTP_FAST_WORDPRESS_PROXY_PEER'] = '172.20.0.5';
$expected_peer = $spoofed_peer;
unset($expected_peer['HTTP_X_FORWARDED_PROTO']);
$assert_same($expected_peer, fast_wordpress_https_server($spoofed_peer, array('172.20.0.5'), true), 'Forwarded client IP and lookalike HTTP header cannot impersonate the proxy peer');

putenv('WORDPRESS_HTTPS=1');
putenv('WORDPRESS_URL=https://localhost:8443');
$trusted = fast_wordpress_https_server($forwarded, array('172.20.0.5'), true);
$assert_same('on', $trusted['HTTPS'], 'Trusted proxy enables HTTPS');
$assert_same('8443', $trusted['SERVER_PORT'], 'Trusted proxy uses public port');
$assert_same('localhost:8443', $trusted['HTTP_HOST'], 'Host and public port remain intact');
$request = array('HTTP_HOST' => 'localhost:89', 'REQUEST_URI' => '/wp-login.php?action=lostpassword&redirect_to=%2Fwp-admin%2F');
$redirect = 'https://localhost:8443' . $request['REQUEST_URI'];
$assert_same($redirect, fast_wordpress_https_redirect_url($request), 'HTTP login uses configured HTTPS port and preserves path and query');
$request['HTTP_HOST'] = 'attacker.example:1234';
$assert_same($redirect, fast_wordpress_https_redirect_url($request), 'Untrusted Host cannot change the redirect origin');
$request['HTTP_X_FORWARDED_PROTO'] = 'https';
$assert_same($redirect, fast_wordpress_https_redirect_url($request), 'A forwarded header alone cannot suppress the redirect');
$assert_same(null, fast_wordpress_https_redirect_url($trusted + array('REQUEST_URI' => '/wp-login.php')), 'Trusted HTTPS request does not redirect again');
$assert_same(null, fast_wordpress_https_redirect_url(array('HTTPS' => '1', 'REQUEST_URI' => '/wp-admin/')), 'Native HTTPS does not loop');
$assert_same(null, fast_wordpress_https_redirect_url(array()), 'Requests without a URI are not redirected');
foreach (array('', 'wp-login.php', 'https://attacker.example/', "/wp-login.php\r\nX-Injected: yes", '/\\attacker.example/', array()) as $uri) {
    $assert_same(null, fast_wordpress_https_redirect_url(array('REQUEST_URI' => $uri)), 'Malformed request URI cannot become a Location header');
}
$assert_same('https://localhost:8443//attacker.example/path', fast_wordpress_https_redirect_url(array('REQUEST_URI' => '//attacker.example/path')), 'Network-path request remains a path on the configured origin');
foreach (array('https,http', 'http,https', 'HTTPS', 'https.example', array('https')) as $spoofed) {
    $bad_server = $server + array('HTTP_X_FORWARDED_PROTO' => $spoofed);
    $assert_same($server, fast_wordpress_https_server($bad_server, array('172.20.0.5'), true), 'Only the exact Caddy protocol header is accepted');
}

foreach (array(
    'http://localhost:8443/',
    'https://localhost/',
    'https://localhost:8444/',
    'https://localhost.example:8443/',
    'https://example.test:8443/',
    'https://user@localhost:8443/',
    'https://user:password@localhost:8443/',
    'https://localhost:8443/#fragment',
    'https://localhost:8443\\@example.test/',
    "https://localhost:8443/\r\nHeader:value",
    'https://localhost:99999/',
    '//localhost:8443/',
    false,
    array(),
) as $other) {
    $assert_same(null, fast_wordpress_https_local_origin($other), 'Reject malformed or different origin');
    $assert_same($args, fast_wordpress_https_request_args($args, $other), 'Leave unrelated request arguments unchanged');
    $assert_same(array(), fast_wordpress_https_curl_options($other), 'Never connect unrelated requests to Caddy');
}

$expected_origin = array('host' => 'localhost', 'port' => 8443);
foreach (array('https://localhost:8443/', 'https://LOCALHOST:8443/wp-json/', 'https://localhost:8443/wp-cron.php?doing_wp_cron=123') as $local) {
    $assert_same($expected_origin, fast_wordpress_https_local_origin($local), 'Recognize exact local origin');
    $local_args = fast_wordpress_https_request_args($args, $local);
    $assert_same(true, $local_args['sslverify'], 'Local verification remains enabled even when CA is missing');
    $assert_same($args['sslcertificates'], $local_args['sslcertificates'], 'Missing CA fails closed using original roots');
    $assert_same(false, $local_args['blocking'], 'Cron remains nonblocking');
    $assert_same(0.01, $local_args['timeout'], 'Cron timeout is preserved');
    if (defined('CURLOPT_CONNECT_TO')) {
        $assert_same(array(CURLOPT_CONNECT_TO => array('localhost:8443:https:443')), fast_wordpress_https_curl_options($local), 'Map only configured host and public port to Caddy');
    }
}

putenv('WORDPRESS_URL=https://localhost');
$assert_same(array('host' => 'localhost', 'port' => 443), fast_wordpress_https_local_origin('https://localhost:443/'), 'Implicit and explicit default ports match');
$assert_same('https://localhost/wp-admin/', fast_wordpress_https_redirect_url(array('REQUEST_URI' => '/wp-admin/')), 'Redirect omits the default TLS port');
putenv('WORDPRESS_URL=https://user@localhost');
$assert_same(null, fast_wordpress_https_local_origin('https://localhost/'), 'Invalid configured origin cannot enable routing');
$assert_same(null, fast_wordpress_https_redirect_url(array('REQUEST_URI' => '/wp-login.php')), 'Invalid configured origin cannot enable a redirect');

$public = tempnam(sys_get_temp_dir(), 'https-test-public-');
$root = tempnam(sys_get_temp_dir(), 'https-test-root-');
try {
    file_put_contents($public, "PUBLIC ROOTS\n");
    file_put_contents($root, "LOCAL ROOT\n");
    $bundle = fast_wordpress_https_ca_bundle($public, $root);
    $assert_same(true, $bundle !== $public, 'Create a separate combined CA bundle');
    $assert_same("PUBLIC ROOTS\n\nLOCAL ROOT\n\n", file_get_contents($bundle), 'Preserve public roots for external redirects');
    $assert_same("PUBLIC ROOTS\n", file_get_contents($public), 'Original CA bundle is not modified');
    $assert_same($bundle, fast_wordpress_https_ca_bundle($public, $root), 'Reuse combined CA bundle within a request');
    $assert_same($public, fast_wordpress_https_ca_bundle($public, $root . '.missing'), 'Unavailable local CA does not disable verification');
    $assert_same($public . '.missing', fast_wordpress_https_ca_bundle($public . '.missing', $root), 'Unavailable public CA fails closed');
} finally {
    unlink($public);
    unlink($root);
}

echo "HTTPS integration unit checks passed: {$assertions}.\n";
