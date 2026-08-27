#!/bin/bash
set -euo pipefail

cd /var/www/html

OBJECT_CACHE_MODE="${WORDPRESS_OBJECT_CACHE:-none}"
OBJECT_CACHE_STATE_FILE="/snapshots/.fast-wordpress-object-cache"
OBJECT_CACHE_DROPIN="/var/www/html/wp-content/object-cache.php"
OBJECT_CACHE_OWNERSHIP_FILE="/snapshots/.fast-wordpress-object-cache-dropin"
REDIS_PLUGIN_STATE_FILE="/snapshots/.fast-wordpress-redis-plugin-installed"
REDIS_PLUGIN_SOURCE="/usr/local/share/wordpress-object-cache/redis-cache.zip"
MEMCACHED_DROPIN_SOURCE="/usr/local/share/wordpress-object-cache/memcached.php"
MEMCACHED_KEY_SALT="fast-wordpress-on-docker"
FLUSH_CACHE=0

case "${1:-}" in
    "") ;;
    --flush) FLUSH_CACHE=1 ;;
    *)
        printf 'ERROR: unsupported argument: %q\n' "$1" >&2
        exit 1
        ;;
esac

if [ "$#" -gt 1 ]; then
    echo "ERROR: too many arguments." >&2
    exit 1
fi

case "$OBJECT_CACHE_MODE" in
    none|redis|memcached) ;;
    *)
        printf 'ERROR: unsupported WORDPRESS_OBJECT_CACHE: %q\n' "$OBJECT_CACHE_MODE" >&2
        exit 1
        ;;
esac

detect_object_cache_dropin() {
    if [ -L "$OBJECT_CACHE_DROPIN" ] || { [ -e "$OBJECT_CACHE_DROPIN" ] && [ ! -f "$OBJECT_CACHE_DROPIN" ]; }; then
        echo "unknown"
    elif [ ! -e "$OBJECT_CACHE_DROPIN" ]; then
        echo "none"
    elif grep -q "Plugin Name: Redis Object Cache" "$OBJECT_CACHE_DROPIN"; then
        echo "redis"
    elif grep -q "Plugin Name: Memcached" "$OBJECT_CACHE_DROPIN" \
        && grep -q "Install this file to wp-content/object-cache.php" "$OBJECT_CACHE_DROPIN"; then
        echo "memcached"
    else
        echo "unknown"
    fi
}

read_previous_mode() {
    if [ -L "$OBJECT_CACHE_STATE_FILE" ]; then
        echo "ERROR: object cache state file cannot be a symbolic link." >&2
        return 1
    elif [ -e "$OBJECT_CACHE_STATE_FILE" ] && [ ! -f "$OBJECT_CACHE_STATE_FILE" ]; then
        echo "ERROR: object cache state path is not a regular file." >&2
        return 1
    elif [ -f "$OBJECT_CACHE_STATE_FILE" ]; then
        local previous_mode
        previous_mode="$(< "$OBJECT_CACHE_STATE_FILE")"
        case "$previous_mode" in
            none|redis|memcached)
                echo "$previous_mode"
                return 0
                ;;
            *)
                printf 'ERROR: unsupported object cache state value: %q\n' "$previous_mode" >&2
                return 1
                ;;
        esac
    fi

    echo "none"
}

write_state_value() {
    local path="$1"
    local value="$2"
    local state_dir="${path%/*}"
    local temp_file

    if [ -L "$path" ]; then
        printf 'ERROR: state file cannot be a symbolic link: %s\n' "$path" >&2
        return 1
    elif [ -e "$path" ] && [ ! -f "$path" ]; then
        printf 'ERROR: state path is not a regular file: %s\n' "$path" >&2
        return 1
    fi

    mkdir -p -- "$state_dir"
    temp_file="$(mktemp "$state_dir/.fast-wordpress-object-cache.tmp.XXXXXX")"

    if ! printf '%s\n' "$value" > "$temp_file"; then
        rm -f -- "$temp_file"
        return 1
    fi

    if ! mv -f -- "$temp_file" "$path"; then
        rm -f -- "$temp_file"
        return 1
    fi
}

write_current_mode() {
    write_state_value "$OBJECT_CACHE_STATE_FILE" "$OBJECT_CACHE_MODE"
}

record_dropin_ownership() {
    local mode="$1"
    local dropin_hash

    dropin_hash="$(sha256sum "$OBJECT_CACHE_DROPIN" | awk '{print $1}')"
    write_state_value "$OBJECT_CACHE_OWNERSHIP_FILE" "$mode $dropin_hash"
}

