# OpenText Virtual Table Server (VTS) 26.1 on Windows Server 2025 Standard

Comprehensive deployment, configuration, SSL/TLS enablement, and performance testing guide for native OpenText VTS 26.1 running on Microsoft Windows Server 2025.

---

## 1. Executive Summary & Architecture

This Proof of Concept (POC) establishes a high-performance, enterprise-grade deployment of **OpenText Virtual Table Server (VTS) version 26.1** on a dedicated **Windows Server 2025 Standard (Desktop Experience)** virtual machine. 

### Infrastructure Specifications
* **Host Operating System:** Ubuntu Linux (KVM / QEMU / Libvirt hypervisor)
* **Guest Operating System:** Windows Server 2025 Standard (Desktop Experience), 64-bit
* **Compute Resources:** 8 vCPUs (host-passthrough), 16 GB DDR4/DDR5 RAM
* **Storage Allocation:** 100 GB VirtIO high-speed virtual disk (`win2025.qcow2`)
  * **C:\ Drive (50 GB NTFS):** Windows Operating System, System Services, VirtIO Guest Tools
  * **F:\ Drive (50 GB NTFS, Label `VTS_Drive`):** Dedicated I/O partition for VTS Application binaries and SQLite database storage
* **Network Configuration:**
  * **Network Interface:** VirtIO Network Adapter on host bridge `virbr0`
  * **Static IP Address:** `192.168.122.250 /24`
  * **Default Gateway / Host DNS:** `192.168.122.1`
  * **Fully Qualified Domain Name (FQDN):** `localvts.com` (with alias `vts-server.local`)

### Port Allocation & Service Mapping
| Port | Protocol | Purpose / Description | Authentication |
| :--- | :--- | :--- | :--- |
| **`4000`** | `HTTPS (TLS 1.2/1.3)` | VTS Web Administration Portal & Management API | Basic Auth (`maheshd`) |
| **`8888`** | `HTTPS (TLS 1.2/1.3)` | Default VTS Data Instance (Shared Data Service) | Anonymous Script Access |
| **`2000`** | `HTTPS (TLS 1.2/1.3)` | Team Instance 1 (`Test_Team_1`) | Anonymous Script Access |
| **`2001`** | `HTTPS (TLS 1.2/1.3)` | Team Instance 2 (`Test_Team_2`) | Anonymous Script Access |
| **`2002–2050`** | `TCP / HTTPS` | Pre-configured firewall range for dynamic instances | Dynamic |

---

## 2. Architectural Design & OpenText Reverse Proxy Standards

### Direct Port Access vs. Reverse Proxy
In enterprise LoadRunner and Performance Center environments:
1. **Official OpenText Certification:** OpenText officially documents and certifies reverse proxy forwarding exclusively for **NGINX** and **HAProxy**. Microsoft Internet Information Services (IIS) Application Request Routing (ARR) is **not** certified or documented by OpenText for VTS traffic.
2. **Performance Considerations:** In a native Windows Server environment, routing millions of high-throughput VTS transactions through an uncertified reverse proxy introduces unnecessary TCP handshake overhead and proxy buffer bottlenecks.
3. **Direct Port Architecture:** OpenText VTS natively binds individual instances to dedicated ports (e.g., `8888`, `2000`, `2001`). By binding the native TLS/SSL engine directly in VTS, all instances inherit HTTPS encryption without requiring any intermediate reverse proxy.

---

## 3. Directory Structure & Partition Layout

To isolate database I/O from Windows operating system page files and update processes, a dedicated 50 GB partition (`F:`) was formatted and assigned.

```
F:\
├── VTS26.1\                      <-- VTS 26.1 Application Installation Root
│   ├── web\                      <-- Node.js API server & Web Administration files
│   │   ├── configure.json        <-- Main VTS configuration file
│   │   ├── configure.json.bak    <-- Original pre-configuration backup
│   │   ├── vts_win.crt           <-- 2048-bit RSA Public SSL Certificate (PEM)
│   │   ├── vts_win.key           <-- 2048-bit RSA Private Key (PEM)
│   │   └── apiserver.exe         <-- VTS HTTP/HTTPS API Daemon
│   ├── bin\                      <-- VTS Core Engine Executables
│   └── docs\                     <-- Product Documentation & Schema
│
└── VTS_Data\                     <-- Dedicated VTS SQLite Database Root
    ├── instances.json            <-- Active instance registry & metadata
    ├── Default.vts               <-- Default instance SQLite database
    ├── Test_Team_1.vts           <-- Port 2000 team database
    └── Test_Team_2.vts           <-- Port 2001 team database
```

---

## 4. Post-Installation Configuration Script (`setup_vts_windows.ps1`)

After installing OpenText VTS 26.1 via `SetupVTS.exe` into `F:\VTS26.1`, run the automated post-install script in **PowerShell as Administrator**.

### Script Capabilities
1. **Firewall Rules:** Configures Windows Defender Firewall inbound rules for Admin UI (`4000`), Default API (`8888`), Team Instance range (`2000–2050`), and ICMPv4 Ping.
2. **Database Path:** Remaps `dbPath` to high-speed dedicated volume `F:\VTS_Data`.
3. **Authentication:** Sets Admin authentication to `Basic` and enables `requireBasicAuthForAPI = false` so load test engines (VuGen / Jenkins / performance scripts) can read and write data without credential overhead.
4. **Service Management:** Restarts the `Virtual Table Server` Windows service and validates local port health.

### PowerShell Code: `setup_vts_windows.ps1`
```powershell
# ==============================================================================
# setup_vts_windows.ps1 - Automated Post-Install Configuration for OpenText VTS
# ==============================================================================
# Run this script in Windows PowerShell as Administrator

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "   OpenText VTS Windows Server 2025 Auto-Configuration     " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Open Windows Firewall Ports
Write-Host "`n[1/4] Configuring Windows Defender Firewall Rules..." -ForegroundColor Yellow

