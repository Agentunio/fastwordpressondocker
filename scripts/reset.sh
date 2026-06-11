#!/bin/bash
set -e

if [ ! -f /snapshots/state-0.sql ] || [ ! -f /snapshots/state-0-wp-content.tar.gz ] || [ ! -f /snapshots/state-0-wp-config.php ]; then
    echo "ERROR: snapshot state-0 not complete in /snapshots."
    echo "Expected: state-0.sql, state-0-wp-content.tar.gz, state-0-wp-config.php"
    exit 1
fi

cd /var/www/html
WORDPRESS_URL="${WORDPRESS_URL:-http://localhost}"

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

chown -R www-data:www-data /var/www/html/wp-content /var/www/html/wp-config.php

echo "Downloading latest WordPress core..."
wp --allow-root core download --force --skip-content
wp --allow-root core update-db

echo "Updating All-in-One WP Migration to latest version..."
wp --allow-root plugin install all-in-one-wp-migration --force --activate

echo "Updating Advanced Custom Fields to latest version..."
wp --allow-root plugin install advanced-custom-fields --force --activate

shopt -s nullglob
for zip in /plugins/*.zip; do
    echo "Refreshing premium plugin from local zip: $zip"
    wp --allow-root plugin install "$zip" --force --activate
done
shopt -u nullglob

bash /scripts/remove-default-plugins.sh

chown -R www-data:www-data /var/www/html/wp-content /var/www/html/wp-config.php

echo "Reset complete. Restored state-0 and refreshed WordPress/All-in-One WP Migration."
