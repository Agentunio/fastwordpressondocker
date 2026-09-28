<?php

// Optionally pass the image's pinned memcached.php to exercise its actual method.
$delete_method = <<<'PHP'
	function delete( $id, $group = 'default' ) {
		$key = $this->key( $id, $group );

		if ( in_array( $group, $this->no_mc_groups ) ) {
			unset( $this->cache[ $key ] );

			return true;
		}

		$mc =& $this->get_mc( $group );

		$this->timer_start();
		$result = $mc->delete( $key );
		$elapsed = $this->timer_stop();

		$this->group_ops_stats( 'delete', $key, $group, null, $elapsed );

		if ( false !== $result ) {
			unset( $this->cache[ $key ] );
		}

		return $result;
	}
PHP;
$source = isset($argv[1]) ? file_get_contents($argv[1]) : "<?php\nclass WP_Object_Cache {\n$delete_method\n}\n";
if ($source === false) {
    throw new RuntimeException('Cannot read the supplied pinned drop-in.');
}

$assertions = 0;
$assert_same = static function ($expected, $actual, string $label) use (&$assertions): void {
    ++$assertions;
    if ($expected !== $actual) {
        throw new RuntimeException($label);
    }
};
$temporary = tempnam(sys_get_temp_dir(), 'memcached-delete-');
if ($temporary === false) {
    throw new RuntimeException('Cannot create the test fixture.');
}
$patch = static function (string $contents) use ($temporary): array {
    file_put_contents($temporary, $contents);
    $process = proc_open(
        [PHP_BINARY, dirname(__DIR__) . '/scripts/patch-memcached-dropin.php', $temporary],
        [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']],
        $pipes
    );
    if (!is_resource($process)) {
        throw new RuntimeException('Cannot run the patch helper.');
    }
    fclose($pipes[0]);
    $stdout = stream_get_contents($pipes[1]);
    $stderr = stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    return [proc_close($process), $stdout, $stderr];
};

class MemcachedDeleteBackend
{
    public $result = false;
    public array $deleted = [];

    public function delete($key)
    {
        $this->deleted[] = $key;
        return $this->result;
    }
}

class MemcachedDeleteHarness
{
    public array $cache = [];
    public array $no_mc_groups = ['local'];
    public array $operations = [];
    public MemcachedDeleteBackend $backend;

    public function __construct()
    {
        $this->backend = new MemcachedDeleteBackend();
    }

    public function key($id, $group)
    {
        return $group . ':' . $id;
    }

    public function &get_mc($group)
    {
        return $this->backend;
    }

    public function timer_start() {}

    public function timer_stop()
    {
        return 0.25;
    }

    public function group_ops_stats(...$arguments)
    {
        $this->operations[] = $arguments;
    }
}

$load_method = static function (string $contents, string $class): void {
    if (preg_match('/\tfunction delete\( \$id, \$group = \'default\' \) \{.*?\n\t\}/s', $contents, $matches) !== 1) {
        throw new RuntimeException('Cannot locate the pinned delete method.');
    }
    eval('class ' . $class . ' extends MemcachedDeleteHarness { ' . $matches[0] . ' }');
};

try {
    [$status, $patched, $stderr] = $patch($source);
    $assert_same(0, $status, 'The pinned source can be patched');
    $assert_same('', $stderr, 'Patching the pinned source emits no errors');
    $assert_same($source, file_get_contents($temporary), 'Patching does not modify the source');
    [$status, $second_pass, $stderr] = $patch($patched);
    $assert_same(0, $status, 'The patch is idempotent');
    $assert_same($patched, $second_pass, 'A second patch leaves all bytes unchanged');

    foreach (['<?php', $source . $source, $patched . $patched, $source . $patched,
        str_replace('false !== $result', 'true === $result', $source)] as $unsupported) {
        [$status, $output, $stderr] = $patch($unsupported);
        $assert_same(1, $status, 'Unknown or ambiguous implementations fail closed');
        $assert_same('', $output, 'An unsupported source cannot be installed through stdout');
        $assert_same(true, $stderr !== '', 'Refusal explains the unsupported source');
    }

    $load_method($source, 'OriginalMemcachedDelete');
    $load_method($patched, 'PatchedMemcachedDelete');
    $original = new OriginalMemcachedDelete();
    $original->cache['users:17'] = ['value' => 'stale role', 'found' => true];
    $assert_same(false, $original->delete(17, 'users'), 'The original backend reports an already missing key');
    $assert_same(true, isset($original->cache['users:17']), 'The original method reproduces stale local data');

    foreach ([false, true] as $backend_result) {
        foreach (['users', 'user_meta', 'default'] as $group) {
            $cache = new PatchedMemcachedDelete();
            $cache->backend->result = $backend_result;
            $key = $cache->key(17, $group);
            $cache->cache[$key] = ['value' => 'stale value', 'found' => true];
            $cache->cache['unrelated:19'] = ['value' => 'keep', 'found' => true];
            $assert_same($backend_result, $cache->delete(17, $group), 'The backend result is preserved');
            $assert_same(false, isset($cache->cache[$key]), 'Local data is invalidated even when shared deletion fails');
            $assert_same('keep', $cache->cache['unrelated:19']['value'], 'Unrelated local values survive');
            $assert_same([$key], $cache->backend->deleted, 'Deletion still reaches the selected shared key once');
            $assert_same([['delete', $key, $group, null, 0.25]], $cache->operations, 'Operation statistics remain unchanged');
            $cache->backend->result = false;
            $assert_same(false, $cache->delete(17, $group), 'Repeated deletion preserves the missing-key result');
            $assert_same(false, isset($cache->cache[$key]), 'Repeated deletion cannot revive stale data');
        }
    }

    $cache = new PatchedMemcachedDelete();
    $cache->cache['local:17'] = ['value' => 'local value', 'found' => true];
    $assert_same(true, $cache->delete(17, 'local'), 'Nonpersistent group deletion still succeeds');
    $assert_same(false, isset($cache->cache['local:17']), 'Nonpersistent group deletion clears its local value');
    $assert_same([], $cache->backend->deleted, 'Nonpersistent groups never call the backend');
    $assert_same([], $cache->operations, 'Nonpersistent groups retain their original statistics behavior');

    echo "PASS: $assertions Memcached delete invalidation assertions.\n";
} finally {
    unlink($temporary);
}
