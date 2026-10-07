#!/usr/bin/env bash
set -euo pipefail

DEFAULT_PHP_VERSION="8.3"
DEFAULT_WORDPRESS_PORT="80"
DEFAULT_WORDPRESS_HTTPS="0"
DEFAULT_WORDPRESS_HTTP_VERSION="1.1"
DEFAULT_WORDPRESS_HTTPS_PORT="443"
DEFAULT_PHPMYADMIN_PORT="8080"
DEFAULT_MAILPIT_PORT="8025"
DEFAULT_OPTIONAL_PLUGIN="none"
DEFAULT_WORDPRESS_OBJECT_CACHE="none"
DEFAULT_WORDPRESS_ADMIN_USER="admin_qmpgfd"
DEFAULT_WORDPRESS_ADMIN_PASSWORD="R40U8zp17YlwvQNkDEKgnhx2!@#"
DEFAULT_WORDPRESS_ADMIN_EMAIL="admin@example.com"
ENV_FILE=".env"
manual_restore=0
env_backup=""
env_existed=0
env_rollback_pending=0
compose_runtime_changed=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --manual-restore)
            manual_restore=1
            ;;
        -h|--help)
            echo "Usage: bash ./start.sh [--manual-restore]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: bash ./start.sh [--manual-restore]" >&2
            exit 2
            ;;
    esac
    shift
done

assert_wordpress_storage() {
    local container_ids configuration validator container_id mounts image image_reference engine_os docker_desktop=0
    container_ids="$(docker compose ps --all --quiet wordpress)" || {
        echo "ERROR: cannot inspect the existing WordPress service. Startup cancelled." >&2
        return 1
    }
    [ -n "$container_ids" ] || return 0

    configuration="$(docker compose config --format json)" || {
        echo "ERROR: cannot resolve Compose storage configuration. Startup cancelled." >&2
        return 1
    }
    engine_os="$(docker info --format '{{.OperatingSystem}}')" || {
        echo "ERROR: cannot identify the Docker engine. Startup cancelled." >&2
        return 1
    }
    if [ "$engine_os" = "Docker Desktop" ]; then docker_desktop=1; fi
    validator="?>$(cat "$(dirname -- "${BASH_SOURCE[0]}")/scripts/check-wordpress-storage.php")" || return 1
    while IFS= read -r container_id; do
        mounts="$(docker inspect --format '{{json .Mounts}}' "$container_id")" || return 1
        image="$(docker inspect --format '{{.Image}}' "$container_id")" || return 1
        if [[ ! "$image" =~ ^sha256:[a-f0-9]{64}$ ]]; then
            echo "ERROR: cannot identify the existing WordPress image. Startup cancelled." >&2
            return 1
        fi

        if ! docker image inspect -- "$image" >/dev/null 2>&1; then
            image_reference="$(docker inspect --format '{{.Config.Image}}' "$container_id")" || return 1
            if [ -z "$image_reference" ]; then
                echo "ERROR: cannot identify the WordPress image reference. Startup cancelled." >&2
                return 1
            fi
            if ! image="$(docker image inspect --format '{{.Id}}' -- "$image_reference" 2>/dev/null)"; then
                echo "WordPress image is missing. Rebuilding it for the storage check..."
                if ! PHP_VERSION="${previous_php_version:-$php_version}" docker compose build wordpress; then
                    echo "ERROR: cannot rebuild the WordPress image. The existing container was not recreated." >&2
                    return 1
                fi
                image="$(docker image inspect --format '{{.Id}}' -- "$image_reference")" || {
                    echo "ERROR: WordPress image is still unavailable. The existing container was not recreated." >&2
                    return 1
                }
            fi
            if [[ ! "$image" =~ ^sha256:[a-f0-9]{64}$ ]]; then
                echo "ERROR: cannot identify the replacement WordPress image. Startup cancelled." >&2
                return 1
            fi
        fi

        if ! printf '%s\n%s\n' "$mounts" "$configuration" | docker run --rm --pull never --network none --read-only --cap-drop ALL --security-opt no-new-privileges --env "FAST_WORDPRESS_DOCKER_DESKTOP=$docker_desktop" -i --entrypoint php "$image" -r "$validator"; then
            echo "ERROR: WordPress storage check failed. The existing container was not recreated." >&2
            return 1
        fi
    done <<< "$container_ids"
}

set_env_value() {
    local key="$1"
    local value="$2"
    local file="$3"

    touch "$file"

    if grep -q "^${key}=" "$file"; then
        local tmp_file
        tmp_file="$(mktemp)"
        FWD_ENV_KEY="$key" FWD_ENV_VALUE="$value" awk '
            BEGIN {
                key = ENVIRON["FWD_ENV_KEY"]
                value = ENVIRON["FWD_ENV_VALUE"]
            }
            index($0, key "=") == 1 { print key "=" value; next }
            { print }
        ' "$file" > "$tmp_file"
        mv "$tmp_file" "$file"
    else
        printf "%s=%s\n" "$key" "$value" >> "$file"
    fi
}

get_env_value() {
    local key="$1"
    local file="$2"

    [ -f "$file" ] || return 0

    awk -v key="$key" '
        index($0, key "=") == 1 {
            print substr($0, length(key) + 2)
            exit
        }
    ' "$file"
}

env_value_or_default() {
    local value
    value="$(get_env_value "$1" "$ENV_FILE")"
    echo "${value:-$2}"
}

safe_display_value() {
    local destination="$1"
    local value="$2"
    local safe_value
    local LC_ALL=C

    safe_value="${value//[![:print:]]/?}"
    printf -v "$destination" '%s' "$safe_value"
}

invalid_env_value() {
    printf 'ERROR: invalid %s in %s.\n' "$1" "$ENV_FILE" >&2
    return 1
}

invalid_env_file() {
    printf 'ERROR: invalid or unsafe structure in %s.\n' "$ENV_FILE" >&2
    return 1
}

is_safe_env_value() {
    local value="$1"
    local LC_ALL=C

    [ "$value" = "${value//[![:print:]]/}" ]
}

is_valid_port() {
    local port="$1"

    [[ "$port" =~ ^[0-9]+$ ]] \
        && [ "${#port}" -le 5 ] \
        && [ "$port" -ge 1 ] \
        && [ "$port" -le 65535 ]
}

is_valid_optional_plugins() {
    local value="$1"
    local plugin
    local plugins

    if [ "$value" = "none" ]; then
        return 0
    fi

    if [ -z "$value" ] || [[ "$value" == ,* ]] || [[ "$value" == *, ]] || [[ "$value" == *,,* ]]; then
        return 1
    fi

    IFS=',' read -ra plugins <<< "$value"
    for plugin in "${plugins[@]}"; do
        case "$plugin" in
            all-in-one-wp-migration|updraftplus|advanced-custom-fields) ;;
            *) return 1 ;;
        esac
    done
}

