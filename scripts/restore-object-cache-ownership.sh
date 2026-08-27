#!/bin/bash
set -euo pipefail

OBJECT_CACHE_OWNERSHIP_FILE="/snapshots/.fast-wordpress-object-cache-dropin"
SNAPSHOT_OWNERSHIP_FILE="/snapshots/state-0-object-cache-dropin"

validate_active_path() {
    if [ -L "$OBJECT_CACHE_OWNERSHIP_FILE" ]; then
        echo "ERROR: object cache ownership file cannot be a symbolic link." >&2
        return 1
    elif [ -e "$OBJECT_CACHE_OWNERSHIP_FILE" ] && [ ! -f "$OBJECT_CACHE_OWNERSHIP_FILE" ]; then
        echo "ERROR: object cache ownership path is not a regular file." >&2
        return 1
    fi
}

clear_active_ownership() {
    validate_active_path
    if [ -f "$OBJECT_CACHE_OWNERSHIP_FILE" ]; then
        rm -f -- "$OBJECT_CACHE_OWNERSHIP_FILE"
    fi
}

restore_snapshot_ownership() {
    local mode=""
    local dropin_hash=""
    local extra=""
    local temp_file

    if [ -L "$SNAPSHOT_OWNERSHIP_FILE" ]; then
        echo "ERROR: snapshot object cache ownership file cannot be a symbolic link." >&2
        return 1
    elif [ -e "$SNAPSHOT_OWNERSHIP_FILE" ] && [ ! -f "$SNAPSHOT_OWNERSHIP_FILE" ]; then
        echo "ERROR: snapshot object cache ownership path is not a regular file." >&2
        return 1
    elif [ ! -f "$SNAPSHOT_OWNERSHIP_FILE" ] \
        || [ "$(< "$SNAPSHOT_OWNERSHIP_FILE")" = "none" ]; then
        clear_active_ownership
        return 0
    fi

    read -r mode dropin_hash extra < "$SNAPSHOT_OWNERSHIP_FILE" || true
    case "$mode" in
        redis|memcached) ;;
        *)
            printf 'ERROR: invalid snapshot object cache ownership mode: %q\n' "$mode" >&2
            return 1
            ;;
    esac
    if [[ ! "$dropin_hash" =~ ^[0-9a-f]{64}$ ]] || [ -n "$extra" ]; then
        echo "ERROR: invalid snapshot object cache ownership hash." >&2
        return 1
    fi

    validate_active_path
    temp_file="$(mktemp /snapshots/.fast-wordpress-object-cache.tmp.XXXXXX)"
    if ! printf '%s %s\n' "$mode" "$dropin_hash" > "$temp_file"; then
        rm -f -- "$temp_file"
        return 1
    fi
    if ! mv -f -- "$temp_file" "$OBJECT_CACHE_OWNERSHIP_FILE"; then
        rm -f -- "$temp_file"
        return 1
    fi
}

case "${1:-}" in
    --from-state-zero)
        restore_snapshot_ownership
        ;;
    --clear)
        clear_active_ownership
        ;;
    *)
        printf 'ERROR: expected --from-state-zero or --clear, got: %q\n' "${1:-}" >&2
        exit 1
        ;;
esac
