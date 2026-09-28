<?php

// Run without WordPress: php tests/default-admin-guardian-password.php.
// Separate processes exercise immutable WordPress authentication constants.
$case = $argv[1] ?? null;
if ($case === null) {
    $assertions = 0;
    $initial_hash = password_hash("fixture-pass\\word\"'", PASSWORD_BCRYPT, array('cost' => 4));
    $original_proof = '';
    foreach (array('core', 'hex-keys', 'rotated-key', 'rotated-salt', 'changed-db-host', 'changed-db-name', 'custom-checker', 'missing-key', 'missing-salt', 'short-key', 'short-salt', 'repeated-key', 'repeated-salt', 'default-key', 'default-salt', 'duplicate-keys', 'nonstring-key', 'nonstring-salt') as $child_case) {
        $process = proc_open(array(PHP_BINARY, __FILE__, $child_case, $initial_hash, $original_proof), array(1 => array('pipe', 'w'), 2 => array('pipe', 'w')), $pipes);
        if (! is_resource($process)) {
            throw new RuntimeException('Cannot start the isolated test process.');
        }
        $output = stream_get_contents($pipes[1]);
        $errors = stream_get_contents($pipes[2]);
        fclose($pipes[1]);
        fclose($pipes[2]);
        if (proc_close($process) !== 0) {
            throw new RuntimeException($child_case . ': ' . $errors . $output);
        }
        $result = json_decode($output, true);
        if (! is_array($result) || ! isset($result['assertions'])) {
            throw new RuntimeException('Invalid result from ' . $child_case . '.');
        }
        $assertions += $result['assertions'];
        if ($child_case === 'core') {
            $original_proof = $result['original_proof'];
        }
    }
    echo "Default administrator password unit checks passed: {$assertions}.\n";
    exit(0);
}

$assertions = 0;
function guardian_assert_same($expected, $actual, $label)
{
    ++$GLOBALS['assertions'];
    if ($expected !== $actual) {
        // Do not include password, hash, or proof values in failure output.
        throw new RuntimeException($label);
    }
}

class GuardianPasswordDatabase
{
    public $users = 'wp_users';
    public $last_error = '';
    public $hash;
    public $fail_read = false;
    public $suppressed = false;
    public $reads = 0;
    public $prepared_arguments = array();

    public function suppress_errors($suppress)
    {
        $previous = $this->suppressed;
        $this->suppressed = $suppress;
        return $previous;
    }

    public function prepare($query, ...$arguments)
    {
        $this->prepared_arguments = $arguments;
        return $query;
    }

    public function get_var($query)
    {
        ++$this->reads;
        guardian_assert_same(true, strpos($query, 'SELECT user_pass FROM ' . $this->users) === 0, 'Password checks query the current user table.');
        guardian_assert_same(true, strpos($query, 'WHERE ID = %d AND user_login = %s LIMIT 1') !== false, 'Password reads constrain both account ID and login.');
        $this->last_error = $this->fail_read ? 'Simulated database failure' : '';
        return $this->hash;
    }
}

function has_filter($tag)
{
    guardian_assert_same('check_password', $tag, 'Only password verification filters affect memoization.');
    return $GLOBALS['password_filter'];
}

function get_option($name)
{
    return $GLOBALS['guardian_options'][$name] ?? false;
}

function update_option($name, $value, $autoload = null)
{
    ++$GLOBALS['option_writes'];
    guardian_assert_same(false, $autoload, 'Verification proofs are not autoloaded.');
    if ($GLOBALS['fail_option_write']) {
        return false;
    }
    $GLOBALS['guardian_options'][$name] = $value;
    return true;
}

function delete_option($name)
{
    ++$GLOBALS['option_deletes'];
    unset($GLOBALS['guardian_options'][$name]);
    return true;
}

function guardian_reset()
{
    $GLOBALS['wpdb'] = new GuardianPasswordDatabase();
    $GLOBALS['wpdb']->hash = $GLOBALS['initial_hash'];
    $GLOBALS['wp_version'] = '6.8-test';
    $GLOBALS['wp_hasher'] = null;
    $GLOBALS['password_filter'] = false;
    $GLOBALS['guardian_options'] = array();
    $GLOBALS['password_checks'] = 0;
    $GLOBALS['checked_arguments'] = array();
    $GLOBALS['after_password_check'] = null;
    $GLOBALS['option_writes'] = 0;
    $GLOBALS['option_deletes'] = 0;
    $GLOBALS['fail_option_write'] = false;
}

