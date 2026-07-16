#!/bin/bash
set -e

INIT_STATUS_FILE="/tmp/fast-wordpress-init.status"
printf 'running\n' > "$INIT_STATUS_FILE"


(
    set -o pipefail

    if bash /scripts/init.sh 2>&1 | sed 's/^/[init] /'; then
        printf 'ready\n' > "$INIT_STATUS_FILE"
    else
        printf 'failed\n' > "$INIT_STATUS_FILE"
    fi
) &

exec docker-entrypoint.sh "$@"
