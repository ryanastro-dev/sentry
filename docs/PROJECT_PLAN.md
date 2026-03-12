# Sentry Core Project Plan (Stable Track)

Last updated: 2026-03-12

## 1) Scope

Build a low-overhead Windows activity monitor with:
- Zig watcher (Win32 integration, sidecar binary)
- Tauri v2 Rust host (process control, ingestion, persistence)
- Svelte UI (activity timeline and summaries)

Target behavior:
- Foreground app and window title tracking
- Accurate session durations
- Reliable local persistence (SQLite)
- Low resource footprint for always-on usage

## 2) Stable Version Baseline (Pinned)

Pinned from official sources as of 2026-03-12:
- Zig: `0.15.2` (stable)
- Rust: `1.94.0` (stable)
- Tauri crates: `2.10.3`
- `@tauri-apps/api`: `2.10.1`
- `tauri-cli`: `2.10.1`
- Svelte: `5.53.9`
- SQLite: `3.52.0`

Rule: no `-dev`, `master`, or prerelease artifacts in this track.

## 3) Architecture Decision Summary

- Event-first capture:
  - Primary: `SetWinEventHook` with `EVENT_SYSTEM_FOREGROUND`
  - Optional title-change hook: `EVENT_OBJECT_NAMECHANGE` (filtered)
  - Safety fallback: low-rate polling loop (1s) for resilience
- Zig sidecar emits JSON lines to `stdout`
- Rust host owns SQLite writes (single-writer model)
- UI reads aggregated data via Tauri commands

## 4) Milestones

## M0 - Repo and Toolchain Bootstrap (0.5 day)
Deliverables:
- Workspace layout and build scripts
- Version pins in docs and config
- Smoke-run script for Zig sidecar + host launcher

Exit criteria:
- Clean local build with pinned versions
- Sidecar process launches from host and exits cleanly

## M1 - Zig Watcher Core (2 days)
Deliverables:
- Win32 FFI bindings for:
  - `GetForegroundWindow`
  - `GetWindowThreadProcessId`
  - `OpenProcess`
  - `QueryFullProcessImageNameW`
  - `GetWindowTextW`
  - `SetWinEventHook` / `UnhookWinEvent`
- UTF-16 -> UTF-8 conversion pipeline
- Change detection and duration calculation

Exit criteria:
- Emits valid JSONL activity records
- No handle leaks (`CloseHandle` coverage)
- Watcher recovers from transient API failures

## M2 - Rust Host + Sidecar Integration (1.5 days)
Deliverables:
- Tauri command to start/stop watcher sidecar
- Async stdout stream ingestion
- Parse, validate, normalize events
- Crash-safe restart/backoff policy

Exit criteria:
- End-to-end stream ingestion with >99.9% valid event parse in test run
- Host remains responsive during watcher restart cycles

## M3 - SQLite Storage Layer (1 day)
Deliverables:
- Schema v1:
  - `apps`
  - `windows`
  - `focus_events`
  - `sessions`
- Insert pipeline + transactional writes
- Basic aggregation queries

Exit criteria:
- No DB corruption under abrupt sidecar termination test
- Timeline query and app summary query return expected results

## M4 - Svelte UI (1.5 days)
Deliverables:
- Live current activity card
- Daily timeline view
- App usage summary

Exit criteria:
- UI updates in near-real-time (<=2s perceived lag)
- Desktop and mobile-friendly layout in Tauri window sizes

## M5 - Performance and Reliability Hardening (2 days)
Deliverables:
- Benchmark harness for CPU/RAM footprint
- Log rotation / retention policy
- Error telemetry and diagnostics panel

Exit criteria:
- CPU average near idle baseline during normal use
- Memory footprint minimized and documented
- 24-hour soak test without crashes or unbounded growth

## 5) Resource Targets

Hard target:
- Watcher process RSS: `< 8 MB` initial stable target

Stretch target:
- Watcher process RSS: `< 2 MB` (requires aggressive alloc control and lean runtime path)

Rationale:
- `<2 MB` is possible but high-risk as a first acceptance gate on modern Windows.
- We lock first gate at `<8 MB`, then optimize to stretch target in M5.

## 6) Risks and Mitigations

Risk: title capture inconsistency across processes.
- Mitigation: prefer caption text only; tolerate empty titles; include retries and null-safe schema.

Risk: missed transitions due to pure polling.
- Mitigation: event-driven primary path + polling fallback.

Risk: SQLite write contention.
- Mitigation: single writer in Rust host; batching and WAL mode.

Risk: API failures for protected/system processes.
- Mitigation: degrade gracefully with PID-only event and error classification.

## 7) Definition of Done (Project)

- Stable toolchain-only build
- End-to-end activity tracking and persistence
- Recoverable sidecar lifecycle
- Baseline performance report and known limitations documented
- Packaged Tauri app with sidecar on Windows x86_64

## 8) Immediate Next Execution Order

1. Create workspace structure and task scripts.
2. Implement Zig watcher skeleton with WinEvent hook and JSONL output.
3. Wire sidecar spawn/ingest in Rust host.
4. Add SQLite schema + writer + queries.
5. Build UI views.
6. Run performance pass and tighten memory.
