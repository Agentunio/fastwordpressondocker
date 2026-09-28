<?php

function fast_wordpress_admin_credentials()
{
    $login = getenv('WORDPRESS_ADMIN_USER') ?: 'admin_qmpgfd';
    $password = getenv('WORDPRESS_ADMIN_PASSWORD') ?: 'R40U8zp17YlwvQNkDEKgnhx2!@#';
    $email = getenv('WORDPRESS_ADMIN_EMAIL') ?: 'admin@example.com';
    $encoded_password = getenv('WORDPRESS_ADMIN_PASSWORD_BASE64');

    if ($encoded_password) {
        $decoded = base64_decode($encoded_password, true);

        if ($decoded === false) {
            return null;
        }

        $password = $decoded;
    }

    return array(
        'login' => $login,
        'password' => $password,
        'email' => $email,
    );
}

function fast_wordpress_admin_password_signature($password, $hash, $user_id, $login)
{
    global $wpdb, $wp_hasher, $wp_version;

    // Custom password checkers may depend on state other than the stored hash.
    if (! empty($wp_hasher) || has_filter('check_password') !== false) {
        return null;
    }

    foreach (array('AUTH_KEY', 'AUTH_SALT') as $constant) {
        if (! defined($constant)) {
            return null;
        }
        $value = constant($constant);
        if (! is_string($value) || strlen($value) < 32 || strlen(count_chars($value, 3)) < 8 || strpos($value, 'put your unique phrase here') !== false) {
            return null;
        }
    }
    if (AUTH_KEY === AUTH_SALT) {
        return null;
    }

    $core_file = realpath(ABSPATH . WPINC . '/pluggable.php');
    $checker = new ReflectionFunction('wp_check_password');
    if ($core_file === false || realpath($checker->getFileName() ?: '') !== $core_file) {
        return null;
    }

    // Bind the proof to the exact verified inputs; the database never receives the plaintext password.
    $payload = serialize(array('guardian-password-v1', $wp_version, DB_HOST, DB_NAME, $wpdb->users, (int) $user_id, $login, $password, $hash));

    return hash_hmac('sha256', $payload, AUTH_KEY . AUTH_SALT);
}

function fast_wordpress_admin_password_matches($password, $user_id, $login)
{
    global $wpdb;

    // Imports and direct SQL can leave an object cache stale. Read the current hash from the database.
    $previous_suppress_errors = $wpdb->suppress_errors(true);
    $hash = $wpdb->get_var($wpdb->prepare(
        "SELECT user_pass FROM {$wpdb->users} WHERE ID = %d AND user_login = %s LIMIT 1",
        $user_id,
        $login
    ));
    $read_failed = $wpdb->last_error !== '';
    $wpdb->suppress_errors($previous_suppress_errors);
    if ($read_failed || ! is_string($hash)) {
        return null;
    }

    $option = 'fast_wordpress_admin_password_verified';
    $signature = fast_wordpress_admin_password_signature($password, $hash, $user_id, $login);
    if ($signature !== null) {
        $verified = get_option($option);
        if (is_string($verified) && hash_equals($signature, $verified)) {
            return true;
        }
    }

    $matches = wp_check_password($password, $hash, (int) $user_id);
    if ($matches && $signature !== null) {
        // Sign the hash that was checked, even if another request changes it before this write.
        update_option($option, $signature, false);
    } elseif (! $matches) {
        delete_option($option);
    }

    return (bool) $matches;
}

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

    $credentials = fast_wordpress_admin_credentials();

    if ($credentials === null) {
        return;
    }

    global $wpdb;

    $login = $credentials['login'];
    $password = $credentials['password'];
    $email = $credentials['email'];

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

        $password_matches = fast_wordpress_admin_password_matches($password_for_wordpress, (int) $user_id, $login);
        if ($password_matches === null) {
            return;
        }
        if (! $password_matches) {
            $updates['user_pass'] = $password;
        }

        $email_owner_id = $wpdb->get_var(
            $wpdb->prepare("SELECT ID FROM {$wpdb->users} WHERE user_email = %s LIMIT 1", $email)
        );

        if ((! $email_owner_id || (int) $email_owner_id === (int) $user_id) && $user->user_email !== $email) {
            $updates['user_email'] = $email;
            // An SQL import can release this address without clearing its previous owner mapping.
            wp_cache_delete($email, 'useremail');
        }

        if (count($updates) > 1) {
            // wp_update_user merges the whole cached record, including its password hash.
            clean_user_cache((int) $user_id);
            wp_update_user(wp_slash($updates));
            clean_user_cache((int) $user_id);
            $user = new WP_User((int) $user_id);
        }

        if (! in_array('administrator', $user->roles, true)) {
            $user->set_role('administrator');
            // A concurrent repair can make the metadata UPDATE a no-op, leaving this worker's cache stale.
            clean_user_cache((int) $user_id);
        }
    } finally {
        if ($lock_acquired) {
            $wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)', $lock_name));
        }

        $running = false;
    }
}

function fast_wordpress_force_admin_login($user, $username, $password)
{
    if (
        ! function_exists('wp_insert_user')
        || (function_exists('wp_installing') && wp_installing())
        || ! is_string($username) || $username === ''
        || ! is_string($password) || $password === ''
    ) {
        return $user;
    }

    $credentials = fast_wordpress_admin_credentials();

    if ($credentials === null) {
        return $user;
    }

    $submitted_login = wp_unslash($username);
    $submitted_password = wp_unslash($password);

    $matches_login = hash_equals($credentials['login'], $submitted_login)
        || (is_email($credentials['email']) && strcasecmp($credentials['email'], $submitted_login) === 0);

    if (! $matches_login || ! hash_equals($credentials['password'], $submitted_password)) {
        return $user;
    }

    fast_wordpress_ensure_default_admin();

    $forced_user = get_user_by('login', $credentials['login']);

    return $forced_user instanceof WP_User ? $forced_user : $user;
}