dropin_is_managed() {
    local owned_mode=""
    local owned_hash=""
    local extra=""

    if [ -L "$OBJECT_CACHE_OWNERSHIP_FILE" ]; then
        echo "ERROR: object cache ownership file cannot be a symbolic link." >&2
        return 2
    elif [ -e "$OBJECT_CACHE_OWNERSHIP_FILE" ] && [ ! -f "$OBJECT_CACHE_OWNERSHIP_FILE" ]; then
        echo "ERROR: object cache ownership path is not a regular file." >&2
        return 2
    elif [ ! -f "$OBJECT_CACHE_OWNERSHIP_FILE" ] || [ ! -f "$OBJECT_CACHE_DROPIN" ]; then
        return 1
    fi

    read -r owned_mode owned_hash extra < "$OBJECT_CACHE_OWNERSHIP_FILE" || true
    if [ "$owned_mode" != "$1" ] \
        || [[ ! "$owned_hash" =~ ^[0-9a-f]{64}$ ]] \
        || [ -n "$extra" ]; then
        return 1
    fi

    [ "$(sha256sum "$OBJECT_CACHE_DROPIN" | awk '{print $1}')" = "$owned_hash" ]
}

delete_config_constant() {
    wp --allow-root config delete "$1" --type=constant >/dev/null 2>&1 || true
}

delete_config_variable() {
    wp --allow-root config delete "$1" --type=variable >/dev/null 2>&1 || true
}

delete_constant_if_value() {
    local name="$1"
    local expected="$2"
    local actual

    actual="$(wp --allow-root config get "$name" --type=constant 2>/dev/null || true)"
    if [ "$actual" = "$expected" ]; then
        delete_config_constant "$name"
    fi
}

remove_unselected_config() {
    if [ "$OBJECT_CACHE_MODE" != "redis" ]; then
        delete_constant_if_value WP_REDIS_HOST redis
        delete_constant_if_value WP_REDIS_PORT 6379
        delete_constant_if_value WP_REDIS_CLIENT phpredis
        delete_constant_if_value WP_REDIS_PREFIX fast-wordpress-on-docker:
        delete_constant_if_value WP_REDIS_GRACEFUL 1
        delete_constant_if_value WP_REDIS_GRACEFUL true
    fi

    if [ "$OBJECT_CACHE_MODE" != "memcached" ]; then
        if [ "$PREVIOUS_MODE" = "memcached" ] || [ "$RESTORED_DROPIN" = "memcached" ]; then
            delete_config_variable memcached_servers
        fi
        delete_constant_if_value WP_CACHE_KEY_SALT "$MEMCACHED_KEY_SALT"
    fi
}

mark_redis_plugin_installed() {
    write_state_value "$REDIS_PLUGIN_STATE_FILE" installed
}

deactivate_managed_redis_plugin() {
    if [ -L "$REDIS_PLUGIN_STATE_FILE" ]; then
        echo "ERROR: Redis plugin state file cannot be a symbolic link." >&2
        return 1
    elif [ -e "$REDIS_PLUGIN_STATE_FILE" ] && [ ! -f "$REDIS_PLUGIN_STATE_FILE" ]; then
        echo "ERROR: Redis plugin state path is not a regular file." >&2
        return 1
    elif [ ! -f "$REDIS_PLUGIN_STATE_FILE" ]; then
        return 0
    elif [ "$(< "$REDIS_PLUGIN_STATE_FILE")" != "installed" ]; then
        echo "ERROR: invalid Redis plugin state value." >&2
        return 1
    fi

    if wp --allow-root plugin is-active redis-cache --skip-plugins --skip-themes 2>/dev/null; then
        echo "[object-cache] Deactivating the managed Redis Object Cache plugin."
        wp --allow-root plugin deactivate redis-cache --skip-plugins --skip-themes
    fi
}

wait_for_cache_server() {
    local attempt

    for attempt in $(seq 1 60); do
        case "$OBJECT_CACHE_MODE" in
            redis)
                php -r '$cache = new Redis(); exit(@$cache->connect("redis", 6379, 1.0) ? 0 : 1);' \
                    >/dev/null 2>&1 && return 0
                ;;
            memcached)
                php -r '$cache = new Memcache(); exit(@$cache->connect("memcached", 11211, 1) ? 0 : 1);' \
                    >/dev/null 2>&1 && return 0
                ;;
        esac

        if [ "$attempt" -eq 1 ]; then
            echo "[object-cache] Waiting for ${OBJECT_CACHE_MODE} server..."
        fi
        sleep 1
    done

    echo "[object-cache] ERROR: ${OBJECT_CACHE_MODE} server is unavailable." >&2
    return 1
}

flush_cache_server() {
    case "$OBJECT_CACHE_MODE" in
        redis)
            php -r '$cache = new Redis(); exit($cache->connect("redis", 6379, 1.0) && $cache->flushDB() ? 0 : 1);'
            ;;
        memcached)
            php -r '$cache = new Memcache(); exit($cache->connect("memcached", 11211, 1) && $cache->flush() ? 0 : 1);'
            ;;
        none)
            return 0
            ;;
    esac

    echo "[object-cache] Flushed ${OBJECT_CACHE_MODE}."
}

