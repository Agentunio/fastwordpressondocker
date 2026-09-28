<?php

ini_set('zend.exception_ignore_args', '1');

// Run only on a disposable installation:
// FAST_WORDPRESS_DISPOSABLE_TEST=1 wp --allow-root eval-file /tests/default-admin-guardian.php
if (! defined('WP_CLI') || ! WP_CLI || getenv('FAST_WORDPRESS_DISPOSABLE_TEST') !== '1') {
    throw new RuntimeException('This test requires WP-CLI and FAST_WORDPRESS_DISPOSABLE_TEST=1.');
}

if (! function_exists('fast_wordpress_ensure_default_admin')) {
    throw new RuntimeException('The default administrator guardian must be loaded.');
}

global $wpdb;
$assertions = 0;
$assert_same = static function ($expected, $actual, $label) use (&$assertions) {
    ++$assertions;
    if ($expected !== $actual) {
        // Values can include credentials, so never print them on failure.
        throw new RuntimeException('Assertion failed: ' . $label);
    }
};
$read_user = static function ($login) use ($wpdb) {
    return $wpdb->get_row($wpdb->prepare("SELECT * FROM {$wpdb->users} WHERE user_login = %s", $login));
};
$assert_admin = static function ($login, $password, $email = null) use ($assert_same, $read_user) {
    $row = $read_user($login);
    $assert_same(true, is_object($row), 'Managed account exists');
    $assert_same(true, wp_check_password(wp_slash($password), $row->user_pass, (int) $row->ID), 'Stored hash accepts the configured WordPress password');
    if ($email !== null) {
        $assert_same($email, $row->user_email, 'Managed account has the configured email');
    }
    $user = get_userdata((int) $row->ID);
    $assert_same(true, $user instanceof WP_User, 'Managed account is available through the WordPress cache');
    $assert_same(true, in_array('administrator', $user->roles, true), 'Managed account retains administrator access');
    return $row;
};
$assert_stable = static function ($login, $password, $email = null) use ($assert_same, $assert_admin, $read_user, $wpdb) {
    $before = $read_user($login);
    for ($iteration = 0; $iteration < 3; ++$iteration) {
        fast_wordpress_ensure_default_admin();
        $after = $assert_admin($login, $password, $email);
        $assert_same($before->user_pass, $after->user_pass, 'Repeated checks do not rewrite a valid password hash');
        $assert_same((int) $before->ID, (int) $after->ID, 'Repeated checks reuse the same account');
    }
    $count = $wpdb->get_var($wpdb->prepare("SELECT COUNT(*) FROM {$wpdb->users} WHERE user_login = %s", $login));
    $assert_same(1, (int) $count, 'Repeated checks do not create duplicate accounts');
};
$warm_user_cache = static function ($user_id) {
    $user = get_userdata($user_id);
    get_user_by('login', $user->user_login);
    get_user_by('email', $user->user_email);
    get_user_meta($user_id);
};
$environment_names = array(
    'WORDPRESS_ADMIN_USER',
    'WORDPRESS_ADMIN_PASSWORD',
    'WORDPRESS_ADMIN_PASSWORD_BASE64',
    'WORDPRESS_ADMIN_EMAIL',
);
$original_environment = array();
foreach ($environment_names as $name) {
    $original_environment[$name] = getenv($name);
}
$suffix = bin2hex(random_bytes(6));
$login = 'guardian_test_' . $suffix;
$email = 'guardian-' . $suffix . '@example.test';
$password = 'Guardian initial password ' . $suffix;
$test_logins = array($login);
$owner_id = 0;
$proof_option = 'fast_wordpress_admin_password_verified';