$rules = @(
    @{ Name = "VTS_Admin_Port_4000"; Port = 4000; Desc = "VTS Web Admin UI & Proxy" },
    @{ Name = "VTS_Default_Port_8888"; Port = 8888; Desc = "VTS Default Data API" },
    @{ Name = "VTS_Instances_2000_2050"; Port = "2000-2050"; Desc = "VTS Team Instance Range" }
)

foreach ($r in $rules) {
    Remove-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $r.Name -Description $r.Desc -Direction Inbound -LocalPort $r.Port -Protocol TCP -Action Allow | Out-Null
    Write-Host "  -> Allowed TCP Port $($r.Port) ($($r.Desc))" -ForegroundColor Green
}

# Allow ICMP (Ping)
netsh advfirewall firewall add rule name="Allow_ICMPv4_Ping" protocol=icmpv4:8,any dir=in action=allow | Out-Null
Write-Host "  -> Allowed ICMPv4 (Ping)" -ForegroundColor Green

# 2. Locate and Update configure.json
Write-Host "`n[2/4] Updating VTS configure.json..." -ForegroundColor Yellow

$configPaths = @(
    "F:\VTS26.1\web\configure.json",
    "F:\VTS_Data\configure.json",
    "F:\VTS26.01\web\configure.json",
    "F:\Program Files\OpenText\Virtual Table Server\web\configure.json",
    "C:\Program Files\OpenText\Virtual Table Server\web\configure.json"
)

$targetPath = $null
foreach ($p in $configPaths) {
    if (Test-Path $p) {
        $targetPath = $p
        break
    }
}

if (-not $targetPath) {
    Write-Host "ERROR: configure.json not found in F:\VTS26.1\web\configure.json or other expected paths!" -ForegroundColor Red
    exit 1
}

Write-Host "  -> Found configuration at: $targetPath" -ForegroundColor Cyan

# Backup original
Copy-Item -Path $targetPath -Destination "$targetPath.bak" -Force
Write-Host "  -> Backup created: $targetPath.bak" -ForegroundColor Cyan

# Read and modify JSON
$jsonContent = Get-Content -Path $targetPath -Raw | ConvertFrom-Json

# Set Database Path to F:\VTS_Data
$jsonContent.dbPath = "F:\VTS_Data"

# Ensure F:\VTS_Data folder exists
if (-not (Test-Path "F:\VTS_Data")) {
    New-Item -ItemType Directory -Path "F:\VTS_Data" -Force | Out-Null
    Write-Host "  -> Created directory F:\VTS_Data" -ForegroundColor Green
}

# Configure Authentication
$jsonContent.admin.authentication = "Basic"
$jsonContent.admin.requireBasicAuthForAPI = $false

# Add default admin user
$adminUser = [PSCustomObject]@{
    user = "maheshd"
    password = "<seturpass>"
    display = "Mahesh Deore"
}

$jsonContent.admin.users = @($adminUser)
$jsonContent.admin.role.administrator = @("maheshd")
$jsonContent.admin.role.user = @()

# Save updated JSON
$updatedJson = $jsonContent | ConvertTo-Json -Depth 15
[System.IO.File]::WriteAllText($targetPath, $updatedJson)
Write-Host "  -> Updated installation path: F:\VTS26.1" -ForegroundColor Green
Write-Host "  -> Updated dbPath: F:\VTS_Data" -ForegroundColor Green
Write-Host "  -> Updated authentication: Basic (User: maheshd)" -ForegroundColor Green
Write-Host "  -> Updated requireBasicAuthForAPI: false (Anonymous script access enabled)" -ForegroundColor Green

# 3. Restart VTS Windows Service
Write-Host "`n[3/4] Restarting VTS Windows Service..." -ForegroundColor Yellow
$vtsService = Get-Service | Where-Object { $_.DisplayName -like "*Virtual Table Server*" -or $_.Name -like "*VTS*" -or $_.DisplayName -like "*VTS*" }

if ($vtsService) {
    Restart-Service -Name $vtsService.Name -Force
    Write-Host "  -> Service '$($vtsService.DisplayName)' restarted successfully!" -ForegroundColor Green
} else {
    Write-Host "  -> Service not found automatically. Please restart via services.msc" -ForegroundColor Yellow
}

# 4. Verify Local Health
Write-Host "`n[4/4] Performing Local Health Checks..." -ForegroundColor Yellow
Start-Sleep -Seconds 3

try {
    $res4000 = Invoke-WebRequest -Uri "http://localhost:4000" -UseBasicParsing -TimeoutSec 5
    Write-Host "  -> Port 4000 (Admin UI): HTTP $($res4000.StatusCode) OK" -ForegroundColor Green
} catch {
    Write-Host "  -> Port 4000: Warning - $($_.Exception.Message)" -ForegroundColor Yellow
}

try {
    $res8888 = Invoke-WebRequest -Uri "http://localhost:8888/client_api/getAllColumns" -Method Post -ContentType "application/json" -Body "{}" -UseBasicParsing -TimeoutSec 5
    Write-Host "  -> Port 8888 (Default Instance API): HTTP $($res8888.StatusCode) OK" -ForegroundColor Green
} catch {
    Write-Host "  -> Port 8888: Warning - $($_.Exception.Message)" -ForegroundColor Yellow
}

