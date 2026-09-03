param (
    [switch] $ManualRestore
)

$ErrorActionPreference = "Stop"

$DefaultPhpVersion = "8.3"
$DefaultWordPressPort = "80"
$DefaultPhpMyAdminPort = "8080"
$DefaultMailpitPort = "8025"
$DefaultOptionalPlugin = "none"
$DefaultWordPressObjectCache = "none"
$DefaultWordPressAdminUser = "admin_qmpgfd"
$DefaultWordPressAdminPassword = "R40U8zp17YlwvQNkDEKgnhx2!@#"
$DefaultWordPressAdminEmail = "admin@example.com"
$EnvFile = ".env"

function Set-EnvValue {
    param (
        [string] $Key,
        [string] $Value,
        [string] $File
    )

    $lines = @()
    if (Test-Path -LiteralPath $File) {
        $lines = Get-Content -LiteralPath $File
    }

    $found = $false
    $updatedLines = @(
        foreach ($line in $lines) {
            if ($line -match "^$([regex]::Escape($Key))=") {
                $found = $true
                "$Key=$Value"
            } else {
                $line
            }
        }
    )

    if (-not $found) {
        $updatedLines = @($updatedLines) + "$Key=$Value"
    }

    Set-Content -LiteralPath $File -Value $updatedLines
}

function Get-EnvValue {
    param (
        [string] $Key,
        [string] $File
    )

    if (-not (Test-Path -LiteralPath $File)) {
        return $null
    }

    foreach ($line in Get-Content -LiteralPath $File) {
        if ($line -match "^$([regex]::Escape($Key))=") {
            return $line.Substring($Key.Length + 1)
        }
    }

    return $null
}

function Get-EnvValueOrDefault {
    param (
        [string] $Key,
        [string] $File,
        [string] $Default
    )

    $value = Get-EnvValue $Key $File

    if ([string]::IsNullOrEmpty($value)) {
        return $Default
    }

    return $value
}

function ConvertTo-SafeDisplayValue {
    param (
        [AllowEmptyString()]
        [string] $Value
    )

    return [regex]::Replace($Value, '[\p{Cc}\p{Cf}]', '?')
}

function Test-SafeEnvValue {
    param (
        [AllowEmptyString()]
        [string] $Value
    )

    return $Value -notmatch '[^\x20-\x7E]'
}

function Test-PortValue {
    param (
        [string] $Value
    )

    $port = 0
    return [int]::TryParse($Value, [ref] $port) -and $port -ge 1 -and $port -le 65535
}

function Test-OptionalPluginsValue {
    param (
        [string] $Value
    )

    if ($Value -eq "none") {
        return $true
    }

    $allowedPlugins = @("all-in-one-wp-migration", "updraftplus", "advanced-custom-fields")
    $plugins = @($Value -split ',', -1)

    if ($plugins.Count -eq 0 -or $plugins -contains "") {
        return $false
    }

    foreach ($plugin in $plugins) {
        if ($allowedPlugins -notcontains $plugin) {
            return $false
        }
    }

    return $true
}

function Assert-EnvFileStructure {
    $item = Get-Item -LiteralPath $EnvFile -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Invalid or unsafe structure in $EnvFile."
    }

    $seenKeys = @{}
    foreach ($line in Get-Content -LiteralPath $EnvFile) {
        if (-not (Test-SafeEnvValue $line)) {
            throw "Invalid or unsafe structure in $EnvFile."
        }

        if ([string]::IsNullOrEmpty($line) -or $line.StartsWith('#')) {
            continue
        }

        if ($line -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=') {
            throw "Invalid or unsafe structure in $EnvFile."
        }

        $key = $Matches[1]
        if ($key -like 'COMPOSE_*' -and $key -ne 'COMPOSE_PROFILES') {
            throw "Invalid or unsafe structure in $EnvFile."
        }

        if ($seenKeys.ContainsKey($key)) {
            throw "Invalid or unsafe structure in $EnvFile."
        }

        $seenKeys[$key] = $true
    }
}

