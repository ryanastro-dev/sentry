$ErrorActionPreference = "Stop"

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$pidFile = Join-Path $root "docs\perf\watcher-soak.pid"

if (-not (Test-Path $pidFile)) {
    Write-Host "No soak PID file found."
    exit 0
}

$pidRaw = Get-Content $pidFile -ErrorAction SilentlyContinue
if (-not $pidRaw) {
    Write-Host "PID file empty."
    exit 0
}

$proc = Get-Process -Id $pidRaw -ErrorAction SilentlyContinue
if ($proc) {
    Stop-Process -Id $pidRaw -Force
    Write-Host "Stopped soak process PID $pidRaw"
} else {
    Write-Host "Soak process PID $pidRaw not running."
}

cmd /c del /q "$pidFile" 2>$null
