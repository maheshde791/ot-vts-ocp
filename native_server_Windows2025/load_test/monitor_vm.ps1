# ==============================================================================
# monitor_vm.ps1 - Background CPU & RAM Resource Monitor for Windows Server
# ==============================================================================
[CmdletBinding()]
param(
    [string]$OutputFile = "vm_metrics.csv",
    [int]$Interval = 1
)

"Timestamp,CPU_Usage_Pct,RAM_Used_MB,RAM_Total_MB,RAM_Usage_Pct" | Out-File -FilePath $OutputFile -Encoding utf8

$os = Get-CimInstance Win32_OperatingSystem
$totalRamMB = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)

while ($true) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    
    # Sample CPU %
    $cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    if ($null -eq $cpu) { $cpu = 0 }
    $cpu = [math]::Round($cpu, 1)
    
    # Sample Memory
    $osInfo = Get-CimInstance Win32_OperatingSystem
    $freeRamMB = [math]::Round($osInfo.FreePhysicalMemory / 1024, 0)
    $usedRamMB = $totalRamMB - $freeRamMB
    $ramPct = [math]::Round(($usedRamMB / $totalRamMB) * 100, 1)
    
    "$ts,$cpu,$usedRamMB,$totalRamMB,$ramPct" | Out-File -FilePath $OutputFile -Append -Encoding utf8
    Start-Sleep -Seconds $Interval
}