validate_env_file_structure() {
    local line
    local key
    local seen_keys="|"

    [ ! -L "$ENV_FILE" ] || invalid_env_file || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        is_safe_env_value "$line" || invalid_env_file || return 1

        case "$line" in
            ""|\#*) continue ;;
            *=*) key="${line%%=*}" ;;
            *) invalid_env_file || return 1 ;;
        esac

        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || invalid_env_file || return 1

        case "$key" in
            COMPOSE_PROFILES) ;;
            COMPOSE_*) invalid_env_file || return 1 ;;
        esac

        case "$seen_keys" in
            *"|${key}|"*) invalid_env_file || return 1 ;;
        esac
        seen_keys="${seen_keys}${key}|"
    done < "$ENV_FILE"
}

validate_current_settings() {
    local key
    local value

    while IFS='|' read -r key value; do
        is_safe_env_value "$value" || invalid_env_value "$key" || return 1
    done <<EOF
PHP_VERSION|${php_version}
WORDPRESS_PORT|${wordpress_port}
WORDPRESS_HTTPS|${wordpress_https}
WORDPRESS_HTTP_VERSION|${wordpress_http_version}
WORDPRESS_HTTPS_PORT|${wordpress_https_port}
PHPMYADMIN_PORT|${phpmyadmin_port}
MAILPIT_PORT|${mailpit_port}
WORDPRESS_OPTIONAL_PLUGIN|${optional_plugin}
WORDPRESS_OBJECT_CACHE|${wordpress_object_cache}
WORDPRESS_ADMIN_USER|${wordpress_admin_user}
WORDPRESS_ADMIN_PASSWORD|${wordpress_admin_password}
WORDPRESS_ADMIN_PASSWORD_BASE64|${wordpress_admin_password_base64}
WORDPRESS_ADMIN_EMAIL|${wordpress_admin_email}
EOF

    case "$php_version" in
        8.1|8.2|8.3|8.4|8.5) ;;
        *) invalid_env_value "PHP_VERSION" || return 1 ;;
    esac

    is_valid_port "$wordpress_port" || invalid_env_value "WORDPRESS_PORT" || return 1
    is_valid_port "$wordpress_https_port" || invalid_env_value "WORDPRESS_HTTPS_PORT" || return 1
    case "$wordpress_https:$wordpress_http_version" in
        0:1.1|1:1.1|1:2) ;;
        *) invalid_env_value "WORDPRESS_HTTPS / WORDPRESS_HTTP_VERSION" || return 1 ;;
    esac
    is_valid_port "$phpmyadmin_port" || invalid_env_value "PHPMYADMIN_PORT" || return 1
    is_valid_port "$mailpit_port" || invalid_env_value "MAILPIT_PORT" || return 1
    is_valid_optional_plugins "$optional_plugin" || invalid_env_value "WORDPRESS_OPTIONAL_PLUGIN" || return 1

    case "$wordpress_object_cache" in
        none|redis|memcached) ;;
        *) invalid_env_value "WORDPRESS_OBJECT_CACHE" || return 1 ;;
    esac

    [[ "$wordpress_admin_user" =~ ^[A-Za-z0-9._@-]{1,60}$ ]] \
        || invalid_env_value "WORDPRESS_ADMIN_USER" \
        || return 1
    [[ "$wordpress_admin_email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] \
        || invalid_env_value "WORDPRESS_ADMIN_EMAIL" \
        || return 1

    if [ -n "$wordpress_admin_password_base64" ]; then
        [[ "$wordpress_admin_password_base64" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] \
            && [ "$(( ${#wordpress_admin_password_base64} % 4 ))" -eq 0 ] \
            || invalid_env_value "WORDPRESS_ADMIN_PASSWORD_BASE64" \
            || return 1
    fi
}

restore_tty_echo() {
    stty echo icanon 2>/dev/null < /dev/tty || true
}

rollback_launcher() {
    [ "$env_rollback_pending" -eq 1 ] || return 0
    env_rollback_pending=0

    if [ "$env_existed" -eq 1 ]; then
        if ! cp "$env_backup" "$ENV_FILE"; then
            echo "ERROR: the previous .env could not be restored; backup retained at ${env_backup}." >&2
            return 1
        fi
        if [ "$compose_runtime_changed" -eq 1 ]; then
            sync_compose_transport_environment
            stop_unselected_https "$previous_wordpress_https" || true
            if ! docker compose up -d --wait --wait-timeout 360; then
                echo "ERROR: the previous configuration could not be restarted automatically." >&2
            else
                stop_unselected_cache "${previous_wordpress_object_cache:-none}" || true
            fi
        fi
    else
        # Keep the attempted configuration available until all of its services stop.
        if [ "$compose_runtime_changed" -eq 1 ]; then
            docker compose stop || true
        fi
        rm -f -- "$ENV_FILE"
    fi
}

cleanup_launcher() {
    local exit_status=$?
    trap - EXIT
    # Complete one rollback even if another interrupt arrives during recovery.
    trap '' INT TERM
    set +e
    restore_tty_echo

    if rollback_launcher && [ -n "$env_backup" ] && [ -f "$env_backup" ]; then
        rm -f -- "$env_backup"
    fi
    exit "$exit_status"
}

trap cleanup_launcher EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap '' TTOU

open_menu_tty() {
    if ! { exec 3</dev/tty; } 2>/dev/null; then
        return 1
    fi

    trap 'close_menu_tty; exit 130' INT
    trap 'close_menu_tty; exit 143' TERM

    stty -echo -icanon min 1 time 0 2>/dev/null <&3 || true
}

close_menu_tty() {
    { stty echo icanon 2>/dev/null <&3 || true; } 2>/dev/null
    exec 3<&-
}

erase_menu_block() {
    local lines="$1"

    printf "\033[%sA\r\033[0J" "$lines" >&2
}

# Cursor-relative rendering needs the whole menu block plus the cursor line
# on screen at once; on a shorter terminal ESC[nA clamps at the top row and
# rewrites land on the wrong lines.
menu_fits_terminal() {
    local needed_rows="$1"
    local term_rows

    term_rows="$(stty size 2>/dev/null <&3 | awk '{print $1}')" || term_rows=""

    # 0 rows means the terminal did not report a size — assume it fits.
    if [[ "$term_rows" =~ ^[0-9]+$ ]] && [ "$term_rows" -gt 0 ] && [ "$term_rows" -lt "$needed_rows" ]; then
        return 1
    fi

    return 0
}

rewrite_menu_line() {
    local option_count="$1"
    local index="$2"
    local text="$3"
    local lines_up

    lines_up=$((option_count - index + 2))
    printf "\033[%sA\r%s\033[%sB" "$lines_up" "$text" "$lines_up" >&2
}

# Sets MENU_KEY instead of printing: a $(...) fork per keypress opens a
# window where Ctrl+C wedges bash 3.2 inside the command-substitution wait.
MENU_KEY="OTHER"

read_menu_key() {
    local c
    local seq
    local started
    local instant_failures=0

    MENU_KEY="OTHER"

    # Poll with -t 1 instead of blocking forever: bash 3.2 never delivers a
    # pending SIGINT to a read that is blocked, only between commands. On
    # timeout read returns 1 (same as EOF), so EOF is detected as failures
    # that return instantly (SECONDS did not advance).
    while true; do
        started="$SECONDS"
        if IFS= read -rsd '' -n1 -t 1 c <&3; then
            break
        fi

        if [ "$((SECONDS - started))" -ge 1 ]; then
            instant_failures=0
            continue
        fi

        instant_failures=$((instant_failures + 1))
        if [ "$instant_failures" -ge 2 ]; then
            return 1
        fi
    done

    case "$c" in
        $'\x1b')
            IFS= read -rsd '' -n1 -t 1 c <&3 || return 0

            case "$c" in
                "[")
                    seq=""
                    while IFS= read -rsd '' -n1 -t 1 c <&3; do
                        seq="${seq}${c}"
                        case "$c" in
                            [A-Za-z~]) break ;;
                        esac
                        if [ "${#seq}" -ge 32 ]; then
                            break
                        fi
                    done

                    case "$seq" in
                        A) MENU_KEY="UP" ;;
                        B) MENU_KEY="DOWN" ;;
                        D) MENU_KEY="LEFT" ;;
                        M)
                            IFS= read -rsd '' -n3 -t 1 c <&3 || true
                            ;;
                    esac
                    ;;
                "O")
                    IFS= read -rsd '' -n1 -t 1 c <&3 || c=""
                    case "$c" in
                        A) MENU_KEY="UP" ;;
                        B) MENU_KEY="DOWN" ;;
                        D) MENU_KEY="LEFT" ;;
                    esac
                    ;;
            esac
            ;;
        $'\r'|$'\n') MENU_KEY="ENTER" ;;
        " ") MENU_KEY="SPACE" ;;
        $'\x7f'|$'\x08') MENU_KEY="BACKSPACE" ;;
    esac
}

