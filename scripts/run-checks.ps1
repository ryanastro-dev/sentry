param(
    [switch]$WithTauriBuild
)

$ErrorActionPreference = "Stop"

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

Write-Host "[1/6] Build watcher (Zig stable 0.15.2)"
powershell -ExecutionPolicy Bypass -File (Join-Path $root "scripts\build-watcher.ps1")

Write-Host "[2/6] Run watcher unit tests"
& (Join-Path $root ".tools\zig-x86_64-windows-0.15.2\zig.exe") test (Join-Path $root "watcher-zig\src\main.zig")

Write-Host "[3/6] Rust check"
Push-Location (Join-Path $root "ui\src-tauri")
try {
    cargo check
    Write-Host "[4/6] Rust tests"
    cargo test
}
finally {
    Pop-Location
}

Write-Host "[5/6] UI typecheck + build"
Push-Location (Join-Path $root "ui")
try {
    if (-not (Test-Path "node_modules")) {
        npm ci
    }

    npm run check
    npm run build

    if ($WithTauriBuild) {
        Write-Host "[6/6] Tauri debug build"
        npm run tauri:build -- --debug
    }
}
finally {
    Pop-Location
}

Write-Host "All checks completed."