$root = sys_get_temp_dir() . '/guardian-password-' . bin2hex(random_bytes(8));
if (! mkdir($root . '/wp-includes', 0700, true)) {
    throw new RuntimeException('Cannot create the isolated core fixture.');
}
$checker_source = <<<'PHP'
<?php
function wp_check_password($password, $hash, $user_id = '')
{
    ++$GLOBALS['password_checks'];
    $GLOBALS['checked_arguments'][] = array($password, $hash, $user_id);
    $matches = password_verify($password, $hash);
    if ($GLOBALS['after_password_check'] !== null) {
        $matches = ($GLOBALS['after_password_check'])($matches);
    }
    return $matches;
}
PHP;
file_put_contents($root . '/wp-includes/pluggable.php', $checker_source);
file_put_contents($root . '/custom-checker.php', $checker_source);
register_shutdown_function(static function () use ($root) {
    unlink($root . '/wp-includes/pluggable.php');
    unlink($root . '/custom-checker.php');
    rmdir($root . '/wp-includes');
    rmdir($root);
});
define('ABSPATH', $root . '/');
define('WPINC', 'wp-includes');
define('DB_HOST', $case === 'changed-db-host' ? 'other-test-database' : 'guardian-test-database');
define('DB_NAME', $case === 'changed-db-name' ? 'other-test-schema' : 'guardian-test');
$auth_key = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-key';
$auth_salt = 'ZYXWVUTSRQPONMLKJIHGFEDCBAzyxwvutsrqponmlkjihgfedcba9876543210-salt';
if ($case === 'short-key') {
    $auth_key = 'TooShort';
} elseif ($case === 'short-salt') {
    $auth_salt = 'TooShort';
} elseif ($case === 'repeated-key') {
    $auth_key = str_repeat('a', 64);
} elseif ($case === 'repeated-salt') {
    $auth_salt = str_repeat('a', 64);
} elseif ($case === 'default-key') {
    $auth_key = 'put your unique phrase here ' . $auth_key;
} elseif ($case === 'default-salt') {
    $auth_salt = 'put your unique phrase here ' . $auth_salt;
} elseif ($case === 'duplicate-keys') {
    $auth_salt = $auth_key;
} elseif ($case === 'nonstring-key') {
    $auth_key = 123456;
} elseif ($case === 'nonstring-salt') {
    $auth_salt = 123456;
} elseif ($case === 'hex-keys') {
    $auth_key = '0123456789abcde0123456789abcde0123456789';
    $auth_salt = 'edcba9876543210edcba9876543210edcba98765';
    guardian_assert_same(40, strlen($auth_key), 'The hexadecimal key fixture is 40 characters long.');
    guardian_assert_same(40, strlen($auth_salt), 'The hexadecimal salt fixture is 40 characters long.');
    guardian_assert_same(15, strlen(count_chars($auth_key, 3)), 'A valid hexadecimal key can have fewer than 16 distinct characters.');
} elseif ($case === 'rotated-key') {
    $auth_key = strrev($auth_key);
} elseif ($case === 'rotated-salt') {
    $auth_salt = strrev($auth_salt);
}
if ($case !== 'missing-key') {
    define('AUTH_KEY', $auth_key);
}
if ($case !== 'missing-salt') {
    define('AUTH_SALT', $auth_salt);
}
require $root . ($case === 'custom-checker' ? '/custom-checker.php' : '/wp-includes/pluggable.php');
require __DIR__ . '/../scripts/default-admin-guardian.php';

$password = "fixture-pass\\word\"'";
$initial_hash = $argv[2];
$option = 'fast_wordpress_admin_password_verified';
guardian_reset();

if (in_array($case, array('hex-keys', 'rotated-key', 'rotated-salt', 'changed-db-host', 'changed-db-name'), true)) {
    $guardian_options[$option] = $argv[3];
    guardian_assert_same(true, fast_wordpress_admin_password_matches($password, 7, 'test-admin'), 'Changed immutable configuration preserves real password verification.');
    guardian_assert_same(1, $password_checks, 'A marker from different authentication keys or database identity cannot skip verification.');
    guardian_assert_same(1, $option_writes, 'Strong keys, including hexadecimal keys, can store a proof.');
    guardian_assert_same(true, fast_wordpress_admin_password_matches($password, 7, 'test-admin'), 'A new proof is accepted under its current configuration.');
    guardian_assert_same(1, $password_checks, 'The current proof skips another expensive check.');
    echo json_encode(array('assertions' => $assertions));
    exit(0);
}

