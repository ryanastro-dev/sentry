param(
    [switch]$Run
)

$ErrorActionPreference = "Stop"

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$expectedVersion = "0.15.2"
$zigDir = Join-Path $root ".tools\zig-x86_64-windows-$expectedVersion"
$zig = Join-Path $zigDir "zig.exe"

function Get-ZigVersion([string]$exePath) {
    try {
        return (& $exePath version).Trim()
    }
    catch {
        return ""
    }
}

function Ensure-StableZig {
    if ((Test-Path $zig) -and (Get-ZigVersion $zig) -eq $expectedVersion) {
        return $zig
    }

    $pathZig = Get-Command zig -ErrorAction SilentlyContinue
    if ($pathZig) {
        $pathVersion = Get-ZigVersion $pathZig.Source
        if ($pathVersion -eq $expectedVersion) {
            return $pathZig.Source
        }
    }

    New-Item -ItemType Directory -Force (Join-Path $root ".tools") | Out-Null
    $zip = Join-Path $root ".tools\zig-$expectedVersion.zip"
    $url = "https://ziglang.org/download/$expectedVersion/zig-x86_64-windows-$expectedVersion.zip"

    if (-not (Test-Path $zip)) {
        Write-Host "Downloading Zig $expectedVersion..."
        $oldProgressPreference = $ProgressPreference
        try {
            $ProgressPreference = "SilentlyContinue"
            Invoke-WebRequest -Uri $url -OutFile $zip
        }
        finally {
            $ProgressPreference = $oldProgressPreference
        }
    }

    Expand-Archive -Path $zip -DestinationPath (Join-Path $root ".tools") -Force

    if (-not (Test-Path $zig)) {
        throw "Zig bootstrap failed. Expected toolchain at: $zig"
    }
    return $zig
}

$zig = Ensure-StableZig
$version = Get-ZigVersion $zig
if ($version -ne $expectedVersion) {
    throw "Expected Zig $expectedVersion, got $version from $zig"
}

Push-Location (Join-Path $root "watcher-zig")
try {
    & $zig build

    $binDir = Join-Path (Get-Location) "zig-out\bin"
    $plainExe = Join-Path $binDir "sentry-watcher.exe"
    $sidecarExe = Join-Path $binDir "sentry-watcher-x86_64-pc-windows-msvc.exe"
    if (Test-Path $plainExe) {
        Copy-Item -Force $plainExe $sidecarExe
    }

    if ($Run) {
        & $plainExe
    }
}
finally {
    Pop-Location
}