choose_option_by_number() {
    local prompt="$1"
    shift
    local options=("$@")
    local option

    echo "$prompt" >&2
    PS3="Choose option: "
    select option in "${options[@]}"; do
        if [ -n "${option:-}" ]; then
            echo "$option"
            return 0
        fi
        echo "Invalid option. Choose a number from 1 to ${#options[@]}." >&2
    done

    # select ended on stdin EOF.
    return 1
}

choose_option() {
    local allow_back=0
    local default_option=""

    while true; do
        case "${1:-}" in
            --allow-back)
                allow_back=1
                shift
                ;;
            --default)
                default_option="$2"
                shift 2
                ;;
            *)
                break
                ;;
        esac
    done

    local prompt="$1"
    shift
    local options=("$@")
    local selected=0
    local previous
    local i
    local hint="Use Up/Down arrows and Enter."

    if [ "$allow_back" -eq 1 ]; then
        hint="Use Up/Down arrows and Enter. Left/Backspace = back."
    fi

    if [ -n "$default_option" ]; then
        for i in "${!options[@]}"; do
            if [ "${options[$i]}" = "$default_option" ]; then
                selected="$i"
            fi
        done
    fi

    if ! open_menu_tty; then
        if choose_option_by_number "$prompt" "${options[@]}"; then
            return 0
        fi
        return 1
    fi

    if ! menu_fits_terminal $((${#options[@]} + 5)); then
        close_menu_tty
        if choose_option_by_number "$prompt" "${options[@]}"; then
            return 0
        fi
        return 1
    fi

    printf "%s\n\n" "$prompt" >&2
    for i in "${!options[@]}"; do
        if [ "$i" -eq "$selected" ]; then
            printf "> %s\n" "${options[$i]}" >&2
        else
            printf "  %s\n" "${options[$i]}" >&2
        fi
    done
    printf "\n%s\n" "$hint" >&2

    while true; do
        read_menu_key || {
            close_menu_tty
            return 1
        }

        previous="$selected"

        case "$MENU_KEY" in
            UP)
                if [ "$selected" -gt 0 ]; then
                    selected=$((selected - 1))
                else
                    selected=$((${#options[@]} - 1))
                fi
                ;;
            DOWN)
                if [ "$selected" -lt $((${#options[@]} - 1)) ]; then
                    selected=$((selected + 1))
                else
                    selected=0
                fi
                ;;
            ENTER)
                erase_menu_block $((${#options[@]} + 4))
                printf "%s %s\n" "$prompt" "${options[$selected]}" >&2
                echo "${options[$selected]}"
                close_menu_tty
                return 0
                ;;
            LEFT|BACKSPACE)
                if [ "$allow_back" -eq 1 ]; then
                    erase_menu_block $((${#options[@]} + 4))
                    close_menu_tty
                    return 2
                fi
                ;;
        esac

        if [ "$selected" -ne "$previous" ]; then
            rewrite_menu_line "${#options[@]}" "$previous" "  ${options[$previous]}"
            rewrite_menu_line "${#options[@]}" "$selected" "> ${options[$selected]}"
        fi
    done
}

optional_plugin_selected() {
    local selected_plugins="$1"
    local slug="$2"

    case ",${selected_plugins}," in
        *",${slug},"*) return 0 ;;
        *) return 1 ;;
    esac
}

read_optional_plugins_by_number() {
    local raw_choice
    local selected_plugins
    local slug
    local valid
    local choices
    local choice

    while true; do
        echo "Choose optional plugins:" >&2
        echo "1) None" >&2
        echo "2) All-in-One WP Migration" >&2
        echo "3) UpdraftPlus" >&2
        echo "4) Advanced Custom Fields" >&2
        printf "Choose options separated by comma (empty = none): " >&2
        read -r raw_choice || return 1

        raw_choice="${raw_choice//[[:space:]]/}"
        if [ -z "$raw_choice" ] || [ "$raw_choice" = "1" ]; then
            echo "none"
            return 0
        fi

        selected_plugins=""
        valid=1
        IFS=',' read -ra choices <<< "$raw_choice"

        for choice in "${choices[@]}"; do
            case "$choice" in
                1)
                    selected_plugins=""
                    break
                    ;;
                2)
                    slug="all-in-one-wp-migration"
                    ;;
                3)
                    slug="updraftplus"
                    ;;
                4)
                    slug="advanced-custom-fields"
                    ;;
                *)
                    valid=0
                    ;;
            esac

            if [ "$valid" -eq 1 ] && [ "$choice" != "1" ] && ! optional_plugin_selected "$selected_plugins" "$slug"; then
                if [ -n "$selected_plugins" ]; then
                    selected_plugins="${selected_plugins},${slug}"
                else
                    selected_plugins="$slug"
                fi
            fi
        done

        if [ "$valid" -eq 1 ]; then
            echo "${selected_plugins:-none}"
            return 0
        fi

        echo "Invalid option. Choose numbers from 1 to 4." >&2
    done
}

choose_optional_plugins() {
    local current_plugins="$1"
    local labels=("None" "All-in-One WP Migration" "UpdraftPlus" "Advanced Custom Fields" "Confirm")
    local slugs=("none" "all-in-one-wp-migration" "updraftplus" "advanced-custom-fields")
    local confirm_index=$((${#labels[@]} - 1))
    local checked=(0 0 0 0)
    local selected=0
    local previous
    local i
    local selected_plugins

    if [ -z "$current_plugins" ] || [ "$current_plugins" = "none" ]; then
        checked[0]=1
    else
        for i in 1 2 3; do
            if optional_plugin_selected "$current_plugins" "${slugs[$i]}"; then
                checked[$i]=1
            fi
        done
    fi

    if [ "${checked[1]}" -eq 0 ] && [ "${checked[2]}" -eq 0 ] && [ "${checked[3]}" -eq 0 ]; then
        checked[0]=1
    fi

    if ! open_menu_tty; then
        read_optional_plugins_by_number
        return 0
    fi

    if ! menu_fits_terminal $((${#labels[@]} + 5)); then
        close_menu_tty
        read_optional_plugins_by_number
        return 0
    fi

    optional_plugin_line() {
        local option_index="$1"
        local prefix=" "
        local mark=" "

        if [ "$option_index" -eq "$selected" ]; then
            prefix=">"
        fi

        if [ "$option_index" -eq "$confirm_index" ]; then
            printf "%s %s" "$prefix" "${labels[$option_index]}"
            return 0
        fi

        if [ "${checked[$option_index]}" -eq 1 ]; then
            mark="x"
        fi

        printf "%s [%s] %s" "$prefix" "$mark" "${labels[$option_index]}"
    }

    toggle_selected_plugin() {
        if [ "$selected" -eq 0 ]; then
            checked=(1 0 0 0)
        else
            checked[0]=0
            if [ "${checked[$selected]}" -eq 1 ]; then
                checked[$selected]=0
            else
                checked[$selected]=1
            fi

            if [ "${checked[1]}" -eq 0 ] && [ "${checked[2]}" -eq 0 ] && [ "${checked[3]}" -eq 0 ]; then
                checked[0]=1
            fi
        fi

        local line
        for line in "${!labels[@]}"; do
            rewrite_menu_line "${#labels[@]}" "$line" "$(optional_plugin_line "$line")"
        done
    }

    printf "Choose optional plugins:\n\n" >&2
    for i in "${!labels[@]}"; do
        printf "%s\n" "$(optional_plugin_line "$i")" >&2
    done
    printf "\nEnter/Space toggles, Confirm continues, Left/Backspace = back.\n" >&2

    while true; do
        read_menu_key || {
            close_menu_tty
            return 1
        }

        previous="$selected"

        case "$MENU_KEY" in
            UP)
                if [ "$selected" -gt 0 ]; then
                    selected=$((selected - 1))
                else
                    selected=$((${#labels[@]} - 1))
                fi
                ;;
            DOWN)
                if [ "$selected" -lt $((${#labels[@]} - 1)) ]; then
                    selected=$((selected + 1))
                else
                    selected=0
                fi
                ;;
            SPACE)
                if [ "$selected" -ne "$confirm_index" ]; then
                    toggle_selected_plugin
                fi
                ;;
            ENTER)
                if [ "$selected" -ne "$confirm_index" ]; then
                    toggle_selected_plugin
                else
                    selected_plugins=""
                    for i in 1 2 3; do
                        if [ "${checked[$i]}" -eq 1 ]; then
                            if [ -n "$selected_plugins" ]; then
                                selected_plugins="${selected_plugins},${slugs[$i]}"
                            else
                                selected_plugins="${slugs[$i]}"
                            fi
                        fi
                    done

                    erase_menu_block $((${#labels[@]} + 4))
                    printf "Choose optional plugins: %s\n" "${selected_plugins:-none}" >&2
                    echo "${selected_plugins:-none}"
                    close_menu_tty
                    return 0
                fi
                ;;
            LEFT|BACKSPACE)
                erase_menu_block $((${#labels[@]} + 4))
                close_menu_tty
                return 2
                ;;
        esac

        if [ "$selected" -ne "$previous" ]; then
            rewrite_menu_line "${#labels[@]}" "$previous" "$(optional_plugin_line "$previous")"
            rewrite_menu_line "${#labels[@]}" "$selected" "$(optional_plugin_line "$selected")"
        fi
    done
}

read_port() {
    local prompt="$1"
    local port
    local failed=0
    local tty_ui=0
    local use_tty=0
    local interactive=0
    local rc

    # Read from the same place the menus do: with stdin redirected but a
    # terminal present, stdin would EOF instantly and loop back forever.
    if [ -t 0 ]; then
        interactive=1
    elif { exec 4</dev/tty; } 2>/dev/null; then
        use_tty=1
        interactive=1
    fi

    if [ "$interactive" -eq 1 ] && [ -t 2 ]; then
        tty_ui=1
    fi

    while true; do
        printf "%s" "$prompt" >&2

        rc=0
        if [ "$use_tty" -eq 1 ]; then
            IFS= read -r port <&4 || rc=$?
        else
            IFS= read -r port || rc=$?
        fi

        if [ "$rc" -ne 0 ]; then
            if [ "$interactive" -eq 0 ]; then
                return 1
            fi

            # Ctrl+D: no newline was echoed, normalize the cursor first so
            # the erase below does not eat the previous summary line.
            printf "\n" >&2
            if [ "$tty_ui" -eq 1 ]; then
                erase_menu_block $((1 + failed))
            fi
            return 2
        fi

        if [ -z "$port" ]; then
            if [ "$tty_ui" -eq 1 ]; then
                erase_menu_block $((1 + failed))
            fi
            return 2
        fi

        if [[ "$port" =~ ^[0-9]+$ ]] && [ "${#port}" -le 5 ] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            if [ "$tty_ui" -eq 1 ] && [ "$failed" -eq 1 ]; then
                erase_menu_block 2
                printf "%s%s\n" "$prompt" "$port" >&2
            fi
            echo "$port"
            return 0
        fi

        if [ "$tty_ui" -eq 1 ]; then
            erase_menu_block $((1 + failed))
        fi
        echo "Invalid port. Enter a number from 1 to 65535." >&2
        failed=1
    done
}

choose_port() {
    local prompt="$1"
    local default_port="$2"
    local current_port="${3:-}"
    local include_standard="${4:-0}"
    local port_choice
    local port
    local rc
    local current_option=""
    local current_port_display=""

    while true; do
        rc=0
        if [ -n "$current_port" ]; then
            safe_display_value current_port_display "$current_port"
            current_option="Current settings (${current_port_display})"
            if [ "$include_standard" = "1" ]; then
                port_choice="$(choose_option --allow-back "$prompt" "$current_option" "Standard (${default_port})" "Custom")" || rc=$?
            else
                port_choice="$(choose_option --allow-back "$prompt" "$current_option" "Custom")" || rc=$?
            fi
        else
            port_choice="$(choose_option --allow-back "$prompt" "Standard (${default_port})" "Custom")" || rc=$?
        fi
        if [ "$rc" -ne 0 ]; then
            return "$rc"
        fi

        if [ -n "$current_option" ] && [ "$port_choice" = "$current_option" ]; then
            echo "$current_port"
            return 0
        fi

        if [ "$port_choice" = "Standard (${default_port})" ]; then
            echo "$default_port"
            return 0
        fi

        rc=0
        port="$(read_port "Enter custom port (empty = back): ")" || rc=$?
        if [ "$rc" -eq 2 ]; then
            if [ -t 2 ]; then
                erase_menu_block 1
            fi
            continue
        fi
        if [ "$rc" -ne 0 ]; then
            return "$rc"
        fi

        echo "$port"
        return 0
    done
}

read_admin_input() {
    local prompt="$1"
    local secret="${2:-0}"
    local value
    local rc=0
    local use_tty=0

    if [ ! -t 0 ] && { exec 4</dev/tty; } 2>/dev/null; then
        use_tty=1
    fi

    printf "%s" "$prompt" >&2

    if [ "$use_tty" -eq 1 ]; then
        if [ "$secret" -eq 1 ]; then
            IFS= read -rs value <&4 || rc=$?
        else
            IFS= read -r value <&4 || rc=$?
        fi
        exec 4<&-
    elif [ "$secret" -eq 1 ]; then
        IFS= read -rs value || rc=$?
    else
        IFS= read -r value || rc=$?
    fi

    if [ "$secret" -eq 1 ]; then
        printf "\n" >&2
    fi

    if [ "$rc" -ne 0 ]; then
        return 1
    fi

    ADMIN_INPUT="$value"
}

read_custom_admin() {
    local username
    local email
    local password
    local password_confirmation

    while true; do
        read_admin_input "Enter admin username (empty = back): " || return 1
        username="$ADMIN_INPUT"
        [ -n "$username" ] || return 2

        if [[ "$username" =~ ^[A-Za-z0-9._@-]{1,60}$ ]]; then
            break
        fi

        echo "Invalid username. Use 1-60 letters, numbers, dots, underscores, @ or hyphens." >&2
    done

    while true; do
        read_admin_input "Enter admin email (empty = back): " || return 1
        email="$ADMIN_INPUT"
        [ -n "$email" ] || return 2

        if [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
            break
        fi

        echo "Invalid email address." >&2
    done

    while true; do
        read_admin_input "Enter admin password (empty = back): " 1 || return 1
        password="$ADMIN_INPUT"
        [ -n "$password" ] || return 2
        read_admin_input "Repeat admin password: " 1 || return 1
        password_confirmation="$ADMIN_INPUT"

        if [ "$password" = "$password_confirmation" ]; then
            break
        fi

        echo "Passwords do not match." >&2
    done

    custom_admin_user="$username"
    custom_admin_email="$email"
    custom_admin_password_base64="$(printf '%s' "$password" | base64 | tr -d '\r\n')"
}

admin_mode_label() {
    if [ "$wordpress_admin_user" = "$DEFAULT_WORDPRESS_ADMIN_USER" ] \
        && [ "$wordpress_admin_password" = "$DEFAULT_WORDPRESS_ADMIN_PASSWORD" ] \
        && [ -z "$wordpress_admin_password_base64" ] \
        && [ "$wordpress_admin_email" = "$DEFAULT_WORDPRESS_ADMIN_EMAIL" ]; then
        echo "Default WordPress admin"
    else
        echo "Custom WordPress admin"
    fi
}

localhost_url() {
    local port="$1"
    local scheme="${2:-http}"

    if { [ "$scheme" = "http" ] && [ "$port" = "80" ]; } || { [ "$scheme" = "https" ] && [ "$port" = "443" ]; }; then
        echo "${scheme}://localhost"
    else
        echo "${scheme}://localhost:${port}"
    fi
}

if [ -L "$ENV_FILE" ] || { [ -e "$ENV_FILE" ] && [ ! -f "$ENV_FILE" ]; }; then
    invalid_env_file
    exit 1
fi

php_version="$(env_value_or_default "PHP_VERSION" "$DEFAULT_PHP_VERSION")"
wordpress_port="$(env_value_or_default "WORDPRESS_PORT" "$DEFAULT_WORDPRESS_PORT")"
wordpress_https="$(env_value_or_default "WORDPRESS_HTTPS" "$DEFAULT_WORDPRESS_HTTPS")"
wordpress_http_version="$(env_value_or_default "WORDPRESS_HTTP_VERSION" "$DEFAULT_WORDPRESS_HTTP_VERSION")"
wordpress_https_port="$(env_value_or_default "WORDPRESS_HTTPS_PORT" "$DEFAULT_WORDPRESS_HTTPS_PORT")"
phpmyadmin_port="$(env_value_or_default "PHPMYADMIN_PORT" "$DEFAULT_PHPMYADMIN_PORT")"
mailpit_port="$(env_value_or_default "MAILPIT_PORT" "$DEFAULT_MAILPIT_PORT")"
optional_plugin="$(env_value_or_default "WORDPRESS_OPTIONAL_PLUGIN" "$DEFAULT_OPTIONAL_PLUGIN")"
wordpress_object_cache="$(env_value_or_default "WORDPRESS_OBJECT_CACHE" "$DEFAULT_WORDPRESS_OBJECT_CACHE")"
wordpress_admin_user="$(env_value_or_default "WORDPRESS_ADMIN_USER" "$DEFAULT_WORDPRESS_ADMIN_USER")"
wordpress_admin_password="$(env_value_or_default "WORDPRESS_ADMIN_PASSWORD" "$DEFAULT_WORDPRESS_ADMIN_PASSWORD")"
wordpress_admin_password_base64="$(get_env_value "WORDPRESS_ADMIN_PASSWORD_BASE64" "$ENV_FILE")"
wordpress_admin_email="$(env_value_or_default "WORDPRESS_ADMIN_EMAIL" "$DEFAULT_WORDPRESS_ADMIN_EMAIL")"
previous_php_version="$(get_env_value "PHP_VERSION" "$ENV_FILE")"
previous_wordpress_object_cache="$(get_env_value "WORDPRESS_OBJECT_CACHE" "$ENV_FILE")"
previous_wordpress_https="$wordpress_https"

if [ -f "$ENV_FILE" ]; then
    validate_env_file_structure || exit 1
    validate_current_settings || exit 1
fi

case "$wordpress_object_cache" in
    none|redis|memcached) ;;
    *) wordpress_object_cache="$DEFAULT_WORDPRESS_OBJECT_CACHE" ;;
esac

if [ -n "$wordpress_admin_password_base64" ]; then
    wordpress_admin_password=""
fi


initial_php_version="$php_version"
initial_optional_plugin="$optional_plugin"
initial_wordpress_object_cache="$wordpress_object_cache"
initial_wordpress_admin_user="$wordpress_admin_user"
initial_wordpress_admin_password="$wordpress_admin_password"
initial_wordpress_admin_password_base64="$wordpress_admin_password_base64"
initial_wordpress_admin_email="$wordpress_admin_email"
initial_wordpress_port="$wordpress_port"
initial_wordpress_https="$wordpress_https"
initial_wordpress_http_version="$wordpress_http_version"
initial_wordpress_https_port="$wordpress_https_port"
initial_phpmyadmin_port="$phpmyadmin_port"
initial_mailpit_port="$mailpit_port"
initial_wordpress_admin_mode="$(admin_mode_label)"
initial_php_version_display=""
initial_optional_plugin_display=""
initial_wordpress_admin_user_display=""
initial_wordpress_port_display=""
initial_phpmyadmin_port_display=""
initial_mailpit_port_display=""
safe_display_value initial_php_version_display "$initial_php_version"
safe_display_value initial_optional_plugin_display "$initial_optional_plugin"
safe_display_value initial_wordpress_admin_user_display "$initial_wordpress_admin_user"
safe_display_value initial_wordpress_port_display "$initial_wordpress_port"
safe_display_value initial_phpmyadmin_port_display "$initial_phpmyadmin_port"
safe_display_value initial_mailpit_port_display "$initial_mailpit_port"
has_current_settings=0

if [ -f "$ENV_FILE" ]; then
    has_current_settings=1
    printf "Current settings: PHP %s, WP port %s, phpMyAdmin port %s, Mailpit port %s, plugins: %s, object cache: %s, admin: %s (%s)\n\n" "$initial_php_version_display" "$initial_wordpress_port_display" "$initial_phpmyadmin_port_display" "$initial_mailpit_port_display" "$initial_optional_plugin_display" "$wordpress_object_cache" "$initial_wordpress_admin_user_display" "$initial_wordpress_admin_mode" >&2
    if [ "$wordpress_https" = "1" ]; then
        printf 'HTTPS enabled, port %s, HTTP/%s\n\n' "$wordpress_https_port" "$wordpress_http_version" >&2
    else
        printf 'HTTPS disabled, HTTP/1.1\n\n' >&2
    fi
    keep_option="Current settings"
else
    keep_option="Default settings"
fi

php_version_label() {
    if [ "$1" = "$DEFAULT_PHP_VERSION" ]; then
        echo "Standard (PHP ${DEFAULT_PHP_VERSION})"
    else
        echo "PHP $1"
    fi
}

object_cache_label() {
    case "$1" in
        redis) echo "Redis" ;;
        memcached) echo "Memcached" ;;
        *) echo "None" ;;
    esac
}

stop_unselected_cache() {
    case "$1" in
        redis)
            docker compose stop memcached
            ;;
        memcached)
            docker compose stop redis
            ;;
        none|*)
            docker compose stop redis memcached
            ;;
    esac
}

stop_unselected_https() {
    if [ "$1" = "0" ]; then
        docker compose stop https
    fi
}

sync_compose_transport_environment() {
    WORDPRESS_HTTPS="$(env_value_or_default WORDPRESS_HTTPS 0)"
    WORDPRESS_HTTP_VERSION="$(env_value_or_default WORDPRESS_HTTP_VERSION 1.1)"
    WORDPRESS_HTTPS_PORT="$(env_value_or_default WORDPRESS_HTTPS_PORT 443)"
    WORDPRESS_PORT="$(env_value_or_default WORDPRESS_PORT 80)"
    WORDPRESS_URL="$(env_value_or_default WORDPRESS_URL "$(localhost_url "$WORDPRESS_PORT")")"
    COMPOSE_PROFILES="$(env_value_or_default COMPOSE_PROFILES none)"
    export WORDPRESS_HTTPS WORDPRESS_HTTP_VERSION WORDPRESS_HTTPS_PORT WORDPRESS_PORT WORDPRESS_URL COMPOSE_PROFILES
}

verify_https() {
    local actual_version
    actual_version="$(docker compose exec -T wordpress curl \
        --fail --silent --show-error --max-time 30 \
        "--http${wordpress_http_version}" \
        --cacert /usr/local/share/fast-wordpress-ca/root.crt \
        --connect-to "localhost:${wordpress_https_port}:https:443" \
        --output /dev/null --write-out '%{http_version}' "$wordpress_url")" || return 1
    if [ "$actual_version" != "$wordpress_http_version" ]; then
        echo "ERROR: HTTPS negotiated HTTP/${actual_version}, expected HTTP/${wordpress_http_version}." >&2
        return 1
    fi
}

step=0
while true; do
    case "$step" in
        0)
            rc=0
            setup_mode="$(choose_option "Choose setup mode:" "$keep_option" "Custom settings")" || rc=$?
            if [ "$rc" -ne 0 ]; then
                exit 1
            fi

            if [ "$setup_mode" != "Custom settings" ]; then
                php_version="$initial_php_version"
                optional_plugin="$initial_optional_plugin"
                if [ "$keep_option" = "Default settings" ]; then
                    wordpress_object_cache="$DEFAULT_WORDPRESS_OBJECT_CACHE"
                else
                    wordpress_object_cache="$initial_wordpress_object_cache"
                fi
                wordpress_admin_user="$initial_wordpress_admin_user"
                wordpress_admin_password="$initial_wordpress_admin_password"
                wordpress_admin_password_base64="$initial_wordpress_admin_password_base64"
                wordpress_admin_email="$initial_wordpress_admin_email"
                wordpress_port="$initial_wordpress_port"
                wordpress_https="$initial_wordpress_https"
                wordpress_http_version="$initial_wordpress_http_version"
                wordpress_https_port="$initial_wordpress_https_port"
                phpmyadmin_port="$initial_phpmyadmin_port"
                mailpit_port="$initial_mailpit_port"
                break
            fi
            step=1
            ;;
        1)
            rc=0
            php_options=("Standard (PHP ${DEFAULT_PHP_VERSION})" "PHP 8.1" "PHP 8.2" "PHP 8.4" "PHP 8.5")
            php_default_option="$(php_version_label "$php_version")"
            current_php_option=""
            if [ "$has_current_settings" -eq 1 ]; then
                current_php_option="Current settings (PHP ${initial_php_version_display})"
                php_options=("$current_php_option" "${php_options[@]}")
                php_default_option="$current_php_option"
            fi

            php_choice="$(choose_option --allow-back --default "$php_default_option" "Choose PHP version:" "${php_options[@]}")" || rc=$?
            if [ "$rc" -eq 2 ]; then
                step=0
                continue
            fi
            if [ "$rc" -ne 0 ]; then
                exit 1
            fi

            case "$php_choice" in
                "$current_php_option")
                    php_version="$initial_php_version"
                    ;;
                "Standard (PHP ${DEFAULT_PHP_VERSION})")
                    php_version="$DEFAULT_PHP_VERSION"
                    ;;
                "PHP 8.1")
                    php_version="8.1"
                    ;;
                "PHP 8.2")
                    php_version="8.2"
                    ;;
                "PHP 8.4")
                    php_version="8.4"
                    ;;
                "PHP 8.5")
                    php_version="8.5"
                    ;;
            esac
            step=2
            ;;
        2)
            rc=0
            if [ "$has_current_settings" -eq 1 ]; then
                current_plugin_option="Current settings (${initial_optional_plugin_display})"
                plugin_setup_choice="$(choose_option --allow-back "Choose optional plugins:" "$current_plugin_option" "Custom")" || rc=$?
                if [ "$rc" -eq 2 ]; then
                    step=1
                    continue
                fi
                if [ "$rc" -ne 0 ]; then
                    exit 1
                fi
                if [ "$plugin_setup_choice" = "$current_plugin_option" ]; then
                    optional_plugin="$initial_optional_plugin"
                    step=3
                    continue
                fi
            fi

            rc=0
            plugin_choice="$(choose_optional_plugins "$optional_plugin")" || rc=$?
            if [ "$rc" -eq 2 ]; then
                if [ "$has_current_settings" -eq 0 ]; then
                    step=1
                fi
                continue
            fi
            if [ "$rc" -ne 0 ]; then
                exit 1
            fi

            optional_plugin="$plugin_choice"
            step=3
            ;;
        3)
            rc=0
            cache_options=("None" "Redis" "Memcached")
            cache_default_option="$(object_cache_label "$wordpress_object_cache")"
            current_cache_option=""
            if [ "$has_current_settings" -eq 1 ]; then
                current_cache_option="Current settings ($(object_cache_label "$initial_wordpress_object_cache"))"
                cache_options=("$current_cache_option" "${cache_options[@]}")
                cache_default_option="$current_cache_option"
            fi

            cache_choice="$(choose_option --allow-back --default "$cache_default_option" "Choose WordPress object cache:" "${cache_options[@]}")" || rc=$?
            if [ "$rc" -eq 2 ]; then
                step=2
                continue
            fi
            if [ "$rc" -ne 0 ]; then
                exit 1
            fi

            if [ -n "$current_cache_option" ] && [ "$cache_choice" = "$current_cache_option" ]; then
                wordpress_object_cache="$initial_wordpress_object_cache"
            else
                wordpress_object_cache="$(printf '%s' "$cache_choice" | tr '[:upper:]' '[:lower:]')"
            fi
            step=4
            ;;
        4)
            rc=0
            admin_options=("Default WordPress admin" "Custom WordPress admin")
            admin_default_option="$(admin_mode_label)"
            current_admin_option=""
            if [ "$has_current_settings" -eq 1 ]; then
                current_admin_option="Current settings (${initial_wordpress_admin_user_display}, ${initial_wordpress_admin_mode})"
                admin_options=("$current_admin_option" "${admin_options[@]}")
                admin_default_option="$current_admin_option"
            fi

            admin_choice="$(choose_option --allow-back --default "$admin_default_option" "Choose WordPress administrator:" "${admin_options[@]}")" || rc=$?
            if [ "$rc" -eq 2 ]; then
                step=3
                continue
            fi
            if [ "$rc" -ne 0 ]; then
                exit 1
            fi

            if [ -n "$current_admin_option" ] && [ "$admin_choice" = "$current_admin_option" ]; then
                wordpress_admin_user="$initial_wordpress_admin_user"
                wordpress_admin_password="$initial_wordpress_admin_password"
                wordpress_admin_password_base64="$initial_wordpress_admin_password_base64"
                wordpress_admin_email="$initial_wordpress_admin_email"
            elif [ "$admin_choice" = "Default WordPress admin" ]; then
                wordpress_admin_user="$DEFAULT_WORDPRESS_ADMIN_USER"
                wordpress_admin_password="$DEFAULT_WORDPRESS_ADMIN_PASSWORD"
                wordpress_admin_password_base64=""
                wordpress_admin_email="$DEFAULT_WORDPRESS_ADMIN_EMAIL"
            else
                rc=0
                read_custom_admin || rc=$?
                if [ "$rc" -eq 2 ]; then
                    continue
                fi
                if [ "$rc" -ne 0 ]; then
                    exit 1
                fi

                wordpress_admin_user="$custom_admin_user"
                wordpress_admin_password=""
                wordpress_admin_password_base64="$custom_admin_password_base64"
                wordpress_admin_email="$custom_admin_email"
            fi

            step=https
            ;;
        https)
            rc=0
            https_default="No (default)"
            [ "$wordpress_https" != "1" ] || https_default="Yes"
            https_choice="$(choose_option --allow-back --default "$https_default" "Enable HTTPS?" "No (default)" "Yes")" || rc=$?
            if [ "$rc" -eq 2 ]; then step=4; continue; fi
            if [ "$rc" -ne 0 ]; then exit 1; fi
            if [ "$https_choice" = "Yes" ]; then
                wordpress_https=1
                step=protocol
            else
                wordpress_https=0
                wordpress_http_version=1.1
                step=5
            fi
            ;;
        protocol)
            rc=0
            protocol_choice="$(choose_option --allow-back --default "HTTP/${wordpress_http_version}" "Choose HTTP protocol:" "HTTP/1.1" "HTTP/2")" || rc=$?
            if [ "$rc" -eq 2 ]; then step=https; continue; fi
            if [ "$rc" -ne 0 ]; then exit 1; fi
            wordpress_http_version="${protocol_choice#HTTP/}"
            step=5
            ;;
        5)
            rc=0
            current_port=""
            if [ "$has_current_settings" -eq 1 ]; then
                current_port="$initial_wordpress_port"
            fi
            port_choice="$(choose_port "Choose WordPress port:" "$DEFAULT_WORDPRESS_PORT" "$current_port")" || rc=$?
            if [ "$rc" -eq 2 ]; then
                if [ "$wordpress_https" = "1" ]; then step=protocol; else step=https; fi
                continue
            fi
            if [ "$rc" -ne 0 ]; then
                exit 1
            fi

            wordpress_port="$port_choice"
            if [ "$wordpress_https" = "1" ]; then step=https-port; else step=6; fi
            ;;
        https-port)
            rc=0
            current_port=""
            if [ "$has_current_settings" -eq 1 ] && [ "$initial_wordpress_https" = "1" ]; then current_port="$initial_wordpress_https_port"; fi
            port_choice="$(choose_port "Choose HTTPS port:" "$DEFAULT_WORDPRESS_HTTPS_PORT" "$current_port" 1)" || rc=$?
            if [ "$rc" -eq 2 ]; then step=5; continue; fi
            if [ "$rc" -ne 0 ]; then exit 1; fi
            if [ "$port_choice" = "$wordpress_port" ]; then
                echo "HTTPS port must be different from WordPress HTTP port." >&2
                continue
            fi
            wordpress_https_port="$port_choice"
            step=6
            ;;
        6)
            rc=0
            current_port=""
            if [ "$has_current_settings" -eq 1 ]; then
                current_port="$initial_phpmyadmin_port"
            fi
            port_choice="$(choose_port "Choose phpMyAdmin port:" "$DEFAULT_PHPMYADMIN_PORT" "$current_port")" || rc=$?
            if [ "$rc" -eq 2 ]; then
                if [ "$wordpress_https" = "1" ]; then step=https-port; else step=5; fi
                continue
            fi
            if [ "$rc" -ne 0 ]; then
                exit 1
            fi

            if [ "$port_choice" = "$wordpress_port" ] || { [ "$wordpress_https" = "1" ] && [ "$port_choice" = "$wordpress_https_port" ]; }; then
                wordpress_port_display=""
                safe_display_value wordpress_port_display "$wordpress_port"
                echo "phpMyAdmin port must be different from WordPress HTTP and HTTPS ports." >&2
                continue
            fi

            phpmyadmin_port="$port_choice"
            step=7
            ;;
        7)
            rc=0
            current_port=""
            if [ "$has_current_settings" -eq 1 ]; then
                current_port="$initial_mailpit_port"
            fi
            port_choice="$(choose_port "Choose Mailpit port:" "$DEFAULT_MAILPIT_PORT" "$current_port")" || rc=$?
            if [ "$rc" -eq 2 ]; then
                step=6
                continue
            fi
            if [ "$rc" -ne 0 ]; then
                exit 1
            fi

            if [ "$port_choice" = "$wordpress_port" ] || [ "$port_choice" = "$phpmyadmin_port" ] || { [ "$wordpress_https" = "1" ] && [ "$port_choice" = "$wordpress_https_port" ]; }; then
                echo "Mailpit port must be different from WordPress HTTP/HTTPS and phpMyAdmin ports." >&2
                continue
            fi

            mailpit_port="$port_choice"
            break
            ;;
    esac
