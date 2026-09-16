#!/bin/bash
set -e

cd /var/www/html
WORDPRESS_URL="${WORDPRESS_URL:-http://localhost}"
WORDPRESS_ADMIN_USER="${WORDPRESS_ADMIN_USER:-admin_qmpgfd}"
WORDPRESS_ADMIN_PASSWORD="${WORDPRESS_ADMIN_PASSWORD:-R40U8zp17YlwvQNkDEKgnhx2!@#}"
WORDPRESS_ADMIN_PASSWORD_BASE64="${WORDPRESS_ADMIN_PASSWORD_BASE64:-}"
WORDPRESS_ADMIN_EMAIL="${WORDPRESS_ADMIN_EMAIL:-admin@example.com}"
CORE_CONTENT_REPAIRED=0
INSTALL_CHECK_ERRORS="$(mktemp /tmp/fast-wordpress-install-check.XXXXXX)"

fix_wordpress_ownership() {
    find /var/www/html -mindepth 1 \
        ! -path /var/www/html/wp-cli.yml \
        ! -path /var/www/html/wp-cli.local.yml \
        \( ! -user www-data -o ! -group www-data \) \
        -exec chown -h www-data:www-data {} + || true
}

remove_untrusted_wp_cli_config() {
    local planted

    planted="$(find /var/www/html -maxdepth 1 \
        \( -name 'wp-cli.yml' -o -name 'wp-cli.local.yml' \) \
        ! -user root 2>/dev/null || true)"

    if [ -n "$planted" ]; then
        echo "[init] WARNING: removing untrusted WP-CLI config from the WordPress root:"
        printf '%s\n' "$planted"
        find /var/www/html -maxdepth 1 \
            \( -name 'wp-cli.yml' -o -name 'wp-cli.local.yml' \) \
            ! -user root -delete
    fi
}

harden_wordpress_root() {
    local config

    for config in /var/www/html/wp-cli.yml /var/www/html/wp-cli.local.yml; do
        if [ -e "$config" ]; then
            chown root:root "$config"
            chmod 644 "$config"
        else
            install -o root -g root -m 644 /dev/null "$config"
        fi
    done

    chown root:root /var/www/html
    chmod 1777 /var/www/html
}

finalize_wordpress_permissions() {
    fix_wordpress_ownership
    remove_untrusted_wp_cli_config
    harden_wordpress_root
}

remove_untrusted_wp_cli_config
harden_wordpress_root
bash /scripts/prepare-object-cache.sh

trap finalize_wordpress_permissions EXIT

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
    echo "[init] Creating state-0 snapshot..."
    bash /scripts/snapshot.sh
}

for i in $(seq 1 60); do
    [ -f wp-load.php ] && break
    sleep 1
done

for i in $(seq 1 60); do
    wp --allow-root db check 2>/dev/null && break
    sleep 1
done

INSTALLED_RC=0
wp --allow-root core is-installed --skip-plugins --skip-themes 2>"$INSTALL_CHECK_ERRORS" || INSTALLED_RC=$?

if [ "$INSTALLED_RC" -gt 1 ]; then
    cat "$INSTALL_CHECK_ERRORS" >&2 || true
    echo "[init] ERROR: cannot determine the install state (wp exited with ${INSTALLED_RC}) - refusing to reset or reinstall automatically."
    exit 1
fi

if [ "$INSTALLED_RC" -ne 0 ]; then
    DB_TABLE_COUNT="$(wp --allow-root db query 'SHOW TABLES' --skip-column-names 2>/dev/null | wc -l)"
    if [ "${DB_TABLE_COUNT:-0}" -gt 0 ]; then
        cat "$INSTALL_CHECK_ERRORS" >&2 || true
        echo "[init] ERROR: WordPress reports not-installed but the database contains ${DB_TABLE_COUNT} tables (a crashed plugin bootstrap can cause this) - refusing to reset or reinstall automatically."
        exit 1
    fi
fi
rm -f "$INSTALL_CHECK_ERRORS"

if [ "$INSTALLED_RC" -eq 0 ]; then
    echo "[init] WordPress already installed - syncing settings from environment..."
    mkdir -p /snapshots
    repair_missing_default_theme
    wp --allow-root config set WP_AUTO_UPDATE_CORE false --raw
    bash /scripts/apply-object-cache.sh
    wp --allow-root eval-file /scripts/sync-wordpress-url.php "$WORDPRESS_URL" --skip-plugins --skip-themes
    active_theme="$(wp --allow-root option get stylesheet --skip-plugins --skip-themes 2>/dev/null || true)"
    if [ -n "$active_theme" ] && [ ! -d "wp-content/themes/$active_theme" ]; then
        echo "[init] Active theme files missing - activating twentytwentyfive..."
        wp --allow-root theme activate twentytwentyfive --skip-plugins --skip-themes
    fi
    bash /scripts/apply-optional-plugin.sh
    bash /scripts/install-local-plugins.sh
    if [ "$CORE_CONTENT_REPAIRED" -eq 1 ]; then
        bash /scripts/remove-default-plugins.sh
    fi
    fix_wordpress_ownership
    if ! state0_snapshot_complete; then
        bash /scripts/remove-default-plugins.sh
        create_state0_snapshot
    fi
    echo "[init] Settings synced."
    exit 0
fi

mkdir -p /snapshots

if state0_snapshot_complete; then
    echo "[init] Volume is empty but state-0 snapshot exists - restoring it."
    bash /scripts/reset.sh
    wp --allow-root config set WP_AUTO_UPDATE_CORE false --raw
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
wp --allow-root theme activate twentytwentyfive --skip-plugins --skip-themes

bash /scripts/apply-object-cache.sh
bash /scripts/apply-optional-plugin.sh

bash /scripts/install-local-plugins.sh

bash /scripts/remove-default-plugins.sh

echo "[init] Fixing file ownership..."
fix_wordpress_ownership

create_state0_snapshot
echo "[init] Done."
