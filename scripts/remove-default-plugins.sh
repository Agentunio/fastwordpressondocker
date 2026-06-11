#!/bin/bash
set -e

cd /var/www/html

# Remove the plugins WordPress ships with by default.
for plugin in akismet hello hello-dolly; do
    if wp --allow-root plugin is-installed "$plugin" 2>/dev/null; then
        echo "Removing default plugin: $plugin"
        wp --allow-root plugin delete "$plugin"
    fi
done