if ($case !== 'core') {
    guardian_assert_same(null, fast_wordpress_admin_password_signature($password, $initial_hash, 7, 'test-admin'), 'Unsupported checker or key configuration does not produce a proof.');
    for ($i = 0; $i < 2; ++$i) {
        guardian_assert_same(true, fast_wordpress_admin_password_matches($password, 7, 'test-admin'), 'Fallback preserves successful password verification.');
    }
    guardian_assert_same(2, $password_checks, 'Fallback verifies the password on every request.');
    guardian_assert_same(0, $option_writes, 'Fallback cannot persist an eligible proof.');
    guardian_assert_same(array(), $guardian_options, 'Fallback leaves the proof store empty.');
    echo json_encode(array('assertions' => $assertions));
    exit(0);
}

guardian_assert_same(true, fast_wordpress_admin_password_matches($password, '7', 'test-admin'), 'The first request verifies the password.');
guardian_assert_same(1, $password_checks, 'The first request performs one expensive check.');
guardian_assert_same(1, $option_writes, 'A successful first check stores one proof.');
$original_proof = $guardian_options[$option];
guardian_assert_same(64, strlen($guardian_options[$option]), 'The stored proof has the expected fixed digest size.');
guardian_assert_same(false, strpos($guardian_options[$option], $password) !== false, 'The proof does not contain the plaintext password.');
guardian_assert_same(true, fast_wordpress_admin_password_matches($password, 7, 'test-admin'), 'The second request accepts the verified inputs.');
guardian_assert_same(1, $password_checks, 'An unchanged password skips the expensive check.');
guardian_assert_same(2, $wpdb->reads, 'Every request still reads the current database hash.');
guardian_assert_same(array(7, 'test-admin'), $wpdb->prepared_arguments, 'The raw hash read uses the requested account identity.');
guardian_assert_same(7, $checked_arguments[0][2], 'The checker receives an integer user ID.');
guardian_assert_same(false, $wpdb->suppressed, 'Database error suppression is restored after successful reads.');

foreach (array('hash', 'password', 'user-id', 'login', 'wordpress-version', 'users-table') as $changed) {
    guardian_reset();
    fast_wordpress_admin_password_matches($password, 7, 'test-admin');
    $candidate = $password;
    $user_id = 7;
    $login = 'test-admin';
    if ($changed === 'hash') {
        $wpdb->hash = password_hash($password, PASSWORD_BCRYPT, array('cost' => 4));
    } elseif ($changed === 'password') {
        $candidate .= '-changed';
    } elseif ($changed === 'user-id') {
        $user_id = 8;
    } elseif ($changed === 'login') {
        $login = 'other-admin';
    } elseif ($changed === 'wordpress-version') {
        $wp_version = '6.9-test';
    } elseif ($changed === 'users-table') {
        $wpdb->users = 'restored_users';
    }
    guardian_assert_same($changed !== 'password', fast_wordpress_admin_password_matches($candidate, $user_id, $login), 'Changed input preserves the actual password result: ' . $changed . '.');
    guardian_assert_same(2, $password_checks, 'Changed input invalidates the proof: ' . $changed . '.');
}

foreach (array('deleted', 'tampered', 'array', 'boolean', 'integer') as $marker) {
    guardian_reset();
    fast_wordpress_admin_password_matches($password, 7, 'test-admin');
    if ($marker === 'deleted') {
        unset($guardian_options[$option]);
    } elseif ($marker === 'tampered') {
        $guardian_options[$option] = str_repeat('0', 64);
    } elseif ($marker === 'array') {
        $guardian_options[$option] = array('untrusted');
    } elseif ($marker === 'boolean') {
        $guardian_options[$option] = true;
    } else {
        $guardian_options[$option] = 123;
    }
    guardian_assert_same(true, fast_wordpress_admin_password_matches($password, 7, 'test-admin'), 'An invalid marker falls back to real verification: ' . $marker . '.');
    guardian_assert_same(2, $password_checks, 'An invalid marker cannot suppress real verification: ' . $marker . '.');
}

