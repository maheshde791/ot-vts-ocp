# ==============================================================================
# master_load_tester.ps1 - Master Load Testing & Benchmark Orchestrator for Windows VTS
# ==============================================================================
# Run this script in PowerShell:
#   .\master_load_tester.ps1
# Or with custom options:
#   .\master_load_tester.ps1 -ReadWorkers 5 -WriteWorkers 5 -ReadReqsPerWorker 20 -WriteReqsPerWorker 20
# ==============================================================================

[CmdletBinding()]
param(
    [string]$TargetHost = "https://localvts.com",
    [string[]]$InstancePorts = @("8888", "2000", "2001"),
    [int]$ReadWorkers = 10,
    [int]$ReadReqsPerWorker = 50,
    [int]$WriteWorkers = 10,
    [int]$WriteReqsPerWorker = 50,
    [string]$Auth = "maheshd:maheshd",
    [int]$MaxIndex = 500
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$resultsDir = Join-Path $scriptDir "results"
if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null }

# Trust self-signed certificates
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13

$numPorts = $InstancePorts.Count
$totalReadWorkers = $ReadWorkers * $numPorts
$totalWriteWorkers = $WriteWorkers * $numPorts
$totalConcurrency = $totalReadWorkers + $totalWriteWorkers

$totalReadReqs = $totalReadWorkers * $ReadReqsPerWorker
$totalWriteReqs = $totalWriteWorkers * $WriteReqsPerWorker
$totalRequests = $totalReadReqs + $totalWriteReqs

Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "          INITIALIZING VTS MULTI-INSTANCE LOAD TEST & BENCHMARK (WINDOWS)       " -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host " Target Host         : $TargetHost"
Write-Host " Active Instances    : $($InstancePorts -join ' ') ($numPorts instances under load simultaneously)"
Write-Host " Workers / Instance  : $ReadWorkers Readers + $WriteWorkers Writers = $($ReadWorkers + $WriteWorkers) threads/instance"
Write-Host " Total Concurrency   : $totalConcurrency parallel worker threads across all instances"
Write-Host " Total Requests      : $totalRequests ($totalReadReqs Reads, $totalWriteReqs Writes)"
if ($Auth) {
    Write-Host " Authentication      : Enabled (Basic Auth)"
}
Write-Host "--------------------------------------------------------------------------------"

# Step 1: Pre-flight check on ALL instances
Write-Host "[1/5] Running pre-flight health checks across all instances..." -ForegroundColor Yellow
$headers = @{ "Content-Type" = "application/json" }
if ($Auth) {
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($Auth)
    $b64 = [System.Convert]::ToBase64String($bytes)
    $headers["Authorization"] = "Basic $b64"
}

foreach ($port in $InstancePorts) {
    Write-Host -NoNewline "  -> Checking Instance on Port $port... "
    $checkUrl = "$TargetHost`:$port/client_api/getAllColumns"
    try {
        $res = Invoke-RestMethod -Uri $checkUrl -Method Post -Headers $headers -Body "{}" -TimeoutSec 5 -ErrorAction Stop
        Write-Host "OK (HTTP 200)" -ForegroundColor Green
    } catch {
        Write-Host "FAILED! ($($_.Exception.Message))" -ForegroundColor Red
        Write-Host "Error: Cannot connect to instance on port $port. Check if port is open and VTS service is running." -ForegroundColor Red
        exit 1
    }
}

# Step 2: Temporary Directory for In-Flight CSV Data
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("vts_load_" + [System.Guid]::NewGuid().ToString().Substring(0, 8))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

$rawResultsFile = Join-Path $tmpDir "all_requests.csv"
$vmMetricsFile = Join-Path $tmpDir "vm_metrics.csv"

# Step 3: Start VM Resource Monitoring in Background
Write-Host -NoNewline "[2/5] Starting background CPU/RAM monitor... " -ForegroundColor Yellow
$monitorScript = Join-Path $scriptDir "monitor_vm.ps1"
$monitorJob = Start-Job -FilePath $monitorScript -ArgumentList @($vmMetricsFile, 1)
Write-Host "Active (Job ID: $($monitorJob.Id))" -ForegroundColor Green

$timeFrom = (Get-Date).ToString("yyyyMMdd_HHmmss")
$swTotal = [System.Diagnostics.Stopwatch]::StartNew()

# Brief pause for baseline metrics
Start-Sleep -Seconds 2

