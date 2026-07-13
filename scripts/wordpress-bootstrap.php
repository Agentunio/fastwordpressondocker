<?php

require_once __DIR__ . '/default-admin-guardian.php';

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

$GLOBALS['wp_filter']['wp_mail_from'][10][] = array(
    'function' => 'fast_wordpress_mailpit_from',
    'accepted_args' => 1,
);

$GLOBALS['wp_filter']['phpmailer_init'][PHP_INT_MAX][] = array(
    'function' => 'fast_wordpress_mailpit_phpmailer',
    'accepted_args' => 1,
);

register_shutdown_function('fast_wordpress_ensure_default_admin');
