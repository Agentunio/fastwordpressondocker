#!/usr/bin/env pwsh
$ErrorActionPreference = "Stop"

Write-Host "==> Overwriting state-0 snapshot with current WordPress state..." -ForegroundColor Cyan
Write-Host "    (uzyj gdy dodales wiecej wtyczek/motywow do stanu bazowego)" -ForegroundColor DarkGray
docker compose exec -T wordpress bash /scripts/snapshot.sh
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Snapshot updated." -ForegroundColor Green
