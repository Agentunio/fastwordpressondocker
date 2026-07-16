#!/usr/bin/env bash
set -e

echo "==> Restoring WordPress from manual backup files..."
docker compose exec -T wordpress bash /scripts/restore-manual.sh

echo "Manual restore complete."
