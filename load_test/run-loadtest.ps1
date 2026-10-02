# run-loadtest.ps1
# Runs the k6 load test and collects cluster state before / during / after.
# Read-only: it only runs kubectl get/top/describe/exec(select count). It does not modify the cluster.
#
# Usage (run in the folder that contains k6-loadtest.js):
#   .\run-loadtest.ps1 -PeakVus 50 -HotTime 3m
#
# Output: .\loadtest-logs\<timestamp>-vu<N>\  and a .zip of the same folder
#   meta.txt         start/end times and parameters
#   before.txt       state before the test (hpa, pods, nodes, top)
#   samples.log      state every N seconds during and after the test
#   after.txt        state right after k6 finishes
#   final.txt        state after the post-test wait (scale-down check)
#   hpa-describe.txt / events.txt   HPA events (SuccessfulRescale etc.)
#   k6-summary.txt / k6-summary.json   k6 result

param(
    [int]$PeakVus = 50,
    [string]$HotTime = "3m",
    [string]$TargetUrl = "https://leechs.shop",
    [string]$TargetPath = "/api/v1/products",
    [string]$K6Script = ".\k6-loadtest.js",
    [int]$SampleSec = 15,
    [int]$AfterMinutes = 6
)

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$dir = Join-Path (Get-Location) "loadtest-logs\$stamp-vu$PeakVus"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$samples = Join-Path $dir "samples.log"
$dbSql = "select count(*) from pg_stat_activity where backend_type = 'client backend';"

function Write-Section($file, $title, $text) {
    "[$title]" | Add-Content -Path $file -Encoding utf8
    ($text | Out-String).TrimEnd() | Add-Content -Path $file -Encoding utf8
}

function Take-Snapshot($name) {
    $f = Join-Path $dir "$name.txt"
    "## $name  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File -FilePath $f -Encoding utf8
    Write-Section $f "hpa (all)" (kubectl get hpa -A 2>&1)
    Write-Section $f "pods product-service" (kubectl get pods -n product-service -o wide 2>&1)
    Write-Section $f "pods api-gateway" (kubectl get pods -n api-gateway -o wide 2>&1)
    Write-Section $f "nodes" (kubectl get nodes -L karpenter.sh/nodepool,node.kubernetes.io/instance-type 2>&1)
    Write-Section $f "top product-service" (kubectl top pods -n product-service 2>&1)
    Write-Section $f "top api-gateway" (kubectl top pods -n api-gateway 2>&1)
    Write-Section $f "db client connections" (kubectl exec -n database petflow-db-1 -c postgres -- psql -t -c $dbSql 2>&1)
}

function Take-Sample {
    "=== $(Get-Date -Format 'HH:mm:ss')" | Add-Content -Path $samples -Encoding utf8
    Write-Section $samples "hpa product" (kubectl get hpa product-service-hpa -n product-service --no-headers 2>&1)
    Write-Section $samples "pods product" (kubectl get pods -n product-service --no-headers 2>&1)
    Write-Section $samples "top product" (kubectl top pods -n product-service --no-headers 2>&1)
    Write-Section $samples "top gateway" (kubectl top pods -n api-gateway --no-headers 2>&1)
    Write-Section $samples "nodes" (kubectl get nodes --no-headers 2>&1)
    Write-Section $samples "db connections" (kubectl exec -n database petflow-db-1 -c postgres -- psql -t -c $dbSql 2>&1)
}

$testStart = Get-Date
@(
    "target      : $TargetUrl$TargetPath",
    "peak VUs    : $PeakVus",
    "hot time    : $HotTime",
    "script start: $($testStart.ToString('yyyy-MM-dd HH:mm:ss'))"
) | Out-File -FilePath (Join-Path $dir "meta.txt") -Encoding utf8

Write-Host "Collecting BEFORE snapshot..."
Take-Snapshot "before"

$k6Args = @(
    "run",
    "-e", "TARGET_URL=$TargetUrl",
    "-e", "TARGET_PATH=$TargetPath",
    "-e", "PEAK_VUS=$PeakVus",
    "-e", "HOT_TIME=$HotTime",
    "--summary-export", "`"$(Join-Path $dir 'k6-summary.json')`"",
    "`"$K6Script`""
)

$k6 = $null
try {
    $k6Start = Get-Date
    "k6 start    : $($k6Start.ToString('yyyy-MM-dd HH:mm:ss'))" | Add-Content (Join-Path $dir "meta.txt") -Encoding utf8
    $k6 = Start-Process -FilePath "k6" -ArgumentList $k6Args -NoNewWindow -PassThru `
        -RedirectStandardOutput (Join-Path $dir "k6-summary.txt")

    Write-Host "k6 running. Sampling every $SampleSec s. Ctrl+C to stop."
    while (-not $k6.HasExited) {
        Take-Sample
        Start-Sleep -Seconds $SampleSec
    }
    $k6End = Get-Date
    "k6 end      : $($k6End.ToString('yyyy-MM-dd HH:mm:ss'))  (exit code $($k6.ExitCode))" |
        Add-Content (Join-Path $dir "meta.txt") -Encoding utf8

    Write-Host "k6 finished. Collecting AFTER snapshot..."
    Take-Snapshot "after"

    Write-Host "Watching scale-down for $AfterMinutes minutes..."
    $until = (Get-Date).AddMinutes($AfterMinutes)
    while ((Get-Date) -lt $until) {
        Take-Sample
        Start-Sleep -Seconds $SampleSec
    }
}
finally {
    if ($k6 -and -not $k6.HasExited) {
        Stop-Process -Id $k6.Id -Force
        "k6 stopped manually (Ctrl+C or error)" | Add-Content (Join-Path $dir "meta.txt") -Encoding utf8
    }
    Write-Host "Collecting FINAL snapshot and events..."
    Take-Snapshot "final"
    kubectl describe hpa product-service-hpa -n product-service 2>&1 |
        Out-File -FilePath (Join-Path $dir "hpa-describe.txt") -Encoding utf8
    kubectl get events -n product-service --sort-by=.lastTimestamp 2>&1 |
        Out-File -FilePath (Join-Path $dir "events.txt") -Encoding utf8
    "script end  : $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))" |
        Add-Content (Join-Path $dir "meta.txt") -Encoding utf8

    $zip = "$dir.zip"
    Compress-Archive -Path "$dir\*" -DestinationPath $zip -Force
    Write-Host "Done. Folder: $dir"
    Write-Host "Zip   : $zip"
}
