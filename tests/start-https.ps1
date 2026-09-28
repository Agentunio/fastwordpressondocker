# Run with PowerShell 7. Docker and certificate trust are mocked in temporary projects.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$oldEnv = "PHP_VERSION=8.4`nWORDPRESS_PORT=89`nWORDPRESS_URL=http://localhost:89`nWORDPRESS_OBJECT_CACHE=redis`nCOMPOSE_PROFILES=redis`n"
$tlsEnv = $oldEnv.Replace("http://localhost:89", "https://localhost:8443").Replace("COMPOSE_PROFILES=redis`n", "COMPOSE_PROFILES=redis,https`n") + "WORDPRESS_HTTPS=1`nWORDPRESS_HTTP_VERSION=2`nWORDPRESS_HTTPS_PORT=8443`n"
$assertions = 0

function Assert-True($Condition, $Message) {
    if (-not $Condition) { throw $Message }
    $script:assertions++
}

function Test-Launcher($Initial, $Parameters, $FailTrust = $false, $FailUp = $false, $ExistingStorage = $false, $FailStorage = "", $EngineOs = "Linux") {
    $directory = Join-Path ([IO.Path]::GetTempPath()) ("fwd-ps-test-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path (Join-Path $directory "scripts") | Out-Null
    try {
        Copy-Item (Join-Path $root "start.ps1") $directory
        Copy-Item (Join-Path $root "scripts/check-wordpress-storage.php") (Join-Path $directory "scripts")
        if ($ExistingStorage) { New-Item -ItemType File -Path (Join-Path $directory "existing-storage") | Out-Null }
        if ($FailStorage) { Set-Content (Join-Path $directory "fail-storage") $FailStorage }
        Set-Content (Join-Path $directory "engine-os") $EngineOs
        if ($null -ne $Initial) { [IO.File]::WriteAllText((Join-Path $directory ".env"), $Initial) }
        $helper = 'Add-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot) "calls") -Value "TRUST"'
        if ($FailTrust) { $helper += '; throw "Simulated trust failure"' }
        [IO.File]::WriteAllText((Join-Path $directory "scripts/trust-local-ca.ps1"), $helper)
        if ($FailUp) { New-Item -ItemType File -Path (Join-Path $directory "fail-up") | Out-Null }
        $Parameters | ConvertTo-Json | Set-Content (Join-Path $directory "parameters.json")
        @'
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
function global:docker {
    $command = $args -join " "
    Add-Content calls "$command|https=$env:WORDPRESS_HTTPS|profiles=$env:COMPOSE_PROFILES"
    $global:LASTEXITCODE = 0
    $failure = if (Test-Path fail-storage) { (Get-Content fail-storage -Raw).Trim() } else { "" }
    if ($command -eq "compose ps --all --quiet wordpress") {
        if ($failure -eq "ps") { $global:LASTEXITCODE = 5; return }
        if (Test-Path existing-storage) { "wordpress-container" }
        return
    }
    if ($command -eq "compose config --format json") {
        if ($failure -eq "config") { $global:LASTEXITCODE = 5; return }
        "{}"
        return
    }
    if ($command.StartsWith("info --format ")) {
        if ($failure -eq "info") { $global:LASTEXITCODE = 5; return }
        (Get-Content engine-os -Raw).Trim()
        return
    }
    if ($command.StartsWith("inspect --format ")) {
        if ($failure -eq "inspect") { $global:LASTEXITCODE = 5; return }
        if ($command.Contains(".Mounts")) { "[]" }
        elseif ($failure -eq "image") { "invalid-image" }
        else { "sha256:" + ("0" * 64) }
        return
    }
    if ($command.StartsWith("run ")) {
        if ($failure -eq "validator") { $global:LASTEXITCODE = 5 }
        return
    }
    if ($command.Contains(" up ") -and (Test-Path fail-up)) {
        Remove-Item fail-up
        $global:LASTEXITCODE = 6
    }
    if ($command.Contains(" exec ") -and $command.Contains("curl")) { $env:WORDPRESS_HTTP_VERSION }
}
function global:Invoke-WebRequest { return @{ StatusCode = 200 } }
$parameters = Get-Content parameters.json -Raw | ConvertFrom-Json -AsHashtable
& ./start.ps1 @parameters
exit $LASTEXITCODE
'@ | Set-Content (Join-Path $directory "runner.ps1")
        $output = & (Get-Process -Id $PID).Path -NoLogo -NoProfile -File (Join-Path $directory "runner.ps1") 2>&1 | Out-String
        $code = $LASTEXITCODE
        $saved = if (Test-Path (Join-Path $directory ".env")) { [IO.File]::ReadAllText((Join-Path $directory ".env")) } else { $null }
        $calls = if (Test-Path (Join-Path $directory "calls")) { Get-Content (Join-Path $directory "calls") -Raw } else { "" }
        return @{ Code = $code; Saved = $saved; Calls = $calls; Output = $output }
    } finally {
        Remove-Item $directory -Recurse -Force
    }
}

$result = Test-Launcher $null @{ WordPressPort = "80" }
Assert-True ($result.Code -eq 0) $result.Output
Assert-True ($result.Saved.Contains("WORDPRESS_URL=http://localhost`n")) "Fresh defaults use HTTP."
Assert-True ($result.Saved.Contains("WORDPRESS_HTTPS=0`n")) "HTTPS defaults to off."
Assert-True (-not $result.Calls.Contains("TRUST")) "Default does not install CA."

$result = Test-Launcher $oldEnv @{ WordPressPort = "89" }
Assert-True ($result.Code -eq 0) $result.Output
Assert-True ($result.Saved.Contains("WORDPRESS_URL=http://localhost:89`n")) "Old env remains HTTP."
Assert-True ($result.Saved.Contains("COMPOSE_PROFILES=redis`n")) "Existing cache is preserved."

foreach ($version in @("1.1", "2")) {
    $result = Test-Launcher $oldEnv @{ WordPressHttps = "1"; WordPressHttpVersion = $version; WordPressHttpsPort = "8443" }
    Assert-True ($result.Code -eq 0) $result.Output
    Assert-True ($result.Saved.Contains("WORDPRESS_URL=https://localhost:8443`n")) "Correct TLS URL."
    Assert-True ($result.Saved.Contains("COMPOSE_PROFILES=redis,https`n")) "Compose combines profiles."
    Assert-True ($result.Calls.Contains("--http$version")) "Selected protocol is checked."
    Assert-True ($result.Calls.Contains("TRUST")) "HTTPS installs CA."
}

$result = Test-Launcher $tlsEnv @{ WordPressHttps = "0" }
Assert-True ($result.Code -eq 0) $result.Output
Assert-True ($result.Saved.Contains("WORDPRESS_URL=http://localhost:89`n")) "Disabling restores HTTP URL."
Assert-True ($result.Saved.Contains("WORDPRESS_HTTP_VERSION=1.1`n")) "Disabling resets HTTP version."
Assert-True ($result.Calls.IndexOf("stop https") -lt $result.Calls.IndexOf(" up ")) "Stop proxy before switching."

$result = Test-Launcher $oldEnv @{ WordPressHttps = "1"; WordPressHttpVersion = "2" } $true
Assert-True ($result.Code -ne 0) "Trust failure exits unsuccessfully."
Assert-True ($result.Saved -ceq $oldEnv) "Trust failure restores original env."
Assert-True ($result.Calls.Contains("stop https|https=0|profiles=redis")) "Rollback stops proxy."
Assert-True (([regex]::Matches($result.Calls, " up ")).Count -eq 2) "Rollback restarts previous configuration."

$result = Test-Launcher $tlsEnv @{ WordPressHttps = "0" } $false $true
Assert-True ($result.Code -ne 0) "Startup failure exits unsuccessfully."
Assert-True ($result.Saved -ceq $tlsEnv) "Startup failure restores TLS env."
Assert-True ($result.Calls.Contains("up -d --wait --wait-timeout 360|https=1|profiles=redis,https")) "Rollback restores TLS profile."

$result = Test-Launcher $oldEnv @{ WordPressHttps = "0"; WordPressHttpVersion = "2" }
Assert-True ($result.Code -ne 0) "HTTP/2 without HTTPS is rejected."
Assert-True ($result.Saved -ceq $oldEnv) "Invalid mode does not change env."
Assert-True ($result.Calls -eq "") "Invalid mode does not invoke Docker."

$result = Test-Launcher $oldEnv @{ WordPressHttps = "1"; WordPressHttpsPort = "0089" }
Assert-True ($result.Code -ne 0) "Port conflict with leading zeros is rejected."
Assert-True ($result.Calls -eq "") "Conflicting ports do not invoke Docker."

$result = Test-Launcher $tlsEnv @{ WordPressHttps = "0" } $false $false $true
Assert-True ($result.Code -eq 0) $result.Output
Assert-True ($result.Calls.Contains("--network none --read-only --cap-drop ALL")) "Storage validator cannot access site data or network."
Assert-True ($result.Calls.IndexOf("run --rm") -lt $result.Calls.IndexOf("stop https")) "Storage is checked before stopping HTTPS."
Assert-True ($result.Calls.IndexOf("stop https") -lt $result.Calls.IndexOf(" up ")) "Safe storage permits switching transport."

foreach ($initial in @($null, $oldEnv, $tlsEnv)) {
    foreach ($stage in @("ps", "config", "info", "inspect", "image", "validator")) {
        $result = Test-Launcher $initial @{ WordPressPort = "89" } $false $false $true $stage
        Assert-True ($result.Code -ne 0) "Storage check failure exits unsuccessfully: $stage"
        Assert-True ($result.Saved -ceq $initial) "Storage check failure restores original env: $stage"
        Assert-True (-not $result.Calls.Contains(" up ")) "Storage rejection does not start or roll back containers: $stage"
        Assert-True (-not $result.Calls.Contains(" stop")) "Storage rejection does not stop containers: $stage"
        Assert-True (-not $result.Calls.Contains("TRUST")) "Storage rejection does not install CA: $stage"
    }
}

$result = Test-Launcher $null @{ WordPressPort = "80" } $false $true
Assert-True ($result.Code -ne 0) "Failed initial startup exits unsuccessfully."
Assert-True ($null -eq $result.Saved) "Failed initial startup removes its new env."
Assert-True ($result.Calls.Contains("compose stop|")) "Failed initial startup stops all attempted services."

foreach ($engine in @("Docker Desktop", "Linux", "docker desktop", "")) {
    $result = Test-Launcher $oldEnv @{ WordPressPort = "89" } $false $false $true "" $engine
    $mode = if ($engine -ceq "Docker Desktop") { "1" } else { "0" }
    Assert-True ($result.Code -eq 0) $result.Output
    Assert-True ($result.Calls.Contains("--env FAST_WORDPRESS_DOCKER_DESKTOP=$mode")) "Only a verified Desktop engine enables storage aliases."
}

Write-Host "PowerShell launcher checks passed: $assertions."
