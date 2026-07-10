#!/bin/bash
set -e

cd /var/www/html
WORDPRESS_URL="${WORDPRESS_URL:-http://localhost}"
WORDPRESS_ADMIN_USER="${WORDPRESS_ADMIN_USER:-admin_qmpgfd}"
WORDPRESS_ADMIN_PASSWORD="${WORDPRESS_ADMIN_PASSWORD:-R40U8zp17YlwvQNkDEKgnhx2!@#}"
WORDPRESS_ADMIN_PASSWORD_BASE64="${WORDPRESS_ADMIN_PASSWORD_BASE64:-}"
WORDPRESS_ADMIN_EMAIL="${WORDPRESS_ADMIN_EMAIL:-admin@example.com}"
CORE_CONTENT_REPAIRED=0

if [ -n "$WORDPRESS_ADMIN_PASSWORD_BASE64" ]; then
    if ! WORDPRESS_ADMIN_PASSWORD="$(printf '%s' "$WORDPRESS_ADMIN_PASSWORD_BASE64" | base64 --decode 2>/dev/null)"; then
        echo "ERROR: WORDPRESS_ADMIN_PASSWORD_BASE64 is not valid Base64."
        exit 1
    fi
fi

repair_missing_default_theme() {
    if [ -d wp-content/themes/twentytwentyfive ]; then
        return 0
    fi

    echo "[init] Default theme files missing - restoring WordPress content..."
    wp --allow-root core download --force
    CORE_CONTENT_REPAIRED=1
}

state0_snapshot_complete() {
    [ -f /snapshots/state-0.sql ] && [ -f /snapshots/state-0-wp-content.tar.gz ] && [ -f /snapshots/state-0-wp-config.php ]
}

create_state0_snapshot() {
    mkdir -p /snapshots

    echo "[init] Creating state-0 snapshot..."
    wp --allow-root core version > /snapshots/state-0-core-version
    wp --allow-root db export /snapshots/state-0.sql
    tar czf /snapshots/state-0-wp-content.tar.gz -C /var/www/html wp-content
    cp /var/www/html/wp-config.php /snapshots/state-0-wp-config.php
}

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
    mkdir -p /snapshots
    repair_missing_default_theme
    wp --allow-root config set WP_AUTO_UPDATE_CORE false --raw
    wp --allow-root option update home "$WORDPRESS_URL"
    wp --allow-root option update siteurl "$WORDPRESS_URL"
    active_theme="$(wp --allow-root option get stylesheet 2>/dev/null || true)"
    if [ -n "$active_theme" ] && [ ! -d "wp-content/themes/$active_theme" ]; then
        echo "[init] Active theme files missing - activating twentytwentyfive..."
        wp --allow-root theme activate twentytwentyfive
    fi
    bash /scripts/apply-optional-plugin.sh
    bash /scripts/install-local-plugins.sh
    if [ "$CORE_CONTENT_REPAIRED" -eq 1 ]; then
        bash /scripts/remove-default-plugins.sh
    fi
    chown -R www-data:www-data /var/www/html/wp-content
    if ! state0_snapshot_complete; then
        bash /scripts/remove-default-plugins.sh
        create_state0_snapshot
    fi
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
    --admin_user="$WORDPRESS_ADMIN_USER" \
    --admin_password="$WORDPRESS_ADMIN_PASSWORD" \
    --admin_email="$WORDPRESS_ADMIN_EMAIL" \
    --skip-email

echo "[init] Disabling WordPress core auto-updates..."
wp --allow-root config set WP_AUTO_UPDATE_CORE false --raw

echo "[init] Activating default theme..."
wp --allow-root theme activate twentytwentyfive

bash /scripts/apply-optional-plugin.sh

bash /scripts/install-local-plugins.sh

bash /scripts/remove-default-plugins.sh

echo "[init] Fixing wp-content ownership..."
chown -R www-data:www-data /var/www/html/wp-content

create_state0_snapshot
echo "[init] Done."
