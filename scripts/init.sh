#!/bin/bash
set -e

cd /var/www/html
WORDPRESS_URL="${WORDPRESS_URL:-http://localhost}"

for i in $(seq 1 60); do
    [ -f wp-load.php ] && break
    sleep 1
done

for i in $(seq 1 60); do
    wp --allow-root db check 2>/dev/null && break
    sleep 1
done

if wp --allow-root core is-installed 2>/dev/null; then
    echo "[init] WordPress already installed - syncing settings from environment..."
    wp --allow-root config set WP_AUTO_UPDATE_CORE false --raw
    wp --allow-root option update home "$WORDPRESS_URL"
    wp --allow-root option update siteurl "$WORDPRESS_URL"
    bash /scripts/apply-optional-plugin.sh
    bash /scripts/install-local-plugins.sh
    chown -R www-data:www-data /var/www/html/wp-content
    echo "[init] Settings synced."
    exit 0
fi

mkdir -p /snapshots

if [ -f /snapshots/state-0.sql ] && [ -f /snapshots/state-0-wp-content.tar.gz ] && [ -f /snapshots/state-0-wp-config.php ]; then
    echo "[init] Volume is empty but state-0 snapshot exists - restoring it."
    bash /scripts/reset.sh
    wp --allow-root config set WP_AUTO_UPDATE_CORE false --raw
    chown -R www-data:www-data /var/www/html/wp-content
    exit 0
fi

echo "[init] Fresh install..."
echo "[init] Downloading latest WordPress core..."
wp --allow-root core download --force

wp --allow-root core install \
    --url="$WORDPRESS_URL" \
    --title="Fast WordPress on Docker" \
    --admin_user='admin_qmpgfd' \
    --admin_password='R40U8zp17YlwvQNkDEKgnhx2!@#' \
    --admin_email=admin@example.com \
    --skip-email

echo "[init] Disabling WordPress core auto-updates..."
wp --allow-root config set WP_AUTO_UPDATE_CORE false --raw

echo "[init] Activating default theme..."
wp --allow-root theme activate twentytwentyfive

FREE_PLUGINS=(
    "advanced-custom-fields"
)
for slug in "${FREE_PLUGINS[@]}"; do
    echo "[init] Installing free plugin: $slug"
    wp --allow-root plugin install "$slug" --activate
done

bash /scripts/apply-optional-plugin.sh

bash /scripts/install-local-plugins.sh

bash /scripts/remove-default-plugins.sh

echo "[init] Fixing wp-content ownership..."
chown -R www-data:www-data /var/www/html/wp-content

echo "[init] Creating state-0 snapshot..."
wp --allow-root core version > /snapshots/state-0-core-version
wp --allow-root db export /snapshots/state-0.sql
tar czf /snapshots/state-0-wp-content.tar.gz -C /var/www/html wp-content
cp /var/www/html/wp-config.php /snapshots/state-0-wp-config.php
echo "[init] Done."