done

validate_current_settings
for port_variable in wordpress_port wordpress_https_port phpmyadmin_port mailpit_port; do
    printf -v "$port_variable" '%s' "$((10#${!port_variable}))"
done

if [ "$wordpress_https" = "1" ]; then
    if [ "$wordpress_https_port" = "$wordpress_port" ] || [ "$wordpress_https_port" = "$phpmyadmin_port" ] || [ "$wordpress_https_port" = "$mailpit_port" ]; then
        echo "ERROR: HTTPS port must be different from all other service ports." >&2
        exit 1
    fi
    wordpress_url="$(localhost_url "$wordpress_https_port" https)"
else
    wordpress_url="$(localhost_url "$wordpress_port")"
fi
phpmyadmin_url="$(localhost_url "$phpmyadmin_port")"
mailpit_url="$(localhost_url "$mailpit_port")"

env_backup="$(mktemp)"
if [ -f "$ENV_FILE" ]; then
    cp "$ENV_FILE" "$env_backup"
    env_existed=1
fi
env_rollback_pending=1

if [ ! -e "$ENV_FILE" ]; then
    (umask 077; touch "$ENV_FILE")
fi
chmod 600 "$ENV_FILE"

set_env_value "PHP_VERSION" "$php_version" "$ENV_FILE"
set_env_value "WORDPRESS_OPTIONAL_PLUGIN" "$optional_plugin" "$ENV_FILE"
set_env_value "WORDPRESS_OBJECT_CACHE" "$wordpress_object_cache" "$ENV_FILE"
compose_profiles="$wordpress_object_cache"
if [ "$wordpress_https" = "1" ]; then compose_profiles="${compose_profiles},https"; fi
set_env_value "COMPOSE_PROFILES" "$compose_profiles" "$ENV_FILE"
set_env_value "WORDPRESS_ADMIN_USER" "$wordpress_admin_user" "$ENV_FILE"
set_env_value "WORDPRESS_ADMIN_PASSWORD" "$wordpress_admin_password" "$ENV_FILE"
set_env_value "WORDPRESS_ADMIN_PASSWORD_BASE64" "$wordpress_admin_password_base64" "$ENV_FILE"
set_env_value "WORDPRESS_ADMIN_EMAIL" "$wordpress_admin_email" "$ENV_FILE"
set_env_value "WORDPRESS_PORT" "$wordpress_port" "$ENV_FILE"
set_env_value "WORDPRESS_HTTPS" "$wordpress_https" "$ENV_FILE"
set_env_value "WORDPRESS_HTTP_VERSION" "$wordpress_http_version" "$ENV_FILE"
set_env_value "WORDPRESS_HTTPS_PORT" "$wordpress_https_port" "$ENV_FILE"
set_env_value "WORDPRESS_URL" "$wordpress_url" "$ENV_FILE"
set_env_value "PHPMYADMIN_PORT" "$phpmyadmin_port" "$ENV_FILE"
set_env_value "MAILPIT_PORT" "$mailpit_port" "$ENV_FILE"
sync_compose_transport_environment

