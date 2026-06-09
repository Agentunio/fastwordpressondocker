#!/bin/bash
set -e

cd /var/www/html
WORDPRESS_URL="${WORDPRESS_URL:-http://localhost}"

# Wait until WP core files are copied in by the official entrypoint
for i in $(seq 1 60); do
    [ -f wp-load.php ] && break
    sleep 1
done

# Wait for DB
for i in $(seq 1 60); do
    wp --allow-root db check 2>/dev/null && break
    sleep 1
done

if wp --allow-root core is-installed 2>/dev/null; then
    echo "[init] WordPress already installed, nothing to do."
    exit 0
fi

mkdir -p /snapshots

if [ -f /snapshots/state-0.sql ] && [ -f /snapshots/state-0-wp-content.tar.gz ] && [ -f /snapshots/state-0-wp-config.php ]; then
    echo "[init] Volume is empty but state-0 snapshot exists - restoring it."
    bash /scripts/reset.sh
    exit 0
fi

echo "[init] Fresh install..."
echo "[init] Downloading latest WordPress core..."
wp --allow-root core download --force --skip-content

wp --allow-root core install \
    --url="$WORDPRESS_URL" \
    --title="Test WordPress" \
    --admin_user='admin_qmpgfd' \
    --admin_password='R40U8zp17YlwvQNkDEKgnhx2!@#' \
    --admin_email=admin@example.com \
    --skip-email

# Free plugins from wp.org
FREE_PLUGINS=(
    "advanced-custom-fields"
    "all-in-one-wp-migration"
)
for slug in "${FREE_PLUGINS[@]}"; do
    echo "[init] Installing free plugin: $slug"
    wp --allow-root plugin install "$slug" --activate
done

# Premium plugins from /plugins/*.zip
shopt -s nullglob
for zip in /plugins/*.zip; do
    echo "[init] Installing premium plugin: $zip"
    wp --allow-root plugin install "$zip" --activate
done
shopt -u nullglob

bash /scripts/remove-default-plugins.sh

echo "[init] Fixing wp-content ownership..."
chown -R www-data:www-data /var/www/html/wp-content

echo "[init] Creating state-0 snapshot..."
wp --allow-root db export /snapshots/state-0.sql
tar czf /snapshots/state-0-wp-content.tar.gz -C /var/www/html wp-content
cp /var/www/html/wp-config.php /snapshots/state-0-wp-config.php
echo "[init] Done."
