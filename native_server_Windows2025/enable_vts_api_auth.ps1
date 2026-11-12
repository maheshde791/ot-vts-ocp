# ==============================================================================
# enable_vts_api_auth.ps1 - Enable API Authentication & Configure User Roles
# ==============================================================================
# Run in PowerShell as Administrator on Windows Server 2025:
#   .\enable_vts_api_auth.ps1
# Or via one-liner:
#   powershell -ExecutionPolicy Bypass -Command "irm http://192.168.122.1:8000/enable_vts_api_auth.ps1 | iex"
# ==============================================================================

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "      Enabling OpenText VTS API Authentication & Roles     " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$configPath = "F:\VTS26.1\web\configure.json"

if (-not (Test-Path $configPath)) {
    Write-Host "ERROR: $configPath not found!" -ForegroundColor Red
    exit 1
}

# 1. Backup existing configure.json
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupPath = "$configPath.pre_auth_$timestamp.bak"
Copy-Item $configPath $backupPath -Force
Write-Host "`n[1/3] Created configuration backup at: $backupPath" -ForegroundColor Yellow

# 2. Update configure.json
Write-Host "`n[2/3] Configuring API Authentication and User Roles..." -ForegroundColor Yellow
$json = Get-Content $configPath -Raw | ConvertFrom-Json

# Enable API Authentication
$json.admin.requireBasicAuthForAPI = $true
Write-Host "  -> requireBasicAuthForAPI set to: true" -ForegroundColor Green

# Define desired users
$targetUsers = @(
    @{
        user     = "maheshd"
        password = "maheshd"
        display  = "Mahesh Deore"
    },
    @{
        user     = "vts_admin"
        password = "vts_admin"
        display  = "VTS Platform Admin"
    },
    @{
        user     = "vts_tester"
        password = "vts_tester"
        display  = "Performance Test User"
    },
    @{
        user     = "vts_viewer"
        password = "vts_viewer"
        display  = "Read-Only Reporting Viewer"
    }
)

# Merge or update users list
$existingUsers = @($json.admin.users)
$userList = [System.Collections.Generic.List[PSObject]]::new()

foreach ($tUser in $targetUsers) {
    $existing = $existingUsers | Where-Object { $_.user -eq $tUser.user }
    if ($existing) {
        # Keep existing password if already set (e.g. for maheshd)
        $userObj = [PSCustomObject]@{
            user     = $existing.user
            password = $existing.password
            display  = $tUser.display
        }
        Write-Host "  -> Retained user '$($existing.user)' with existing credentials" -ForegroundColor Cyan
    } else {
        $userObj = [PSCustomObject]@{
            user     = $tUser.user
            password = $tUser.password
            display  = $tUser.display
        }
        Write-Host "  -> Added user '$($tUser.user)'" -ForegroundColor Green
    }
    $userList.Add($userObj)
}

$json.admin.users = $userList

# Set Roles
$json.admin.role.administrator = @("maheshd", "vts_admin")
$json.admin.role.user = @("vts_tester", "vts_viewer")

Write-Host "  -> Administrator Role : maheshd, vts_admin" -ForegroundColor Green
Write-Host "  -> User (Read-Only)   : vts_tester, vts_viewer" -ForegroundColor Green

# Save formatted JSON
$updatedJson = $json | ConvertTo-Json -Depth 15
[System.IO.File]::WriteAllText($configPath, $updatedJson)
Write-Host "  -> Saved updated $configPath successfully" -ForegroundColor Green

# 3. Restart VTS Windows Service
Write-Host "`n[3/3] Restarting OpenText VTS Windows Service..." -ForegroundColor Yellow
$vtsService = Get-Service | Where-Object { $_.DisplayName -like "*Virtual Table Server*" -or $_.Name -like "*VTS*" }

if ($vtsService) {
    Restart-Service -Name $vtsService.Name -Force
    Write-Host "  -> Service '$($vtsService.DisplayName)' restarted successfully!" -ForegroundColor Green
} else {
    Write-Host "  -> Service not found automatically. Restart via services.msc" -ForegroundColor Yellow
}

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host " VTS Security Hardening Complete!" -ForegroundColor Green
Write-Host " API calls now strictly require HTTP Basic Authentication." -ForegroundColor Green
Write-Host " Admin UI: https://localvts.com:4000" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan

