#!/bin/bash
set -e

OPTIONAL_PLUGINS="${WORDPRESS_OPTIONAL_PLUGIN:-none}"

MANAGED_OPTIONAL_PLUGINS=(
    "all-in-one-wp-migration"
    "updraftplus"
    "advanced-custom-fields"
)

SELECTED_OPTIONAL_PLUGINS=()

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

for slug in "${MANAGED_OPTIONAL_PLUGINS[@]}"; do
    if optional_plugin_is_selected "$slug"; then
        if ! wp --allow-root plugin is-installed "$slug" 2>/dev/null; then
            echo "[plugins] Installing optional plugin: $slug"
            wp --allow-root plugin install "$slug"
        fi
        if ! wp --allow-root plugin is-active "$slug" 2>/dev/null; then
            wp --allow-root plugin activate "$slug"
        fi
    elif wp --allow-root plugin is-installed "$slug" 2>/dev/null; then
        echo "[plugins] Removing unselected optional plugin: $slug"
        if wp --allow-root plugin is-active "$slug" 2>/dev/null; then
            wp --allow-root plugin deactivate "$slug"
        fi
        wp --allow-root plugin delete "$slug"
    fi
done

if [ "${#SELECTED_OPTIONAL_PLUGINS[@]}" -eq 0 ]; then
    echo "[plugins] No optional plugins selected."
fi
