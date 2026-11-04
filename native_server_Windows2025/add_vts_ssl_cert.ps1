# ==============================================================================
# add_vts_ssl_cert.ps1 - Generate & Configure SSL Certificate for OpenText VTS
# ==============================================================================
# Target: Windows Server 2025 (PowerShell 5.1 / 7.x)
# Description: Generates a self-signed SAN SSL certificate and RSA private key
#              directly on Windows (no external downloads needed), exports them
#              to PEM (.crt and .key), configures configure.json, adds local DNS,
#              and restarts the Virtual Table Server service.
# Run this script in PowerShell as Administrator:
#   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
#   .\add_vts_ssl_cert.ps1
# ==============================================================================

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "     OpenText VTS Native SSL Certificate Setup            " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$webDir = "F:\VTS26.1\web"
$configPath = "$webDir\configure.json"
$certPath = "$webDir\vts_win.crt"
$keyPath = "$webDir\vts_win.key"
$domain = "localvts.com"
$ipAddress = "192.168.122.250"

if (-not (Test-Path $configPath)) {
    Write-Host "ERROR: $configPath not found! Ensure VTS is installed in F:\VTS26.1" -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------------------
# STEP 1: Generate Self-Signed Certificate and Export PEM Files
# ------------------------------------------------------------------------------
Write-Host "`n[1/4] Generating SSL Certificate and RSA Private Key..." -ForegroundColor Yellow

$openSslCmd = Get-Command openssl -ErrorAction SilentlyContinue

if ($openSslCmd) {
    Write-Host "  -> OpenSSL detected. Generating certificate using OpenSSL CLI..." -ForegroundColor Cyan
    & openssl req -x509 -nodes -days 730 -newkey rsa:2048 `
        -keyout $keyPath `
        -out $certPath `
        -subj "/C=US/ST=State/L=City/O=Enterprise/OU=Performance/CN=$domain" `
        -addext "subjectAltName=DNS:$domain,DNS:vts-server.local,IP:$ipAddress"
} else {
    Write-Host "  -> OpenSSL not found. Generating certificate using native PowerShell..." -ForegroundColor Cyan

    # Generate Self-Signed Certificate in Windows Certificate Store
    $cert = New-SelfSignedCertificate -DnsName $domain, "vts-server.local", $ipAddress `
        -CertStoreLocation "Cert:\LocalMachine\My" `
        -KeyExportPolicy Exportable `
        -KeySpec Signature `
        -KeyLength 2048 `
        -KeyAlgorithm RSA `
        -HashAlgorithm SHA256 `
        -NotAfter (Get-Date).AddYears(2) `
        -Subject "CN=$domain, O=Enterprise, OU=Performance"

    Write-Host "  -> Certificate generated with Thumbprint: $($cert.Thumbprint)" -ForegroundColor Green

    # 1. Export Public Certificate as PEM (.crt)
    $certBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $certBase64 = [System.Convert]::ToBase64String($certBytes, [System.Base64FormattingOptions]::InsertLineBreaks)
    $certPem = "-----BEGIN CERTIFICATE-----`r`n$certBase64`r`n-----END CERTIFICATE-----`r`n"
    [System.IO.File]::WriteAllText($certPath, $certPem)
    Write-Host "  -> Exported Public Certificate to: $certPath" -ForegroundColor Green

    # 2. Export RSA Private Key as PEM (.key)
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    
    # Check if modern .NET method ExportPkcs8PrivateKey is available (.NET 5+ / PowerShell 7)
    $pkcs8Method = $rsa.GetType().GetMethod("ExportPkcs8PrivateKey", [type]::EmptyTypes)
    if ($pkcs8Method) {
        $keyBytes = $pkcs8Method.Invoke($rsa, $null)
        $keyBase64 = [System.Convert]::ToBase64String($keyBytes, [System.Base64FormattingOptions]::InsertLineBreaks)
        $keyPem = "-----BEGIN PRIVATE KEY-----`r`n$keyBase64`r`n-----END PRIVATE KEY-----`r`n"
        [System.IO.File]::WriteAllText($keyPath, $keyPem)
    } else {
        # Pure .NET Framework 4.8 / PowerShell 5.1 ASN.1 PKCS#1 DER encoder
        $rsaParams = $rsa.ExportParameters($true)

        function Encode-Length([int]$Length) {
            if ($Length -lt 128) { return [byte[]]@([byte]$Length) }
            $bytes = New-Object System.Collections.Generic.List[byte]
            $temp = $Length
            while ($temp -gt 0) {
                $bytes.Insert(0, [byte]($temp -band 0xFF))
                $temp = $temp -shr 8
            }
            $header = [byte](0x80 -bor $bytes.Count)
            return ,@($header) + $bytes.ToArray()
        }

        function Encode-Integer([byte[]]$Data) {
            if ($Data[0] -ge 0x80) { $Data = ,@([byte]0x00) + $Data }
            $len = Encode-Length $Data.Length
            return ,@([byte]0x02) + $len + $Data
        }

        $stream = New-Object System.Collections.Generic.List[byte]
        $stream.AddRange((Encode-Integer @([byte]0x00))) # Version 0
        $stream.AddRange((Encode-Integer $rsaParams.Modulus))
        $stream.AddRange((Encode-Integer $rsaParams.Exponent))
        $stream.AddRange((Encode-Integer $rsaParams.D))
        $stream.AddRange((Encode-Integer $rsaParams.P))
        $stream.AddRange((Encode-Integer $rsaParams.Q))
        $stream.AddRange((Encode-Integer $rsaParams.DP))
        $stream.AddRange((Encode-Integer $rsaParams.DQ))
        $stream.AddRange((Encode-Integer $rsaParams.InverseQ))

        $seqLen = Encode-Length $stream.Count
        $der = ,@([byte]0x30) + $seqLen + $stream.ToArray()

        $keyBase64 = [System.Convert]::ToBase64String($der, [System.Base64FormattingOptions]::InsertLineBreaks)
        $keyPem = "-----BEGIN RSA PRIVATE KEY-----`r`n$keyBase64`r`n-----END RSA PRIVATE KEY-----`r`n"
        [System.IO.File]::WriteAllText($keyPath, $keyPem)
    }
    Write-Host "  -> Exported RSA Private Key to: $keyPath" -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# STEP 2: Update configure.json with Native SSL Parameters
# ------------------------------------------------------------------------------
Write-Host "`n[2/4] Updating configure.json with SSL Configuration..." -ForegroundColor Yellow
Copy-Item $configPath "$configPath.pre_ssl.bak" -Force

$json = Get-Content $configPath -Raw | ConvertFrom-Json
$json.admin.useSSL = $true
$json.admin.certificate = "F:\\VTS26.1\\web\\vts_win.crt"
$json.admin.privateKey = "F:\\VTS26.1\\web\\vts_win.key"
$json.admin.ca = "F:\\VTS26.1\\web\\vts_win.crt"
$json.admin.minVersion = "TLSv1.2"
$json.admin.maxVersion = "TLSv1.3"

$updatedJson = $json | ConvertTo-Json -Depth 15
[System.IO.File]::WriteAllText($configPath, $updatedJson)
Write-Host "  -> admin.useSSL set to: true" -ForegroundColor Green
Write-Host "  -> admin.certificate set to: F:\VTS26.1\web\vts_win.crt" -ForegroundColor Green
Write-Host "  -> admin.privateKey set to: F:\VTS26.1\web\vts_win.key" -ForegroundColor Green
Write-Host "  -> admin.minVersion / maxVersion: TLSv1.2 / TLSv1.3" -ForegroundColor Green

# ------------------------------------------------------------------------------
# STEP 3: Add Hostname to Local hosts File
# ------------------------------------------------------------------------------
Write-Host "`n[3/4] Updating Windows Hosts File..." -ForegroundColor Yellow
$hostsPath = "C:\Windows\System32\drivers\etc\hosts"
$hostsText = Get-Content $hostsPath -Raw -ErrorAction SilentlyContinue
if ($hostsText -notlike "*$domain*") {
    Add-Content -Path $hostsPath -Value "`n$ipAddress $domain vts-server.local"
    Write-Host "  -> Added '$ipAddress $domain vts-server.local' to $hostsPath" -ForegroundColor Green
} else {
    Write-Host "  -> Host entry for $domain already exists in hosts file." -ForegroundColor Cyan
}

# ------------------------------------------------------------------------------
# STEP 4: Restart VTS Windows Service and Verify
# ------------------------------------------------------------------------------
Write-Host "`n[4/4] Restarting OpenText VTS Service..." -ForegroundColor Yellow
$vtsService = Get-Service | Where-Object { $_.DisplayName -like "*Virtual Table Server*" -or $_.Name -like "*VTS*" }

if ($vtsService) {
    Restart-Service -Name $vtsService.Name -Force
    Write-Host "  -> Service '$($vtsService.DisplayName)' restarted successfully!" -ForegroundColor Green
} else {
    Write-Host "  -> WARNING: VTS Service not found. Please restart manually via services.msc" -ForegroundColor Yellow
}

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host " SSL Setup Complete!" -ForegroundColor Green
Write-Host " HTTPS Web Admin UI: https://$domain`:4000" -ForegroundColor Green
Write-Host " Direct IP Access  : https://$ipAddress`:4000" -ForegroundColor Green
Write-Host " Default Data API  : https://$domain`:8888" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan
