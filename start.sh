#!/usr/bin/env bash
set -euo pipefail

DEFAULT_PHP_VERSION="8.3"
DEFAULT_WORDPRESS_PORT="80"
DEFAULT_PHPMYADMIN_PORT="8080"
DEFAULT_OPTIONAL_PLUGIN="none"
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

choose_option() {
    local prompt="$1"
    shift
    local options=("$@")
    local selected=0
    local key

    if ! { exec 3</dev/tty; } 2>/dev/null; then
        echo "$prompt" >&2
        PS3="Choose option: "
        select option in "${options[@]}"; do
            if [ -n "${option:-}" ]; then
                echo "$option"
                return 0
            fi
            echo "Invalid option. Choose a number from 1 to ${#options[@]}." >&2
        done
    fi

    while true; do
        printf "\033[2J\033[H" >&2
        printf "%s\n\n" "$prompt" >&2

        for i in "${!options[@]}"; do
            if [ "$i" -eq "$selected" ]; then
                printf "> %s\n" "${options[$i]}" >&2
            else
                printf "  %s\n" "${options[$i]}" >&2
            fi
        done

        printf "\nUse Up/Down arrows and Enter.\n" >&2

        IFS= read -rsn1 key <&3 || {
            exec 3<&-
            return 1
        }

        case "$key" in
            $'\x1b')
                IFS= read -rsn2 -t 1 key <&3 || key=""
                case "$key" in
                    "[A")
                        if [ "$selected" -gt 0 ]; then
                            selected=$((selected - 1))
                        else
                            selected=$((${#options[@]} - 1))
                        fi
                        ;;
                    "[B")
                        if [ "$selected" -lt $((${#options[@]} - 1)) ]; then
                            selected=$((selected + 1))
                        else
                            selected=0
                        fi
                        ;;
                esac
                ;;
            ""|$'\r'|$'\n')
                printf "\n" >&2
                echo "${options[$selected]}"
                exec 3<&-
                return 0
                ;;
        esac
    done
}

read_port() {
    local prompt="$1"
    local port

    while true; do
        printf "%s" "$prompt" >&2
        read -r port

        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            echo "$port"
            return 0
        fi

        echo "Invalid port. Enter a number from 1 to 65535." >&2
    done
}

choose_port() {
    local prompt="$1"
    local default_port="$2"
    local port_choice

    port_choice="$(choose_option "$prompt" "Standard (${default_port})" "Custom")"

    if [ "$port_choice" = "Standard (${default_port})" ]; then
        echo "$default_port"
        return 0
    fi

    read_port "Enter custom port: "
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
optional_plugin="$(env_value_or_default "WORDPRESS_OPTIONAL_PLUGIN" "$DEFAULT_OPTIONAL_PLUGIN")"
previous_php_version="$(get_env_value "PHP_VERSION" "$ENV_FILE")"

if [ -f "$ENV_FILE" ]; then
    keep_option="Current settings (PHP ${php_version}, WP port ${wordpress_port}, phpMyAdmin port ${phpmyadmin_port}, plugin: ${optional_plugin})"
else
    keep_option="Default settings"
fi

setup_mode="$(choose_option "Choose setup mode:" "$keep_option" "Custom settings")"

if [ "$setup_mode" = "Custom settings" ]; then
    php_choice="$(choose_option "Choose PHP version:" "Standard (PHP ${DEFAULT_PHP_VERSION})" "PHP 8.1" "PHP 8.2" "PHP 8.4" "PHP 8.5")"

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

    plugin_choice="$(choose_option "Choose optional plugin:" "None" "All-in-One WP Migration" "UpdraftPlus")"

    case "$plugin_choice" in
        "None")
            optional_plugin="none"
            ;;
        "All-in-One WP Migration")
            optional_plugin="all-in-one-wp-migration"
            ;;
        "UpdraftPlus")
            optional_plugin="updraftplus"
            ;;
    esac

    wordpress_port="$(choose_port "Choose WordPress port:" "$DEFAULT_WORDPRESS_PORT")"

    while true; do
        phpmyadmin_port="$(choose_port "Choose phpMyAdmin port:" "$DEFAULT_PHPMYADMIN_PORT")"

        if [ "$phpmyadmin_port" != "$wordpress_port" ]; then
            break
        fi

        echo "phpMyAdmin port must be different from WordPress port (${wordpress_port})." >&2
    done
fi

wordpress_url="$(localhost_url "$wordpress_port")"
phpmyadmin_url="$(localhost_url "$phpmyadmin_port")"

set_env_value "PHP_VERSION" "$php_version" "$ENV_FILE"
set_env_value "WORDPRESS_OPTIONAL_PLUGIN" "$optional_plugin" "$ENV_FILE"
set_env_value "WORDPRESS_PORT" "$wordpress_port" "$ENV_FILE"
set_env_value "WORDPRESS_URL" "$wordpress_url" "$ENV_FILE"
set_env_value "PHPMYADMIN_PORT" "$phpmyadmin_port" "$ENV_FILE"

echo "Starting WordPress with PHP ${php_version}..."
echo "WordPress URL: ${wordpress_url}"
echo "phpMyAdmin URL: ${phpmyadmin_url}"

if [ "$previous_php_version" != "$php_version" ]; then
    echo "Rebuilding image because PHP version changed."
    docker compose up -d --build
else
    docker compose up -d
fi
