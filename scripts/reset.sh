#!/bin/bash
set -e

for i in $(seq 1 120); do
    if [ -f /snapshots/state-0.sql ] && [ -f /snapshots/state-0-wp-content.tar.gz ] && [ -f /snapshots/state-0-wp-config.php ]; then
        break
    fi

    if [ "$i" -eq 1 ]; then
        echo "Waiting for state-0 snapshot..."
    fi

    sleep 1
done

if [ ! -f /snapshots/state-0.sql ] || [ ! -f /snapshots/state-0-wp-content.tar.gz ] || [ ! -f /snapshots/state-0-wp-config.php ]; then
    echo "ERROR: snapshot state-0 not complete in /snapshots."
    echo "Expected: state-0.sql, state-0-wp-content.tar.gz, state-0-wp-config.php"
    exit 1
fi

cd /var/www/html
WORDPRESS_URL="${WORDPRESS_URL:-http://localhost}"

if [ -f /snapshots/state-0-core-version ]; then
    SNAPSHOT_CORE_VERSION="$(cat /snapshots/state-0-core-version)"
    CURRENT_CORE_VERSION="$(wp --allow-root core version 2>/dev/null || echo "unknown")"
    if [ "$CURRENT_CORE_VERSION" != "$SNAPSHOT_CORE_VERSION" ]; then
        echo "Restoring WordPress core ${SNAPSHOT_CORE_VERSION} (currently ${CURRENT_CORE_VERSION})..."
        wp --allow-root core download --force --skip-content --version="$SNAPSHOT_CORE_VERSION"
    fi
fi

echo "Resetting database..."
wp --allow-root db reset --yes
wp --allow-root db import /snapshots/state-0.sql
wp --allow-root option update home "$WORDPRESS_URL"
wp --allow-root option update siteurl "$WORDPRESS_URL"

echo "Wiping wp-content..."
find /var/www/html/wp-content -mindepth 1 -delete

echo "Restoring wp-content from snapshot..."
tar xzf /snapshots/state-0-wp-content.tar.gz -C /var/www/html

echo "Restoring wp-config.php..."
cp /snapshots/state-0-wp-config.php /var/www/html/wp-config.php

bash /scripts/apply-optional-plugin.sh
bash /scripts/install-local-plugins.sh

chown -R www-data:www-data /var/www/html/wp-content /var/www/html/wp-config.php

echo "Reset complete. Restored state-0."
