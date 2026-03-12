# Sentry

[![CI](https://github.com/ryanastro-dev/sentry/actions/workflows/ci.yml/badge.svg)](https://github.com/ryanastro-dev/sentry/actions/workflows/ci.yml)
[![Release Build](https://github.com/ryanastro-dev/sentry/actions/workflows/release.yml/badge.svg)](https://github.com/ryanastro-dev/sentry/actions/workflows/release.yml)
![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)
![Zig](https://img.shields.io/badge/Zig-0.15.2-F7A41D?logo=zig&logoColor=white)
![Rust](https://img.shields.io/badge/Rust-1.94.0-DEA584?logo=rust&logoColor=white)
![Tauri](https://img.shields.io/badge/Tauri-2.10.3-24C8DB?logo=tauri&logoColor=white)
![Svelte](https://img.shields.io/badge/Svelte-5.53.10-FF3E00?logo=svelte&logoColor=white)
![SQLite](https://img.shields.io/badge/SQLite-3.52.0-003B57?logo=sqlite&logoColor=white)

Low-overhead Windows activity monitor built with a Zig sidecar watcher, Tauri (Rust) host, SQLite persistence, and Svelte UI.

## Overview

Sentry tracks active window usage in near real-time and stores local timeline/session data for digital wellbeing insights.

- Event-first foreground tracking on Windows (`SetWinEventHook`) with polling fallback.
- Sidecar isolation: Zig watcher does low-level capture, Rust host handles lifecycle/persistence.
- Local-first storage in SQLite (WAL mode) with timeline and usage summary queries.
- Lightweight dashboard for current activity, recent sessions, and top usage.

## Architecture

1. Zig watcher captures active window/process/title changes.
2. Watcher emits JSONL records to stdout.
3. Tauri Rust host ingests stream, validates, and writes into SQLite.
4. Svelte UI reads data through Tauri commands.

Primary docs:

- `docs/PROJECT_PLAN.md`
- `docs/ARCHITECTURE.md`
- `docs/IMPLEMENTATION_BACKLOG.md`
- `docs/KNOWN_LIMITATIONS.md`

## Version Baseline (Stable)

As of 2026-03-12:

- Zig `0.15.2`
- Rust `1.94.0`
- `tauri` crate `2.10.3`
- `@tauri-apps/api` `2.10.1`
- `tauri-cli` `2.10.1`
- Svelte `5.53.10`
- SQLite `3.52.0`

## Prerequisites

- Windows 10/11 (x64)
- PowerShell
- Rust toolchain `1.94.0+`
- Node.js `24+` and npm `11+`

Note:

- Project-local Zig is expected at `.tools/zig-x86_64-windows-0.15.2/zig.exe`.

## Quick Start

1. Build watcher sidecar:
   - `powershell -ExecutionPolicy Bypass -File .\scripts\build-watcher.ps1`
2. Install frontend dependencies:
   - `cd ui`
   - `npm install`
3. Run desktop app in development:
   - `npm run tauri:dev`

## Verification Commands

- Build watcher:
  - `powershell -ExecutionPolicy Bypass -File .\scripts\build-watcher.ps1`
- Build watcher and run directly:
  - `powershell -ExecutionPolicy Bypass -File .\scripts\build-watcher.ps1 -Run`
- Run full local checks:
  - `powershell -ExecutionPolicy Bypass -File .\scripts\run-checks.ps1`
- Run full checks with Tauri debug build:
  - `powershell -ExecutionPolicy Bypass -File .\scripts\run-checks.ps1 -WithTauriBuild`
- Build release binary:
  - `cd ui`
  - `npm run tauri:build`

## Performance and Soak

- Short benchmark:
  - `powershell -ExecutionPolicy Bypass -File .\scripts\benchmark-watcher.ps1 -DurationSeconds 30 -SampleMs 500`
- One-shot soak run:
  - `powershell -ExecutionPolicy Bypass -File .\scripts\soak-watcher.ps1 -DurationSeconds 86400 -SampleMs 5000`
- Background soak controls:
  - Start: `powershell -ExecutionPolicy Bypass -File .\scripts\start-soak.ps1`
  - Check: `powershell -ExecutionPolicy Bypass -File .\scripts\check-soak.ps1`
  - Stop: `powershell -ExecutionPolicy Bypass -File .\scripts\stop-soak.ps1`

Latest performance references:

- `docs/perf/watcher-benchmark-summary.md`
- `docs/perf/watcher-soak-latest-summary.md`

## Release Artifacts

- Windows release executable:
  - `ui/src-tauri/target/release/sentry-desktop.exe`
- Windows MSI installer bundle:
  - `ui/src-tauri/target/release/bundle/msi/*.msi`

## Project Layout

```text
sentry/
  docs/
  scripts/
  ui/
    src/
    src-tauri/
  watcher-zig/
    src/
```

## Current Status

- [x] Zig watcher implemented (event hook + polling fallback + tests)
- [x] Rust host integration (ingestion + restart/backoff + SQLite pipeline)
- [x] Svelte dashboard implementation
- [x] Local verification scripts and benchmark harness
- [ ] 24h soak test final report
