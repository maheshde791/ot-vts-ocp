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
Write-Host " (Remember to change <seturpass> in configure.json to your password)" -ForegroundColor DarkYellow
Write-Host "==========================================================" -ForegroundColor Cyan
