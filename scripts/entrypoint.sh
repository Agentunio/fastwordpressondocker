#!/bin/bash
set -e

# Run init in background after original entrypoint completes.
# init.sh polls for wp-load.php and DB readiness, so it can race safely.
(bash /scripts/init.sh 2>&1 | sed 's/^/[init] /') &

exec docker-entrypoint.sh "$@"
