<?php

// Run only on a disposable WordPress installation: wp eval-file tests/sync-wordpress-url.php.
if (! defined('WP_CLI') || ! WP_CLI) {
    exit(1);
}

$helper = '/scripts/sync-wordpress-url.php';
if (! is_file($helper)) {
    WP_CLI::error('Missing URL synchronization helper: ' . $helper);
}

global $wpdb;
$assertions = 0;
$assert_same = static function ($expected, $actual, $label) use (&$assertions) {
    ++$assertions;
    if ($expected !== $actual) {
        WP_CLI::error($label . ': expected ' . var_export($expected, true) . ', got ' . var_export($actual, true));
    }
};
$run = static function ($target, $success = true) use ($helper, $assert_same) {
    $result = WP_CLI::runcommand(
        'eval-file ' . escapeshellarg($helper) . ' ' . escapeshellarg($target),
        array('return' => 'all', 'exit_error' => false, 'launch' => true)
    );
    $assert_same($success, $result->return_code === 0, 'Helper exit status for ' . $target . ': ' . $result->stderr);
    wp_cache_flush();
};
$run_unchanged = static function ($target) use ($helper, $assert_same, $wpdb) {
    $cache_key = 'url_sync_noop_probe';
    $assert_same(true, wp_cache_set($cache_key, 'preserved', 'url_sync_test', 60), 'Create cache preservation probe');
    $queries = array();
    $record_query = static function ($query) use (&$queries) {
        $queries[] = $query;
        return $query;
    };
    add_filter('query', $record_query);
    try {
        (static function ($args) use ($helper) {
            require $helper;
        })(array($target));
    } finally {
        remove_filter('query', $record_query);
    }
    $assert_same('preserved', wp_cache_get($cache_key, 'url_sync_test'), 'Unchanged URL preserves object cache');
    $assert_same(1, count($queries), 'Unchanged URL performs one database query');
    $assert_same(1, preg_match('/^SELECT\\b/i', $queries[0]), 'Unchanged URL only reads the database');
    $assert_same(true, strpos($queries[0], $wpdb->options) !== false, 'Unchanged URL reads only options');
    wp_cache_delete($cache_key, 'url_sync_test');
};
$read_option = static function ($name) use ($wpdb) {
    return $wpdb->get_var($wpdb->prepare("SELECT option_value FROM {$wpdb->options} WHERE option_name = %s", $name));
};
$set_urls = static function ($home, $siteurl) {
    update_option('home', $home);
    update_option('siteurl', $siteurl);
    wp_cache_flush();
};
$database_snapshot = static function () use ($wpdb) {
    $tables = $wpdb->get_col($wpdb->prepare('SHOW TABLES LIKE %s', $wpdb->esc_like($wpdb->prefix) . '%'));
    $snapshot = array();
    foreach ($tables as $table) {
        $rows = $wpdb->get_results($wpdb->prepare('SELECT * FROM %i', $table), ARRAY_A);
        $rows = array_map('serialize', $rows);
        sort($rows, SORT_STRING);
        $snapshot[$table] = $rows;
    }
    ksort($snapshot);
    return $snapshot;
};
$assert_database_same = static function ($before, $after, $label) use ($assert_same) {
    $assert_same(array_keys($before), array_keys($after), $label . ': table names');
    foreach ($before as $table => $rows) {
        $removed = array_values(array_diff($rows, $after[$table]));
        $added = array_values(array_diff($after[$table], $rows));
        $assert_same($removed, $added, $label . ': changed rows in ' . $table);
    }
};

$base = 'http://localhost';
$set_urls($base, $base);
$page_id = wp_insert_post(array(
    'post_type' => 'page',
    'post_status' => 'publish',
    'post_title' => 'URL migration regression',
    'post_content' => '<a href="' . $base . '/page">Page</a>',
), true);
if (is_wp_error($page_id)) {
    WP_CLI::error($page_id->get_error_message());
}
$guid = $base . '/?page_id=' . $page_id;
$wpdb->update($wpdb->posts, array('guid' => $guid), array('ID' => $page_id));
$menu_id = wp_create_nav_menu('URL migration regression ' . $page_id);
if (is_wp_error($menu_id)) {
    WP_CLI::error($menu_id->get_error_message());
}
$menu_item_id = wp_update_nav_menu_item($menu_id, 0, array(
    'menu-item-title' => 'Migration link',
    'menu-item-type' => 'custom',
    'menu-item-url' => $base . '/menu',
    'menu-item-status' => 'publish',
));
if (is_wp_error($menu_item_id)) {
    WP_CLI::error($menu_item_id->get_error_message());
}

$meta_ids = array();
$write_meta = static function ($key, $value) use ($wpdb, $page_id, &$meta_ids) {
    if (isset($meta_ids[$key])) {
        $result = $wpdb->update($wpdb->postmeta, array('meta_value' => $value), array('meta_id' => $meta_ids[$key]));
    } else {
        $result = $wpdb->insert($wpdb->postmeta, array('post_id' => $page_id, 'meta_key' => $key, 'meta_value' => $value));
        $meta_ids[$key] = $wpdb->insert_id;
    }
    if ($result === false) {
        WP_CLI::error('Cannot write metadata fixture: ' . $key);
    }
};
$read_meta = static function ($key) use ($wpdb, &$meta_ids) {
    return $wpdb->get_var($wpdb->prepare("SELECT meta_value FROM {$wpdb->postmeta} WHERE meta_id = %d", $meta_ids[$key]));
};
$nested = static function ($url) {
    return array('nested' => array('url' => $url . '/nested', 'number' => 12, 'enabled' => true));
};
$write_meta('plain', $base . '/plain');
$write_meta('serialized', serialize($nested($base)));
$write_meta('json', wp_json_encode(array('url' => $base . '/json')));
$option_name = 'url_sync_regression_' . $page_id;
add_option($option_name, $nested($base), '', false);

$table = $wpdb->prefix . 'url_sync_regression';
if ($wpdb->get_var($wpdb->prepare('SHOW TABLES LIKE %s', $wpdb->esc_like($table)))) {
    WP_CLI::error('Regression table already exists; use a fresh disposable installation.');
}
$created = $wpdb->query($wpdb->prepare(
    'CREATE TABLE %i (record_key varchar(191) NOT NULL PRIMARY KEY, payload longtext NOT NULL, settings longtext NOT NULL)',
    $table
));
$assert_same(true, $created !== false, 'Create plugin table');
$primary_key = $base . '/plugin-row';
$inserted = $wpdb->insert($table, array(
    'record_key' => $primary_key,
    'payload' => $base . '/plugin',
    'settings' => serialize($nested($base)),
));
$assert_same(1, $inserted, 'Create plugin row');
$batch_table = $wpdb->prefix . 'url_sync_batches';
$assert_same(true, $wpdb->query($wpdb->prepare(
    'CREATE TABLE %i (group_id int NOT NULL, item_id int NOT NULL, payload text NOT NULL, PRIMARY KEY (group_id, item_id))',
    $batch_table
)) !== false, 'Create composite-key table');
for ($index = 0; $index < 505; $index++) {
    if ($wpdb->insert($batch_table, array(
        'group_id' => intdiv($index, 100),
        'item_id' => $index % 100,
        'payload' => $base . '/batch',
    )) === false) {
        WP_CLI::error('Cannot create batching fixture.');
    }
}

$unchanged = 'http://localhost.example/path http://localhost:820/path https://example.com/path';
$float_serialized = str_replace('d:1;', 'd:1.0;', serialize(array('number' => 1.0, 'url' => 'http://localhost.example/path')));
$assert_same(true, strpos($float_serialized, 'd:1.0;') !== false, 'Noncanonical float fixture');
$write_meta('boundaries', $unchanged);
$write_meta('float_unchanged', $float_serialized);

foreach (array('http://localhost:82', 'http://localhost:83', 'http://localhost') as $target) {
    $already_target = $target . '/already?ref=1';
    $key_only = str_replace('d:1;', 'd:1.0;', serialize(array($base . '/key-only' => 1.0)));
    $write_meta('already_target', $already_target);
    $write_meta('key_only', $key_only);
    $run($target);

    foreach (array('home', 'siteurl') as $name) {
        $assert_same($target, $read_option($name), $name . ' in raw DB');
        $assert_same($target, get_option($name), $name . ' through WordPress');
    }
    $content = '<a href="' . $target . '/page">Page</a>';
    $assert_same($content, $wpdb->get_var($wpdb->prepare("SELECT post_content FROM {$wpdb->posts} WHERE ID = %d", $page_id)), 'Page in raw DB');
    $assert_same($content, get_post($page_id)->post_content, 'Page through WordPress');
    $assert_same($guid, get_post($page_id)->guid, 'GUID preserved');
    $assert_same($target . '/plain', $read_meta('plain'), 'Plain metadata in raw DB');
    $assert_same($target . '/plain', get_post_meta($page_id, 'plain', true), 'Plain metadata through WordPress');
    $assert_same(serialize($nested($target)), $read_meta('serialized'), 'Serialized metadata in raw DB');
    $assert_same($nested($target), get_post_meta($page_id, 'serialized', true), 'Serialized metadata through WordPress');
    $assert_same(wp_json_encode(array('url' => $target . '/json')), $read_meta('json'), 'Escaped JSON in raw DB');
    $assert_same(array('url' => $target . '/json'), json_decode(get_post_meta($page_id, 'json', true), true), 'Escaped JSON through WordPress');
    $assert_same(serialize($nested($target)), $read_option($option_name), 'Serialized option in raw DB');
    $assert_same($nested($target), get_option($option_name), 'Serialized option through WordPress');
    $menu_url = $wpdb->get_var($wpdb->prepare(
        "SELECT meta_value FROM {$wpdb->postmeta} WHERE post_id = %d AND meta_key = %s",
        $menu_item_id,
        '_menu_item_url'
    ));
    $assert_same($target . '/menu', $menu_url, 'Custom menu URL in raw DB');
    $menu_items = wp_get_nav_menu_items($menu_id);
    $assert_same(1, count($menu_items), 'Custom menu item count');
    $assert_same($target . '/menu', $menu_items[0]->url, 'Custom menu URL through WordPress');
    $row = $wpdb->get_row($wpdb->prepare('SELECT * FROM %i', $table), ARRAY_A);
    $assert_same($primary_key, $row['record_key'], 'Plugin primary key preserved');
    $assert_same($target . '/plugin', $row['payload'], 'Plugin text migrated');
    $assert_same(serialize($nested($target)), $row['settings'], 'Plugin serialized data migrated');
    $assert_same('505', $wpdb->get_var($wpdb->prepare(
        'SELECT COUNT(*) FROM %i WHERE payload = %s',
        $batch_table,
        $target . '/batch'
    )), 'All batches with composite primary keys migrated');
    $assert_same($already_target, $read_meta('already_target'), 'Existing target preserved');
    $assert_same($unchanged, $read_meta('boundaries'), 'Other hosts and ports preserved');
    $assert_same($float_serialized, $read_meta('float_unchanged'), 'Unmatched serialization preserved byte for byte');
    $assert_same($key_only, $read_meta('key_only'), 'URL-only array key preserved byte for byte');

    $before = $database_snapshot();
    $run_unchanged($target);
    $assert_database_same($before, $database_snapshot(), 'Repeated migration is a DB no-op');
    $base = $target;
}

$set_urls('http://localhost', 'http://localhost/wp');
$target = 'http://localhost:84';
$write_meta('split_urls', 'http://localhost/page http://localhost/wp/wp-admin/');
$run($target);
$assert_same($target . '/page ' . $target . '/wp-admin/', $read_meta('split_urls'), 'Longest home/siteurl match wins');
$assert_same($target, $read_option('home'), 'Split home updated');
$assert_same($target, $read_option('siteurl'), 'Split siteurl updated');

$target = 'http://localhost:84/local/$1';
$write_meta('overlap', 'http://localhost:84/page ' . $target . '/already');
$write_meta('overlap_json', wp_json_encode(array('old' => 'http://localhost:84/json', 'target' => $target . '/already')));
$run($target);
$assert_same($target . '/page ' . $target . '/already', $read_meta('overlap'), 'Overlapping target and literal replacement dollar');
$assert_same(
    wp_json_encode(array('old' => $target . '/json', 'target' => $target . '/already')),
    $read_meta('overlap_json'),
    'Overlapping escaped JSON target and literal replacement dollar'
);

$before = $database_snapshot();
$run('javascript:alert(1)', false);
$assert_database_same($before, $database_snapshot(), 'Invalid target leaves the DB unchanged');

$set_urls('http://localhost', 'http://localhost');
$write_meta('retry', 'http://localhost/retry');
$failure_table = $wpdb->prefix . 'url_sync_failure';
$assert_same(true, $wpdb->query($wpdb->prepare(
    'CREATE TABLE %i (id int NOT NULL PRIMARY KEY, payload varchar(16) NOT NULL)',
    $failure_table
)) !== false, 'Create write-failure fixture');
$assert_same(1, $wpdb->insert($failure_table, array('id' => 1, 'payload' => 'http://localhost')), 'Insert write-failure fixture');
$run('http://localhost:82', false);
$assert_same('http://localhost', $read_option('home'), 'Failed migration preserves source home');
$assert_same('http://localhost', $read_option('siteurl'), 'Failed migration preserves source siteurl');
$assert_same('http://localhost:82/retry', $read_meta('retry'), 'Migration reached content before write failure');
$assert_same(true, $wpdb->query($wpdb->prepare(
    'ALTER TABLE %i MODIFY payload varchar(100) NOT NULL',
    $failure_table
)) !== false, 'Resolve write-failure fixture');
$run('http://localhost:82');
$assert_same('http://localhost:82/retry', $read_meta('retry'), 'Retry preserves already migrated content');
$assert_same('http://localhost:82', $wpdb->get_var($wpdb->prepare('SELECT payload FROM %i WHERE id = 1', $failure_table)), 'Retry completes pending content');
$assert_same('http://localhost:82', $read_option('home'), 'Retry updates home after success');

WP_CLI::success('PASS: ' . $assertions . ' URL migration assertions.');
