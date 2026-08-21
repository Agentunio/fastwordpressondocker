<?php

require_once __DIR__ . '/default-admin-guardian.php';
require_once __DIR__ . '/mailpit-wp-mail.php';

if (! defined('WPMS_ON')) {
    define('WPMS_ON', true);
    define('WPMS_MAILER', 'smtp');
    define('WPMS_SMTP_HOST', 'mailpit');
    define('WPMS_SMTP_PORT', 1025);
    define('WPMS_SSL', 'none');
    define('WPMS_SMTP_AUTH', false);
    define('WPMS_SMTP_AUTOTLS', false);
    define('WPMS_MAIL_FROM', 'wordpress@example.test');
    define('WPMS_MAIL_FROM_FORCE', true);
}

function fast_wordpress_mailpit_from($from)
{
    if (function_exists('is_email') && ! is_email($from)) {
        return 'wordpress@example.test';
    }

    return $from;
}

function fast_wordpress_mailpit_phpmailer($phpmailer)
{
    $phpmailer->isSMTP();
    $phpmailer->Host = 'mailpit';
    $phpmailer->Port = 1025;
    $phpmailer->SMTPAuth = false;
    $phpmailer->SMTPSecure = '';
    $phpmailer->SMTPAutoTLS = false;
}

function fast_wordpress_mailpit_fix_localhost($value)
{
    if (is_array($value)) {
        return array_map('fast_wordpress_mailpit_fix_localhost', $value);
    }

    if (is_string($value)) {
        return preg_replace('~@localhost(:\d+)?(?![\w.-])~i', '@example.test', $value);
    }

    return $value;
}

function fast_wordpress_mailpit_recipients($atts)
{
    foreach (array('to', 'headers') as $key) {
        if (isset($atts[$key])) {
            $atts[$key] = fast_wordpress_mailpit_fix_localhost($atts[$key]);
        }
    }

    return $atts;
}

function fast_wordpress_response_is_html()
{
    foreach (headers_list() as $header) {
        if (stripos($header, 'content-type:') === 0) {
            return stripos($header, 'text/html') !== false;
        }
    }
    return true;
}

function fast_wordpress_downgrade_local_https($html)
{
    if (! is_string($html) || $html === '' || ! function_exists('home_url')) {
        return $html;
    }

    if (! fast_wordpress_response_is_html()) {
        return $html;
    }

    $parts = parse_url(home_url());

    if (empty($parts['host']) || (isset($parts['scheme']) && $parts['scheme'] !== 'http')) {
        return $html;
    }

    $host = $parts['host'];

    if (strpos($html, 'https://' . $host) === false) {
        return $html;
    }

    $pattern = '~https://' . preg_quote($host, '~') . '(?=[:/"\'?#\s]|$)~i';
    $rewritten = preg_replace($pattern, 'http://' . $host, $html);

    return $rewritten === null ? $html : $rewritten;
}

function fast_wordpress_start_https_downgrade_buffer()
{
    ob_start('fast_wordpress_downgrade_local_https');
}

$GLOBALS['wp_filter']['wp_mail_from'][10][] = array(
    'function' => 'fast_wordpress_mailpit_from',
    'accepted_args' => 1,
);

$GLOBALS['wp_filter']['wp_mail'][PHP_INT_MAX][] = array(
    'function' => 'fast_wordpress_mailpit_recipients',
    'accepted_args' => 1,
);

$GLOBALS['wp_filter']['phpmailer_init'][PHP_INT_MAX][] = array(
    'function' => 'fast_wordpress_mailpit_phpmailer',
    'accepted_args' => 1,
);

$GLOBALS['wp_filter']['authenticate'][PHP_INT_MAX][] = array(
    'function' => 'fast_wordpress_force_admin_login',
    'accepted_args' => 3,
);

$GLOBALS['wp_filter']['template_redirect'][0][] = array(
    'function' => 'fast_wordpress_start_https_downgrade_buffer',
    'accepted_args' => 1,
);

register_shutdown_function('fast_wordpress_ensure_default_admin');
