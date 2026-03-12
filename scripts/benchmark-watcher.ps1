param(
    [int]$DurationSeconds = 30,
    [int]$SampleMs = 1000
)

$ErrorActionPreference = "Stop"

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$watcher = Join-Path $root "watcher-zig\zig-out\bin\sentry-watcher.exe"

if (-not (Test-Path $watcher)) {
    throw "Watcher binary not found. Run scripts/build-watcher.ps1 first."
}

$outputDir = Join-Path $root "docs\perf"
New-Item -ItemType Directory -Force $outputDir | Out-Null

$samplesPath = Join-Path $outputDir "watcher-samples.csv"
$summaryPath = Join-Path $outputDir "watcher-benchmark-summary.md"
$stdoutPath = Join-Path $outputDir "watcher-benchmark-output.log"

if (Test-Path $samplesPath) { cmd /c del /q $samplesPath }
if (Test-Path $summaryPath) { cmd /c del /q $summaryPath }
if (Test-Path $stdoutPath) { cmd /c del /q $stdoutPath }

$proc = Start-Process -FilePath $watcher -RedirectStandardOutput $stdoutPath -PassThru
$logicalCpu = [int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors

"timestamp_ms,rss_mb,cpu_percent" | Out-File -Encoding utf8 $samplesPath

$start = Get-Date
$prevCpu = 0.0
$prevTime = Get-Date
$sampleCount = 0
$rssTotal = 0.0
$cpuTotal = 0.0
$rssMax = 0.0
$cpuMax = 0.0

try {
    while (((Get-Date) - $start).TotalSeconds -lt $DurationSeconds) {
        Start-Sleep -Milliseconds $SampleMs
        $proc.Refresh()
        if ($proc.HasExited) { break }

        $now = Get-Date
        $elapsed = ($now - $prevTime).TotalSeconds
        if ($elapsed -le 0) { continue }

        $cpuNow = $proc.CPU
        $cpuDelta = $cpuNow - $prevCpu
        $cpuPct = [math]::Max(0, [math]::Round(($cpuDelta / ($elapsed * $logicalCpu)) * 100, 4))
        $rssMb = [math]::Round($proc.WorkingSet64 / 1MB, 4)

        $ts = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
        "$ts,$rssMb,$cpuPct" | Add-Content -Encoding utf8 $samplesPath

        $sampleCount++
        $rssTotal += $rssMb
        $cpuTotal += $cpuPct
        if ($rssMb -gt $rssMax) { $rssMax = $rssMb }
        if ($cpuPct -gt $cpuMax) { $cpuMax = $cpuPct }

        $prevCpu = $cpuNow
        $prevTime = $now
    }
}
finally {
    if (-not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force
    }
}

$rssAvg = if ($sampleCount -gt 0) { [math]::Round($rssTotal / $sampleCount, 4) } else { 0.0 }
$cpuAvg = if ($sampleCount -gt 0) { [math]::Round($cpuTotal / $sampleCount, 4) } else { 0.0 }

$summary = @"
# Watcher Benchmark Summary

Date: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz")
Duration seconds: $DurationSeconds
Sample interval ms: $SampleMs
Samples collected: $sampleCount

## Results

- RSS average (MB): $rssAvg
- RSS max (MB): $rssMax
- CPU average (%): $cpuAvg
- CPU max (%): $cpuMax

Artifacts:
- Samples CSV: docs/perf/watcher-samples.csv
- Raw watcher stdout: docs/perf/watcher-benchmark-output.log
"@

$summary | Out-File -Encoding utf8 $summaryPath

Write-Host "Benchmark complete."
Write-Host "Summary: $summaryPath"
Write-Host "Samples: $samplesPath"
