#!/bin/bash
set -e

OPTIONAL_PLUGINS="${WORDPRESS_OPTIONAL_PLUGIN:-none}"
OPTIONAL_PLUGIN_STATE_FILE="/snapshots/.fast-wordpress-optional-plugins"
PRESERVE_UNSELECTED=0

case "${1:-}" in
    "")
        ;;
    --preserve-unselected)
        PRESERVE_UNSELECTED=1
        ;;
    *)
        printf 'ERROR: unsupported argument: %q\n' "$1" >&2
        exit 1
        ;;
esac

if [ "$#" -gt 1 ]; then
    echo "ERROR: too many arguments." >&2
    exit 1
fi

MANAGED_OPTIONAL_PLUGINS=(
    "all-in-one-wp-migration"
    "updraftplus"
    "advanced-custom-fields"
)

SELECTED_OPTIONAL_PLUGINS=()
PREVIOUS_OPTIONAL_PLUGINS=()

optional_plugin_is_managed() {
    local requested_slug="$1"
    local managed_slug

    for managed_slug in "${MANAGED_OPTIONAL_PLUGINS[@]}"; do
        if [ "$managed_slug" = "$requested_slug" ]; then
            return 0
        fi
    done

    return 1
}

optional_plugin_is_selected() {
    local requested_slug="$1"
    local selected_slug

    for selected_slug in "${SELECTED_OPTIONAL_PLUGINS[@]}"; do
        if [ "$selected_slug" = "$requested_slug" ]; then
            return 0
        fi
    done

    return 1
}

optional_plugin_was_selected() {
    local requested_slug="$1"
    local selected_slug

    for selected_slug in "${PREVIOUS_OPTIONAL_PLUGINS[@]}"; do
        if [ "$selected_slug" = "$requested_slug" ]; then
            return 0
        fi
    done

    return 1
}

write_optional_plugin_state() {
    local state_dir="${OPTIONAL_PLUGIN_STATE_FILE%/*}"
    local state_value="none"
    local temp_file

    if [ -L "$OPTIONAL_PLUGIN_STATE_FILE" ]; then
        echo "ERROR: optional plugin state file cannot be a symbolic link." >&2
        return 1
    elif [ -e "$OPTIONAL_PLUGIN_STATE_FILE" ] && [ ! -f "$OPTIONAL_PLUGIN_STATE_FILE" ]; then
        echo "ERROR: optional plugin state path is not a regular file." >&2
        return 1
    fi

    mkdir -p -- "$state_dir"

    if [ "${#SELECTED_OPTIONAL_PLUGINS[@]}" -gt 0 ]; then
        state_value="$(IFS=,; printf '%s' "${SELECTED_OPTIONAL_PLUGINS[*]}")"
    fi

    temp_file="$(mktemp "$state_dir/.fast-wordpress-optional-plugins.tmp.XXXXXX")"
    if ! printf '%s\n' "$state_value" > "$temp_file"; then
        rm -f -- "$temp_file"
        return 1
    fi

    if ! mv -f -- "$temp_file" "$OPTIONAL_PLUGIN_STATE_FILE"; then
        rm -f -- "$temp_file"
        return 1
    fi
}

IFS=',' read -ra requested_optional_plugins <<< "$OPTIONAL_PLUGINS"

for slug in "${requested_optional_plugins[@]}"; do
    slug="${slug//[[:space:]]/}"

    case "$slug" in
        ""|"none")
            continue
            ;;
    esac

    if ! optional_plugin_is_managed "$slug"; then
        echo "ERROR: unsupported WORDPRESS_OPTIONAL_PLUGIN: $slug"
        exit 1
    fi

    if ! optional_plugin_is_selected "$slug"; then
        SELECTED_OPTIONAL_PLUGINS+=("$slug")
    fi
done

previous_optional_plugins_value="none"

if [ -L "$OPTIONAL_PLUGIN_STATE_FILE" ]; then
    echo "ERROR: optional plugin state file cannot be a symbolic link." >&2
    exit 1
elif [ -e "$OPTIONAL_PLUGIN_STATE_FILE" ] && [ ! -f "$OPTIONAL_PLUGIN_STATE_FILE" ]; then
    echo "ERROR: optional plugin state path is not a regular file." >&2
    exit 1
elif [ -f "$OPTIONAL_PLUGIN_STATE_FILE" ]; then
    previous_optional_plugins_value="$(< "$OPTIONAL_PLUGIN_STATE_FILE")"
fi

IFS=',' read -ra previous_optional_plugins <<< "$previous_optional_plugins_value"

for slug in "${previous_optional_plugins[@]}"; do
    slug="${slug//[[:space:]]/}"

    case "$slug" in
        ""|"none")
            continue
            ;;
    esac

    if ! optional_plugin_is_managed "$slug"; then
        printf 'ERROR: unsupported optional plugin state value: %q\n' "$slug" >&2
        exit 1
    fi

    if ! optional_plugin_was_selected "$slug"; then
        PREVIOUS_OPTIONAL_PLUGINS+=("$slug")
    fi
done

for slug in "${MANAGED_OPTIONAL_PLUGINS[@]}"; do
    if optional_plugin_is_selected "$slug"; then
        if ! wp --allow-root plugin is-installed "$slug" 2>/dev/null; then
            echo "[plugins] Installing optional plugin: $slug"
            wp --allow-root plugin install "$slug"
        fi
        if ! wp --allow-root plugin is-active "$slug" 2>/dev/null; then
            wp --allow-root plugin activate "$slug"
        fi
    elif [ "$PRESERVE_UNSELECTED" -eq 0 ] && optional_plugin_was_selected "$slug"; then
        if wp --allow-root plugin is-installed "$slug" 2>/dev/null; then
            echo "[plugins] Removing deselected optional plugin: $slug"
            if wp --allow-root plugin is-active "$slug" 2>/dev/null; then
                wp --allow-root plugin deactivate "$slug"
            fi
            wp --allow-root plugin delete "$slug"
        fi
    fi
done
write_optional_plugin_state

if [ "${#SELECTED_OPTIONAL_PLUGINS[@]}" -eq 0 ]; then
    echo "[plugins] No optional plugins selected."
fi
