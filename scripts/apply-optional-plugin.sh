#!/bin/bash
set -e

OPTIONAL_PLUGIN="${WORDPRESS_OPTIONAL_PLUGIN:-none}"

MANAGED_OPTIONAL_PLUGINS=(
    "all-in-one-wp-migration"
    "updraftplus"
)

case "$OPTIONAL_PLUGIN" in
    "none"|""|"all-in-one-wp-migration"|"updraftplus")
        ;;
    *)
        echo "ERROR: unsupported WORDPRESS_OPTIONAL_PLUGIN: $OPTIONAL_PLUGIN"
        exit 1
        ;;
esac

for slug in "${MANAGED_OPTIONAL_PLUGINS[@]}"; do
    if [ "$slug" = "$OPTIONAL_PLUGIN" ]; then
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

if [ "$OPTIONAL_PLUGIN" = "none" ] || [ -z "$OPTIONAL_PLUGIN" ]; then
    echo "[plugins] No optional plugin selected."
fi
