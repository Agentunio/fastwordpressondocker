#!/bin/bash
set -Eeuo pipefail

TOTAL_STEPS=7
CURRENT_STEP=0
CURRENT_STEP_LABEL=""
SNAPSHOT_STARTED_AT=$SECONDS
SNAPSHOT_STAGING_DIR=""
SNAPSHOT_ARCHIVE_ATTEMPTS=3

cleanup_staging_dir() {
    if [ -z "$SNAPSHOT_STAGING_DIR" ]; then
        return
    fi

    case "$SNAPSHOT_STAGING_DIR" in
        /snapshots/.state-0.*) ;;
        *)
            printf '[snapshot] Refusing to clean unexpected staging path: %s\n' \
                "$SNAPSHOT_STAGING_DIR" >&2
            return
            ;;
    esac

    if [ -d "$SNAPSHOT_STAGING_DIR" ]; then
        find "$SNAPSHOT_STAGING_DIR" -mindepth 1 -delete
        rmdir "$SNAPSHOT_STAGING_DIR"
    fi

    SNAPSHOT_STAGING_DIR=""
}

start_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    CURRENT_STEP_LABEL="$1"
    printf '[snapshot] [%d/%d] %s\n' "$CURRENT_STEP" "$TOTAL_STEPS" "$CURRENT_STEP_LABEL"
}

on_error() {
    printf '[snapshot] ERROR at step %d/%d: %s\n' \
        "$CURRENT_STEP" "$TOTAL_STEPS" "$CURRENT_STEP_LABEL" >&2
}

trap on_error ERR
trap cleanup_staging_dir EXIT

cd /var/www/html

start_step "Checking the WordPress installation..."
if ! wp --allow-root core is-installed 2>/dev/null; then
    echo "[snapshot] ERROR: WordPress is not installed yet." >&2
    exit 1
fi

start_step "Preparing the snapshot directory..."
mkdir -p /snapshots
SNAPSHOT_STAGING_DIR="$(mktemp -d /snapshots/.state-0.XXXXXX)"

start_step "Removing default WordPress plugins..."
bash /scripts/remove-default-plugins.sh

start_step "Saving the WordPress core version..."
wp --allow-root core version > "$SNAPSHOT_STAGING_DIR/state-0-core-version"

start_step "Exporting the database..."
wp --allow-root db export "$SNAPSHOT_STAGING_DIR/state-0.sql"

start_step "Archiving wp-content..."
archive_attempt=1
while [ "$archive_attempt" -le "$SNAPSHOT_ARCHIVE_ATTEMPTS" ]; do
    archive_status=0
    tar \
        --create \
        --gzip \
        --file="$SNAPSHOT_STAGING_DIR/state-0-wp-content.tar.gz" \
        --warning=no-file-changed \
        --exclude='wp-content/cache' \
        --exclude='wp-content/wflogs' \
        --exclude='wp-content/upgrade' \
        --exclude='.DS_Store' \
        -C /var/www/html \
        wp-content \
        || archive_status=$?

    if [ "$archive_status" -eq 0 ]; then
        break
    fi

    if [ "$archive_status" -ne 1 ]; then
        printf '[snapshot] tar failed with exit code %d.\n' "$archive_status" >&2
        on_error
        exit "$archive_status"
    fi

    if [ "$archive_attempt" -eq "$SNAPSHOT_ARCHIVE_ATTEMPTS" ]; then
        printf '[snapshot] wp-content kept changing after %d attempts.\n' \
            "$SNAPSHOT_ARCHIVE_ATTEMPTS" >&2
        on_error
        exit 1
    fi

    printf '[snapshot] wp-content changed while archiving; retrying (%d/%d)...\n' \
        "$((archive_attempt + 1))" "$SNAPSHOT_ARCHIVE_ATTEMPTS"
    archive_attempt=$((archive_attempt + 1))
    sleep 1
done

gzip --test "$SNAPSHOT_STAGING_DIR/state-0-wp-content.tar.gz"
tar --list --gzip --file="$SNAPSHOT_STAGING_DIR/state-0-wp-content.tar.gz" > /dev/null

start_step "Finalizing the snapshot..."
cp /var/www/html/wp-config.php "$SNAPSHOT_STAGING_DIR/state-0-wp-config.php"

for snapshot_file in \
    state-0-core-version \
    state-0.sql \
    state-0-wp-content.tar.gz \
    state-0-wp-config.php; do
    mv "$SNAPSHOT_STAGING_DIR/$snapshot_file" "/snapshots/$snapshot_file"
done

rmdir "$SNAPSHOT_STAGING_DIR"
SNAPSHOT_STAGING_DIR=""

printf '[snapshot] Complete: state-0 updated in %ds.\n' "$((SECONDS - SNAPSHOT_STARTED_AT))"
