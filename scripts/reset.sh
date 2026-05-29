#!/bin/bash
set -e

if [ ! -f /snapshots/state-0.sql ] || [ ! -f /snapshots/state-0-wp-content.tar.gz ] || [ ! -f /snapshots/state-0-wp-config.php ]; then
    echo "ERROR: snapshot state-0 not complete in /snapshots."
    echo "Expected: state-0.sql, state-0-wp-content.tar.gz, state-0-wp-config.php"
    exit 1
fi

cd /var/www/html

echo "Resetting database..."
wp --allow-root db reset --yes
wp --allow-root db import /snapshots/state-0.sql

echo "Wiping wp-content..."
# wp-content to bind-mount (punkt montowania) — nie da sie usunac samego katalogu,
# czyscimy tylko jego zawartosc (lacznie z plikami ukrytymi)
find /var/www/html/wp-content -mindepth 1 -delete

echo "Restoring wp-content from snapshot..."
tar xzf /snapshots/state-0-wp-content.tar.gz -C /var/www/html

echo "Restoring wp-config.php..."
cp /snapshots/state-0-wp-config.php /var/www/html/wp-config.php

chown -R www-data:www-data /var/www/html/wp-content /var/www/html/wp-config.php

echo "Reset complete. Everything back to state 0."
