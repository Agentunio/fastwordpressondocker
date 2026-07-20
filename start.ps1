param (
    [switch] $ManualRestore
)

$ErrorActionPreference = "Stop"

$DefaultPhpVersion = "8.3"
$DefaultWordPressPort = "80"
$DefaultPhpMyAdminPort = "8080"
$DefaultMailpitPort = "8025"
$DefaultOptionalPlugin = "none"
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
    if (Test-Path $File) {
        $lines = Get-Content $File
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

    Set-Content -Path $File -Value $updatedLines
}

function Get-EnvValue {
    param (
        [string] $Key,
        [string] $File
    )

    if (-not (Test-Path $File)) {
        return $null
    }

    foreach ($line in Get-Content $File) {
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
        [string] $DefaultPort
    )

    while ($true) {
        $portChoice = Read-MenuChoice $Prompt @("Standard ($DefaultPort)", "Custom") -AllowBack

        if ($null -eq $portChoice) {
            return $null
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

$phpVersion = Get-EnvValueOrDefault "PHP_VERSION" $EnvFile $DefaultPhpVersion
$wordPressPort = Get-EnvValueOrDefault "WORDPRESS_PORT" $EnvFile $DefaultWordPressPort
$phpMyAdminPort = Get-EnvValueOrDefault "PHPMYADMIN_PORT" $EnvFile $DefaultPhpMyAdminPort
$mailpitPort = Get-EnvValueOrDefault "MAILPIT_PORT" $EnvFile $DefaultMailpitPort
$optionalPlugin = Get-EnvValueOrDefault "WORDPRESS_OPTIONAL_PLUGIN" $EnvFile $DefaultOptionalPlugin
$wordPressAdminUser = Get-EnvValueOrDefault "WORDPRESS_ADMIN_USER" $EnvFile $DefaultWordPressAdminUser
$wordPressAdminPassword = Get-EnvValueOrDefault "WORDPRESS_ADMIN_PASSWORD" $EnvFile $DefaultWordPressAdminPassword
$wordPressAdminPasswordBase64 = Get-EnvValue "WORDPRESS_ADMIN_PASSWORD_BASE64" $EnvFile
$wordPressAdminEmail = Get-EnvValueOrDefault "WORDPRESS_ADMIN_EMAIL" $EnvFile $DefaultWordPressAdminEmail
$previousPhpVersion = Get-EnvValue "PHP_VERSION" $EnvFile

if (-not [string]::IsNullOrEmpty($wordPressAdminPasswordBase64)) {
    $wordPressAdminPassword = ""
}


$initialPhpVersion = $phpVersion
$initialOptionalPlugin = $optionalPlugin
$initialWordPressAdminUser = $wordPressAdminUser
$initialWordPressAdminPassword = $wordPressAdminPassword
$initialWordPressAdminPasswordBase64 = $wordPressAdminPasswordBase64
$initialWordPressAdminEmail = $wordPressAdminEmail
$initialWordPressPort = $wordPressPort
$initialPhpMyAdminPort = $phpMyAdminPort
$initialMailpitPort = $mailpitPort

if (Test-Path $EnvFile) {
    $adminModeLabel = Get-AdminModeLabel
    $setupPrompt = "Current settings: PHP $phpVersion, WP port $wordPressPort, phpMyAdmin port $phpMyAdminPort, Mailpit port $mailpitPort, plugins: $optionalPlugin, admin: $wordPressAdminUser ($adminModeLabel)`n`nChoose setup mode:"
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

$phpMyAdminPrompt = "Choose phpMyAdmin port:"
$step = 0
$done = $false

while (-not $done) {
    if ($step -eq 0) {
        $setupMode = Read-MenuChoice $setupPrompt @($keepOption, "Custom settings")

        if ($setupMode -ne "Custom settings") {
            $phpVersion = $initialPhpVersion
            $optionalPlugin = $initialOptionalPlugin
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
        $phpChoice = Read-MenuChoice "Choose PHP version:" @(
            "Standard (PHP $DefaultPhpVersion)",
            "PHP 8.1",
            "PHP 8.2",
            "PHP 8.4",
            "PHP 8.5"
        ) -AllowBack -DefaultOption (Get-PhpVersionLabel $phpVersion)

        if ($null -eq $phpChoice) {
            $step = 0
            continue
        }

        switch ($phpChoice) {
            "Standard (PHP $DefaultPhpVersion)" { $phpVersion = $DefaultPhpVersion }
            "PHP 8.1" { $phpVersion = "8.1" }
            "PHP 8.2" { $phpVersion = "8.2" }
            "PHP 8.4" { $phpVersion = "8.4" }
            "PHP 8.5" { $phpVersion = "8.5" }
        }

        $step = 2
    } elseif ($step -eq 2) {
        $pluginChoice = Read-OptionalPlugins $optionalPlugin

        if ($null -eq $pluginChoice) {
            $step = 1
            continue
        }

        $optionalPlugin = $pluginChoice
        $step = 3
    } elseif ($step -eq 3) {
        $adminChoice = Read-MenuChoice "Choose WordPress administrator:" @(
            "Default WordPress admin",
            "Custom WordPress admin"
        ) -AllowBack -DefaultOption (Get-AdminModeLabel)

        if ($null -eq $adminChoice) {
            $step = 2
            continue
        }

        if ($adminChoice -eq "Default WordPress admin") {
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

        $step = 4
    } elseif ($step -eq 4) {
        $portChoice = Read-PortChoice "Choose WordPress port:" $DefaultWordPressPort

        if ($null -eq $portChoice) {
            $step = 3
            continue
        }

        $wordPressPort = $portChoice
        $phpMyAdminPrompt = "Choose phpMyAdmin port:"
        $step = 5
    } elseif ($step -eq 5) {
        $portChoice = Read-PortChoice $phpMyAdminPrompt $DefaultPhpMyAdminPort

        if ($null -eq $portChoice) {
            $step = 4
            continue
        }

        if ($portChoice -eq $wordPressPort) {
            $phpMyAdminPrompt = "phpMyAdmin port must be different from WordPress port ($wordPressPort).`n`nChoose phpMyAdmin port:"
            continue
        }

        $phpMyAdminPort = $portChoice
        $step = 6
    } else {
        $portChoice = Read-PortChoice "Choose Mailpit port:" $DefaultMailpitPort

        if ($null -eq $portChoice) {
            $step = 5
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

Set-EnvValue "PHP_VERSION" $phpVersion $EnvFile
Set-EnvValue "WORDPRESS_OPTIONAL_PLUGIN" $optionalPlugin $EnvFile
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

Write-Host "Starting WordPress with PHP $phpVersion..."
Write-Host "WordPress URL: $wordPressUrl"
Write-Host "phpMyAdmin URL: $phpMyAdminUrl"
Write-Host "Mailpit URL: $mailpitUrl"

if ($previousPhpVersion -ne $phpVersion) {
    Write-Host "Rebuilding image because PHP version changed."
    docker compose up -d --build
} else {
    docker compose up -d
}

if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if ($ManualRestore) {
    Write-Host "==> Restoring WordPress from manual backup files..." -ForegroundColor Cyan
    docker compose exec -T wordpress bash /scripts/restore-manual.sh
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Write-Host "Manual restore complete." -ForegroundColor Green
}
