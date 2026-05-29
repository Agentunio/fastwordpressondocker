#!/usr/bin/env bash
set -e

echo "==> Overwriting state-0 snapshot with current WordPress state..."
echo "    (uzyj gdy dodales wiecej wtyczek/motywow do stanu bazowego)"
docker compose exec -T wordpress bash /scripts/snapshot.sh

echo "Snapshot updated."
