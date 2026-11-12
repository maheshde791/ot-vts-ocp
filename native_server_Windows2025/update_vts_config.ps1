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