php_version_display=""
wordpress_url_display=""
phpmyadmin_url_display=""
mailpit_url_display=""
safe_display_value php_version_display "$php_version"
safe_display_value wordpress_url_display "$wordpress_url"
safe_display_value phpmyadmin_url_display "$phpmyadmin_url"
safe_display_value mailpit_url_display "$mailpit_url"
echo "Starting WordPress with PHP ${php_version_display}..."
echo "WordPress URL: ${wordpress_url_display}"
echo "phpMyAdmin URL: ${phpmyadmin_url_display}"
echo "Mailpit URL: ${mailpit_url_display}"
echo "WordPress object cache: ${wordpress_object_cache}"
echo "WordPress protocol: HTTP/${wordpress_http_version} (HTTPS: ${wordpress_https})"

# The EXIT trap restores .env on rejection, without applying the unsafe Compose file.
assert_wordpress_storage || exit 1

compose_status=0
if [ "$wordpress_https" = "0" ]; then
    compose_runtime_changed=1
    stop_unselected_https "$wordpress_https" || compose_status=$?
fi
if [ "$compose_status" -ne 0 ]; then
    :
elif [ -z "$previous_php_version" ]; then
    compose_runtime_changed=1
    docker compose up -d --build --wait --wait-timeout 360 || compose_status=$?
elif [ "$previous_php_version" != "$php_version" ]; then
    echo "Rebuilding image because PHP version changed."
    compose_runtime_changed=1
    docker compose up -d --build --wait --wait-timeout 360 || compose_status=$?
else
    compose_runtime_changed=1
    docker compose up -d --wait --wait-timeout 360 || compose_status=$?
fi

if [ "$compose_status" -eq 0 ] && [ "$wordpress_https" = "1" ]; then
    verify_https || compose_status=$?
    if [ "$compose_status" -eq 0 ]; then
        bash ./scripts/trust-local-ca.sh || compose_status=$?
    fi
fi

if [ "$compose_status" -ne 0 ]; then
    echo "ERROR: the new configuration could not be verified; restoring the previous .env." >&2
    exit "$compose_status"
fi

env_rollback_pending=0
rm -f -- "$env_backup"
env_backup=""

stop_unselected_cache "$wordpress_object_cache"

if [ "$manual_restore" -eq 1 ]; then
    echo "==> Restoring WordPress from manual backup files..."
    docker compose exec -T wordpress bash /scripts/restore-manual.sh
    echo "Manual restore complete."
fi
