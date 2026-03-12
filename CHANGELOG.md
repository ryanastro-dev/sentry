# Changelog

All notable changes to this project are documented in this file.

The format is based on Keep a Changelog, and this project follows Semantic Versioning.

## [Unreleased]

## [0.1.2] - 2026-03-13

### Fixed
- Prevented desktop-style usage friction by disabling browser-like refresh shortcuts (`F5`, `Ctrl/Cmd+R`), text select-all shortcut, context menu, and drag-select behavior in the app shell.
- Reduced visual clutter and tightened spacing for a more compact dashboard layout.

### Changed
- Replaced hidden scrollbar behavior with a thin, theme-aligned scrollbar for better usability while preserving the compact look.

## [0.1.1] - 2026-03-12

### Fixed
- Prevented watcher loop termination on transient snapshot errors by logging and continuing.
- Added reliable stdout flushing for watcher JSON event output.
- Reduced process path lookup memory overhead with small-buffer-first + dynamic fallback strategy.
- Removed CI sidecar placeholder workaround; rust checks now build a real watcher sidecar first.
- Improved async safety in Tauri host by migrating shared state locks to `tokio::sync::{Mutex, RwLock}`.
- Fixed app upsert behavior to avoid overwriting existing display names unexpectedly.
- Added missing SQLite index on `sessions(app_id)` to improve query performance.
- Eliminated temporary test DB leakage by using RAII cleanup (`tempfile::TempDir`).
- Cleared stale UI error state correctly after successful monitor start/stop flows.
- Improved UI refresh stability by guarding overlapping refresh cycles.

### Changed
- Updated CI/release runners to `windows-latest`.
- Added committed generated TypeScript model bindings and CI verification step.
- Renamed PowerShell function to approved verb (`Resolve-StableZig`) for script lint compatibility.
- Added watcher test step in Zig build configuration.

[Unreleased]: https://github.com/ryanastro-dev/sentry/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/ryanastro-dev/sentry/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/ryanastro-dev/sentry/compare/v0.1.0...v0.1.1
