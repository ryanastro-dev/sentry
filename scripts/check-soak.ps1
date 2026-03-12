$ErrorActionPreference = "Stop"

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$pidFile = Join-Path $root "docs\perf\watcher-soak.pid"
$metaFile = Join-Path $root "docs\perf\watcher-soak-meta.txt"
$latestSummary = Join-Path $root "docs\perf\watcher-soak-latest-summary.md"

if (-not (Test-Path $pidFile)) {
    Write-Host "No active soak PID file found."
    if (Test-Path $latestSummary) {
        Write-Host "Latest summary: $latestSummary"
    }
    exit 0
}

$pidRaw = Get-Content $pidFile -ErrorAction SilentlyContinue
if (-not $pidRaw) {
    Write-Host "PID file is empty."
    exit 0
}

$proc = Get-Process -Id $pidRaw -ErrorAction SilentlyContinue
if ($proc) {
    Write-Host "Soak is running."
    Write-Host "PID: $pidRaw"
    if (Test-Path $metaFile) {
        Write-Host "Metadata:"
        Get-Content $metaFile
    }
    exit 0
}

Write-Host "Soak process is not running (stale PID file: $pidRaw)."
if (Test-Path $latestSummary) {
    Write-Host "Latest summary: $latestSummary"
}