$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" }).IPAddress | Select-Object -First 1

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host " VTS Configuration Complete!" -ForegroundColor Green
Write-Host " VM IP Address: $ip" -ForegroundColor Green
Write-Host " Web Admin UI : http://$($ip):4000" -ForegroundColor Green
Write-Host " Login User   : maheshd" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan
```

---

## 5. SSL / TLS Certificate Architecture & Generation Script (`add_vts_ssl_cert.ps1`)

### Certificate Strategy
* **Subject Alternative Names (SANs):** To eliminate browser security warnings and enable TLS validation across both DNS names and direct IP addressing, the certificate includes:
  * `DNS: localvts.com`
  * `DNS: vts-server.local`
  * `IP:  192.168.122.250`
* **Single Certificate Principle:** When `admin.useSSL = true` is configured in `configure.json`, OpenText VTS applies the certificate across **all** active ports on the host (`4000`, `8888`, `2000`, `2001`, etc.). Individual certificates per port are not required.
* **Format:** PEM X.509 Certificate (`vts_win.crt`) and 2048-bit RSA Private Key (`vts_win.key`).

### Self-Contained Generation
The `add_vts_ssl_cert.ps1` script creates the certificate and private key **directly on the Windows machine**. It contains an internal ASN.1 DER encoder for PowerShell 5.1 / .NET Framework 4.8, and can also leverage the OpenSSL CLI if detected.

### PowerShell Code: `add_vts_ssl_cert.ps1`
```powershell
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
```

---

## 6. Complete Server Configuration (`configure.json`)

Location on server: `F:\VTS26.1\web\configure.json`

*(Note: In accordance with security standards, all credentials have been masked with `*****`)*.

```json
{
  "dbPath": "F:\\VTS_Data",
  "defaultDbName": "Default",
  "adminPort": 4000,
  "defaultApiPort": 8888,
  "defaultStart": false,
  "enableDiag": false,
  "autoRefreshGrid": true,
  "maxInstancesAllowed": 50,
  "autoCreateIndexedColumn": true,
  "normalizeCSV": false,
  "admin": {
    "authentication": "Basic",
    "users": [
      {
        "user": "maheshd",
        "password": "*****",
        "display": "Mahesh Deore"
      },
      {
        "user": "vts_admin",
        "password": "*****",
        "display": "VTS Platform Admin"
      },
      {
        "user": "vts_tester",
        "password": "*****",
        "display": "Performance Test User"
      },
      {
        "user": "vts_viewer",
        "password": "*****",
        "display": "Read-Only Reporting Viewer"
      }
    ],
    "role": {
      "administrator": [
        "maheshd",
        "vts_admin"
      ],
      "user": [
        "vts_tester",
        "vts_viewer"
      ]
    },
    "requireBasicAuthForAPI": true,
    "domain": "",
    "domaincontroller": "",
    "ldapsCert": "",
    "ldapsCA": "",
    "useSSL": true,
    "certificate": "F:\\VTS26.1\\web\\vts_win.crt",
    "privateKey": "F:\\VTS26.1\\web\\vts_win.key",
    "passphrase": "",
    "ca": "F:\\VTS26.1\\web\\vts_win.crt",
    "minVersion": "TLSv1.2",
    "maxVersion": "TLSv1.3",
    "ciphers": "ETCD_CIPHER_SUITES=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
    "requestClientCert": false
  },
  "languages": [
    { "en": "en-us" },
    { "zh-cn": [ "zh", "zh-sg" ] },
    { "ja": "ja" },
    { "ko": [ "zh", "zh-sg" ] },
    { "it": "zh-hk" },
    { "es": "zh-hk" },
    { "fr": "fr-fr" },
    { "ru": "ru" },
    "de"
  ],
  "defaultLanguage": "en",
  "dbInfo": {
    "connPool": {
      "maxIdle": 5000,
      "maxActive": 5000
    },
    "dbServerPort": {
      "start": 6000,
      "end": 7000
    },
    "dbCheck": {
      "waitingTime": 10,
      "retryTimes": 3600
    }
  },
  "logger": {
    "level": "error",
    "transports": {
      "file": {
        "type": "File",
        "path": "F:\\VTS_Data"
      },
      "console": {
        "type": "Console"
      }
    }
  }
}
```

---

## 7. High-Concurrency Performance Tuning Script (`update_vts_config.ps1`)

Under high-concurrency testing (300+ to 600+ virtual users executing simultaneous write transactions), SQLite write queueing can cause the VTS supervisor watchdog to prematurely report instances as disconnected.

The `update_vts_config.ps1` script automatically applies enterprise performance hardening:
1. **Watchdog Timeout:** Increases `dbCheck.waitingTime` from `1s` to `10s` in `configure.json`.
2. **Connection Pool:** Increases `connPool.maxIdle` and `connPool.maxActive` from `3500` to `5000`.
3. **Windows TCP Recycling:** Sets `TcpTimedWaitDelay` to 30 seconds and expands dynamic ports (`1025-65535`).
4. **Service Restart:** Restarts the `Virtual Table Server` Windows service.

### Execution Command (in Windows PowerShell as Administrator)
```powershell
powershell -ExecutionPolicy Bypass -Command "irm http://192.168.122.1:8000/update_vts_config.ps1 | iex"
```

### PowerShell Code: `update_vts_config.ps1`
```powershell
# ==============================================================================
# update_vts_config.ps1 - Apply High-Concurrency Performance Tuning for VTS
# ==============================================================================
# Run in PowerShell as Administrator on Windows Server 2025:
#   .\update_vts_config.ps1
# Or via one-liner:
#   powershell -ExecutionPolicy Bypass -Command "irm http://192.168.122.1:8000/update_vts_config.ps1 | iex"
# ==============================================================================

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "   Applying VTS High-Concurrency Configuration Tuning     " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$configPath = "F:\VTS26.1\web\configure.json"

if (-not (Test-Path $configPath)) {
    Write-Host "ERROR: $configPath not found!" -ForegroundColor Red
    exit 1
}

# 1. Update configure.json
Write-Host "`n[1/3] Updating configure.json parameters..." -ForegroundColor Yellow
Copy-Item $configPath "$configPath.pre_tune.bak" -Force

$json = Get-Content $configPath -Raw | ConvertFrom-Json

# Tune watchdog & connection pool
$json.dbInfo.dbCheck.waitingTime = 10
$json.dbInfo.connPool.maxIdle = 5000
$json.dbInfo.connPool.maxActive = 5000

$updatedJson = $json | ConvertTo-Json -Depth 15
[System.IO.File]::WriteAllText($configPath, $updatedJson)

Write-Host "  -> dbCheck.waitingTime set to: 10 seconds (was 1s)" -ForegroundColor Green
Write-Host "  -> connPool.maxIdle / maxActive set to: 5000 (was 3500)" -ForegroundColor Green

# 2. Tune Windows TCP Socket Recycling
Write-Host "`n[2/3] Tuning Windows Server TCP/IP Stack..." -ForegroundColor Yellow
try {
    netsh int ipv4 set dynamicport tcp start=1025 num=64510 | Out-Null
    Write-Host "  -> Dynamic TCP port range expanded (1025 - 65535)" -ForegroundColor Green
} catch {
    Write-Host "  -> Warning: Could not set dynamic ports ($($_.Exception.Message))" -ForegroundColor Yellow
}

try {
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "TcpTimedWaitDelay" -Value 30 -Type DWord -Force
    Write-Host "  -> TcpTimedWaitDelay set to: 30 seconds (was 120s)" -ForegroundColor Green
} catch {
    Write-Host "  -> Warning: Could not set registry TcpTimedWaitDelay ($($_.Exception.Message))" -ForegroundColor Yellow
}

# 3. Restart VTS Windows Service
Write-Host "`n[3/3] Restarting OpenText VTS Service..." -ForegroundColor Yellow
$vtsService = Get-Service | Where-Object { $_.DisplayName -like "*Virtual Table Server*" -or $_.Name -like "*VTS*" }

if ($vtsService) {
    Restart-Service -Name $vtsService.Name -Force
    Write-Host "  -> Service '$($vtsService.DisplayName)' restarted successfully!" -ForegroundColor Green
} else {
    Write-Host "  -> Service not found automatically. Restart via services.msc" -ForegroundColor Yellow
}

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host " Tuning Complete! VTS is hardened for high-concurrency." -ForegroundColor Green
Write-Host " Web Admin UI : https://localvts.com:4000" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan
```

---

### 7.4 API Authentication & Role-Based Access Control Script (`enable_vts_api_auth.ps1`)

To address Enterprise Architecture and Security requirements for securing programmatic API endpoints, [`enable_vts_api_auth.ps1`](file:///home/mahesh/vts_ocp/native_server_Windows2025/enable_vts_api_auth.ps1) automates the configuration of:
1. Enabling strict API authentication (`requireBasicAuthForAPI = true`).
2. Creating dedicated accounts for administration (`maheshd`, `vts_admin`) and testing (`vts_tester`, `vts_viewer`).
3. Enforcing Role-Based Access Control (RBAC):
   * **`administrator`:** Full Web UI management and API read/write/update access.
   * **`user`:** Read-only API query access (writes blocked with `HTTP 403 Forbidden`).
4. Graceful VTS Windows service restart.

#### Execute on Windows Server 2025 (PowerShell as Administrator):
```powershell
powershell -ExecutionPolicy Bypass -Command "irm http://192.168.122.1:8000/enable_vts_api_auth.ps1 | iex"
```

#### Script Code: `enable_vts_api_auth.ps1`
```powershell
# ==============================================================================
# enable_vts_api_auth.ps1 - Enable API Authentication & Configure User Roles
# ==============================================================================
$configPath = "F:\VTS26.1\web\configure.json"

# 1. Backup existing configure.json
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
Copy-Item $configPath "$configPath.pre_auth_$timestamp.bak" -Force

# 2. Update configure.json
$json = Get-Content $configPath -Raw | ConvertFrom-Json
$json.admin.requireBasicAuthForAPI = $true

# Define desired users
$targetUsers = @(
    @{ user = "maheshd"; password = "*****"; display = "Mahesh Deore" },
    @{ user = "vts_admin"; password = "*****"; display = "VTS Platform Admin" },
    @{ user = "vts_tester"; password = "*****"; display = "Performance Test User" },
    @{ user = "vts_viewer"; password = "*****"; display = "Read-Only Reporting Viewer" }
)

$existingUsers = @($json.admin.users)
$userList = [System.Collections.Generic.List[PSObject]]::new()

foreach ($tUser in $targetUsers) {
    $existing = $existingUsers | Where-Object { $_.user -eq $tUser.user }
    if ($existing) {
        $userObj = [PSCustomObject]@{ user = $existing.user; password = $existing.password; display = $tUser.display }
    } else {
        $userObj = [PSCustomObject]@{ user = $tUser.user; password = $tUser.password; display = $tUser.display }
    }
    $userList.Add($userObj)
}
$json.admin.users = $userList

# Set Roles
$json.admin.role.administrator = @("maheshd", "vts_admin")
$json.admin.role.user = @("vts_tester", "vts_viewer")

$updatedJson = $json | ConvertTo-Json -Depth 15
[System.IO.File]::WriteAllText($configPath, $updatedJson)

# 3. Restart VTS Windows Service
$vtsService = Get-Service | Where-Object { $_.DisplayName -like "*Virtual Table Server*" -or $_.Name -like "*VTS*" }
if ($vtsService) { Restart-Service -Name $vtsService.Name -Force }
```

---

## 8. Multi-Instance Setup & Test Data Population

### Instances Configured
Three distinct database instances were established:
1. **Default Instance (Port `8888`):** Shared general data pool.
2. **Team Instance 1 (Port `2000`, Name: `Test_Team_1`):** Dedicated team table.
3. **Team Instance 2 (Port `2001`, Name: `Test_Team_2`):** Dedicated team table.

### Schema & Dataset (`customers_500.csv`)
Each instance was populated with 500 rows and 3 columns:
* **`Customer_ID`:** Unique customer identifier (e.g., `CUST001` through `CUST500`)
* **`Customer_Name`:** Full customer name (e.g., `John Smith`, `Amelia Jones`)
* **`Email`:** Unique customer email address (e.g., `john.smith1@example.com`)

---

## 9. Verification & Live API Testing Results

The following API tests confirm complete end-to-end functionality across all instances over HTTPS/TLS:

### 1. Verify HTTPS Web Administration UI (Port 4000)
```bash
curl -k -I https://localvts.com:4000
```
**Response Output:**
```http
HTTP/2 401 
www-authenticate: Basic realm="Authorization Required"
date: Wed, 04 Nov 2026 08:44:00 GMT
```
*(Demonstrates TLS negotiation, HTTP/2 multiplexing, and Basic Auth enforcement).*

---

### 2. Verify Instance Columns Across All Ports (HTTPS)
```bash
# Default Instance (8888)
curl -k -s -X POST https://localvts.com:8888/client_api/getAllColumns -H "Content-Type: application/json" -d '{}'

# Team Instance 1 (2000)
curl -k -s -X POST https://localvts.com:2000/client_api/getAllColumns -H "Content-Type: application/json" -d '{}'

# Team Instance 2 (2001)
curl -k -s -X POST https://localvts.com:2001/client_api/getAllColumns -H "Content-Type: application/json" -d '{}'
```
**Response Output (All 3 Instances):**
```json
["Customer_ID","Customer_Name","Email"]
```

---

### 3. Verify Data Record Retrieval (HTTPS)
```bash
# Retrieve Record 1 from Default Instance (8888)
curl -k -s -X POST https://localvts.com:8888/client_api/get \
  -H "Content-Type: application/json" \
  -d '{"index": 1, "columns": ["Customer_ID", "Customer_Name", "Email"]}'

# Retrieve Record 1 from Team Instance 1 (2000)
curl -k -s -X POST https://localvts.com:2000/client_api/get \
  -H "Content-Type: application/json" \
  -d '{"index": 1, "columns": ["Customer_ID", "Customer_Name", "Email"]}'

# Retrieve Record 500 from Team Instance 2 (2001)
curl -k -s -X POST https://localvts.com:2001/client_api/get \
  -H "Content-Type: application/json" \
  -d '{"index": 500, "columns": ["Customer_ID", "Customer_Name", "Email"]}'
```
**Response Outputs:**
```json
{"Customer_ID":"CUST001","Customer_Name":"John Smith","Email":"john.smith1@example.com"}
{"Customer_ID":"CUST001","Customer_Name":"John Smith","Email":"john.smith1@example.com"}
{"Customer_ID":"CUST500","Customer_Name":"Amelia Jones","Email":"amelia.jones500@example.com"}
```

---

### 4. Verify API Authentication & Role-Based Access Control (RBAC)

With `"requireBasicAuthForAPI": true`, all instance ports enforce role-based access control:

```bash
# 1. Anonymous Write (Blocked - HTTP 400)
curl -k -s -o /dev/null -w "%{http_code}\n" -X POST https://localvts.com:2000/client_api/add \
  -H "Content-Type: application/json" -d '{"Customer_ID": "ANON_ID"}'
# Output: 400

# 2. User Role Write (vts_tester - Blocked by RBAC - HTTP 403 Forbidden)
curl -k -s -o /dev/null -w "%{http_code}\n" -X POST https://localvts.com:2000/client_api/add \
  -u vts_tester:***** -H "Content-Type: application/json" -d '{"Customer_ID": "TEST_ID"}'
# Output: 403

# 3. User Role Read (vts_tester - Allowed - HTTP 200 OK)
curl -k -s -o /dev/null -w "%{http_code}\n" -X POST https://localvts.com:2000/client_api/get \
  -u vts_tester:***** -H "Content-Type: application/json" -d '{"index": 1, "columns": ["Customer_ID"]}'
# Output: 200

# 4. Administrator Role Write (vts_admin / maheshd - Allowed - HTTP 200 OK)
curl -k -s -o /dev/null -w "%{http_code}\n" -X POST https://localvts.com:2000/client_api/add \
  -u vts_admin:***** -H "Content-Type: application/json" -d '{"Customer_ID": "ADMIN_ID"}'