function Assert-CurrentSettings {
    $safeValues = @{
        PHP_VERSION = $phpVersion
        WORDPRESS_PORT = $wordPressPort
        PHPMYADMIN_PORT = $phpMyAdminPort
        MAILPIT_PORT = $mailpitPort
        WORDPRESS_OPTIONAL_PLUGIN = $optionalPlugin
        WORDPRESS_OBJECT_CACHE = $wordPressObjectCache
        WORDPRESS_ADMIN_USER = $wordPressAdminUser
        WORDPRESS_ADMIN_PASSWORD = $wordPressAdminPassword
        WORDPRESS_ADMIN_PASSWORD_BASE64 = $wordPressAdminPasswordBase64
        WORDPRESS_ADMIN_EMAIL = $wordPressAdminEmail
    }

    foreach ($entry in $safeValues.GetEnumerator()) {
        if (-not (Test-SafeEnvValue $entry.Value)) {
            throw "Invalid $($entry.Key) in $EnvFile."
        }
    }

    if (@("8.1", "8.2", "8.3", "8.4", "8.5") -notcontains $phpVersion) {
        throw "Invalid PHP_VERSION in $EnvFile."
    }

    foreach ($portEntry in @{
        WORDPRESS_PORT = $wordPressPort
        PHPMYADMIN_PORT = $phpMyAdminPort
        MAILPIT_PORT = $mailpitPort
    }.GetEnumerator()) {
        if (-not (Test-PortValue $portEntry.Value)) {
            throw "Invalid $($portEntry.Key) in $EnvFile."
        }
    }

    if (-not (Test-OptionalPluginsValue $optionalPlugin)) {
        throw "Invalid WORDPRESS_OPTIONAL_PLUGIN in $EnvFile."
    }

    if (@("none", "redis", "memcached") -notcontains $wordPressObjectCache) {
        throw "Invalid WORDPRESS_OBJECT_CACHE in $EnvFile."
    }

    if ($wordPressAdminUser -notmatch '^[A-Za-z0-9._@-]{1,60}$') {
        throw "Invalid WORDPRESS_ADMIN_USER in $EnvFile."
    }

    if ($wordPressAdminEmail -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
        throw "Invalid WORDPRESS_ADMIN_EMAIL in $EnvFile."
    }

    if (
        -not [string]::IsNullOrEmpty($wordPressAdminPasswordBase64) -and
        (
            $wordPressAdminPasswordBase64 -notmatch '^[A-Za-z0-9+/]+={0,2}$' -or
            $wordPressAdminPasswordBase64.Length % 4 -ne 0
        )
    ) {
        throw "Invalid WORDPRESS_ADMIN_PASSWORD_BASE64 in $EnvFile."
    }
}

function Read-MenuChoice {
    param (
        [string] $Prompt,
        [string[]] $Options,
        [switch] $AllowBack,
        [string] $DefaultOption = ""
    )

    if ($Options.Count -eq 0) {
        throw "No menu options available."
    }

    if ([Console]::IsInputRedirected) {
        return Read-MenuChoiceByNumber $Prompt $Options
    }

    $hint = "Use Up/Down arrows and Enter."
    if ($AllowBack) {
        $hint = "Use Up/Down arrows and Enter. Left/Backspace = back."
    }

    $selectedIndex = 0
    if ($DefaultOption) {
        for ($i = 0; $i -lt $Options.Count; $i++) {
            if ($Options[$i] -eq $DefaultOption) {
                $selectedIndex = $i
            }
        }
    }

    while ($true) {
        Clear-Host
        Write-Host $Prompt
        Write-Host ""

        for ($i = 0; $i -lt $Options.Count; $i++) {
            if ($i -eq $selectedIndex) {
                Write-Host "> $($Options[$i])" -ForegroundColor Cyan
            } else {
                Write-Host "  $($Options[$i])"
            }
        }

        Write-Host ""
        Write-Host $hint

        try {
            $key = [Console]::ReadKey($true)
        } catch {
            return Read-MenuChoiceByNumber $Prompt $Options
        }

        switch ($key.Key) {
            "UpArrow" {
                if ($selectedIndex -gt 0) {
                    $selectedIndex--
                } else {
                    $selectedIndex = $Options.Count - 1
                }
            }
            "DownArrow" {
                if ($selectedIndex -lt ($Options.Count - 1)) {
                    $selectedIndex++
                } else {
                    $selectedIndex = 0
                }
            }
            "Enter" {
                Write-Host ""
                return $Options[$selectedIndex]
            }
            { $_ -eq "LeftArrow" -or $_ -eq "Backspace" } {
                if ($AllowBack) {
                    return $null
                }
            }
        }
    }
}

function Assert-InputAvailable {
    if ([Console]::IsInputRedirected -and [Console]::In.Peek() -eq -1) {
        throw "No more input available on redirected stdin."
    }
}

function Read-MenuChoiceByNumber {
    param (
        [string] $Prompt,
        [string[]] $Options
    )

    while ($true) {
        Assert-InputAvailable
        Write-Host ""
        Write-Host $Prompt
        for ($i = 0; $i -lt $Options.Count; $i++) {
            Write-Host "$($i + 1)) $($Options[$i])"
        }

        $rawChoice = Read-Host "Choose option"
        $choice = 0

        if ([int]::TryParse($rawChoice, [ref] $choice) -and $choice -ge 1 -and $choice -le $Options.Count) {
            return $Options[$choice - 1]
        }

        Write-Host "Invalid option. Choose a number from 1 to $($Options.Count)."
    }
}

function Test-OptionalPluginSelected {
    param (
        [string] $SelectedPlugins,
        [string] $Slug
    )

    $selectedValues = @($SelectedPlugins -split "," | ForEach-Object { $_.Trim() })
    return ($selectedValues -contains $Slug)
}

function Read-OptionalPluginsByNumber {
    while ($true) {
        Assert-InputAvailable
        Write-Host ""
        Write-Host "Choose optional plugins:"
        Write-Host "1) None"
        Write-Host "2) All-in-One WP Migration"
        Write-Host "3) UpdraftPlus"
        Write-Host "4) Advanced Custom Fields"

        $rawChoice = Read-Host "Choose options separated by comma (empty = none)"
        $rawChoice = ($rawChoice -replace "\s", "")

        if ([string]::IsNullOrEmpty($rawChoice) -or $rawChoice -eq "1") {
            return "none"
        }

        $choices = @($rawChoice -split ",")

        if ($choices -contains "1") {
            return "none"
        }

        $selectedPlugins = @()
        $valid = $true

        foreach ($choice in $choices) {
            switch ($choice) {
                "2" { $slug = "all-in-one-wp-migration" }
                "3" { $slug = "updraftplus" }
                "4" { $slug = "advanced-custom-fields" }
                default { $valid = $false }
            }

            if ($valid -and $choice -ne "1" -and $selectedPlugins -notcontains $slug) {
                $selectedPlugins += $slug
            }
        }

        if ($valid) {
            if ($selectedPlugins.Count -eq 0) {
                return "none"
            }

            return ($selectedPlugins -join ",")
        }

        Write-Host "Invalid option. Choose numbers from 1 to 4."
    }
}

function Read-OptionalPlugins {
    param (
        [string] $CurrentPlugins
    )

    $labels = @(
        "None",
        "All-in-One WP Migration",
        "UpdraftPlus",
        "Advanced Custom Fields",
        "Confirm"
    )
    $slugs = @(
        "none",
        "all-in-one-wp-migration",
        "updraftplus",
        "advanced-custom-fields"
    )
    $confirmIndex = $labels.Count - 1
    $checked = @($false, $false, $false, $false)

    if ([string]::IsNullOrEmpty($CurrentPlugins) -or $CurrentPlugins -eq "none") {
        $checked[0] = $true
    } else {
        for ($i = 1; $i -lt $slugs.Count; $i++) {
            if (Test-OptionalPluginSelected $CurrentPlugins $slugs[$i]) {
                $checked[$i] = $true
            }
        }
    }

    if (-not ($checked[1] -or $checked[2] -or $checked[3])) {
        $checked[0] = $true
    }

    if ([Console]::IsInputRedirected) {
        return Read-OptionalPluginsByNumber
    }

    $selectedIndex = 0

    while ($true) {
        Clear-Host
        Write-Host "Choose optional plugins:"
        Write-Host ""

        for ($i = 0; $i -lt $labels.Count; $i++) {
            if ($i -eq $confirmIndex) {
                if ($i -eq $selectedIndex) {
                    Write-Host "> $($labels[$i])" -ForegroundColor Cyan
                } else {
                    Write-Host "  $($labels[$i])"
                }
                continue
            }

            if ($checked[$i]) {
                $mark = "x"
            } else {
                $mark = " "
            }

            if ($i -eq $selectedIndex) {
                Write-Host "> [$mark] $($labels[$i])" -ForegroundColor Cyan
            } else {
                Write-Host "  [$mark] $($labels[$i])"
            }
        }

        Write-Host ""
        Write-Host "Enter/Space toggles, Confirm continues, Left/Backspace = back."

        try {
            $key = [Console]::ReadKey($true)
        } catch {
            return Read-OptionalPluginsByNumber
        }

        $toggle = $false

        switch ($key.Key) {
            "UpArrow" {
                if ($selectedIndex -gt 0) {
                    $selectedIndex--
                } else {
                    $selectedIndex = $labels.Count - 1
                }
            }
            "DownArrow" {
                if ($selectedIndex -lt ($labels.Count - 1)) {
                    $selectedIndex++
                } else {
                    $selectedIndex = 0
                }
            }
            "Spacebar" {
                if ($selectedIndex -ne $confirmIndex) {
                    $toggle = $true
                }
            }
            "Enter" {
                if ($selectedIndex -ne $confirmIndex) {
                    $toggle = $true
                } else {
                    $selectedPlugins = @()

                    for ($i = 1; $i -lt $slugs.Count; $i++) {
                        if ($checked[$i]) {
                            $selectedPlugins += $slugs[$i]
                        }
                    }

                    Write-Host ""

                    if ($selectedPlugins.Count -eq 0) {
                        return "none"
                    }

                    return ($selectedPlugins -join ",")
                }
            }
            { $_ -eq "LeftArrow" -or $_ -eq "Backspace" } {
                return $null
            }
        }

        if ($toggle) {
            if ($selectedIndex -eq 0) {
                $checked = @($true, $false, $false, $false)
            } else {
                $checked[0] = $false
                $checked[$selectedIndex] = -not $checked[$selectedIndex]

                if (-not ($checked[1] -or $checked[2] -or $checked[3])) {
                    $checked[0] = $true
                }
            }
        }
    }
}

