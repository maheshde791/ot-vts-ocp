# ==============================================================================
# worker_write.ps1 - Parallel Worker for Windows VTS Write/Update Requests
# ==============================================================================
[CmdletBinding()]
param(
    [int]$WorkerId = 1,
    [int]$NumRequests = 50,
    [string]$TargetHost = "https://localvts.com",
    [int]$InstancePort = 2000,
    [string]$OutputFile = "write_worker.csv",
    [int]$MaxIndex = 500,
    [string]$Auth = "maheshd:maheshd"
)

# Trust self-signed certificates
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13

$endpoint = "$TargetHost`:$InstancePort/client_api/update"
$headers = @{ "Content-Type" = "application/json" }

if ($Auth) {
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($Auth)
    $b64 = [System.Convert]::ToBase64String($bytes)
    $headers["Authorization"] = "Basic $b64"
}

$results = [System.Collections.Generic.List[string]]::new()
$sw = [System.Diagnostics.Stopwatch]::new()

for ($i = 1; $i -le $NumRequests; $i++) {
    $rowIdx = Get-Random -Minimum 1 -Maximum ($MaxIndex + 1)
    $newVal = "PERF_P${InstancePort}_W${WorkerId}_R${i}"
    $body = "{`"index`": $rowIdx, `"column`": `"Customer_ID`", `"value`": `"$newVal`"}"
    $reqTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
    
    $sw.Restart()
    $statusCode = 200
    try {
        $response = Invoke-RestMethod -Uri $endpoint -Method Post -Headers $headers -Body $body -TimeoutSec 10 -ErrorAction Stop
    } catch {
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        } else {
            $statusCode = 500
        }
    }
    $sw.Stop()
    $latencyMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
    
    $results.Add("$reqTime,WRITE,$InstancePort,$WorkerId,$i,$statusCode,$latencyMs")
}

[System.IO.File]::AppendAllLines($OutputFile, $results)