# Step 4: Launch Parallel Workers across all instances
Write-Host "[3/5] Spawning $totalConcurrency parallel worker threads across instances [$($InstancePorts -join ' ')]..." -ForegroundColor Yellow
$workerJobs = [System.Collections.Generic.List[System.Management.Automation.Job]]::new()

$workerReadScript = Join-Path $scriptDir "worker_read.ps1"
$workerWriteScript = Join-Path $scriptDir "worker_write.ps1"

foreach ($port in $InstancePorts) {
    # Launch Read Workers
    for ($w = 1; $w -le $ReadWorkers; $w++) {
        $workerOut = Join-Path $tmpDir "read_${port}_${w}.csv"
        $job = Start-Job -FilePath $workerReadScript -ArgumentList @($w, $ReadReqsPerWorker, $TargetHost, [int]$port, $workerOut, $MaxIndex, $Auth)
        $workerJobs.Add($job)
    }

    # Launch Write Workers
    for ($w = 1; $w -le $WriteWorkers; $w++) {
        $workerOut = Join-Path $tmpDir "write_${port}_${w}.csv"
        $job = Start-Job -FilePath $workerWriteScript -ArgumentList @($w, $WriteReqsPerWorker, $TargetHost, [int]$port, $workerOut, $MaxIndex, $Auth)
        $workerJobs.Add($job)
    }
}

Write-Host "[4/5] Multi-instance load test in progress ($totalRequests requests running in parallel)..." -ForegroundColor Yellow

# Monitor progress until all workers complete
while ($true) {
    $runningJobs = ($workerJobs | Where-Object { $_.State -eq "Running" }).Count
    $completedCount = 0
    Get-ChildItem -Path $tmpDir -Filter "*_*.csv" -ErrorAction SilentlyContinue | ForEach-Object {
        $lines = (Get-Content $_.FullName -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
        $completedCount += $lines
    }
    $pct = if ($totalRequests -gt 0) { [math]::Round(($completedCount / $totalRequests) * 100, 0) } else { 0 }
    $elapsedSec = [math]::Round($swTotal.Elapsed.TotalSeconds, 0)
    
    Write-Host -NoNewline "`r  -> Progress: $completedCount / $totalRequests completed ($pct%) | Active Workers: $runningJobs | Elapsed: ${elapsedSec}s  "
    
    if ($runningJobs -eq 0) { break }
    Start-Sleep -Seconds 1
}
Write-Host ""
$swTotal.Stop()
$durationSec = [math]::Round($swTotal.Elapsed.TotalSeconds, 2)
$timeTo = (Get-Date).ToString("yyyyMMdd_HHmmss")

Write-Host "Load execution finished in $durationSec seconds." -ForegroundColor Green

# Clean up worker jobs
$workerJobs | Remove-Job -Force | Out-Null

# Step 5: Stop Monitor & Consolidate Results
Write-Host -NoNewline "[5/5] Finalizing metrics and calculating per-instance percentiles... " -ForegroundColor Yellow
Stop-Job -Job $monitorJob -ErrorAction SilentlyContinue | Out-Null
Remove-Job -Job $monitorJob -Force -ErrorAction SilentlyContinue | Out-Null

# Consolidate worker CSVs
Get-ChildItem -Path $tmpDir -Filter "*_*.csv" | ForEach-Object {
    Get-Content $_.FullName | Add-Content -Path $rawResultsFile
}
Write-Host "Done." -ForegroundColor Green
Write-Host ""

# Format Report Filename: <userNumber>users_<requests>requests_<timestampfrom>-<timestampto>.txt
$reportFileName = "${totalConcurrency}users_${totalRequests}requests_${timeFrom}-${timeTo}.txt"
$reportFile = Join-Path $resultsDir $reportFileName

# Step 6: Generate Benchmark Report
$calcScript = Join-Path $scriptDir "calculate_stats.ps1"
$reportOutput = & $calcScript -ResultsCsv $rawResultsFile -MetricsCsv $vmMetricsFile -DurationSec $durationSec

$reportOutput | Tee-Object -FilePath $reportFile

# Cleanup temporary folder
Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host " Report successfully saved to: $reportFile" -ForegroundColor Green
Write-Host " (Temporary CSV files were cleaned up; results folder contains only final reports)" -ForegroundColor DarkGray
Write-Host "================================================================================" -ForegroundColor Cyan

