<?php

// Run without Docker: php tests/check-wordpress-storage.php.
$mounts = [
    ['Type' => 'volume', 'Name' => 'example_wp_data', 'Source' => '/var/lib/docker/volumes/example_wp_data/_data', 'Destination' => '/var/www/html', 'RW' => true],
    ['Type' => 'bind', 'Source' => '/Users/example/project/wp-content', 'Destination' => '/var/www/html/wp-content', 'RW' => true],
    ['Type' => 'bind', 'Source' => '/Users/example/project/scripts', 'Destination' => '/scripts', 'RW' => false],
];
$configuration = [
    'services' => ['wordpress' => ['volumes' => [
        ['type' => 'volume', 'source' => 'wp_data', 'target' => '/var/www/html'],
        ['type' => 'bind', 'source' => '/Users/example/project/wp-content', 'target' => '/var/www/html/wp-content'],
        ['type' => 'bind', 'source' => '/Users/example/project/scripts', 'target' => '/scripts', 'read_only' => true],
    ]]],
    'volumes' => ['wp_data' => ['name' => 'example_wp_data']],
];
$assertions = 0;
$checkInput = static function (string $input, bool $accepted, string $label, bool $desktop = false) use (&$assertions): void {
    $process = proc_open([PHP_BINARY, '-n', __DIR__ . '/../scripts/check-wordpress-storage.php'], [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, null, ['FAST_WORDPRESS_DOCKER_DESKTOP' => $desktop ? '1' : '0']);
    fwrite($pipes[0], $input);
    fclose($pipes[0]);
    $output = stream_get_contents($pipes[1]) . stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    $status = proc_close($process);
    ++$assertions;
    if (($status === 0) !== $accepted) {
        throw new RuntimeException($label . ': unexpected validator result: ' . $output);
    }
};
$check = static function (array $actual, array $planned, bool $accepted, string $label, bool $desktop = false) use ($checkInput): void {
    $checkInput(json_encode($actual) . "\n" . json_encode($planned, JSON_PRETTY_PRINT), $accepted, $label, $desktop);
};
$check($mounts, $configuration, true, 'Unchanged storage');
foreach (['none', 'redis', 'memcached', 'none,https', 'redis,https', 'memcached,https'] as $profile) {
    $changed = $configuration;
    $changed['services']['wordpress']['environment'] = ['WORDPRESS_PORT' => '19889', 'WORDPRESS_URL' => 'https://localhost:19443', 'COMPOSE_PROFILES' => $profile];
    $changed['services']['wordpress']['ports'] = [['target' => 80, 'published' => '19889']];
    $check($mounts, $changed, true, 'Port, HTTPS and cache changes preserve storage: ' . $profile);
}
foreach (['other_wp_data', '', null] as $name) {
    $changed = $configuration;
    $changed['volumes']['wp_data']['name'] = $name;
    $check($mounts, $changed, false, 'Changed or missing resolved volume name');
}
foreach (['different-site', '0'] as $subpath) {
    $changed = $configuration;
    $changed['services']['wordpress']['volumes'][0]['volume']['subpath'] = $subpath;
    $check($mounts, $changed, false, 'Volume subpath switches are rejected');
}
foreach ([0, 1] as $index) {
    foreach (['source' => 'different-storage', 'type' => 'tmpfs', 'read_only' => true] as $key => $value) {
        $changed = $configuration;
        $changed['services']['wordpress']['volumes'][$index][$key] = $value;
        $check($mounts, $changed, false, 'Changed mount ' . $index . ': ' . $key);
    }
    $changed = $mounts;
    $changed[$index]['RW'] = false;
    $check($changed, $configuration, false, 'Existing storage must be writable');
    $changed = $configuration;
    unset($changed['services']['wordpress']['volumes'][$index]);
    $changed['services']['wordpress']['volumes'] = array_values($changed['services']['wordpress']['volumes']);
    $check($mounts, $changed, false, 'Missing protected mount');
    $changed = $mounts;
    $changed[] = $changed[$index];
    $check($changed, $configuration, false, 'Duplicate existing protected mount');
    $changed = $configuration;
    $changed['services']['wordpress']['volumes'][] = $changed['services']['wordpress']['volumes'][$index];
    $check($mounts, $changed, false, 'Duplicate planned protected mount');
}
foreach (['/', '/var', '/var/www', '/var/www/html/index.php', '/var/www/html/wp-content/uploads', '/var/./www', '/var/../var/www', '/var//www'] as $target) {
    $changed = $configuration;
    $changed['services']['wordpress']['volumes'][] = ['type' => 'bind', 'source' => '/other', 'target' => $target];
    $check($mounts, $changed, false, 'Overlapping mount: ' . $target);
}
foreach ([
    ['/host_mnt/Users/example/project/wp-content', '/Users/example/project/wp-content', false],
    ['/run/desktop/mnt/host/c/Project/wp-content', 'C:\\Project\\wp-content', false],
    ['C:\\Project\\wp-content', 'c:/Project/wp-content', true],
    ['/Users/example/Project with spaces/żółć/wp-content', '/Users/example/Project with spaces/żółć/wp-content', true],
    ['/Users/example/project/wp-content', '/Users/example/other/wp-content', false],
    ['/Users/example/project/wp-content', './wp-content', false],
    ['/Users/example/project/wp-content', '/Users/example/other/../project/wp-content', false],
    ['/c/project/wp-content', 'C:/project/wp-content', false],
    ['/Users/project\\wp-content', '/Users/project/wp-content', false],
    ['/Users/project/wp-content', '/Users/project\\wp-content', false],
] as [$actual, $planned, $accepted]) {
    $changedMounts = $mounts;
    $changedMounts[1]['Source'] = $actual;
    $changedConfiguration = $configuration;
    $changedConfiguration['services']['wordpress']['volumes'][1]['source'] = $planned;
    $check($changedMounts, $changedConfiguration, $accepted, 'Host path comparison');
}
$desktopMounts = $mounts;
$desktopMounts[1]['Source'] = '/host_mnt' . $mounts[1]['Source'];
$check($desktopMounts, $configuration, true, 'Verified Desktop inspect prefix resolves to the Compose host path', true);
$check($desktopMounts, $configuration, false, 'Linux must not guess Desktop paths');
$changed = $configuration;
$changed['services']['wordpress']['volumes'][1]['source'] = '/host_mnt' . $mounts[1]['Source'];
$check($mounts, $changed, false, 'Desktop normalization never alters the planned source', true);
$changed['services']['wordpress']['volumes'][1]['source'] = '/Users/example/other/wp-content';
$check($desktopMounts, $changed, false, 'Desktop still rejects a changed bind path', true);
foreach (['/host_mnt/c/Project/wp-content', '/run/desktop/mnt/host/c/Project/wp-content'] as $source) {
    $actual = $mounts;
    $actual[1]['Source'] = $source;
    $planned = $configuration;
    $planned['services']['wordpress']['volumes'][1]['source'] = 'C:\\Project\\wp-content';
    $check($actual, $planned, true, 'Verified Desktop Windows drive alias', true);
    $check($actual, $planned, false, 'Windows VM aliases require Desktop verification');
    $planned['services']['wordpress']['volumes'][1]['source'] = 'C:/project/wp-content';
    $check($actual, $planned, false, 'Windows directory case differences fail closed', true);
    $planned['services']['wordpress']['volumes'][1]['source'] = $source;
    $check($actual, $planned, false, 'Planned Windows VM aliases are never rewritten', true);
}
foreach (['/Users/project\\wp-content', '/Users//project/wp-content', '/Users/project/./wp-content', '//server/share'] as $source) {
    $actual = $mounts;
    $actual[1]['Source'] = $source;
    $planned = $configuration;
    $planned['services']['wordpress']['volumes'][1]['source'] = $source;
    $check($actual, $planned, false, 'Matching ambiguous host paths still fail closed');
}
foreach ([0, 1] as $index) {
    $actual = $mounts;
    $actual[$index]['RW'] = false;
    $planned = $configuration;
    $planned['services']['wordpress']['volumes'][$index]['read_only'] = true;
    $check($actual, $planned, false, 'Matching read-only storage is refused');
}
foreach (['/', '/var', '/var/www/html/index.php', '/var/www/html/wp-content/uploads'] as $target) {
    $actual = $mounts;
    $actual[] = ['Type' => 'bind', 'Source' => '/other', 'Destination' => $target, 'RW' => true];
    $planned = $configuration;
    $planned['services']['wordpress']['volumes'][] = ['type' => 'bind', 'source' => '/other', 'target' => $target];
    $check($actual, $planned, false, 'Matching overlapping storage is refused');
}
foreach (['child', '0', 'child/_data'] as $subpath) {
    $actual = $mounts;
    $actual[0]['Source'] .= '/' . $subpath;
    $actual[0]['SubPath'] = $subpath;
    $planned = $configuration;
    $planned['services']['wordpress']['volumes'][0]['volume']['subpath'] = $subpath;
    $check($actual, $planned, false, 'Matching volume subpaths are refused');
}
foreach (['volumes_from' => ['other'], 'tmpfs' => ['/var/www/html/wp-content']] as $key => $value) {
    $planned = $configuration;
    $planned['services']['wordpress'][$key] = $value;
    $check($mounts, $planned, false, 'Additional service mount mechanisms are refused');
}
foreach ([
    ['bind' => ['propagation' => 'rshared']],
    ['bind' => ['selinux' => 'z']],
    ['bind' => ['create_host_path' => 'false']],
    ['bind' => null],
    ['volume' => (object) []],
    ['consistency' => 'cached'],
    ['unrecognized' => true],
] as $options) {
    $planned = $configuration;
    $planned['services']['wordpress']['volumes'][1] += $options;
    $check($mounts, $planned, false, 'Unsupported desired bind mount options');
}
foreach ([['driver' => 'other'], ['driver_opts' => ['device' => '/other']]] as $options) {
    $planned = $configuration;
    $planned['volumes']['wp_data'] += $options;
    $check($mounts, $planned, false, 'Unsupported desired volume definition');
}
foreach ([['nocopy' => true], ['subpath' => null], ['unknown' => false]] as $options) {
    $planned = $configuration;
    $planned['services']['wordpress']['volumes'][0]['volume'] = $options;
    $check($mounts, $planned, false, 'Unsupported desired volume mount options');
}
foreach ([['Driver' => 'other'], ['Source' => '/unknown/location'], ['SubPath' => 'other']] as $options) {
    $actual = $mounts;
    $actual[0] = array_replace($actual[0], $options);
    $check($actual, $configuration, false, 'Unsupported actual volume metadata');
}
$actual = $mounts;
$actual[1]['Propagation'] = 'rshared';
$check($actual, $configuration, false, 'Unsupported actual bind propagation');
$planned = $configuration;
$planned['services']['wordpress']['volumes'][0]['volume'] = ['nocopy' => false, 'subpath' => ''];
$planned['services']['wordpress']['volumes'][1]['bind'] = ['create_host_path' => true, 'propagation' => 'rprivate'];
$planned['services']['wordpress']['volumes'][1]['consistency'] = 'consistent';
$check($mounts, $planned, true, 'Resolved Compose default mount options are accepted');
$actual = $mounts;
$actual[1] = ['Type' => 'volume', 'Name' => 'example_content', 'Source' => '/var/lib/docker/volumes/example_content/_data', 'Destination' => '/var/www/html/wp-content', 'RW' => true];
$planned = $configuration;
$planned['services']['wordpress']['volumes'][1] = ['type' => 'volume', 'source' => 'content', 'target' => '/var/www/html/wp-content'];
$planned['volumes']['content'] = ['name' => 'example_content', 'driver' => 'local'];
$check($actual, $planned, true, 'Safe unchanged content named volume remains supported');
$actual = $mounts;
$actual[0] = ['Type' => 'bind', 'Source' => '/Users/example/core', 'Destination' => '/var/www/html', 'RW' => true];
$planned = $configuration;
$planned['services']['wordpress']['volumes'][0] = ['type' => 'bind', 'source' => '/Users/example/core', 'target' => '/var/www/html'];
$check($actual, $planned, true, 'Safe unchanged core bind mount remains supported');
$check([], ['services' => ['wordpress' => ['volumes' => []]]], false, 'Empty mappings cannot establish storage safety');
foreach (["", "not-json\n{}", "[]\nnot-json", "null\n{}", "{}\n{}", "[]\n[]"] as $input) {
    $checkInput($input, false, 'Malformed or missing configuration fails closed');
}
echo "WordPress storage checks passed: {$assertions}.\n";
