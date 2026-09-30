<?php

function fast_wordpress_perfmatters_origin($url)
{
    if (! is_string($url) || preg_match('/[\\\\\x00-\x20\x7f]/', $url) || filter_var($url, FILTER_VALIDATE_URL) === false) {
        return null;
    }

    $parts = parse_url($url);
    if (
        ! in_array(strtolower($parts['scheme'] ?? ''), array('http', 'https'), true)
        || ! in_array(strtolower($parts['host'] ?? ''), array('localhost', '127.0.0.1', '[::1]'), true)
        || isset($parts['user'])
        || isset($parts['pass'])
        || isset($parts['query'])
        || isset($parts['fragment'])
    ) {
        return null;
    }

    return array(strtolower($parts['host']), $parts['port'] ?? 80);
}

function fast_wordpress_perfmatters_http_cache_path($path)
{
    $configured_url = getenv('WORDPRESS_URL');
    $origin = fast_wordpress_perfmatters_origin($configured_url);
    if (
        getenv('WORDPRESS_HTTPS') === '1'
        || $origin === null
        || strtolower(parse_url($configured_url, PHP_URL_SCHEME)) !== 'http'
        || is_ssl()
        || defined('PERFMATTERS_CACHE_URL')
        || defined('PERFMATTERS_CACHE_DIR')
        || ! is_string($path)
    ) {
        return $path;
    }

    $site_url = get_site_url();
    $content_url = content_url('/');
    if (
        fast_wordpress_perfmatters_origin($site_url) !== $origin
        || fast_wordpress_perfmatters_origin($content_url) !== $origin
    ) {
        return $path;
    }

    $content_url = set_url_scheme($content_url, 'http');
    $site = parse_url($site_url);
    $host = $site['host'] . ($site['path'] ?? '');

    $path .= '/fast-wordpress-http-' . substr(hash('sha256', $content_url), 0, 12);
    define('PERFMATTERS_CACHE_URL', $content_url . $path . '/perfmatters/' . $host . '/');

    return $path;
}

$GLOBALS['wp_filter']['perfmatters_cache_path'][PHP_INT_MAX][] = array(
    'function' => 'fast_wordpress_perfmatters_http_cache_path',
    'accepted_args' => 1,
);
