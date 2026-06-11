#!/usr/bin/env pwsh
$ErrorActionPreference = "Stop"

Write-Host "==> Overwriting state-0 snapshot with current WordPress state..." -ForegroundColor Cyan
Write-Host "    (use this after adding plugins/themes that should be part of the base state)" -ForegroundColor DarkGray
docker compose exec -T wordpress bash /scripts/snapshot.sh
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Snapshot updated." -ForegroundColor Green
