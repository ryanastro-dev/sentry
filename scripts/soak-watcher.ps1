param(
    [int]$DurationSeconds = 86400,
    [int]$SampleMs = 5000,
    [double]$MaxRssMb = 12.0,
    [double]$MaxCpuPct = 1.0
)

$ErrorActionPreference = "Stop"

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$watcher = Join-Path $root "watcher-zig\zig-out\bin\sentry-watcher.exe"

if (-not (Test-Path $watcher)) {
    throw "Watcher binary not found. Run scripts/build-watcher.ps1 first."
}

$outputDir = Join-Path $root "docs\perf\soak"
New-Item -ItemType Directory -Force $outputDir | Out-Null
$pidFile = Join-Path $root "docs\perf\watcher-soak.pid"

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$samplesPath = Join-Path $outputDir "watcher-soak-$stamp-samples.csv"
$summaryPath = Join-Path $outputDir "watcher-soak-$stamp-summary.md"
$stdoutPath = Join-Path $outputDir "watcher-soak-$stamp-stdout.log"
$latestSummary = Join-Path $root "docs\perf\watcher-soak-latest-summary.md"

$logicalCpu = [int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
"timestamp_ms,rss_mb,cpu_percent" | Out-File -Encoding utf8 $samplesPath

$proc = Start-Process -FilePath $watcher -RedirectStandardOutput $stdoutPath -PassThru

$start = Get-Date
$prevCpu = 0.0
$prevTime = Get-Date
$sampleCount = 0
$rssTotal = 0.0
$cpuTotal = 0.0
$rssMax = 0.0
$cpuMax = 0.0
$exitedEarly = $false

try {
    while (((Get-Date) - $start).TotalSeconds -lt $DurationSeconds) {
        Start-Sleep -Milliseconds $SampleMs
        $proc.Refresh()
        if ($proc.HasExited) {
            $exitedEarly = $true
            break
        }

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
$rssPass = $rssMax -le $MaxRssMb
$cpuPass = $cpuMax -le $MaxCpuPct
$overallPass = (-not $exitedEarly) -and $rssPass -and $cpuPass

$summary = @"
# Watcher Soak Summary

Date: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz")
Duration seconds target: $DurationSeconds
Sample interval ms: $SampleMs
Samples collected: $sampleCount
Exited early: $exitedEarly

## Thresholds

- Max RSS threshold (MB): $MaxRssMb
- Max CPU threshold (%): $MaxCpuPct

## Results

- RSS average (MB): $rssAvg
- RSS max (MB): $rssMax
- CPU average (%): $cpuAvg
- CPU max (%): $cpuMax

## Verdict

- RSS threshold pass: $rssPass
- CPU threshold pass: $cpuPass
- Overall pass: $overallPass

Artifacts:
- Samples CSV: $samplesPath
- Raw watcher stdout: $stdoutPath
"@

$summary | Out-File -Encoding utf8 $summaryPath
$summary | Out-File -Encoding utf8 $latestSummary

Write-Host "Soak run complete."
Write-Host "Summary: $summaryPath"
Write-Host "Latest summary: $latestSummary"

if (Test-Path $pidFile) {
    cmd /c del /q "$pidFile" 2>$null
}

if ($overallPass) { exit 0 } else { exit 1 }
