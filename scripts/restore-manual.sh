#!/bin/bash
set -euo pipefail

DATABASE_DIR="/manual/database"
CONTENT_DIR="/manual/content"
WORDPRESS_DIR="/var/www/html"
LOCK_FILE="/tmp/fast-wordpress-manual-restore.lock"
INIT_STATUS_FILE="/tmp/fast-wordpress-init.status"
WORDPRESS_URL="${WORDPRESS_URL:-http://localhost}"
TEMP_DIR=""

cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf -- "$TEMP_DIR"
    fi
}

fail() {
    echo "[manual-restore] ERROR: $*" >&2
    exit 1
}

trap cleanup EXIT

acquire_restore_lock() {
    exec 9>"$LOCK_FILE"

    if ! flock -n 9; then
        fail "Another manual restore is already running."
    fi
}

wait_for_wordpress() {
    local attempt

    for attempt in $(seq 1 120); do
        if [ -f "$WORDPRESS_DIR/wp-load.php" ] && wp --path="$WORDPRESS_DIR" --allow-root db check >/dev/null 2>&1; then
            return 0
        fi

        if [ "$attempt" -eq 1 ]; then
            echo "[manual-restore] Waiting for WordPress and the database..."
        fi

        sleep 1
    done

    fail "WordPress or the database is not ready. Start the environment first."
}

wait_for_initialization() {
    local attempt
    local status

    sleep 1

    for attempt in $(seq 1 180); do
        if [ ! -f "$INIT_STATUS_FILE" ]; then
            return 0
        fi

        status="$(cat "$INIT_STATUS_FILE" 2>/dev/null || true)"

        case "$status" in
            ready)
                return 0
                ;;
            failed)
                echo "[manual-restore] WARNING: Container initialization failed; attempting the manual restore."
                return 0
                ;;
            running|"")
                if [ "$attempt" -eq 1 ]; then
                    echo "[manual-restore] Waiting for container initialization to finish..."
                fi
                sleep 1
                ;;
            *)
                fail "Unexpected container initialization status: $status"
                ;;
        esac
    done

    fail "Container initialization did not finish in time."
}

read_input_files() {
    mapfile -d '' SQL_FILES < <(find "$DATABASE_DIR" -maxdepth 1 -type f -iname '*.sql' -print0 | sort -z)
    mapfile -d '' ZIP_FILES < <(find "$CONTENT_DIR" -maxdepth 1 -type f -iname '*.zip' -print0 | sort -z)

    if [ "${#SQL_FILES[@]}" -gt 1 ]; then
        fail "Place exactly one .sql file in manual/database (found ${#SQL_FILES[@]})."
    fi

    if [ "${#ZIP_FILES[@]}" -gt 1 ]; then
        fail "Place exactly one .zip file in manual/content (found ${#ZIP_FILES[@]})."
    fi

    SQL_FILE="${SQL_FILES[0]:-}"
    ZIP_FILE="${ZIP_FILES[0]:-}"
    CONTENT_FOLDER=""

    if [ -d "$CONTENT_DIR/wp-content" ]; then
        CONTENT_FOLDER="$CONTENT_DIR/wp-content"
    fi

    if [ -n "$ZIP_FILE" ] && [ -n "$CONTENT_FOLDER" ]; then
        fail "Use either a ZIP file or manual/content/wp-content, not both."
    fi

    if [ -z "$SQL_FILE" ] && [ -z "$ZIP_FILE" ] && [ -z "$CONTENT_FOLDER" ]; then
        fail "No backup found. Add one .sql file and/or wp-content backup under manual/."
    fi

    if [ -n "$SQL_FILE" ] && [ ! -s "$SQL_FILE" ]; then
        fail "The SQL backup is empty: $(basename "$SQL_FILE")"
    fi
}

validate_content_tree() {
    local source="$1"

    if [ -z "$(find "$source" -mindepth 1 -maxdepth 1 ! -name '.DS_Store' ! -name '__MACOSX' -print -quit)" ]; then
        fail "The wp-content backup is empty."
    fi

    if [ -d "$source/wp-admin" ] || [ -d "$source/wp-includes" ] || [ -f "$source/wp-config.php" ]; then
        fail "The content backup contains a full WordPress installation. Provide only wp-content."
    fi

    if find "$source" -type l -print -quit | grep -q .; then
        fail "Symbolic links are not supported in wp-content backups."
    fi
}

prepare_zip_content() {
    local entry
    local extracted_dir
    local unexpected_entry
    local unzip_status=0

    unzip -tq "$ZIP_FILE" >/dev/null || unzip_status=$?
    if [ "$unzip_status" -gt 1 ]; then
        fail "The ZIP backup is invalid: $(basename "$ZIP_FILE")"
    fi

    while IFS= read -r entry; do
        entry="${entry%$'\r'}"
        entry="${entry//\\/\/}"
        case "$entry" in
            /*|[A-Za-z]:/*|..|../*|*/../*|*/..)
                fail "The ZIP backup contains an unsafe path: $entry"
                ;;
        esac
    done < <(unzip -Z1 "$ZIP_FILE")

    if zipinfo -l "$ZIP_FILE" | awk '$1 ~ /^l/ { found = 1 } END { exit(found ? 0 : 1) }'; then
        fail "Symbolic links are not supported in ZIP backups."
    fi

    TEMP_DIR="$(mktemp -d)"
    extracted_dir="$TEMP_DIR/extracted"
    mkdir -p "$extracted_dir"
    unzip_status=0
    unzip -q "$ZIP_FILE" -d "$extracted_dir" || unzip_status=$?
    if [ "$unzip_status" -gt 1 ]; then
        fail "The ZIP backup could not be extracted: $(basename "$ZIP_FILE")"
    fi

    if [ -d "$extracted_dir/wp-content" ]; then
        unexpected_entry="$(find "$extracted_dir" -mindepth 1 -maxdepth 1 ! -name 'wp-content' ! -name '__MACOSX' ! -name '.DS_Store' -print -quit)"
        if [ -n "$unexpected_entry" ]; then
            fail "The ZIP contains files next to wp-content. Provide only the wp-content folder."
        fi
        CONTENT_SOURCE="$extracted_dir/wp-content"
    else
        CONTENT_SOURCE="$extracted_dir"
    fi

    validate_content_tree "$CONTENT_SOURCE"
}

