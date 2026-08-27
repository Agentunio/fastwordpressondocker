#!/bin/bash
set -euo pipefail

OBJECT_CACHE_MODE="${WORDPRESS_OBJECT_CACHE:-none}"
OBJECT_CACHE_STATE_FILE="/snapshots/.fast-wordpress-object-cache"

read_current_mode() {
    if [ -L "$OBJECT_CACHE_STATE_FILE" ]; then
        echo "ERROR: object cache state file cannot be a symbolic link." >&2
        return 1
    elif [ -e "$OBJECT_CACHE_STATE_FILE" ] && [ ! -f "$OBJECT_CACHE_STATE_FILE" ]; then
        echo "ERROR: object cache state path is not a regular file." >&2
        return 1
    elif [ -f "$OBJECT_CACHE_STATE_FILE" ]; then
        local saved_mode
        saved_mode="$(< "$OBJECT_CACHE_STATE_FILE")"
        case "$saved_mode" in
            none|redis|memcached)
                echo "$saved_mode"
                return 0
                ;;
            *)
                printf 'ERROR: unsupported object cache state value: %q\n' "$saved_mode" >&2
                return 1
                ;;
        esac
    fi

    echo "$OBJECT_CACHE_MODE"
}

flush_backend() {
    case "$1" in
        none)
            return 0
            ;;
        redis)
            if ! php -r '$cache = new Redis(); exit(@$cache->connect("redis", 6379, 1.0) && $cache->flushDB() ? 0 : 1);'; then
                echo "[object-cache] ERROR: could not flush Redis before replacing WordPress state." >&2
                return 1
            fi
            ;;
        memcached)
            if ! php -r '$cache = new Memcache(); exit(@$cache->connect("memcached", 11211, 1) && $cache->flush() ? 0 : 1);'; then
                echo "[object-cache] ERROR: could not flush Memcached before replacing WordPress state." >&2
                return 1
            fi
            ;;
        *)
            printf 'ERROR: unsupported WORDPRESS_OBJECT_CACHE: %q\n' "$1" >&2
            return 1
            ;;
    esac

    echo "[object-cache] Flushed $1 before replacing WordPress state."
}

CURRENT_MODE="$(read_current_mode)"
flush_backend "$CURRENT_MODE"

if [ "$OBJECT_CACHE_MODE" != "$CURRENT_MODE" ]; then
    flush_backend "$OBJECT_CACHE_MODE"
fi
