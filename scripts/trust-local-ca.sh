#!/usr/bin/env bash
set -euo pipefail

for dependency in docker openssl; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        echo "ERROR: ${dependency} is required to trust the local HTTPS certificate." >&2
        exit 1
    fi
done

ca_directory="$(mktemp -d)"
trap 'rm -rf -- "$ca_directory"' EXIT
ca_certificate="${ca_directory}/root.crt"
docker compose cp https:/data/caddy/pki/authorities/local/root.crt "$ca_certificate"
openssl x509 -in "$ca_certificate" -noout -text | grep -q 'CA:TRUE'
openssl verify -CAfile "$ca_certificate" "$ca_certificate" >/dev/null
ca_fingerprint="$(openssl x509 -in "$ca_certificate" -noout -sha256 -fingerprint | cut -d= -f2 | tr -d ':')"
ca_label="Fast WordPress ${ca_fingerprint}"

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

case "$(uname -s)" in
    Darwin)
        if ! security verify-cert -c "$ca_certificate" >/dev/null 2>&1; then
            echo "Trusting this project's local HTTPS CA in the macOS System keychain."
            echo "macOS may request your administrator password."
            as_root security add-trusted-cert -d -r trustRoot \
                -k /Library/Keychains/System.keychain "$ca_certificate"
        fi
        security verify-cert -c "$ca_certificate" >/dev/null
        ;;
    Linux)
        nss_databases=()
        for database in \
            "$HOME"/.mozilla/firefox/*/cert9.db \
            "$HOME"/snap/firefox/common/.mozilla/firefox/*/cert9.db \
            "$HOME"/.var/app/org.mozilla.firefox/.mozilla/firefox/*/cert9.db \
            "$HOME"/.pki/nssdb/cert9.db; do
            [ ! -f "$database" ] || nss_databases+=("${database%/cert9.db}")
        done
        if [ "${#nss_databases[@]}" -gt 0 ] && ! command -v certutil >/dev/null 2>&1; then
            echo "ERROR: install the NSS certutil tool (libnss3-tools or nss-tools) and rerun to trust HTTPS in your browser." >&2
            exit 1
        fi
        if ! openssl verify "$ca_certificate" >/dev/null 2>&1; then
            echo "Trusting this project's local HTTPS CA. sudo may request your password."
            if command -v update-ca-certificates >/dev/null 2>&1; then
                as_root install -m 644 "$ca_certificate" "/usr/local/share/ca-certificates/fast-wordpress-${ca_fingerprint}.crt"
                as_root update-ca-certificates
            elif command -v update-ca-trust >/dev/null 2>&1; then
                if [ -d /etc/pki/ca-trust/source/anchors ]; then
                    ca_anchors=/etc/pki/ca-trust/source/anchors
                else
                    ca_anchors=/etc/ca-certificates/trust-source/anchors
                fi
                as_root install -m 644 "$ca_certificate" "${ca_anchors}/fast-wordpress-${ca_fingerprint}.crt"
                as_root update-ca-trust
            else
                echo "ERROR: this system has no supported CA trust updater." >&2
                exit 1
            fi
        fi
        openssl verify "$ca_certificate" >/dev/null
        for database in "${nss_databases[@]}"; do
            certutil -A -d "sql:${database}" -n "$ca_label" -t 'C,,' -i "$ca_certificate"
        done
        ;;
    *)
        echo "ERROR: use start.ps1 on Windows; automatic CA trust supports macOS and Linux here." >&2
        exit 1
        ;;
esac

echo "Local HTTPS CA trusted. Restart an already-open browser if it still reports a certificate error."