function Read-Port {
    param (
        [string] $Prompt
    )

    while ($true) {
        $rawPort = Read-Host $Prompt

        if ([string]::IsNullOrWhiteSpace($rawPort)) {
            return $null
        }

        $port = 0

        if ([int]::TryParse($rawPort, [ref] $port) -and $port -ge 1 -and $port -le 65535) {
            return $port.ToString()
        }

        Write-Host "Invalid port. Enter a number from 1 to 65535."
    }
}

function Read-PortChoice {
    param (
        [string] $Prompt,
        [string] $DefaultPort,
        [AllowEmptyString()]
        [string] $CurrentPort = ""
    )

    while ($true) {
        $currentOption = ""
        if (-not [string]::IsNullOrEmpty($CurrentPort)) {
            $currentOption = "Current settings ($(ConvertTo-SafeDisplayValue $CurrentPort))"
            $portChoice = Read-MenuChoice -Prompt $Prompt -Options @($currentOption, "Custom") -AllowBack
        } else {
            $portChoice = Read-MenuChoice -Prompt $Prompt -Options @("Standard ($DefaultPort)", "Custom") -AllowBack
        }

        if ($null -eq $portChoice) {
            return $null
        }

        if ($currentOption -and $portChoice -eq $currentOption) {
            return $CurrentPort
        }

        if ($portChoice -eq "Standard ($DefaultPort)") {
            return $DefaultPort
        }

        $port = Read-Port "Enter custom port (empty = back)"

        if ($null -eq $port) {
            continue
        }

        return $port
    }
}

function ConvertFrom-SecureValue {
    param (
        [System.Security.SecureString] $Value
    )

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)

    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Read-CustomAdmin {
    while ($true) {
        $username = Read-Host "Enter admin username (empty = back)"

        if ([string]::IsNullOrEmpty($username)) {
            return $null
        }

        if ($username -match '^[A-Za-z0-9._@-]{1,60}$') {
            break
        }

        Write-Host "Invalid username. Use 1-60 letters, numbers, dots, underscores, @ or hyphens."
    }

    while ($true) {
        $email = Read-Host "Enter admin email (empty = back)"

        if ([string]::IsNullOrEmpty($email)) {
            return $null
        }

        if ($email -match '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
            break
        }

        Write-Host "Invalid email address."
    }

    while ($true) {
        $password = ConvertFrom-SecureValue (Read-Host "Enter admin password (empty = back)" -AsSecureString)

        if ([string]::IsNullOrEmpty($password)) {
            return $null
        }

        $passwordConfirmation = ConvertFrom-SecureValue (Read-Host "Repeat admin password" -AsSecureString)

        if ($password -ceq $passwordConfirmation) {
            break
        }

        Write-Host "Passwords do not match."
    }

    return [PSCustomObject]@{
        User = $username
        Email = $email
        PasswordBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($password))
    }
}

function Get-AdminModeLabel {
    if (
        $wordPressAdminUser -eq $DefaultWordPressAdminUser -and
        $wordPressAdminPassword -eq $DefaultWordPressAdminPassword -and
        [string]::IsNullOrEmpty($wordPressAdminPasswordBase64) -and
        $wordPressAdminEmail -eq $DefaultWordPressAdminEmail
    ) {
        return "Default WordPress admin"
    }

    return "Custom WordPress admin"
}