try {
    putenv('WORDPRESS_ADMIN_USER=' . $login);
    putenv('WORDPRESS_ADMIN_PASSWORD=' . $password);
    putenv('WORDPRESS_ADMIN_PASSWORD_BASE64');
    putenv('WORDPRESS_ADMIN_EMAIL=' . $email);

    fast_wordpress_ensure_default_admin();
    $initial = $assert_admin($login, $password, $email);
    $assert_stable($login, $password, $email);
    $initial_proof = get_option($proof_option);
    $assert_same(1, is_string($initial_proof) ? preg_match('/^[a-f0-9]{64}$/D', $initial_proof) : 0, 'A successful verification stores only a SHA-256 HMAC');
    $assert_same(false, strpos($initial_proof, $password) !== false, 'The verification proof does not contain the configured password');
    $autoload = $wpdb->get_var($wpdb->prepare("SELECT autoload FROM {$wpdb->options} WHERE option_name = %s", $proof_option));
    $autoload_values = function_exists('wp_autoload_values_to_autoload') ? wp_autoload_values_to_autoload() : array('yes');
    $assert_same(false, in_array($autoload, $autoload_values, true), 'The verification proof is not autoloaded');
    update_option($proof_option, str_repeat('0', 64), false);
    fast_wordpress_ensure_default_admin();
    $assert_same($initial_proof, get_option($proof_option), 'A tampered proof is replaced after password verification');
    $assert_same($initial->user_pass, $read_user($login)->user_pass, 'Repairing a proof does not rewrite a valid hash');

    // Simulate a SQL import without invalidating a persistent object cache.
    $warm_user_cache((int) $initial->ID);
    $replacement_hash = wp_hash_password('Imported unrelated password ' . $suffix);
    $assert_same(1, $wpdb->update($wpdb->users, array(
        'user_pass' => $replacement_hash,
        'user_email' => 'imported-' . $suffix . '@example.test',
    ), array('ID' => (int) $initial->ID)), 'SQL import changes the existing account');
    $assert_same(1, $wpdb->update($wpdb->usermeta, array(
        'meta_value' => serialize(array('subscriber' => true)),
    ), array('user_id' => (int) $initial->ID, 'meta_key' => $wpdb->get_blog_prefix() . 'capabilities')), 'SQL import removes administrator capability');
    fast_wordpress_ensure_default_admin();
    $repaired = $assert_admin($login, $password, $email);
    $assert_same(false, wp_check_password('Imported unrelated password ' . $suffix, $repaired->user_pass, (int) $repaired->ID), 'Imported password no longer grants access');
    $assert_stable($login, $password, $email);

    // A concurrent repair must not be undone by an older cached WP_User object.
    $race_hash = wp_hash_password(wp_slash($password));
    $assert_same(1, $wpdb->update($wpdb->users, array(
        'user_pass' => $replacement_hash,
        'user_email' => 'concurrent-' . $email,
    ), array('ID' => (int) $repaired->ID)), 'Prepare a stale user object for concurrent repair');
    $race_triggered = false;
    $race_write_result = null;
    $repair_during_hash_read = static function ($query) use ($wpdb, $repaired, $race_hash, &$race_triggered, &$race_write_result) {
        if (! $race_triggered && stripos(ltrim($query), "SELECT user_pass FROM {$wpdb->users} ") === 0) {
            $race_triggered = true;
            $race_write_result = $wpdb->update($wpdb->users, array('user_pass' => $race_hash), array('ID' => (int) $repaired->ID));
        }
        return $query;
    };
    add_filter('query', $repair_during_hash_read);
    try {
        fast_wordpress_ensure_default_admin();
    } finally {
        remove_filter('query', $repair_during_hash_read);
    }
    $assert_same(true, $race_triggered, 'Concurrent repair runs after the initial user object read');
    $assert_same(1, $race_write_result, 'Concurrent repair changes the stored hash');
    $repaired = $assert_admin($login, $password, $email);
    $assert_same($race_hash, $repaired->user_pass, 'Updating email cannot overwrite a concurrently repaired password with a stale hash');

    // Removing only the role must be repaired even when password proof is cached.
    $warm_user_cache((int) $repaired->ID);
    $assert_same(1, $wpdb->update($wpdb->usermeta, array(
        'meta_value' => serialize(array('subscriber' => true)),
    ), array('user_id' => (int) $repaired->ID, 'meta_key' => $wpdb->get_blog_prefix() . 'capabilities')), 'Direct SQL changes the role alone');
    fast_wordpress_ensure_default_admin();
    $role_repaired = $assert_admin($login, $password, $email);
    $assert_same($repaired->user_pass, $role_repaired->user_pass, 'Role repair preserves a valid password');

    // Another worker can finish the same role repair before our metadata UPDATE.
    $role_race_id = (int) $repaired->ID;
    $capability_key = $wpdb->get_blog_prefix() . 'capabilities';
    $level_key = $wpdb->get_blog_prefix() . 'user_level';
    $assert_same(1, $wpdb->update($wpdb->usermeta, array(
        'meta_value' => serialize(array('subscriber' => true)),
    ), array('user_id' => $role_race_id, 'meta_key' => $capability_key)), 'Prepare a subscriber for concurrent role repair');
    $wpdb->update($wpdb->usermeta, array('meta_value' => '10'), array('user_id' => $role_race_id, 'meta_key' => $level_key));
    clean_user_cache($role_race_id);
    $assert_same(array('subscriber'), get_user_by('login', $login)->roles, 'Warm a stale subscriber role before concurrent repair');
    $assert_same('10', get_user_meta($role_race_id, $level_key, true), 'An unchanged user level cannot incidentally invalidate the stale role cache');
    $role_race_triggered = false;
    $role_race_write_result = null;
    $repair_during_role_update = static function ($query) use ($wpdb, $role_race_id, $capability_key, &$role_race_triggered, &$role_race_write_result) {
        if (
            ! $role_race_triggered
            && stripos(ltrim($query), "UPDATE `{$wpdb->usermeta}` SET ") === 0
            && strpos($query, $wpdb->prepare('`meta_key` = %s', $capability_key)) !== false
        ) {
            // Guard the nested SQL write without clearing this worker's user_meta cache.
            $role_race_triggered = true;
            $role_race_write_result = $wpdb->update($wpdb->usermeta, array(
                'meta_value' => serialize(array('administrator' => true)),
            ), array('user_id' => $role_race_id, 'meta_key' => $capability_key));
        }
        return $query;
    };
    add_filter('query', $repair_during_role_update);
    try {
        fast_wordpress_ensure_default_admin();
        $role_race_outer_result = $wpdb->rows_affected;
    } finally {
        remove_filter('query', $repair_during_role_update);
    }
    $assert_same(true, $role_race_triggered, 'Concurrent role repair runs immediately before the metadata UPDATE');
    $assert_same(1, $role_race_write_result, 'The other worker changes subscriber to administrator');
    $assert_same(0, $role_race_outer_result, 'The original metadata UPDATE affects no rows after concurrent repair');
    $stored_role = $wpdb->get_var($wpdb->prepare(
        "SELECT meta_value FROM {$wpdb->usermeta} WHERE user_id = %d AND meta_key = %s",
        $role_race_id,
        $capability_key
    ));
    $assert_same(array('administrator' => true), maybe_unserialize($stored_role), 'The database contains the repaired administrator role');
    $assert_same(array('administrator'), get_user_by('login', $login)->roles, 'A new user object sees the repaired role after a no-op metadata UPDATE');

    // A deleted database row must not survive through warmed user caches.
    $warm_user_cache((int) $repaired->ID);
    $assert_same(1, $wpdb->delete($wpdb->users, array('ID' => (int) $repaired->ID)), 'Direct SQL deletes the managed account');
    $wpdb->delete($wpdb->usermeta, array('user_id' => (int) $repaired->ID));
    fast_wordpress_ensure_default_admin();
    $recreated = $assert_admin($login, $password, $email);
    $assert_same(false, (int) $repaired->ID === (int) $recreated->ID, 'Deleted account is recreated with a new ID');
    $assert_stable($login, $password, $email);
    $snapshot_password = $password;
    $snapshot_hash = $read_user($login)->user_pass;
    $snapshot_proof = get_option($proof_option);

    $previous_password = $password;
    $password = "Zażółć gęślą jaźń 'quoted' \\path\\end € " . $suffix;
    putenv('WORDPRESS_ADMIN_PASSWORD=' . $password);
    fast_wordpress_ensure_default_admin();
    $updated = $assert_admin($login, $password, $email);
    $assert_same(false, wp_check_password(wp_slash($previous_password), $updated->user_pass, (int) $updated->ID), 'Changing the environment invalidates the previous password');
    $assert_stable($login, $password, $email);

    // Importing an old matching hash and proof cannot roll back desired credentials.
    $warm_user_cache((int) $updated->ID);
    $assert_same(1, $wpdb->update($wpdb->users, array('user_pass' => $snapshot_hash), array('ID' => (int) $updated->ID)), 'SQL import restores an old password hash');
    update_option($proof_option, $snapshot_proof, false);
    fast_wordpress_ensure_default_admin();
    $updated = $assert_admin($login, $password, $email);
    $assert_same(false, wp_check_password(wp_slash($snapshot_password), $updated->user_pass, (int) $updated->ID), 'Restoring an old proof cannot restore an old configured password');
    $assert_stable($login, $password, $email);
    $assert_same(false, $snapshot_proof === get_option($proof_option), 'Restoring an old proof produces proof for the current credentials');

    $previous_password = $password;
    $password = "Base64 密碼 'quoted' \\path\\new\nline " . $suffix;
    putenv('WORDPRESS_ADMIN_PASSWORD_BASE64=' . base64_encode($password));
    $assert_same($password, fast_wordpress_admin_credentials()['password'], 'Base64 credentials override the plain environment value');
    fast_wordpress_ensure_default_admin();
    $updated = $assert_admin($login, $password, $email);
    $assert_same(false, wp_check_password(wp_slash($previous_password), $updated->user_pass, (int) $updated->ID), 'Changing Base64 credentials invalidates the previous password');
    $assert_stable($login, $password, $email);

    $sentinel = new WP_Error('guardian_test_sentinel', 'Preserve previous authentication result');
    foreach (array(
        array($login, 'incorrect password'),
        array('unrelated_' . $login, $password),
        array('', $password),
        array($login, ''),
        array(array($login), $password),
        array($login, array($password)),
    ) as $attempt) {
        $username = is_string($attempt[0]) ? wp_slash($attempt[0]) : $attempt[0];
        $submitted_password = is_string($attempt[1]) ? wp_slash($attempt[1]) : $attempt[1];
        $assert_same($sentinel, fast_wordpress_force_admin_login($sentinel, $username, $submitted_password), 'Unmatched or malformed login preserves the previous result');
    }
    foreach (array($login, $email, strtoupper($email)) as $username) {
        $authenticated = fast_wordpress_force_admin_login($sentinel, wp_slash($username), wp_slash($password));
        $assert_same(true, $authenticated instanceof WP_User, 'Configured login or email authenticates');
        $assert_same((int) $updated->ID, (int) $authenticated->ID, 'Forced authentication returns the managed account');
    }

    putenv('WORDPRESS_ADMIN_PASSWORD_BASE64=invalid%base64');
    $assert_same(null, fast_wordpress_admin_credentials(), 'Invalid Base64 credentials fail closed');
    $hash_before = $read_user($login)->user_pass;
    fast_wordpress_ensure_default_admin();
    $assert_same($hash_before, $read_user($login)->user_pass, 'Invalid credentials do not rewrite the database hash');
    $assert_same($sentinel, fast_wordpress_force_admin_login($sentinel, wp_slash($login), wp_slash($password)), 'Invalid credentials cannot force authentication');
    putenv('WORDPRESS_ADMIN_PASSWORD_BASE64=' . base64_encode($password));

    // An imported legacy hash remains usable with WordPress password support.
    $warm_user_cache((int) $updated->ID);
    $assert_same(1, $wpdb->update($wpdb->users, array('user_pass' => md5(wp_slash($password))), array('ID' => (int) $updated->ID)), 'SQL import supplies a legacy WordPress hash');
    fast_wordpress_ensure_default_admin();
    $assert_admin($login, $password, $email);
    $assert_stable($login, $password, $email);

    // A plugin's custom password decision must never be hidden by cached proof.
    $filter_calls = 0;
    $reject_password = static function () use (&$filter_calls) {
        ++$filter_calls;
        return false;
    };
    $hash_before = $read_user($login)->user_pass;
    add_filter('check_password', $reject_password, 10, 4);
    try {
        fast_wordpress_ensure_default_admin();
        $assert_same(true, $filter_calls > 0, 'A rejecting password filter still runs after previous successful checks');
        $assert_same(false, $hash_before === $read_user($login)->user_pass, 'A rejecting password filter triggers the existing repair behavior');
    } finally {
        remove_filter('check_password', $reject_password, 10);
    }
    $assert_admin($login, $password, $email);

    $filter_calls = 0;
    $accept_password = static function () use (&$filter_calls) {
        ++$filter_calls;
        return true;
    };
    $hash_before = $read_user($login)->user_pass;
    add_filter('check_password', $accept_password, 10, 4);
    try {
        fast_wordpress_ensure_default_admin();
        $assert_same(true, $filter_calls > 0, 'An accepting password filter runs after a repair');
        $assert_same($hash_before, $read_user($login)->user_pass, 'An accepting password filter preserves the hash');
    } finally {
        remove_filter('check_password', $accept_password, 10);
    }

    $previous_login = $login;
    $login = 'guardian_changed_' . $suffix;
    $test_logins[] = $login;
    putenv('WORDPRESS_ADMIN_USER=' . $login);
    putenv('WORDPRESS_ADMIN_EMAIL=changed-' . $email);
    fast_wordpress_ensure_default_admin();
    $assert_admin($login, $password, 'changed-' . $email);
    $assert_same(true, is_object($read_user($previous_login)), 'Changing the configured login preserves unrelated existing accounts');

    $owner_result = wp_insert_user(array(
        'user_login' => 'guardian_owner_' . $suffix,
        'user_pass' => 'Unrelated email owner password ' . $suffix,
        'user_email' => 'owner-' . $email,
        'role' => 'subscriber',
    ));
    $assert_same(false, is_wp_error($owner_result), 'Create an existing owner of the requested email');
    $owner_id = (int) $owner_result;
    $owner_before = $wpdb->get_row($wpdb->prepare("SELECT * FROM {$wpdb->users} WHERE ID = %d", $owner_id));
    $login = 'guardian_collision_' . $suffix;
    $test_logins[] = $login;
    putenv('WORDPRESS_ADMIN_USER=' . $login);
    putenv('WORDPRESS_ADMIN_EMAIL=owner-' . $email);
    fast_wordpress_ensure_default_admin();
    $collision = $assert_admin($login, $password, '');
    $assert_same(false, $owner_id === (int) $collision->ID, 'An email collision cannot convert another account into the managed administrator');
    $owner_after = get_userdata($owner_id);
    $assert_same($owner_before->user_pass, $owner_after->user_pass, 'An email collision preserves the other account password');
    $assert_same(array('subscriber'), $owner_after->roles, 'An email collision preserves the other account role');
    $assert_stable($login, $password, '');

    // Releasing an email by SQL must be visible without a global cache flush.
    get_user_by('email', 'owner-' . $email);
    $assert_same(1, $wpdb->update($wpdb->users, array('user_email' => 'released-' . $email), array('ID' => $owner_id)), 'SQL import releases the requested email');
    fast_wordpress_ensure_default_admin();
    $assert_admin($login, $password, 'owner-' . $email);
} finally {
    foreach ($original_environment as $name => $value) {
        putenv($value === false ? $name : $name . '=' . $value);
    }
    require_once ABSPATH . 'wp-admin/includes/user.php';
    foreach ($test_logins as $test_login) {
        $row = $read_user($test_login);
        if ($row) {
            wp_delete_user((int) $row->ID);
        }
    }
    if ($owner_id > 0) {
        wp_delete_user($owner_id);
    }
}

WP_CLI::success('Default administrator behavior checks passed: ' . $assertions . '.');