verify_persistent_cache() {
    local cache_key="fast_wordpress_probe_$$"
    local cache_value="cache-ok-$$"
    local stored_value

    wp --allow-root cache set "$cache_key" "$cache_value" fast_wordpress 60 >/dev/null
    stored_value="$(wp --allow-root cache get "$cache_key" fast_wordpress)"
    wp --allow-root cache delete "$cache_key" fast_wordpress >/dev/null || true

    if [ "$stored_value" != "$cache_value" ]; then
        echo "[object-cache] ERROR: persistent cache verification failed." >&2
        return 1
    fi
}

PREVIOUS_MODE="$(read_previous_mode)"
RESTORED_DROPIN="$(detect_object_cache_dropin)"

bash /scripts/prepare-object-cache.sh
remove_unselected_config

case "$OBJECT_CACHE_MODE" in
    none)
        deactivate_managed_redis_plugin
        write_current_mode
        echo "[object-cache] Persistent object cache disabled."
        ;;
    redis)
        if ! php -m | grep -qx redis; then
            echo "[object-cache] ERROR: PHP redis extension is not installed." >&2
            exit 1
        fi
        if [ ! -f "$REDIS_PLUGIN_SOURCE" ]; then
            echo "[object-cache] ERROR: pinned Redis Object Cache plugin is missing from the image." >&2
            exit 1
        fi

        wait_for_cache_server
        if [ "$FLUSH_CACHE" -eq 1 ]; then
            flush_cache_server
        fi

        wp --allow-root config set WP_REDIS_HOST redis
        wp --allow-root config set WP_REDIS_PORT 6379 --raw
        wp --allow-root config set WP_REDIS_CLIENT phpredis
        wp --allow-root config set WP_REDIS_PREFIX fast-wordpress-on-docker:
        wp --allow-root config set WP_REDIS_GRACEFUL true --raw

        if ! wp --allow-root plugin is-installed redis-cache --skip-plugins --skip-themes 2>/dev/null; then
            echo "[object-cache] Installing pinned Redis Object Cache plugin."
            wp --allow-root plugin install "$REDIS_PLUGIN_SOURCE" --skip-plugins --skip-themes
            mark_redis_plugin_installed
        fi
        if ! wp --allow-root plugin is-active redis-cache --skip-plugins --skip-themes 2>/dev/null; then
            wp --allow-root plugin activate redis-cache --skip-plugins --skip-themes
        fi

        current_dropin="$(detect_object_cache_dropin)"
        managed_dropin=0
        managed_status=0
        dropin_is_managed redis || managed_status=$?
        if [ "$managed_status" -eq 0 ]; then
            managed_dropin=1
        elif [ "$managed_status" -eq 2 ]; then
            exit 1
        fi

        if [ "$current_dropin" = "none" ] || [ "$managed_dropin" -eq 1 ]; then
            wp --allow-root redis enable --force
            record_dropin_ownership redis
        else
            echo "[object-cache] Preserving the existing unmanaged Redis drop-in."
        fi

        if [ "$FLUSH_CACHE" -eq 1 ]; then
            flush_cache_server
        fi
        verify_persistent_cache
        write_current_mode
        echo "[object-cache] Redis object cache enabled and verified."
        ;;
    memcached)
        if ! php -m | grep -qx memcache; then
            echo "[object-cache] ERROR: PHP memcache extension is not installed." >&2
            exit 1
        fi
        if [ ! -f "$MEMCACHED_DROPIN_SOURCE" ]; then
            echo "[object-cache] ERROR: managed Memcached drop-in is missing from the image." >&2
            exit 1
        fi

        wait_for_cache_server
        if [ "$FLUSH_CACHE" -eq 1 ]; then
            flush_cache_server
        fi
        deactivate_managed_redis_plugin
        wp --allow-root config set memcached_servers \
            "array( 'default' => array( 'memcached:11211' ) )" \
            --raw --type=variable
        wp --allow-root config set WP_CACHE_KEY_SALT "$MEMCACHED_KEY_SALT"

        current_dropin="$(detect_object_cache_dropin)"
        managed_dropin=0
        managed_status=0
        dropin_is_managed memcached || managed_status=$?
        if [ "$managed_status" -eq 0 ]; then
            managed_dropin=1
        elif [ "$managed_status" -eq 2 ]; then
            exit 1
        fi

        if [ "$current_dropin" = "none" ] || [ "$managed_dropin" -eq 1 ]; then
            install -o www-data -g www-data -m 644 \
                "$MEMCACHED_DROPIN_SOURCE" "$OBJECT_CACHE_DROPIN"
            record_dropin_ownership memcached
        else
            echo "[object-cache] Preserving the existing unmanaged Memcached drop-in."
        fi

        if [ "$FLUSH_CACHE" -eq 1 ]; then
            flush_cache_server
        fi
        verify_persistent_cache
        write_current_mode
        echo "[object-cache] Memcached object cache enabled and verified."
        ;;
esac
