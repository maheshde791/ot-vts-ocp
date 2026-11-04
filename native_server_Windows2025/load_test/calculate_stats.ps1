# ==============================================================================
# calculate_stats.ps1 - Aggregate Multi-Instance Latency & Resource Stats
# ==============================================================================
[CmdletBinding()]
param(
    [string]$ResultsCsv = "results.csv",
    [string]$MetricsCsv = "vm_metrics.csv",
    [double]$DurationSec = 1.0
)

function Get-Percentiles {
    param([double[]]$Latencies)
    if (-not $Latencies -or $Latencies.Count -eq 0) {
        return @{ min = 0; avg = 0; p50 = 0; p90 = 0; p95 = 0; p99 = 0; max = 0 }
    }
    $sorted = $Latencies | Sort-Object
    $n = $sorted.Count
    
    function p([double]$pct) {
        $idx = [int][math]::Round(($pct / 100.0) * $n) - 1
        $idx = [math]::Max(0, [math]::Min($idx, $n - 1))
        return $sorted[$idx]
    }
    
    $sum = ($sorted | Measure-Object -Sum).Sum
    return @{
        min = $sorted[0]
        avg = [math]::Round($sum / $n, 1)
        p50 = [math]::Round((p 50), 1)
        p90 = [math]::Round((p 90), 1)
        p95 = [math]::Round((p 95), 1)
        p99 = [math]::Round((p 99), 1)
        max = $sorted[-1]
    }
}

$portData = @{}
$allLats = [System.Collections.Generic.List[double]]::new()
$allReads = [System.Collections.Generic.List[double]]::new()
$allWrites = [System.Collections.Generic.List[double]]::new()
$statusCounts = @{}

if (Test-Path $ResultsCsv) {
    $lines = [System.IO.File]::ReadAllLines($ResultsCsv)
    foreach ($line in $lines) {
        $parts = $line.Split(',')
        if ($parts.Count -ge 7) {
            $opType = $parts[1].Trim()
            $port = $parts[2].Trim()
            $code = $parts[5].Trim()
            $latVal = 0.0
            if (-not [double]::TryParse($parts[6].Trim(), [ref]$latVal)) { continue }
            
            if (-not $portData.ContainsKey($port)) {
                $portData[$port] = @{
                    READ = [System.Collections.Generic.List[double]]::new()
                    WRITE = [System.Collections.Generic.List[double]]::new()
                }
            }
            
            $allLats.Add($latVal)
            if ($portData[$port].ContainsKey($opType)) {
                $portData[$port][$opType].Add($latVal)
            }
            
            if ($opType -eq "READ") { $allReads.Add($latVal) }
            elseif ($opType -eq "WRITE") { $allWrites.Add($latVal) }
            
            if ($statusCounts.ContainsKey($code)) { $statusCounts[$code]++ }
            else { $statusCounts[$code] = 1 }
        }
    }
}

$totalReqs = $allLats.Count
$successReqs = if ($statusCounts.ContainsKey("200")) { $statusCounts["200"] } else { 0 }
$errorReqs = $totalReqs - $successReqs
$duration = if ($DurationSec -gt 0) { $DurationSec } else { 1.0 }
$rps = [math]::Round($totalReqs / $duration, 2)

$allStats = Get-Percentiles -Latencies $allLats.ToArray()

# VM Metrics
$cpuVals = [System.Collections.Generic.List[double]]::new()
$ramUsedVals = [System.Collections.Generic.List[double]]::new()
$ramTotal = 16384.0

if (Test-Path $MetricsCsv) {
    $mLines = [System.IO.File]::ReadAllLines($MetricsCsv)
    for ($i = 1; $i -lt $mLines.Count; $i++) {
        $mParts = $mLines[$i].Split(',')
        if ($mParts.Count -ge 5) {
            $c = 0.0; $r = 0.0; $tot = 0.0
            if ([double]::TryParse($mParts[1].Trim(), [ref]$c)) { $cpuVals.Add($c) }
            if ([double]::TryParse($mParts[2].Trim(), [ref]$r)) { $ramUsedVals.Add($r) }
            if ([double]::TryParse($mParts[3].Trim(), [ref]$tot)) { $ramTotal = $tot }
        }
    }
}

$cpuMin = if ($cpuVals.Count) { ($cpuVals | Measure-Object -Minimum).Minimum } else { 0.0 }
$cpuAvg = if ($cpuVals.Count) { [math]::Round(($cpuVals | Measure-Object -Average).Average, 1) } else { 0.0 }
$cpuMax = if ($cpuVals.Count) { ($cpuVals | Measure-Object -Maximum).Maximum } else { 0.0 }

