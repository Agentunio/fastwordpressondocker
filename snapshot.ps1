#!/usr/bin/env pwsh
$ErrorActionPreference = "Stop"

Write-Host "==> Updating state-0 snapshot from the current WordPress state..." -ForegroundColor Cyan
Write-Host "    (use this after adding plugins/themes that should be part of the base state)" -ForegroundColor DarkGray
docker compose exec -T wordpress bash /scripts/snapshot.sh
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