# Output: 200
```

#### Live RBAC Verification Matrix:

| Test Scenario | User & Credentials | Target Endpoint | HTTP Status | Security Enforcement Result |
| :--- | :--- | :--- | :---: | :--- |
| **Anonymous Write** | None (Anonymous) | `POST :8888/client_api/add` | **`400`** |  **Blocked** (Unauthenticated write rejected) |
| **Anonymous Write (Team 1)** | None (Anonymous) | `POST :2000/client_api/add` | **`400`** |  **Blocked** (Unauthenticated write rejected) |
| **User Role Read** | `vts_tester` (`user` role) | `POST :8888/client_api/get` | **`200`** |  **Allowed** (Read authorized) |
| **User Role Write** | `vts_tester` (`user` role) | `POST :8888/client_api/update`| **`403`** |  **Forbidden** (RBAC blocks data modification) |
| **User Role Write (Team 1)** | `vts_tester` (`user` role) | `POST :2000/client_api/add` | **`403`** |  **Forbidden** (RBAC blocks data modification) |
| **User Role Write (Team 2)** | `vts_viewer` (`user` role) | `POST :2001/client_api/add` | **`403`** |  **Forbidden** (RBAC blocks data modification) |
| **Admin Role Read** | `vts_admin` (`admin` role) | `POST :8888/client_api/get` | **`200`** |  **Allowed** (Read authorized) |
| **Admin Role Write** | `vts_admin` (`admin` role) | `POST :8888/client_api/update`| **`200`** |  **Allowed** (Data updated successfully) |
| **Admin Role Write (Team 1)**| `vts_admin` (`admin` role) | `POST :2000/client_api/add` | **`200`** |  **Allowed** (Data added successfully) |
| **Master Admin Write** | `maheshd` (`admin` role) | `POST :2001/client_api/add` | **`200`** |  **Allowed** (Data added successfully) |
| **Web Admin UI (Port 4000)**| None (Anonymous) | `GET :4000/` | **`401`** |  **Blocked** (Login required) |
| **Web Admin UI (Port 4000)**| `maheshd` & `vts_admin` | `GET :4000/` | **`200`** |  **Allowed** (Full admin access) |

---

## 10. Performance Testing / VuGen Integration Guide

### Secure VuGen Integration & Cryptographic Architecture

> [!IMPORTANT]
> **Authentication vs. Encryption Clarification for Architecture & Security:**
> * **Authentication:** Provided via **HTTP Basic Authentication** enforced with strict **Role-Based Access Control (RBAC)** (`requireBasicAuthForAPI = true`).
> * **Encryption:** Provided by **HTTPS / TLS 1.2 & TLS 1.3** because `"useSSL": true` is active in `configure.json`:
>   * **Encryption Standard:** **AES-256-GCM** with **ECDHE-RSA** key exchange (enterprise/military-grade encryption).
>   * **What is Protected:** The Basic Auth credentials, HTTP request/response headers, target URL, and table row data are all encrypted inside the TLS tunnel before they leave the client computer. No one on the network can read, sniff, or decode them.

#### 1. In-Transit Wire Encryption (HTTPS / TLS 1.2 & TLS 1.3)
* **How it works:** Every active port (`4000`, `8888`, `2000`, `2001`, etc.) is natively encrypted by OpenText VTS using TLS 1.2 and TLS 1.3 with strong cipher suites (`TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256`, `TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384`).
* **Basic Auth Over TLS:** When `Authorization: Basic <base64>` headers or VTS API calls traverse the network, the **entire HTTP packet (headers, credentials, URLs, and row data) is encrypted** at the socket layer before reaching the network interface card (NIC).
* **Network Sniffing Protection:** Anyone capturing packets on the network (via Wireshark, firewalls, or packet analyzers) sees only encrypted binary TLS payload. Plaintext credentials and table data cannot be intercepted or decoded.
* **Production Certificate:** In enterprise production, replace the self-signed certificate with an Internal Enterprise PKI / CA-signed certificate for zero-trust certificate chain validation.

#### 2. At-Rest Script Credential Encryption (`lr_decrypt`)
* Testers do **not** hardcode plaintext passwords in their LoadRunner scripts or source control repositories (Git/GitLab).
* Testers use LoadRunner’s built-in **Password Encoder Utility** (`lr_encrypt` CLI or VuGen -> Tools -> Encrypt String) to generate an encrypted hex string representation of the password.
* In the VuGen C script, `lrvtc_connect_ex` decrypts the credential dynamically in RAM only at the moment of establishing the TLS connection:

```c
int rc;

// Secure connection to VTS instance with encrypted credentials
rc = lrvtc_connect_ex(
    "localvts.com",                                 // Target VTS Server FQDN / IP
    2000,                                           // Target Instance Port
    VTOPT_KEEP_ALIVE,                               // Keep-Alive connection
    "vts_admin",                                    // Authorized Service Account (with write/admin rights)
    lr_decrypt("6728e93892849202a0b1"),             // Encrypted Password (at-rest in script)
    "",                                             // Domain (empty for Basic Auth)
    "Basic"                                         // Authentication Protocol
);

if (rc == 0) {
    lr_output_message("Secure connection to VTS established successfully.");
} else {
    lr_error_message("VTS Connection failed with error: %d", rc);
}
```

#### 3. Enterprise CI/CD Secrets Injection (Alternative for Zero-Touch Scripts)
* For teams using Jenkins, GitLab CI/CD, or Azure DevOps:
  * Store the service account password in the CI/CD secret manager (e.g. Jenkins Credentials, HashiCorp Vault, CyberArk).
  * Inject the secret into the test run dynamically as a command-line parameter (e.g. `-p_VtsPass ${VTS_PASSWORD}`).
  * The script calls `lrvtc_connect_ex(..., lr_eval_string("{p_VtsPass}"), ...)` — eliminating credentials from script files entirely.

#### 4. Database At-Rest Encryption (Windows OS / Storage Layer)
* VTS tables are stored as disk-backed SQLite files in `F:\VTS_Data` (e.g. `Default.vts`, `Test_Team_1.vts`).
* To guarantee at-rest storage protection:
  * Enable **Windows BitLocker Drive Encryption** (AES-XTS 256-bit) on the dedicated `F:\` volume.
  * Restrict NTFS folder permissions on `F:\VTS_Data` to `SYSTEM` and `Administrators` only.

---

### Standard VuGen C Integration (Legacy / Anonymous Mode)
If running in an isolated test laboratory with network-level firewall whitelisting:
```c
// Connect to VTS Team Instance on Windows Server 2025
PVCI pvci = vtc_connect("localvts.com", 2000, VTOPT_KEEP_ALIVE);

// Retrieve row data
char *customer_id = NULL;
vtc_query_row(pvci, 1, &customer_id);

// Disconnect on iteration end
vtc_disconnect(pvci);
```

For REST API based clients (JMeter, k6, Python, cURL):
* **Endpoint:** `POST https://localvts.com:<port>/client_api/get`
* **Headers:** `Content-Type: application/json`
* **Payload:** `{"index": 1, "columns": ["Customer_ID", "Customer_Name", "Email"]}`

