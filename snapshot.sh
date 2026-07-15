#!/usr/bin/env bash
set -e

echo "==> Updating state-0 snapshot from the current WordPress state..."
echo "    (use this after adding plugins/themes that should be part of the base state)"
docker compose exec -T wordpress bash /scripts/snapshot.sh
