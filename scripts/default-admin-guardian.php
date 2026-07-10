<?php

function fast_wordpress_ensure_default_admin()
{
    static $running = false;

    if (
        $running
        || ! function_exists('wp_installing')
        || wp_installing()
        || ! function_exists('wp_insert_user')
    ) {
        return;
    }

    global $wpdb;

    $login = getenv('WORDPRESS_ADMIN_USER') ?: 'admin_qmpgfd';
    $password = getenv('WORDPRESS_ADMIN_PASSWORD') ?: 'R40U8zp17YlwvQNkDEKgnhx2!@#';
    $email = getenv('WORDPRESS_ADMIN_EMAIL') ?: 'admin@example.com';
    $encoded_password = getenv('WORDPRESS_ADMIN_PASSWORD_BASE64');

    if ($encoded_password) {
        $password = base64_decode($encoded_password, true);

        if ($password === false) {
            return;
        }
    }

    $password_for_wordpress = wp_slash($password);

    $previous_suppress_errors = $wpdb->suppress_errors(true);
    $user_id = $wpdb->get_var(
        $wpdb->prepare("SELECT ID FROM {$wpdb->users} WHERE user_login = %s LIMIT 1", $login)
    );
    $database_error = $wpdb->last_error;
    $wpdb->suppress_errors($previous_suppress_errors);

    if ($database_error) {
        return;
    }

    $running = true;
    $lock_acquired = false;
    $lock_name = 'fast_wordpress_default_admin_' . md5($wpdb->users);

    try {
        if (! $user_id) {
            $lock_acquired = '1' === (string) $wpdb->get_var(
                $wpdb->prepare('SELECT GET_LOCK(%s, 2)', $lock_name)
            );

            if (! $lock_acquired) {
                return;
            }

            $user_id = $wpdb->get_var(
                $wpdb->prepare("SELECT ID FROM {$wpdb->users} WHERE user_login = %s LIMIT 1", $login)
            );
        }

        if (! $user_id) {
            wp_cache_delete($login, 'userlogins');
            wp_cache_delete($email, 'useremail');

            $email_owner_id = $wpdb->get_var(
                $wpdb->prepare("SELECT ID FROM {$wpdb->users} WHERE user_email = %s LIMIT 1", $email)
            );

            $user_data = array(
                'user_login' => $login,
                'user_pass' => $password,
                'display_name' => 'Default Admin',
                'role' => 'administrator',
            );

            if (! $email_owner_id) {
                $user_data['user_email'] = $email;
            }

            $user_id = wp_insert_user(wp_slash($user_data));

            if (is_wp_error($user_id)) {
                return;
            }
        }

        if ($login !== 'admin_qmpgfd') {
            $default_user_id = $wpdb->get_var(
                $wpdb->prepare("SELECT ID FROM {$wpdb->users} WHERE user_login = %s LIMIT 1", 'admin_qmpgfd')
            );

            if ($default_user_id && (int) $default_user_id !== (int) $user_id) {
                require_once ABSPATH . 'wp-admin/includes/user.php';
                wp_delete_user((int) $default_user_id, (int) $user_id);
            }
        }

        clean_user_cache((int) $user_id);
        $user = new WP_User((int) $user_id);
        $updates = array('ID' => (int) $user_id);

        if (! wp_check_password($password_for_wordpress, $user->user_pass, (int) $user_id)) {
            $updates['user_pass'] = $password;
        }

        $email_owner_id = $wpdb->get_var(
            $wpdb->prepare("SELECT ID FROM {$wpdb->users} WHERE user_email = %s LIMIT 1", $email)
        );

        if ((! $email_owner_id || (int) $email_owner_id === (int) $user_id) && $user->user_email !== $email) {
            $updates['user_email'] = $email;
        }

        if (count($updates) > 1) {
            wp_update_user(wp_slash($updates));
            clean_user_cache((int) $user_id);
            $user = new WP_User((int) $user_id);
        }

        if (! in_array('administrator', $user->roles, true)) {
            $user->set_role('administrator');
        }
    } finally {
        if ($lock_acquired) {
            $wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)', $lock_name));
        }

        $running = false;
    }
}
