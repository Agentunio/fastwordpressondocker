#!/bin/bash
set -e

shopt -s nullglob
zip_files=(/plugins/*.zip)
shopt -u nullglob

if [ ${#zip_files[@]} -eq 0 ]; then
    echo "[plugins] No local plugin ZIPs found."
    exit 0
fi

for zip in "${zip_files[@]}"; do
    echo "[plugins] Installing local plugin: $zip"
    wp --allow-root plugin install "$zip" --activate --force
done
