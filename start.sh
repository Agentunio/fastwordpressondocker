#!/usr/bin/env bash
set -euo pipefail

DEFAULT_PHP_VERSION="8.3"
DEFAULT_WORDPRESS_PORT="80"
DEFAULT_PHPMYADMIN_PORT="8080"
DEFAULT_MAILPIT_PORT="8025"
DEFAULT_OPTIONAL_PLUGIN="none"
DEFAULT_WORDPRESS_ADMIN_USER="admin_qmpgfd"
DEFAULT_WORDPRESS_ADMIN_PASSWORD="R40U8zp17YlwvQNkDEKgnhx2!@#"
DEFAULT_WORDPRESS_ADMIN_EMAIL="admin@example.com"
ENV_FILE=".env"

set_env_value() {
    local key="$1"
    local value="$2"
    local file="$3"

    touch "$file"

    if grep -q "^${key}=" "$file"; then
        local tmp_file
        tmp_file="$(mktemp)"
        awk -v key="$key" -v value="$value" '
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

restore_tty_echo() {
    stty echo icanon 2>/dev/null < /dev/tty || true
}

trap restore_tty_echo EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap '' TTOU

open_menu_tty() {
    if ! { exec 3</dev/tty; } 2>/dev/null; then
        return 1
    fi

    trap 'close_menu_tty; exit 130' INT TERM

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
    local port_choice
    local port
    local rc

    while true; do
        rc=0
        port_choice="$(choose_option --allow-back "$prompt" "Standard (${default_port})" "Custom")" || rc=$?
        if [ "$rc" -ne 0 ]; then
            return "$rc"
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

    if [ "$port" = "80" ]; then
        echo "http://localhost"
    else
        echo "http://localhost:${port}"
    fi
}

php_version="$(env_value_or_default "PHP_VERSION" "$DEFAULT_PHP_VERSION")"
wordpress_port="$(env_value_or_default "WORDPRESS_PORT" "$DEFAULT_WORDPRESS_PORT")"
phpmyadmin_port="$(env_value_or_default "PHPMYADMIN_PORT" "$DEFAULT_PHPMYADMIN_PORT")"
mailpit_port="$(env_value_or_default "MAILPIT_PORT" "$DEFAULT_MAILPIT_PORT")"
optional_plugin="$(env_value_or_default "WORDPRESS_OPTIONAL_PLUGIN" "$DEFAULT_OPTIONAL_PLUGIN")"
wordpress_admin_user="$(env_value_or_default "WORDPRESS_ADMIN_USER" "$DEFAULT_WORDPRESS_ADMIN_USER")"
wordpress_admin_password="$(env_value_or_default "WORDPRESS_ADMIN_PASSWORD" "$DEFAULT_WORDPRESS_ADMIN_PASSWORD")"
wordpress_admin_password_base64="$(get_env_value "WORDPRESS_ADMIN_PASSWORD_BASE64" "$ENV_FILE")"
wordpress_admin_email="$(env_value_or_default "WORDPRESS_ADMIN_EMAIL" "$DEFAULT_WORDPRESS_ADMIN_EMAIL")"
previous_php_version="$(get_env_value "PHP_VERSION" "$ENV_FILE")"

if [ -n "$wordpress_admin_password_base64" ]; then
    wordpress_admin_password=""
fi


initial_php_version="$php_version"
initial_optional_plugin="$optional_plugin"
initial_wordpress_admin_user="$wordpress_admin_user"
initial_wordpress_admin_password="$wordpress_admin_password"
initial_wordpress_admin_password_base64="$wordpress_admin_password_base64"
initial_wordpress_admin_email="$wordpress_admin_email"
initial_wordpress_port="$wordpress_port"
initial_phpmyadmin_port="$phpmyadmin_port"
initial_mailpit_port="$mailpit_port"

if [ -f "$ENV_FILE" ]; then
    printf "Current settings: PHP %s, WP port %s, phpMyAdmin port %s, Mailpit port %s, plugins: %s, admin: %s (%s)\n\n" "$php_version" "$wordpress_port" "$phpmyadmin_port" "$mailpit_port" "$optional_plugin" "$wordpress_admin_user" "$(admin_mode_label)" >&2
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
                wordpress_admin_user="$initial_wordpress_admin_user"
                wordpress_admin_password="$initial_wordpress_admin_password"
                wordpress_admin_password_base64="$initial_wordpress_admin_password_base64"
                wordpress_admin_email="$initial_wordpress_admin_email"
                wordpress_port="$initial_wordpress_port"
                phpmyadmin_port="$initial_phpmyadmin_port"
                mailpit_port="$initial_mailpit_port"
                break
            fi
            step=1
            ;;
        1)
            rc=0
            php_choice="$(choose_option --allow-back --default "$(php_version_label "$php_version")" "Choose PHP version:" "Standard (PHP ${DEFAULT_PHP_VERSION})" "PHP 8.1" "PHP 8.2" "PHP 8.4" "PHP 8.5")" || rc=$?
            if [ "$rc" -eq 2 ]; then
                step=0
                continue
            fi
            if [ "$rc" -ne 0 ]; then
                exit 1
            fi

            case "$php_choice" in
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
            plugin_choice="$(choose_optional_plugins "$optional_plugin")" || rc=$?
            if [ "$rc" -eq 2 ]; then
                step=1
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
            admin_choice="$(choose_option --allow-back --default "$(admin_mode_label)" "Choose WordPress administrator:" "Default WordPress admin" "Custom WordPress admin")" || rc=$?
            if [ "$rc" -eq 2 ]; then
                step=2
                continue
            fi
            if [ "$rc" -ne 0 ]; then
                exit 1
            fi

            if [ "$admin_choice" = "Default WordPress admin" ]; then
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

            step=4
            ;;
        4)
            rc=0
            port_choice="$(choose_port "Choose WordPress port:" "$DEFAULT_WORDPRESS_PORT")" || rc=$?
            if [ "$rc" -eq 2 ]; then
                step=3
                continue
            fi
            if [ "$rc" -ne 0 ]; then
                exit 1
            fi

            wordpress_port="$port_choice"
            step=5
            ;;
        5)
            rc=0
            port_choice="$(choose_port "Choose phpMyAdmin port:" "$DEFAULT_PHPMYADMIN_PORT")" || rc=$?
            if [ "$rc" -eq 2 ]; then
                step=4
                continue
            fi
            if [ "$rc" -ne 0 ]; then
                exit 1
            fi

            if [ "$port_choice" = "$wordpress_port" ]; then
                echo "phpMyAdmin port must be different from WordPress port (${wordpress_port})." >&2
                continue
            fi

            phpmyadmin_port="$port_choice"
            step=6
            ;;
        6)
            rc=0
            port_choice="$(choose_port "Choose Mailpit port:" "$DEFAULT_MAILPIT_PORT")" || rc=$?
            if [ "$rc" -eq 2 ]; then
                step=5
                continue
            fi
            if [ "$rc" -ne 0 ]; then
                exit 1
            fi

            if [ "$port_choice" = "$wordpress_port" ] || [ "$port_choice" = "$phpmyadmin_port" ]; then
                echo "Mailpit port must be different from WordPress and phpMyAdmin ports." >&2
                continue
            fi

            mailpit_port="$port_choice"
            break
            ;;
    esac