foreach (array('missing-row', 'database-error', 'invalid-row-type') as $failure) {
    guardian_reset();
    fast_wordpress_admin_password_matches($password, 7, 'test-admin');
    $proof = $guardian_options[$option];
    $wpdb->suppressed = true;
    if ($failure === 'missing-row') {
        $wpdb->hash = null;
    } elseif ($failure === 'database-error') {
        $wpdb->fail_read = true;
    } else {
        $wpdb->hash = false;
    }
    guardian_assert_same(null, fast_wordpress_admin_password_matches($password, 7, 'test-admin'), 'Unreadable account state aborts password decisions: ' . $failure . '.');
    guardian_assert_same(1, $password_checks, 'A failed read never invokes the password checker: ' . $failure . '.');
    guardian_assert_same(1, $option_writes, 'A failed read does not write a proof: ' . $failure . '.');
    guardian_assert_same(0, $option_deletes, 'A failed read does not delete an existing proof: ' . $failure . '.');
    guardian_assert_same($proof, $guardian_options[$option], 'A failed read leaves the stored proof unchanged: ' . $failure . '.');
    guardian_assert_same(true, $wpdb->suppressed, 'An existing error suppression setting is restored: ' . $failure . '.');
}

guardian_reset();
$fail_option_write = true;
guardian_assert_same(true, fast_wordpress_admin_password_matches($password, 7, 'test-admin'), 'A failed proof write still returns a verified match.');
guardian_assert_same(true, fast_wordpress_admin_password_matches($password, 7, 'test-admin'), 'A repeated request safely retries real verification after a failed proof write.');
guardian_assert_same(2, $password_checks, 'A failed proof write cannot create an in-memory cache hit.');
guardian_assert_same(2, $option_writes, 'A failed proof write is retried after real verification.');

guardian_reset();
fast_wordpress_admin_password_matches($password, 7, 'test-admin');
for ($i = 0; $i < 2; ++$i) {
    guardian_assert_same(false, fast_wordpress_admin_password_matches($password . '-incorrect', 7, 'test-admin'), 'An incorrect password remains incorrect.');
    guardian_assert_same(false, isset($guardian_options[$option]), 'An incorrect password removes the old positive proof.');
}
guardian_assert_same(3, $password_checks, 'Failed verification is never cached as a positive result.');
guardian_assert_same(1, $option_writes, 'Failed verification never writes a proof.');

guardian_reset();
$new_hash = password_hash('concurrent-password', PASSWORD_BCRYPT, array('cost' => 4));
$old_signature = fast_wordpress_admin_password_signature($password, $initial_hash, 7, 'test-admin');
$after_password_check = static function ($matches) use ($new_hash) {
    $GLOBALS['wpdb']->hash = $new_hash;
    return $matches;
};
guardian_assert_same(true, fast_wordpress_admin_password_matches($password, 7, 'test-admin'), 'A concurrent write does not change the result of the hash already checked.');
guardian_assert_same($old_signature, $guardian_options[$option], 'A proof binds the hash actually verified before a concurrent write.');
$after_password_check = null;
guardian_assert_same(false, fast_wordpress_admin_password_matches($password, 7, 'test-admin'), 'The next request observes the concurrent password change.');
guardian_assert_same(2, $password_checks, 'A concurrent password change requires a fresh real check.');

foreach (array('custom-hasher', 'filter-priority-zero', 'filter-priority-ten') as $override) {
    guardian_reset();
    fast_wordpress_admin_password_matches($password, 7, 'test-admin');
    if ($override === 'custom-hasher') {
        $wp_hasher = new stdClass();
    } else {
        $password_filter = $override === 'filter-priority-zero' ? 0 : 10;
    }
    $after_password_check = static function () {
        return false;
    };
    guardian_assert_same(false, fast_wordpress_admin_password_matches($password, 7, 'test-admin'), 'A customized verifier can reject a previously proven password: ' . $override . '.');
    guardian_assert_same(2, $password_checks, 'A custom verifier cannot be bypassed by an existing proof: ' . $override . '.');
    guardian_assert_same(false, isset($guardian_options[$option]), 'A custom rejection removes the previous proof: ' . $override . '.');
    $after_password_check = static function () {
        return true;
    };
    guardian_assert_same(true, fast_wordpress_admin_password_matches($password, 7, 'test-admin'), 'A custom positive result remains supported: ' . $override . '.');
    guardian_assert_same(1, $option_writes, 'A custom positive result is not memoized: ' . $override . '.');
}

echo json_encode(array('assertions' => $assertions, 'original_proof' => $original_proof));
