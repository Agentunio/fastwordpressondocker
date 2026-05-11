#!/usr/bin/env pwsh
$ErrorActionPreference = "Stop"

Write-Host "==> Resetting WordPress to state-0..." -ForegroundColor Cyan
docker compose exec -T wordpress bash /scripts/reset.sh
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Reset complete." -ForegroundColor Green
