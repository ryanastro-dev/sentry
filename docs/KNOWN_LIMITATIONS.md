# Known Limitations

Last updated: 2026-03-12

## Runtime behavior

- Some protected/system processes may not expose full executable paths due to Windows access controls.
- Window title capture is subject to `GetWindowTextW` cross-process limitations; empty titles are expected in some apps.
- If the watcher process is externally terminated repeatedly, restart backoff increases to reduce rapid respawn loops.

## Performance verification scope

- A short benchmark harness is implemented (`scripts/benchmark-watcher.ps1`) and produces artifacts under `docs/perf/`.
- A 24-hour soak test run is currently in progress via `scripts/start-soak.ps1`.

## Packaging scope

- Tauri debug build is verified. Release signing/notarization flows are not configured in this project skeleton.
