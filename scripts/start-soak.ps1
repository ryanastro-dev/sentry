param(
    [int]$DurationSeconds = 86400,
    [int]$SampleMs = 5000,
    [double]$MaxRssMb = 12.0,
    [double]$MaxCpuPct = 1.0
)

$ErrorActionPreference = "Stop"

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$scriptPath = Join-Path $root "scripts\soak-watcher.ps1"
$perfDir = Join-Path $root "docs\perf"
New-Item -ItemType Directory -Force $perfDir | Out-Null

$pidFile = Join-Path $perfDir "watcher-soak.pid"
$metaFile = Join-Path $perfDir "watcher-soak-meta.txt"

if (Test-Path $pidFile) {
    $existingPid = Get-Content $pidFile -ErrorAction SilentlyContinue
    if ($existingPid) {
        $existingProc = Get-Process -Id $existingPid -ErrorAction SilentlyContinue
        if ($existingProc) {
            throw "Soak run already active with PID $existingPid."
        }
    }
}

$argList = @(
    "-ExecutionPolicy", "Bypass",
    "-File", $scriptPath,
    "-DurationSeconds", $DurationSeconds,
    "-SampleMs", $SampleMs,
    "-MaxRssMb", $MaxRssMb,
    "-MaxCpuPct", $MaxCpuPct
)

$proc = Start-Process -FilePath "powershell" -ArgumentList $argList -WindowStyle Hidden -PassThru

$proc.Id | Out-File -Encoding ascii $pidFile
@"
pid=$($proc.Id)
started_at=$(Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz")
duration_seconds=$DurationSeconds
sample_ms=$SampleMs
max_rss_mb=$MaxRssMb
max_cpu_pct=$MaxCpuPct
"@ | Out-File -Encoding ascii $metaFile

Write-Host "Soak run started."
Write-Host "PID: $($proc.Id)"
Write-Host "PID file: $pidFile"
Write-Host "Meta file: $metaFile"