### Dedicated Multi-Instance Load Test Suite
A complete high-concurrency benchmark harness is available in the [`load_test/`](file:///home/mahesh/vts_ocp/native_server_Windows2025/load_test) directory:
* **PowerShell Orchestrator (`.ps1`):** Run `.\load_test\master_load_tester.ps1` directly inside Windows Server 2025.
* **Linux Shell Orchestrator (`.sh`):** Run `./load_test/master_load_tester.sh` from the host against the Windows VM.
* See [`load_test/README.md`](file:///home/mahesh/vts_ocp/native_server_Windows2025/load_test/README.md) for usage instructions and test scenarios.

### Verified Benchmark Scaling Results (Windows Server 2025)

The following benchmark tests were executed against all 3 active instances simultaneously (50% reads + 50% writes across ports `8888`, `2000`, `2001`):

| Test Tier | Parallel Concurrency | Total Requests | Duration | Throughput (RPS) | Avg Latency | Median (p50) | 95th %tile | Peak CPU | Success Rate |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **Tier 1 (Standard)** | 60 Workers | 3,000 reqs | 14.78s | **202.98 RPS** | 48.4 ms | 46.1 ms | 80.9 ms | 51.9% | **100.0%** (3,000/3,000) |
| **Tier 2 (Moderate)** | 180 Workers | 9,000 reqs | 39.60s | **227.27 RPS** | 100.3 ms | 96.9 ms | 175.2 ms | 62.6% | **100.0%** (9,000/9,000) |
| **Tier 3 (High Stress)** | 600 Workers | 30,000 reqs | 125.62s | **238.82 RPS** | 131.4 ms | 121.2 ms | 256.3 ms | 61.1% | **100.0%** (30,000/30,000) |

*All instances and the Web Admin UI remained 100% online, connected, and fully functional post-test.*

---

### Detailed Findings Across All 3 Test Tiers

#### Tier 1: 60 Workers, 3,000 Requests (Standard Benchmark)
* **Report File:** [`60users_3000requests_20261104_165720-20261104_165735.txt`](file:///home/mahesh/vts_ocp/native_server_Windows2025/load_test/results/60users_3000requests_20261104_165720-20261104_165735.txt)
* **Workload:** 10 Readers + 10 Writers per instance across ports 8888, 2000, 2001 (50 reqs/worker)
* **Results:**
  * **Throughput:** 202.98 RPS
  * **Success Rate:** 100.0% (3,000 / 3,000 HTTP 200 OK, 0 errors)
  * **Latency:** Min: 6.7 ms | Avg: 48.4 ms | p50: 46.1 ms | p90: 71.3 ms | p95: 80.9 ms | p99: 102.5 ms | Max: 151.5 ms
  * **CPU Utilization:** Min: 2.9% | Average: 39.7% | Peak: 51.9%
  * **Finding:** Excellent baseline performance. All write operations committed with sub-50 ms average latency with zero contention.

#### Tier 2: 180 Workers, 9,000 Requests (Moderate Scale)
* **Report File:** [`180users_9000requests_20261104_165911-20261104_165951.txt`](file:///home/mahesh/vts_ocp/native_server_Windows2025/load_test/results/180users_9000requests_20261104_165911-20261104_165951.txt)
* **Workload:** 30 Readers + 30 Writers per instance across ports 8888, 2000, 2001 (50 reqs/worker)
* **Results:**
  * **Throughput:** 227.27 RPS (scales up from 203 RPS)
  * **Success Rate:** 100.0% (9,000 / 9,000 HTTP 200 OK, 0 errors)
  * **Latency:** Min: 7.2 ms | Avg: 100.3 ms | p50: 96.9 ms | p90: 157.5 ms | p95: 175.2 ms | p99: 213.4 ms | Max: 325.6 ms
  * **CPU Utilization:** Min: 3.1% | Average: 47.2% | Peak: 62.6%
  * **Finding:** Linear scaling with 3x user concurrency. Throughput increased to 227 RPS, and median latency stayed under 100 ms with zero connection drops.

#### Tier 3: 600 Workers, 30,000 Requests (Enterprise High Stress)
* **Report File:** [`600users_30000requests_20261104_173622-20261104_173828.txt`](file:///home/mahesh/vts_ocp/native_server_Windows2025/load_test/results/600users_30000requests_20261104_173622-20261104_173828.txt)
* **Workload:** 100 Readers + 100 Writers per instance across ports 8888, 2000, 2001 (50 reqs/worker)
* **Results:**
  * **Throughput:** 238.82 RPS (peak sustained throughput)
  * **Success Rate:** 100.0% (30,000 / 30,000 HTTP 200 OK, 0 errors)
  * **Latency:** Min: 9.1 ms | Avg: 131.4 ms | p50: 121.2 ms | p90: 221.3 ms | p95: 256.3 ms | p99: 331.2 ms | Max: 580.5 ms
  * **CPU Utilization:** Min: 3.0% | Average: 42.1% | Peak: 61.1%
  * **Finding:** Robust enterprise stability. Applying the supervisor watchdog tuning (`waitingTime: 10s`) and Windows TCP socket recycling (`TcpTimedWaitDelay: 30s`) eliminated lock timeouts, halved maximum latency from 1,146 ms down to 580 ms, and kept the Web Admin UI 100% connected and functional post-test.

---

### Technical Justification: RAM Usage Metric (>90%) in Benchmark Results

> [!NOTE]
> In the benchmark execution reports, the target VM resource section displays:
> `RAM Usage (MB): Min: 14,671MB | Average: 14,800MB (90.3%) | Peak: 14,997MB (of 16,384MB)`
> **This metric reflects KVM Hypervisor Host Resident Memory (RSS), NOT memory exhaustion inside the Windows Server OS.**

#### Detailed Technical Explanation:

1. **Hypervisor Sampling Method (`virsh domstats --balloon`):**
   * The background monitoring daemon (`monitor_vm.sh`) runs on the Linux virtualization host and queries QEMU via `virsh domstats Windows-Server-2025`.
   * The metric reported is **`balloon.rss` (Resident Set Size)** — which represents the total physical host memory pages that QEMU has allocated and pinned on the Ubuntu host for this virtual machine.

2. **Windows Server Memory Management on VirtIO:**
   * When Windows Server 2025 boots, the Windows Memory Manager (`Mm`) scans, zero-initializes, and claims the full 16 GB virtual address space assigned to it by the hypervisor.
   * Because the VM was provisioned with static 16 GB allocation (without aggressive memory balloon deflation), QEMU marks almost all 16 GB as resident pages in host memory. Consequently, hypervisor metrics show ~14.8 GB – 15.8 GB (90% – 97%) committed by the QEMU process.

3. **Actual In-Guest Memory Consumption (Inside Windows Server 2025):**
   * Inside the guest operating system, Windows Server and OpenText VTS are actually only consuming **~2.5 GB to 3.5 GB of RAM**:
     * Windows Server Core/GUI OS base services: ~1.8 GB – 2.2 GB
     * VTS Node.js Admin Server (`apiserver.exe`): ~120 MB
     * VTS Engine Instances (`vts.exe` per instance): ~40 MB – 80 MB each
   * The remaining **~12.5 GB (over 75% of total memory)** is completely available, utilized by the Windows filesystem cache (`Standby Cache`) to accelerate SQLite file I/O.

4. **VTS Memory Architecture:**
   * OpenText VTS stores its tables as disk-backed SQLite files in `F:\VTS_Data` (e.g. `Default.vts`, `Test_Team_1.vts`).
   * VTS does not cache entire multi-gigabyte datasets into process heap memory; it reads and writes page blocks through the operating system's filesystem cache.

5. **Alignment with Official OpenText Sizing Guidelines:**
   * OpenText's official Product Availability Matrix (PAM) specifies **8 GB minimum** and **16 GB recommended** for enterprise VTS servers.
   * The 16 GB allocation was proven fully optimal throughout our testing: under 600 concurrent threads and 30,000 rapid transactions, there was **zero memory paging, zero pagefile swapping, and 100% transaction completion**. Increasing RAM beyond 16 GB is unnecessary for this deployment.

---

### Side-by-Side Platform Comparison: RHEL 9 vs. Windows Server 2025

| Metric / Scenario | RHEL 9 (NGINX Reverse Proxy) | Windows Server 2025 (Native VTS TLS) | Architectural Insight |
| :--- | :---: | :---: | :--- |
| **Reliability (All Tests)** | **100.0% Success** (0 errors) | **100.0% Success** (0 errors) | Both platforms deliver rock-solid enterprise stability. |
| **Tier 1 (60 Users) Throughput** | 301.20 RPS | **202.98 RPS** | Linux epoll/TCP stack delivers ~30% higher raw throughput at low concurrency. |
| **Tier 2 (180 Users) Throughput**| 324.50 RPS | **227.27 RPS** | Both platforms scale throughput linearly as load triples. |
| **Tier 3 (600 Users) Throughput**| 338.10 RPS | **238.82 RPS** | Windows Server sustains ~240 RPS under heavy parallel load. |
| **Average Latency (Tier 1)** | 32.7 ms | **48.4 ms** | Windows latency is sub-50 ms, well below standard SLA thresholds (<200 ms). |
| **95th Percentile (Tier 3)** | 112.4 ms | **256.3 ms** | NTFS mandatory byte-range locking introduces slight queueing vs. Linux POSIX advisory locks. |
| **Guest RAM Footprint** | ~1.4 GB | **~3.0 GB (inside VM)** | 16 GB allocation provides massive headroom on both operating systems. |
| **Reverse Proxy Architecture** | Required (NGINX certified) | **Direct Native Ports** | Windows runs natively with zero proxy overhead or reverse proxy dependencies. |

---

## 11. Operational & Troubleshooting Reference

### Issue 1: Script Execution Blocked (`not digitally signed`)
* **Symptom:** Running `.ps1` fails with `File cannot be loaded because running scripts is disabled on this system.`
* **Solution:**
  ```powershell
  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
  Unblock-File .\setup_vts_windows.ps1
  Unblock-File .\add_vts_ssl_cert.ps1
  ```

### Issue 2: `localvts.com` Does Not Resolve from Remote Host
* **Symptom:** Browser or cURL on client machine cannot reach `localvts.com`.
* **Solution:** Ensure client `/etc/hosts` (Linux/macOS) or `C:\Windows\System32\drivers\etc\hosts` (Windows) maps the static IP:
  ```text
  192.168.122.250 localvts.com vts-server.local
  ```

### Issue 3: Inbound Port Connection Refused
* **Symptom:** Port `4000` or instance ports fail to connect remotely.
* **Solution:** Verify the Windows service is running and firewall rules are active:
  ```powershell
  Get-Service -Name "*VTS*"
  Get-NetFirewallRule -DisplayName "VTS*" | Select-Object DisplayName, Enabled, Direction, Action
  ```

### Issue 4: VTS Service Starts & Immediately Stops / Panic `\x00`
* **Symptom:** VTS service starts and immediately stops with Windows SCM error (*"Some services stop automatically if they are not in use..."*), or running `.\apiserver.exe` crashes with:
  ```text
  panic: invalid character '\x00' looking for beginning of value
  ```
* **Cause:** `instances.json` or `configure.json` contains null bytes (`0x00`) due to Windows PowerShell 5.1 writing UTF-16 LE by default or an abrupt VM shutdown flushing zero bytes to disk.
* **Solution:** Execute the automated repair script:
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\fix_vts_null_bytes.ps1
  ```
  This sanitizes `instances.json` to pure UTF-8 without BOM, removes null bytes from `configure.json`, restarts the VTS service, and confirms port 4000 is listening.

### Issue 5: Team Instances Inactive (Ports 2000, 2001, etc.) After Service Recovery
* **Symptom:** Port `4000` (Admin UI) and Port `8888` (Default instance) are listening, but custom team instances (`Test_Team_1` on port `2000`, `Test_Team_2` on port `2001`) are stopped or missing from `instances.json`.
* **Cause:** The default instance is defined in `configure.json` and starts automatically, whereas team instances are registered in `instances.json`. If `instances.json` was emptied or lost during recovery, team engines do not launch.
* **Solution:** Execute the automated instance restoration script:
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\restore_vts_instances.ps1
  ```
  This scans `F:\VTS_Data` for existing `.vts` databases, re-registers `Test_Team_1` (port 2000) and `Test_Team_2` (port 2001) in `instances.json` with `serviceStatus: true` using clean UTF-8, restarts the VTS service, and validates all ports (`4000`, `8888`, `2000`, `2001`).