detect_table_prefix() {
    local table
    local prefix
    local site_url
    local -a tables
    local -a preferred_prefixes=()
    local -a fallback_prefixes=()
    local -A table_exists=()

    mapfile -t tables < <(
        wp --path="$WORDPRESS_DIR" --allow-root db query \
            "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() ORDER BY TABLE_NAME" \
            --skip-column-names
    )

    for table in "${tables[@]}"; do
        if [[ "$table" =~ ^[A-Za-z0-9_]+$ ]]; then
            table_exists["$table"]=1
        fi
    done

    for table in "${tables[@]}"; do
        if [[ ! "$table" =~ ^[A-Za-z0-9_]+_options$ ]]; then
            continue
        fi

        site_url="$(
            wp --path="$WORDPRESS_DIR" --allow-root db query \
                "SELECT option_value FROM \`$table\` WHERE option_name = 'siteurl' LIMIT 1" \
                --skip-column-names 2>/dev/null || true
        )"
        if [ -z "$site_url" ]; then
            continue
        fi

        prefix="${table%options}"
        fallback_prefixes+=("$prefix")
        if [ -n "${table_exists[${prefix}users]:-}" ] && [ -n "${table_exists[${prefix}usermeta]:-}" ]; then
            preferred_prefixes+=("$prefix")
        fi
    done

    if [ "${#preferred_prefixes[@]}" -eq 1 ]; then
        printf '%s' "${preferred_prefixes[0]}"
        return 0
    fi

    if [ "${#preferred_prefixes[@]}" -eq 0 ] && [ "${#fallback_prefixes[@]}" -eq 1 ]; then
        printf '%s' "${fallback_prefixes[0]}"
        return 0
    fi

    fail "Could not determine one WordPress table prefix from the imported database."
}

restore_database() {
    local imported_url
    local table_prefix

    echo "[manual-restore] Replacing the database from $(basename "$SQL_FILE")..."
    wp --path="$WORDPRESS_DIR" --allow-root db reset --yes
    wp --path="$WORDPRESS_DIR" --allow-root db import "$SQL_FILE"

    table_prefix="$(detect_table_prefix)"
    wp --path="$WORDPRESS_DIR" --allow-root config set table_prefix "$table_prefix" --type=variable

    if ! wp --path="$WORDPRESS_DIR" --allow-root core is-installed; then
        fail "The SQL file does not contain a complete WordPress database."
    fi

    imported_url="$(wp --path="$WORDPRESS_DIR" --allow-root option get home 2>/dev/null || true)"
    if [ -n "$imported_url" ] && [ "$imported_url" != "$WORDPRESS_URL" ]; then
        echo "[manual-restore] Replacing $imported_url with $WORDPRESS_URL..."
        wp --path="$WORDPRESS_DIR" --allow-root search-replace \
            "$imported_url" "$WORDPRESS_URL" \
            --all-tables-with-prefix --skip-columns=guid --report-changed-only
    fi

    wp --path="$WORDPRESS_DIR" --allow-root option update home "$WORDPRESS_URL"
    wp --path="$WORDPRESS_DIR" --allow-root option update siteurl "$WORDPRESS_URL"
    wp --path="$WORDPRESS_DIR" --allow-root core update-db
}

prepare_content() {
    if [ -n "$ZIP_FILE" ]; then
        prepare_zip_content
    else
        CONTENT_SOURCE="$CONTENT_FOLDER"
        validate_content_tree "$CONTENT_SOURCE"
    fi
}

restore_content() {
    echo "[manual-restore] Replacing wp-content..."
    find "$WORDPRESS_DIR/wp-content" -mindepth 1 -delete
    tar -C "$CONTENT_SOURCE" -cf - . | tar -C "$WORDPRESS_DIR/wp-content" --warning=no-timestamp -xf -
}

acquire_restore_lock
wait_for_wordpress
wait_for_initialization
read_input_files

if [ -n "$ZIP_FILE" ] || [ -n "$CONTENT_FOLDER" ]; then
    prepare_content
fi

if [ -n "$SQL_FILE" ]; then
    restore_database
fi

if [ -n "$ZIP_FILE" ] || [ -n "$CONTENT_FOLDER" ]; then
    restore_content
fi

bash /scripts/apply-optional-plugin.sh
bash /scripts/install-local-plugins.sh
chown -R www-data:www-data "$WORDPRESS_DIR/wp-content" "$WORDPRESS_DIR/wp-config.php"

echo "[manual-restore] Complete. Run snapshot.sh if this should become the new state-0."
