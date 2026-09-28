<?php

// Patch only the managed, pinned drop-in; never rewrite an imported drop-in.
if ($argc !== 2 || is_link($argv[1]) || !is_file($argv[1])) {
    fwrite(STDERR, "ERROR: expected a regular Memcached drop-in source file.\n");
    exit(1);
}

$source = file_get_contents($argv[1]);
if ($source === false) {
    fwrite(STDERR, "ERROR: cannot read the Memcached drop-in source.\n");
    exit(1);
}

$original = <<<'PHP'
		$this->group_ops_stats( 'delete', $key, $group, null, $elapsed );

		if ( false !== $result ) {
			unset( $this->cache[ $key ] );
		}

		return $result;
PHP;
$patched = <<<'PHP'
		$this->group_ops_stats( 'delete', $key, $group, null, $elapsed );

		// Another worker may have already deleted the shared key.
		unset( $this->cache[ $key ] );

		return $result;
PHP;

$original_count = substr_count($source, $original);
$patched_count = substr_count($source, $patched);
if ($original_count === 1 && $patched_count === 0) {
    $source = str_replace($original, $patched, $source);
} elseif ($original_count !== 0 || $patched_count !== 1) {
    fwrite(STDERR, "ERROR: unsupported Memcached delete implementation; refusing to install it.\n");
    exit(1);
}

if (fwrite(STDOUT, $source) !== strlen($source)) {
    fwrite(STDERR, "ERROR: cannot write the patched Memcached drop-in.\n");
    exit(1);
}
