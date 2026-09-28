<?php

// Input: one line containing inspect Mounts JSON, then resolved Compose config JSON.
(static function () {
    $fail = static function ($message) {
        throw new RuntimeException($message);
    };
    $path = static function ($value, $host = false, $existing = false) use ($fail) {
        if (! is_string($value) || $value === '' || preg_match('/[\x00-\x1f]/', $value)) {
            $fail('Invalid storage path.');
        }
        // Only inspect output from a verified Desktop engine may use these VM aliases.
        if ($existing && getenv('FAST_WORDPRESS_DOCKER_DESKTOP') === '1') {
            $value = preg_replace('~^/(?:run/desktop/mnt/host|host_mnt)/([a-zA-Z])(?=/|$)~', '$1:', $value);
            if (strpos($value, '/host_mnt/') === 0) {
                $value = substr($value, strlen('/host_mnt'));
            }
        }
        if ($host && preg_match('~^[a-zA-Z]:~', $value)) {
            $value = str_replace('\\', '/', $value);
        }
        $drive_path = $host && preg_match('~^[a-zA-Z]:/~', $value);
        if (! $drive_path && substr($value, 0, 1) !== '/') {
            $fail('Storage paths must be absolute; use resolved Compose JSON.');
        }
        if (strpos($value, '//') !== false || strpos($value, '\\') !== false
            || preg_match('~(?:^|/)\.\.?(?:/|$)~', $value)) {
            $fail('Unsupported ambiguous storage path.');
        }
        $value = rtrim($value, '/');
        // Windows can enable case-sensitive directories; only the drive letter is folded.
        return $drive_path ? strtolower($value[0]) . substr($value, 1) : ($value === '' ? '/' : $value);
    };
    $relevant = static function ($target) use ($fail) {
        $core = '/var/www/html';
        if ($target === $core || $target === $core . '/wp-content') {
            return true;
        }
        if ($target === '/' || strpos($core, $target . '/') === 0
            || strpos($target, $core . '/') === 0) {
            $fail('Cannot verify overlapping WordPress storage mounts.');
        }
        return false;
    };
    $keys = static function ($object, $allowed) use ($fail) {
        if (! is_object($object) || array_diff(array_keys(get_object_vars($object)), $allowed)
            || in_array(null, get_object_vars($object), true)) {
            $fail('Unsupported content mount options.');
        }
    };
    $subpath = static function ($value) use ($path, $fail) {
        if (! is_string($value) || substr($value, 0, 1) === '/' || strpos($value, '\\') !== false) {
            $fail('Invalid volume subpath.');
        }
        return $value === '' ? '' : ltrim($path('/' . $value), '/');
    };

    try {
        $first_line = fgets(STDIN);
        if ($first_line === false) {
            $fail('Missing existing container mounts.');
        }
        $mounts = json_decode($first_line, false, 512, JSON_THROW_ON_ERROR);
        $config = json_decode(stream_get_contents(STDIN), false, 512, JSON_THROW_ON_ERROR);
        if (! is_array($mounts) || ! is_object($config)
            || ! isset($config->services->wordpress) || ! is_object($config->services->wordpress)) {
            $fail('Invalid existing mounts or resolved wordpress service configuration.');
        }
        $service = $config->services->wordpress;
        if (isset($service->volumes_from) || isset($service->tmpfs)) {
            $fail('Cannot verify volumes_from or service tmpfs mounts.');
        }
        if (property_exists($service, 'volumes') && ! is_array($service->volumes)) {
            $fail('Invalid Compose volumes list.');
        }
        $existing = array();
        foreach ($mounts as $mount) {
            if (! is_object($mount) || ! isset($mount->Destination)) {
                $fail('Invalid existing container mount.');
            }
            $target = $path($mount->Destination);
            if (! $relevant($target)) {
                continue;
            }
            if (isset($existing[$target]) || ! isset($mount->Type, $mount->RW) || $mount->RW !== true) {
                $fail('Invalid or duplicate existing content mount.');
            }
            if ($mount->Type === 'bind') {
                if (isset($mount->Propagation) && ! in_array($mount->Propagation, array('', 'rprivate'), true)) {
                    $fail('Unsupported existing bind propagation.');
                }
                $identity = array('bind', $path($mount->Source ?? null, true, true), '', false);
            } elseif ($mount->Type === 'volume') {
                if (! isset($mount->Name) || ! is_string($mount->Name) || $mount->Name === ''
                    || (isset($mount->Driver) && $mount->Driver !== 'local')) {
                    $fail('Cannot identify the existing named volume.');
                }
                // Docker reports the mounted subdirectory in Source, not consistently in SubPath.
                $source = $path($mount->Source ?? null);
                if (! preg_match('~/_data(?:/(.*))?$~', $source, $match)) {
                    $fail('Cannot verify the existing volume subpath.');
                }
                $suffix = $subpath($match[1] ?? '');
                if ($suffix !== '' || (property_exists($mount, 'SubPath') && $subpath($mount->SubPath) !== '')) {
                    $fail('Conflicting existing volume subpath metadata.');
                }
                $identity = array('volume', $mount->Name, $suffix, ! $mount->RW);
            } else {
                $fail('Unsupported existing content mount type.');
            }
            $existing[$target] = $identity;
        }

        $desired = array();
        foreach ($service->volumes ?? array() as $mount) {
            if (! is_object($mount) || ! isset($mount->target)) {
                $fail('Expected resolved long-form Compose mounts.');
            }
            $target = $path($mount->target);
            if (! $relevant($target)) {
                continue;
            }
            $keys($mount, array('type', 'source', 'target', 'read_only', 'bind', 'volume', 'consistency'));
            if (isset($desired[$target]) || ! isset($mount->type)
                || (isset($mount->read_only) && $mount->read_only !== false)
                || (isset($mount->consistency) && ! in_array($mount->consistency, array('', 'consistent'), true))) {
                $fail('Invalid or unsupported desired content mount.');
            }
            if ($mount->type === 'bind') {
                if (isset($mount->volume)) {
                    $fail('Invalid bind mount volume options.');
                }
                if (isset($mount->bind)) {
                    $keys($mount->bind, array('create_host_path', 'propagation'));
                    if ((isset($mount->bind->create_host_path) && ! is_bool($mount->bind->create_host_path))
                        || (isset($mount->bind->propagation) && ! in_array($mount->bind->propagation, array('', 'rprivate'), true))) {
                        $fail('Unsupported desired bind options.');
                    }
                }
                $identity = array('bind', $path($mount->source ?? null, true), '', $mount->read_only ?? false);
            } elseif ($mount->type === 'volume') {
                if (isset($mount->bind) || ! isset($mount->source) || ! is_string($mount->source)
                    || ! isset($config->volumes->{$mount->source}) || ! is_object($config->volumes->{$mount->source})) {
                    $fail('Cannot resolve the desired named volume.');
                }
                $definition = $config->volumes->{$mount->source};
                if (! isset($definition->name) || ! is_string($definition->name) || $definition->name === ''
                    || (isset($definition->driver) && $definition->driver !== 'local')
                    || ! empty((array) ($definition->driver_opts ?? array()))) {
                    $fail('Unsupported or unresolved desired volume definition.');
                }
                $suffix = '';
                if (isset($mount->volume)) {
                    $keys($mount->volume, array('subpath', 'nocopy'));
                    if (isset($mount->volume->nocopy) && $mount->volume->nocopy !== false) {
                        $fail('Unsupported desired volume nocopy option.');
                    }
                    $suffix = $subpath($mount->volume->subpath ?? '');
                    if ($suffix !== '') {
                        $fail('Cannot verify WordPress volume subpaths.');
                    }
                }
                $identity = array('volume', $definition->name, $suffix, $mount->read_only ?? false);
            } else {
                $fail('Unsupported desired content mount type.');
            }
            $desired[$target] = $identity;
        }
        ksort($existing);
        ksort($desired);
        if (count($existing) !== 2 || count($desired) !== 2) {
            $fail('Both WordPress core and wp-content storage must be explicit.');
        }
        if ($existing !== $desired) {
            $fail('WordPress content storage mapping would change and may hide existing uploads.');
        }
        fwrite(STDOUT, "WordPress content storage mapping unchanged.\n");
    } catch (Throwable $error) {
        fwrite(STDERR, 'Storage preflight refused: ' . $error->getMessage()
            . " Restore the previous mapping or explicitly migrate files before recreating WordPress.\n");
        exit(1);
    }
})();