$ramMin = if ($ramUsedVals.Count) { ($ramUsedVals | Measure-Object -Minimum).Minimum } else { 0.0 }
$ramAvg = if ($ramUsedVals.Count) { [math]::Round(($ramUsedVals | Measure-Object -Average).Average, 0) } else { 0.0 }
$ramMax = if ($ramUsedVals.Count) { ($ramUsedVals | Measure-Object -Maximum).Maximum } else { 0.0 }
$ramPct = if ($ramTotal -gt 0) { [math]::Round(($ramAvg / $ramTotal) * 100, 1) } else { 0.0 }

$successPct = if ($totalReqs -gt 0) { [math]::Round(($successReqs / $totalReqs) * 100, 1) } else { 0.0 }
$errorPct = if ($totalReqs -gt 0) { [math]::Round(($errorReqs / $totalReqs) * 100, 1) } else { 0.0 }

$instances = ($portData.Keys | Sort-Object | ForEach-Object { "Port $_" }) -join ", "

Write-Output ("=" * 86)
Write-Output ("             VTS MULTI-INSTANCE LOAD TEST & BENCHMARK REPORT (PARALLEL)         ")
Write-Output ("=" * 86)
Write-Output (" Test Duration          : {0:N2} seconds" -f $duration)
Write-Output (" Target Instances       : $instances")
Write-Output (" Total Requests Run     : $totalReqs ({0} Reads, {1} Writes)" -f $allReads.Count, $allWrites.Count)
Write-Output (" Successful (HTTP 200)  : $successReqs ($successPct%)")
Write-Output (" Failed / Errors        : $errorReqs ($errorPct%)")
Write-Output (" Overall Throughput     : {0:N2} Requests/Second (RPS)" -f $rps)
Write-Output ("=" * 86)
Write-Output (" {0,-14} | {1,-6} | {2,-6} | {3,-6} | {4,-6} | {5,-6} | {6,-6} | {7,-6} | {8,-6} | {9,-6}" -f "INSTANCE","OP","COUNT","MIN","AVG","p50","p90","p95","p99","MAX")
Write-Output ("-" * 86)

foreach ($port in ($portData.Keys | Sort-Object)) {
    $rStats = Get-Percentiles -Latencies $portData[$port].READ.ToArray()
    $wStats = Get-Percentiles -Latencies $portData[$port].WRITE.ToArray()
    $cArr = @() + $portData[$port].READ + $portData[$port].WRITE
    $cStats = Get-Percentiles -Latencies $cArr
    
    $pLabel = "Port $port"
    Write-Output (" {0,-14} | {1,-6} | {2,-6} | {3,-6:N1} | {4,-6:N1} | {5,-6:N1} | {6,-6:N1} | {7,-6:N1} | {8,-6:N1} | {9,-6:N1}" -f $pLabel,"READ",$portData[$port].READ.Count,$rStats.min,$rStats.avg,$rStats.p50,$rStats.p90,$rStats.p95,$rStats.p99,$rStats.max)
    Write-Output (" {0,-14} | {1,-6} | {2,-6} | {3,-6:N1} | {4,-6:N1} | {5,-6:N1} | {6,-6:N1} | {7,-6:N1} | {8,-6:N1} | {9,-6:N1}" -f $pLabel,"WRITE",$portData[$port].WRITE.Count,$wStats.min,$wStats.avg,$wStats.p50,$wStats.p90,$wStats.p95,$wStats.p99,$wStats.max)
    Write-Output (" {0,-14} | {1,-6} | {2,-6} | {3,-6:N1} | {4,-6:N1} | {5,-6:N1} | {6,-6:N1} | {7,-6:N1} | {8,-6:N1} | {9,-6:N1}" -f $pLabel,"SUBTOT",$cArr.Count,$cStats.min,$cStats.avg,$cStats.p50,$cStats.p90,$cStats.p95,$cStats.p99,$cStats.max)
    Write-Output ("-" * 86)
}

Write-Output (" {0,-14} | {1,-6} | {2,-6} | {3,-6:N1} | {4,-6:N1} | {5,-6:N1} | {6,-6:N1} | {7,-6:N1} | {8,-6:N1} | {9,-6:N1}" -f "ALL COMBINED","TOTAL",$totalReqs,$allStats.min,$allStats.avg,$allStats.p50,$allStats.p90,$allStats.p95,$allStats.p99,$allStats.max)
Write-Output ("=" * 86)
Write-Output ("                     TARGET VM RESOURCE UTILIZATION                    ")
Write-Output ("=" * 86)
if ($cpuVals.Count -gt 0) {
    Write-Output (" CPU Utilization (%)    : Min: {0:N1}%  |  Average: {1:N1}%  |  Peak: {2:N1}%" -f $cpuMin, $cpuAvg, $cpuMax)
    Write-Output (" RAM Usage (MB)         : Min: {0:N0}MB |  Average: {1:N0}MB ({2:N1}%) |  Peak: {3:N0}MB (of {4:N0}MB)" -f $ramMin, $ramAvg, $ramPct, $ramMax, $ramTotal)
} else {
    Write-Output (" (No VM metrics captured)")
}
Write-Output ("=" * 86)

