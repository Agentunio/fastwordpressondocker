#!/bin/bash
set -e

FREE_PLUGINS=(
    "advanced-custom-fields"
)

for slug in "${FREE_PLUGINS[@]}"; do
    if ! wp --allow-root plugin is-installed "$slug" 2>/dev/null; then
        echo "[plugins] Installing free plugin: $slug"
        wp --allow-root plugin install "$slug"
    fi
    if ! wp --allow-root plugin is-active "$slug" 2>/dev/null; then
        wp --allow-root plugin activate "$slug"
    fi
done
