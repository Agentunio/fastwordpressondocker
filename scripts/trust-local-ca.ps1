$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSEdition -eq "Core" -and -not $IsWindows) {
    & bash (Join-Path $PSScriptRoot "trust-local-ca.sh")
    if ($LASTEXITCODE -ne 0) {
        throw "The local HTTPS certificate authority could not be trusted."
    }
    return
}

$certificatePath = [IO.Path]::GetTempFileName()
$certificate = $null
$store = $null

Push-Location -LiteralPath (Split-Path -Parent $PSScriptRoot)
try {
    docker compose cp "https:/data/caddy/pki/authorities/local/root.crt" $certificatePath
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read the local HTTPS certificate authority from Caddy."
    }

    $pem = [IO.File]::ReadAllText($certificatePath)
    if ($pem -notmatch '\A\s*-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+)\s*-----END CERTIFICATE-----\s*\z') {
        throw "Caddy did not provide a valid public certificate."
    }
    $rawCertificate = [Convert]::FromBase64String($Matches[1])
    $certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(,$rawCertificate)
    $basicConstraints = $certificate.Extensions | Where-Object { $_.Oid.Value -eq "2.5.29.19" } | Select-Object -First 1
    $keyUsage = $certificate.Extensions | Where-Object { $_.Oid.Value -eq "2.5.29.15" } | Select-Object -First 1
    if (
        $null -eq $basicConstraints -or -not $basicConstraints.CertificateAuthority -or
        $null -eq $keyUsage -or ($keyUsage.KeyUsages -band [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign) -eq 0 -or
        $certificate.HasPrivateKey -or $certificate.Subject -ne $certificate.Issuer -or
        $certificate.NotBefore -gt (Get-Date) -or $certificate.NotAfter -le (Get-Date)
    ) {
        throw "Caddy's certificate is not a current public root certificate authority."
    }

    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store -ArgumentList "Root", "CurrentUser"
    $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    $trusted = @($store.Certificates | Where-Object {
        $_.Thumbprint -eq $certificate.Thumbprint -and
        [Convert]::ToBase64String($_.RawData) -ceq [Convert]::ToBase64String($certificate.RawData)
    }).Count -gt 0
    if (-not $trusted) {
        Write-Host "Trusting this project's local HTTPS certificate authority for the current Windows user."
        $store.Add($certificate)
    }

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $fingerprint = [BitConverter]::ToString($sha256.ComputeHash($certificate.RawData)).Replace("-", "")
    } finally {
        $sha256.Dispose()
    }
    Write-Host "Local certificate authority SHA-256: $fingerprint"
} finally {
    if ($null -ne $store) { $store.Close() }
    if ($null -ne $certificate) { $certificate.Dispose() }
    Remove-Item -LiteralPath $certificatePath -Force -ErrorAction SilentlyContinue
    Pop-Location
}
