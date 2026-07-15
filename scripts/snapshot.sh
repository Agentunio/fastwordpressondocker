#!/bin/bash
set -Eeuo pipefail

TOTAL_STEPS=7
CURRENT_STEP=0
CURRENT_STEP_LABEL=""
SNAPSHOT_STARTED_AT=$SECONDS

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

cd /var/www/html

start_step "Checking the WordPress installation..."
if ! wp --allow-root core is-installed 2>/dev/null; then
    echo "[snapshot] ERROR: WordPress is not installed yet." >&2
    exit 1
fi

start_step "Preparing the snapshot directory..."
mkdir -p /snapshots

start_step "Removing default WordPress plugins..."
bash /scripts/remove-default-plugins.sh

start_step "Saving the WordPress core version..."
wp --allow-root core version > /snapshots/state-0-core-version

start_step "Exporting the database..."
wp --allow-root db export /snapshots/state-0.sql

start_step "Archiving wp-content..."
tar czf /snapshots/state-0-wp-content.tar.gz -C /var/www/html wp-content

start_step "Copying wp-config.php..."
cp /var/www/html/wp-config.php /snapshots/state-0-wp-config.php

printf '[snapshot] Complete: state-0 updated in %ds.\n' "$((SECONDS - SNAPSHOT_STARTED_AT))"