done

wordpress_url="$(localhost_url "$wordpress_port")"
phpmyadmin_url="$(localhost_url "$phpmyadmin_port")"
mailpit_url="$(localhost_url "$mailpit_port")"

set_env_value "PHP_VERSION" "$php_version" "$ENV_FILE"
set_env_value "WORDPRESS_OPTIONAL_PLUGIN" "$optional_plugin" "$ENV_FILE"
set_env_value "WORDPRESS_ADMIN_USER" "$wordpress_admin_user" "$ENV_FILE"
set_env_value "WORDPRESS_ADMIN_PASSWORD" "$wordpress_admin_password" "$ENV_FILE"
set_env_value "WORDPRESS_ADMIN_PASSWORD_BASE64" "$wordpress_admin_password_base64" "$ENV_FILE"
set_env_value "WORDPRESS_ADMIN_EMAIL" "$wordpress_admin_email" "$ENV_FILE"
set_env_value "WORDPRESS_PORT" "$wordpress_port" "$ENV_FILE"
set_env_value "WORDPRESS_URL" "$wordpress_url" "$ENV_FILE"
set_env_value "PHPMYADMIN_PORT" "$phpmyadmin_port" "$ENV_FILE"
set_env_value "MAILPIT_PORT" "$mailpit_port" "$ENV_FILE"

echo "Starting WordPress with PHP ${php_version}..."
echo "WordPress URL: ${wordpress_url}"
echo "phpMyAdmin URL: ${phpmyadmin_url}"
echo "Mailpit URL: ${mailpit_url}"

if [ "$previous_php_version" != "$php_version" ]; then
    echo "Rebuilding image because PHP version changed."
    docker compose up -d --build
else
    docker compose up -d
fi