function Get-LocalhostUrl {
    param (
        [string] $Port
    )

    if ($Port -eq "80") {
        return "http://localhost"
    }

    return "http://localhost:$Port"
}

$envItem = Get-Item -LiteralPath $EnvFile -Force -ErrorAction SilentlyContinue
if (
    $null -ne $envItem -and
    (
        $envItem.PSIsContainer -or
        ($envItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    )
) {
    throw "Invalid or unsafe structure in $EnvFile."
}

$hasCurrentSettings = $null -ne $envItem

$phpVersion = Get-EnvValueOrDefault "PHP_VERSION" $EnvFile $DefaultPhpVersion
$wordPressPort = Get-EnvValueOrDefault "WORDPRESS_PORT" $EnvFile $DefaultWordPressPort
$phpMyAdminPort = Get-EnvValueOrDefault "PHPMYADMIN_PORT" $EnvFile $DefaultPhpMyAdminPort
$mailpitPort = Get-EnvValueOrDefault "MAILPIT_PORT" $EnvFile $DefaultMailpitPort
$optionalPlugin = Get-EnvValueOrDefault "WORDPRESS_OPTIONAL_PLUGIN" $EnvFile $DefaultOptionalPlugin
$wordPressObjectCache = (Get-EnvValueOrDefault "WORDPRESS_OBJECT_CACHE" $EnvFile $DefaultWordPressObjectCache).ToLowerInvariant()
$wordPressAdminUser = Get-EnvValueOrDefault "WORDPRESS_ADMIN_USER" $EnvFile $DefaultWordPressAdminUser
$wordPressAdminPassword = Get-EnvValueOrDefault "WORDPRESS_ADMIN_PASSWORD" $EnvFile $DefaultWordPressAdminPassword
$wordPressAdminPasswordBase64 = Get-EnvValue "WORDPRESS_ADMIN_PASSWORD_BASE64" $EnvFile
$wordPressAdminEmail = Get-EnvValueOrDefault "WORDPRESS_ADMIN_EMAIL" $EnvFile $DefaultWordPressAdminEmail
$previousPhpVersion = Get-EnvValue "PHP_VERSION" $EnvFile
$previousWordPressObjectCache = Get-EnvValue "WORDPRESS_OBJECT_CACHE" $EnvFile

if ($hasCurrentSettings) {
    Assert-EnvFileStructure
    Assert-CurrentSettings
}

if (@("none", "redis", "memcached") -notcontains $wordPressObjectCache) {
    $wordPressObjectCache = $DefaultWordPressObjectCache
}

if (-not [string]::IsNullOrEmpty($wordPressAdminPasswordBase64)) {
    $wordPressAdminPassword = ""
}


$initialPhpVersion = $phpVersion
$initialOptionalPlugin = $optionalPlugin
$initialWordPressObjectCache = $wordPressObjectCache
$initialWordPressAdminUser = $wordPressAdminUser
$initialWordPressAdminPassword = $wordPressAdminPassword
$initialWordPressAdminPasswordBase64 = $wordPressAdminPasswordBase64
$initialWordPressAdminEmail = $wordPressAdminEmail
$initialWordPressPort = $wordPressPort
$initialPhpMyAdminPort = $phpMyAdminPort
$initialMailpitPort = $mailpitPort
$initialWordPressAdminMode = Get-AdminModeLabel
$initialPhpVersionDisplay = ConvertTo-SafeDisplayValue $initialPhpVersion
$initialOptionalPluginDisplay = ConvertTo-SafeDisplayValue $initialOptionalPlugin
$initialWordPressAdminUserDisplay = ConvertTo-SafeDisplayValue $initialWordPressAdminUser
$initialWordPressPortDisplay = ConvertTo-SafeDisplayValue $initialWordPressPort
$initialPhpMyAdminPortDisplay = ConvertTo-SafeDisplayValue $initialPhpMyAdminPort
$initialMailpitPortDisplay = ConvertTo-SafeDisplayValue $initialMailpitPort

if ($hasCurrentSettings) {
    $adminModeLabel = Get-AdminModeLabel
    $setupPrompt = "Current settings: PHP $initialPhpVersionDisplay, WP port $initialWordPressPortDisplay, phpMyAdmin port $initialPhpMyAdminPortDisplay, Mailpit port $initialMailpitPortDisplay, plugins: $initialOptionalPluginDisplay, object cache: $wordPressObjectCache, admin: $initialWordPressAdminUserDisplay ($adminModeLabel)`n`nChoose setup mode:"
    $keepOption = "Current settings"
} else {
    $setupPrompt = "Choose setup mode:"
    $keepOption = "Default settings"
}

function Get-PhpVersionLabel {
    param (
        [string] $Version
    )

    if ($Version -eq $DefaultPhpVersion) {
        return "Standard (PHP $DefaultPhpVersion)"
    }

    return "PHP $Version"
}

function Get-WordPressObjectCacheLabel {
    param (
        [string] $ObjectCache
    )

    switch ($ObjectCache) {
        "redis" { return "Redis" }
        "memcached" { return "Memcached" }
        default { return "None" }
    }
}

function Stop-UnselectedCache {
    param (
        [string] $ObjectCache
    )

    switch ($ObjectCache) {
        "redis" { docker compose stop memcached }
        "memcached" { docker compose stop redis }
        default { docker compose stop redis memcached }
    }
}

$phpMyAdminPrompt = "Choose phpMyAdmin port:"
$step = 0
$done = $false

while (-not $done) {
    if ($step -eq 0) {
        $setupMode = Read-MenuChoice -Prompt $setupPrompt -Options @($keepOption, "Custom settings")

        if ($setupMode -ne "Custom settings") {
            $phpVersion = $initialPhpVersion
            $optionalPlugin = $initialOptionalPlugin
            $wordPressObjectCache = if ($keepOption -eq "Default settings") {
                $DefaultWordPressObjectCache
            } else {
                $initialWordPressObjectCache
            }
            $wordPressAdminUser = $initialWordPressAdminUser
            $wordPressAdminPassword = $initialWordPressAdminPassword
            $wordPressAdminPasswordBase64 = $initialWordPressAdminPasswordBase64
            $wordPressAdminEmail = $initialWordPressAdminEmail
            $wordPressPort = $initialWordPressPort
            $phpMyAdminPort = $initialPhpMyAdminPort
            $mailpitPort = $initialMailpitPort
            $done = $true
        } else {
            $step = 1
        }
    } elseif ($step -eq 1) {
        $phpOptions = @(
            "Standard (PHP $DefaultPhpVersion)",
            "PHP 8.1",
            "PHP 8.2",
            "PHP 8.4",
            "PHP 8.5"
        )
        $phpDefaultOption = Get-PhpVersionLabel $phpVersion
        $currentPhpOption = ""
        if ($hasCurrentSettings) {
            $currentPhpOption = "Current settings (PHP $initialPhpVersionDisplay)"
            $phpOptions = @($currentPhpOption) + $phpOptions
            $phpDefaultOption = $currentPhpOption
        }

        $phpChoice = Read-MenuChoice -Prompt "Choose PHP version:" -Options $phpOptions -AllowBack -DefaultOption $phpDefaultOption

        if ($null -eq $phpChoice) {
            $step = 0
            continue
        }

        if ($currentPhpOption -and $phpChoice -eq $currentPhpOption) {
            $phpVersion = $initialPhpVersion
        } else {
            switch ($phpChoice) {
                "Standard (PHP $DefaultPhpVersion)" { $phpVersion = $DefaultPhpVersion }
                "PHP 8.1" { $phpVersion = "8.1" }
                "PHP 8.2" { $phpVersion = "8.2" }
                "PHP 8.4" { $phpVersion = "8.4" }
                "PHP 8.5" { $phpVersion = "8.5" }
            }
        }

        $step = 2
    } elseif ($step -eq 2) {
        if ($hasCurrentSettings) {
            $currentPluginOption = "Current settings ($initialOptionalPluginDisplay)"
            $pluginSetupChoice = Read-MenuChoice -Prompt "Choose optional plugins:" -Options @(
                $currentPluginOption,
                "Custom"
            ) -AllowBack

            if ($null -eq $pluginSetupChoice) {
                $step = 1
                continue
            }

            if ($pluginSetupChoice -eq $currentPluginOption) {
                $optionalPlugin = $initialOptionalPlugin
                $step = 3
                continue
            }
        }

        $pluginChoice = Read-OptionalPlugins $optionalPlugin

        if ($null -eq $pluginChoice) {
            if (-not $hasCurrentSettings) {
                $step = 1
            }
            continue
        }

        $optionalPlugin = $pluginChoice
        $step = 3
    } elseif ($step -eq 3) {
        $cacheOptions = @(
            "None",
            "Redis",
            "Memcached"
        )
        $cacheDefaultOption = Get-WordPressObjectCacheLabel $wordPressObjectCache
        $currentCacheOption = ""
        if ($hasCurrentSettings) {
            $currentCacheOption = "Current settings ($(Get-WordPressObjectCacheLabel $initialWordPressObjectCache))"
            $cacheOptions = @($currentCacheOption) + $cacheOptions
            $cacheDefaultOption = $currentCacheOption
        }

        $cacheChoice = Read-MenuChoice -Prompt "Choose WordPress object cache:" -Options $cacheOptions -AllowBack -DefaultOption $cacheDefaultOption

        if ($null -eq $cacheChoice) {
            $step = 2
            continue
        }

        if ($currentCacheOption -and $cacheChoice -eq $currentCacheOption) {
            $wordPressObjectCache = $initialWordPressObjectCache
        } else {
            $wordPressObjectCache = $cacheChoice.ToLowerInvariant()
        }
        $step = 4
    } elseif ($step -eq 4) {
        $adminOptions = @(
            "Default WordPress admin",
            "Custom WordPress admin"
        )
        $adminDefaultOption = Get-AdminModeLabel
        $currentAdminOption = ""
        if ($hasCurrentSettings) {
            $currentAdminOption = "Current settings ($initialWordPressAdminUserDisplay, $initialWordPressAdminMode)"
            $adminOptions = @($currentAdminOption) + $adminOptions
            $adminDefaultOption = $currentAdminOption
        }

        $adminChoice = Read-MenuChoice -Prompt "Choose WordPress administrator:" -Options $adminOptions -AllowBack -DefaultOption $adminDefaultOption

        if ($null -eq $adminChoice) {
            $step = 3
            continue
        }

        if ($currentAdminOption -and $adminChoice -eq $currentAdminOption) {
            $wordPressAdminUser = $initialWordPressAdminUser
            $wordPressAdminPassword = $initialWordPressAdminPassword
            $wordPressAdminPasswordBase64 = $initialWordPressAdminPasswordBase64
            $wordPressAdminEmail = $initialWordPressAdminEmail
        } elseif ($adminChoice -eq "Default WordPress admin") {
            $wordPressAdminUser = $DefaultWordPressAdminUser
            $wordPressAdminPassword = $DefaultWordPressAdminPassword
            $wordPressAdminPasswordBase64 = ""
            $wordPressAdminEmail = $DefaultWordPressAdminEmail
        } else {
            $customAdmin = Read-CustomAdmin

            if ($null -eq $customAdmin) {
                continue
            }

            $wordPressAdminUser = $customAdmin.User
            $wordPressAdminPassword = ""
            $wordPressAdminPasswordBase64 = $customAdmin.PasswordBase64
            $wordPressAdminEmail = $customAdmin.Email
        }

        $step = 5
    } elseif ($step -eq 5) {
        $currentPort = if ($hasCurrentSettings) { $initialWordPressPort } else { "" }
        $portChoice = Read-PortChoice "Choose WordPress port:" $DefaultWordPressPort $currentPort

        if ($null -eq $portChoice) {
            $step = 4
            continue
        }

        $wordPressPort = $portChoice
        $phpMyAdminPrompt = "Choose phpMyAdmin port:"
        $step = 6
    } elseif ($step -eq 6) {
        $currentPort = if ($hasCurrentSettings) { $initialPhpMyAdminPort } else { "" }
        $portChoice = Read-PortChoice $phpMyAdminPrompt $DefaultPhpMyAdminPort $currentPort

        if ($null -eq $portChoice) {
            $step = 5
            continue
        }

        if ($portChoice -eq $wordPressPort) {
            $phpMyAdminPrompt = "phpMyAdmin port must be different from WordPress port ($(ConvertTo-SafeDisplayValue $wordPressPort)).`n`nChoose phpMyAdmin port:"
            continue
        }

        $phpMyAdminPort = $portChoice
        $step = 7
    } else {
        $currentPort = if ($hasCurrentSettings) { $initialMailpitPort } else { "" }
        $portChoice = Read-PortChoice "Choose Mailpit port:" $DefaultMailpitPort $currentPort

        if ($null -eq $portChoice) {
            $step = 6
            continue
        }

        if ($portChoice -eq $wordPressPort -or $portChoice -eq $phpMyAdminPort) {
            Write-Host "Mailpit port must be different from WordPress and phpMyAdmin ports."
            continue
        }

        $mailpitPort = $portChoice
        $done = $true
    }
}

$wordPressUrl = Get-LocalhostUrl $wordPressPort
$phpMyAdminUrl = Get-LocalhostUrl $phpMyAdminPort
$mailpitUrl = Get-LocalhostUrl $mailpitPort

$envBackup = New-TemporaryFile
$envExisted = Test-Path -LiteralPath $EnvFile
$composeExitCode = 0

if ($envExisted) {
    Copy-Item -LiteralPath $EnvFile -Destination $envBackup -Force
}

try {
    if (-not $envExisted) {
        [IO.File]::WriteAllText($EnvFile, "")
    }

    if ($PSVersionTable.PSEdition -eq "Core" -and -not $IsWindows) {
        $privateEnvMode = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite
        [IO.File]::SetUnixFileMode($EnvFile, $privateEnvMode)
    }

    Set-EnvValue "PHP_VERSION" $phpVersion $EnvFile
    Set-EnvValue "WORDPRESS_OPTIONAL_PLUGIN" $optionalPlugin $EnvFile
    Set-EnvValue "WORDPRESS_OBJECT_CACHE" $wordPressObjectCache $EnvFile
    Set-EnvValue "COMPOSE_PROFILES" $wordPressObjectCache $EnvFile
    Set-EnvValue "WORDPRESS_ADMIN_USER" $wordPressAdminUser $EnvFile
    Set-EnvValue "WORDPRESS_ADMIN_PASSWORD" $wordPressAdminPassword $EnvFile
    Set-EnvValue "WORDPRESS_ADMIN_PASSWORD_BASE64" $wordPressAdminPasswordBase64 $EnvFile
    Set-EnvValue "WORDPRESS_ADMIN_EMAIL" $wordPressAdminEmail $EnvFile
    Set-EnvValue "WORDPRESS_PORT" $wordPressPort $EnvFile
    Set-EnvValue "WORDPRESS_URL" $wordPressUrl $EnvFile
    Set-EnvValue "PHPMYADMIN_PORT" $phpMyAdminPort $EnvFile
    Set-EnvValue "MAILPIT_PORT" $mailpitPort $EnvFile

    if (-not [Console]::IsInputRedirected) {
        Clear-Host
    }

    Write-Host "Starting WordPress with PHP $(ConvertTo-SafeDisplayValue $phpVersion)..."
    Write-Host "WordPress URL: $(ConvertTo-SafeDisplayValue $wordPressUrl)"
    Write-Host "phpMyAdmin URL: $(ConvertTo-SafeDisplayValue $phpMyAdminUrl)"
    Write-Host "Mailpit URL: $(ConvertTo-SafeDisplayValue $mailpitUrl)"
    Write-Host "WordPress object cache: $wordPressObjectCache"

    if ([string]::IsNullOrEmpty($previousPhpVersion)) {
        docker compose up -d --build --wait --wait-timeout 360
    } elseif ($previousPhpVersion -ne $phpVersion) {
        Write-Host "Rebuilding image because PHP version changed."
        docker compose up -d --build --wait --wait-timeout 360
    } else {
        docker compose up -d --wait --wait-timeout 360
    }

    $composeExitCode = $LASTEXITCODE
    if ($composeExitCode -ne 0) {
        throw "The new configuration did not become healthy."
    }
} catch {
    Write-Host "ERROR: $($_.Exception.Message) Restoring the previous .env." -ForegroundColor Red

    if ($envExisted) {
        Copy-Item -LiteralPath $envBackup -Destination $EnvFile -Force
        docker compose up -d --wait --wait-timeout 360
        if ($LASTEXITCODE -eq 0) {
            $rollbackObjectCache = if ([string]::IsNullOrEmpty($previousWordPressObjectCache)) {
                "none"
            } else {
                $previousWordPressObjectCache
            }
            Stop-UnselectedCache $rollbackObjectCache
        } else {
            Write-Host "ERROR: the previous configuration could not be restarted automatically." -ForegroundColor Red
        }
    } elseif (Test-Path -LiteralPath $EnvFile) {
        Remove-Item -LiteralPath $EnvFile -Force
    }

    if ($composeExitCode -eq 0) {
        $composeExitCode = 1
    }
    exit $composeExitCode
} finally {
    Remove-Item -LiteralPath $envBackup -Force -ErrorAction SilentlyContinue
}

Stop-UnselectedCache $wordPressObjectCache
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if ($ManualRestore) {
    Write-Host "==> Restoring WordPress from manual backup files..." -ForegroundColor Cyan
    docker compose exec -T wordpress bash /scripts/restore-manual.sh
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Write-Host "Manual restore complete." -ForegroundColor Green
}
