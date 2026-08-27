#!/bin/bash
set -euo pipefail

OBJECT_CACHE_MODE="${WORDPRESS_OBJECT_CACHE:-none}"
OBJECT_CACHE_DROPIN="/var/www/html/wp-content/object-cache.php"
OBJECT_CACHE_OWNERSHIP_FILE="/snapshots/.fast-wordpress-object-cache-dropin"

case "$OBJECT_CACHE_MODE" in
    none|redis|memcached) ;;
    *)
        printf 'ERROR: unsupported WORDPRESS_OBJECT_CACHE: %q\n' "$OBJECT_CACHE_MODE" >&2
        exit 1
        ;;
esac

detect_object_cache_dropin() {
    if [ -L "$OBJECT_CACHE_DROPIN" ]; then
        echo "unknown"
    elif [ ! -e "$OBJECT_CACHE_DROPIN" ]; then
        echo "none"
    elif [ ! -f "$OBJECT_CACHE_DROPIN" ]; then
        echo "unknown"
    elif grep -q "Plugin Name: Redis Object Cache" "$OBJECT_CACHE_DROPIN"; then
        echo "redis"
    elif grep -q "Plugin Name: Memcached" "$OBJECT_CACHE_DROPIN" \
        && grep -q "Install this file to wp-content/object-cache.php" "$OBJECT_CACHE_DROPIN"; then
        echo "memcached"
    else
        echo "unknown"
    fi
}

read_owned_dropin() {
    OWNED_DROPIN_MODE="none"
    OWNED_DROPIN_HASH=""

    if [ -L "$OBJECT_CACHE_OWNERSHIP_FILE" ]; then
        echo "ERROR: object cache ownership file cannot be a symbolic link." >&2
        return 1
    elif [ -e "$OBJECT_CACHE_OWNERSHIP_FILE" ] && [ ! -f "$OBJECT_CACHE_OWNERSHIP_FILE" ]; then
        echo "ERROR: object cache ownership path is not a regular file." >&2
        return 1
    elif [ ! -f "$OBJECT_CACHE_OWNERSHIP_FILE" ]; then
        return 0
    fi

    local extra=""
    read -r OWNED_DROPIN_MODE OWNED_DROPIN_HASH extra < "$OBJECT_CACHE_OWNERSHIP_FILE" || true

    case "$OWNED_DROPIN_MODE" in
        redis|memcached) ;;
        *)
            printf 'ERROR: unsupported object cache ownership mode: %q\n' "$OWNED_DROPIN_MODE" >&2
            return 1
            ;;
    esac

    if [[ ! "$OWNED_DROPIN_HASH" =~ ^[0-9a-f]{64}$ ]] || [ -n "$extra" ]; then
        echo "ERROR: invalid object cache ownership hash." >&2
        return 1
    fi
}

dropin_matches_ownership() {
    [ "$CURRENT_DROPIN" = "$OWNED_DROPIN_MODE" ] \
        && [ -f "$OBJECT_CACHE_DROPIN" ] \
        && [ "$(sha256sum "$OBJECT_CACHE_DROPIN" | awk '{print $1}')" = "$OWNED_DROPIN_HASH" ]
}

read_owned_dropin
CURRENT_DROPIN="$(detect_object_cache_dropin)"

if [ "$CURRENT_DROPIN" = "none" ]; then
    if [ -f "$OBJECT_CACHE_OWNERSHIP_FILE" ]; then
        rm -f -- "$OBJECT_CACHE_OWNERSHIP_FILE"
    fi
    exit 0
fi

if [ "$CURRENT_DROPIN" = "$OBJECT_CACHE_MODE" ]; then
    exit 0
fi

if dropin_matches_ownership; then
    echo "[object-cache] Removing managed ${CURRENT_DROPIN} drop-in before applying ${OBJECT_CACHE_MODE}."
    rm -f -- "$OBJECT_CACHE_DROPIN" "$OBJECT_CACHE_OWNERSHIP_FILE"
    exit 0
fi

echo "[object-cache] ERROR: refusing to remove or replace unmanaged wp-content/object-cache.php." >&2
echo "[object-cache] Remove or relocate that drop-in before selecting ${OBJECT_CACHE_MODE}." >&2
exit 1
