#!/usr/bin/env bash
set -e

echo "==> Resetting WordPress to state-0..."
docker compose exec -T wordpress bash /scripts/reset.sh

echo "Reset complete."
