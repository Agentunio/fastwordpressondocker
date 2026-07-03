#!/bin/bash
set -e

cd /var/www/html

if ! wp --allow-root core is-installed 2>/dev/null; then
    echo "ERROR: WordPress is not installed yet."
    exit 1
fi

mkdir -p /snapshots

bash /scripts/remove-default-plugins.sh

echo "Overwriting state-0 snapshot with current state..."
wp --allow-root core version > /snapshots/state-0-core-version
wp --allow-root db export /snapshots/state-0.sql
tar czf /snapshots/state-0-wp-content.tar.gz -C /var/www/html wp-content
cp /var/www/html/wp-config.php /snapshots/state-0-wp-config.php

echo "Snapshot updated."
