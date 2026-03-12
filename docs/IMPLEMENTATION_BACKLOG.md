# Implementation Backlog (Sprint 0-1)

Last updated: 2026-03-12

## Setup
- [x] Create workspace layout:
  - [x] `watcher-zig/`
  - [x] `ui/`
  - [x] `ui/src-tauri/`
  - [x] `docs/`
- [x] Pin toolchain versions in bootstrap docs
- [x] Add one-command local build script

## Zig Watcher
- [x] Add Win32 extern declarations
- [x] Implement event hook initialization
- [x] Implement fallback polling heartbeat
- [x] Implement PID and exe path resolution
- [x] Implement title capture + UTF conversion
- [x] Implement change detection and duration compute
- [x] Emit JSONL to stdout
- [x] Add unit tests for conversions and duration math

## Rust Host
- [x] Spawn/stop sidecar command surface
- [x] Stream and parse stdout lines
- [x] Add schema validation and normalization
- [x] Add resilient restart/backoff policy
- [x] Add structured error logs

## SQLite
- [x] Create schema migration v1
- [x] Implement insert pipeline (apps/windows/events/sessions)
- [x] Enable WAL mode and write batching
- [x] Add read queries for timeline and summary
- [x] Add DB integration tests

## UI
- [x] Create live activity panel
- [x] Create timeline visualization
- [x] Create app summary cards
- [x] Wire query commands and refresh loop

## Reliability + Performance
- [x] Add counters: parse errors, API failures, restarts
- [x] Add benchmark harness (CPU/RAM)
- [ ] Run 24h soak test (in progress via `scripts/start-soak.ps1`)
- [x] Document final footprint and known limitations
