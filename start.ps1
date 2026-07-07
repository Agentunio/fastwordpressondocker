$ErrorActionPreference = "Stop"

$DefaultPhpVersion = "8.3"
$DefaultWordPressPort = "80"
$DefaultPhpMyAdminPort = "8080"
$DefaultOptionalPlugin = "none"
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
$optionalPlugin = Get-EnvValueOrDefault "WORDPRESS_OPTIONAL_PLUGIN" $EnvFile $DefaultOptionalPlugin
$previousPhpVersion = Get-EnvValue "PHP_VERSION" $EnvFile

# Snapshots: "Current/Default settings" must not apply edits from an
# abandoned Custom pass reached and backed out of via Left/Backspace.
$initialPhpVersion = $phpVersion
$initialOptionalPlugin = $optionalPlugin
$initialWordPressPort = $wordPressPort
$initialPhpMyAdminPort = $phpMyAdminPort

if (Test-Path $EnvFile) {
    $setupPrompt = "Current settings: PHP $phpVersion, WP port $wordPressPort, phpMyAdmin port $phpMyAdminPort, plugins: $optionalPlugin`n`nChoose setup mode:"
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
            $wordPressPort = $initialWordPressPort
            $phpMyAdminPort = $initialPhpMyAdminPort
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
        $portChoice = Read-PortChoice "Choose WordPress port:" $DefaultWordPressPort

        if ($null -eq $portChoice) {
            $step = 2
            continue
        }

        $wordPressPort = $portChoice
        $phpMyAdminPrompt = "Choose phpMyAdmin port:"
        $step = 4
    } else {
        $portChoice = Read-PortChoice $phpMyAdminPrompt $DefaultPhpMyAdminPort

        if ($null -eq $portChoice) {
            $step = 3
            continue
        }

        if ($portChoice -eq $wordPressPort) {
            $phpMyAdminPrompt = "phpMyAdmin port must be different from WordPress port ($wordPressPort).`n`nChoose phpMyAdmin port:"
            continue
        }

        $phpMyAdminPort = $portChoice
        $done = $true
    }
}

$wordPressUrl = Get-LocalhostUrl $wordPressPort
$phpMyAdminUrl = Get-LocalhostUrl $phpMyAdminPort

Set-EnvValue "PHP_VERSION" $phpVersion $EnvFile
Set-EnvValue "WORDPRESS_OPTIONAL_PLUGIN" $optionalPlugin $EnvFile
Set-EnvValue "WORDPRESS_PORT" $wordPressPort $EnvFile
Set-EnvValue "WORDPRESS_URL" $wordPressUrl $EnvFile
Set-EnvValue "PHPMYADMIN_PORT" $phpMyAdminPort $EnvFile

if (-not [Console]::IsInputRedirected) {
    Clear-Host
}

Write-Host "Starting WordPress with PHP $phpVersion..."
Write-Host "WordPress URL: $wordPressUrl"
Write-Host "phpMyAdmin URL: $phpMyAdminUrl"

if ($previousPhpVersion -ne $phpVersion) {
    Write-Host "Rebuilding image because PHP version changed."
    docker compose up -d --build
} else {
    docker compose up -d
}
