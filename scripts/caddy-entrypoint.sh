#!/bin/sh
set -eu

if [ "${WORDPRESS_HTTPS:-0}" != "1" ]; then
    echo "ERROR: the https profile requires WORDPRESS_HTTPS=1." >&2
    exit 1
fi

case "${WORDPRESS_HTTP_VERSION:-1.1}" in
    1.1) FWD_HTTP_PROTOCOLS="h1" ;;
    2) FWD_HTTP_PROTOCOLS="h1 h2" ;;
    *) echo "ERROR: WORDPRESS_HTTP_VERSION must be 1.1 or 2." >&2; exit 1 ;;
esac
export FWD_HTTP_PROTOCOLS

# Caddy's private CA survives Docker volume resets and is never shared with PHP.
umask 077
mkdir -p /data /ca
chmod 700 /data
chmod 755 /ca
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
cp /data/caddy/pki/authorities/local/root.crt /ca/root.crt.tmp
chmod 644 /ca/root.crt.tmp
mv /ca/root.crt.tmp /ca/root.crt

exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
