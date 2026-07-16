#!/usr/bin/env pwsh
$ErrorActionPreference = "Stop"

Write-Host "==> Restoring WordPress from manual backup files..." -ForegroundColor Cyan
docker compose exec -T wordpress bash /scripts/restore-manual.sh
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Manual restore complete." -ForegroundColor Green
