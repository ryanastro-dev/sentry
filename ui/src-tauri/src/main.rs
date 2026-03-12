mod db;
mod models;

use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use db::Database;
use models::{
    CurrentActivity, CurrentSession, MonitorStats, MonitorStatus, SessionRow, SidecarFocusEvent,
    UsageRow,
};
use tauri::{AppHandle, Manager, State};
use tauri_plugin_shell::{process::CommandEvent, ShellExt};
use tokio::sync::watch;

struct MonitorHandle {
    stop_tx: watch::Sender<bool>,
    task: tauri::async_runtime::JoinHandle<()>,
    started_at_ms: i64,
}

struct AppState {
    db: Arc<Mutex<Database>>,
    monitor: Arc<Mutex<Option<MonitorHandle>>>,
    current: Arc<RwLock<Option<CurrentSession>>>,
    stats: Arc<Mutex<MonitorStats>>,
}

fn now_unix_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

fn with_stats<F>(stats: &Arc<Mutex<MonitorStats>>, update: F)
where
    F: FnOnce(&mut MonitorStats),
{
    if let Ok(mut s) = stats.lock() {
        update(&mut s);
    }
}

fn increment_parse_error(stats: &Arc<Mutex<MonitorStats>>) {
    with_stats(stats, |s| s.parse_errors = s.parse_errors.saturating_add(1));
}

fn increment_db_error(stats: &Arc<Mutex<MonitorStats>>) {
    with_stats(stats, |s| s.db_errors = s.db_errors.saturating_add(1));
}

fn increment_parsed_event(stats: &Arc<Mutex<MonitorStats>>) {
    with_stats(stats, |s| s.parsed_events = s.parsed_events.saturating_add(1));
}

fn increment_restarts(stats: &Arc<Mutex<MonitorStats>>) {
    with_stats(stats, |s| s.restarts = s.restarts.saturating_add(1));
}

fn increment_sidecar_failures(stats: &Arc<Mutex<MonitorStats>>) {
    with_stats(stats, |s| {
        s.sidecar_failures = s.sidecar_failures.saturating_add(1)
    });
}

fn process_event_line(
    line: &str,
    db: &Arc<Mutex<Database>>,
    current: &Arc<RwLock<Option<CurrentSession>>>,
    stats: &Arc<Mutex<MonitorStats>>,
) {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return;
    }

    let parsed = match serde_json::from_str::<SidecarFocusEvent>(trimmed) {
        Ok(value) => value,
        Err(_) => {
            increment_parse_error(stats);
            return;
        }
    };

    if parsed.event != "focus_changed" {
        return;
    }

    let mut current_guard = match current.write() {
        Ok(lock) => lock,
        Err(_) => {
            increment_db_error(stats);
            return;
        }
    };
    let mut db_guard = match db.lock() {
        Ok(lock) => lock,
        Err(_) => {
            increment_db_error(stats);
            return;
        }
    };

    match db_guard.ingest_focus_event(&parsed, &mut current_guard) {
        Ok(_) => increment_parsed_event(stats),
        Err(e) => {
            eprintln!("[sentry][db] ingest failed: {e}");
            increment_db_error(stats);
        }
    }
}

fn consume_stdout_bytes(
    bytes: &[u8],
    buffer: &mut String,
    db: &Arc<Mutex<Database>>,
    current: &Arc<RwLock<Option<CurrentSession>>>,
    stats: &Arc<Mutex<MonitorStats>>,
) {
    buffer.push_str(&String::from_utf8_lossy(bytes));
    while let Some(newline_index) = buffer.find('\n') {
        let line = buffer[..newline_index].trim_end_matches('\r').to_string();
        let rest = buffer[(newline_index + 1)..].to_string();
        *buffer = rest;
        process_event_line(&line, db, current, stats);
    }
}

fn flush_stdout_tail(
    buffer: &mut String,
    db: &Arc<Mutex<Database>>,
    current: &Arc<RwLock<Option<CurrentSession>>>,
    stats: &Arc<Mutex<MonitorStats>>,
) {
    let tail = buffer.trim();
    if !tail.is_empty() {
        process_event_line(tail, db, current, stats);
    }
    buffer.clear();
}

async fn run_monitor_loop(
    app: AppHandle,
    mut stop_rx: watch::Receiver<bool>,
    db: Arc<Mutex<Database>>,
    current: Arc<RwLock<Option<CurrentSession>>>,
    stats: Arc<Mutex<MonitorStats>>,
) {
    let mut restart_attempt: u64 = 0;

    loop {
        if *stop_rx.borrow() {
            break;
        }

        let command = match app.shell().sidecar("sentry-watcher") {
            Ok(cmd) => cmd,
            Err(e) => {
                eprintln!("[sentry][monitor] sidecar config failed: {e}");
                increment_sidecar_failures(&stats);
                tokio::time::sleep(Duration::from_secs(1)).await;
                continue;
            }
        };

        let (mut rx, child) = match command.spawn() {
            Ok(value) => value,
            Err(e) => {
                eprintln!("[sentry][monitor] sidecar spawn failed: {e}");
                increment_sidecar_failures(&stats);
                tokio::time::sleep(Duration::from_secs(1)).await;
                continue;
            }
        };
        let mut buffer = String::new();

        loop {
            tokio::select! {
                changed = stop_rx.changed() => {
                    if changed.is_err() || *stop_rx.borrow() {
                        let _ = child.kill();
                        flush_stdout_tail(&mut buffer, &db, &current, &stats);
                        return;
                    }
                }
                event = rx.recv() => {
                    match event {
                        Some(CommandEvent::Stdout(bytes)) => {
                            consume_stdout_bytes(&bytes, &mut buffer, &db, &current, &stats);
                        }
                        Some(CommandEvent::Stderr(bytes)) => {
                            let text = String::from_utf8_lossy(&bytes).trim().to_string();
                            if !text.is_empty() {
                                eprintln!("[sentry][watcher] {text}");
                            }
                        }
                        Some(CommandEvent::Terminated(status)) => {
                            flush_stdout_tail(&mut buffer, &db, &current, &stats);
                            eprintln!("[sentry][monitor] watcher terminated: {status:?}");
                            increment_restarts(&stats);
                            restart_attempt = restart_attempt.saturating_add(1);
                            let backoff_secs = (1u64 << restart_attempt.min(5)).min(30);
                            tokio::time::sleep(Duration::from_secs(backoff_secs)).await;
                            break;
                        }
                        None => {
                            flush_stdout_tail(&mut buffer, &db, &current, &stats);
                            increment_restarts(&stats);
                            restart_attempt = restart_attempt.saturating_add(1);
                            let backoff_secs = (1u64 << restart_attempt.min(5)).min(30);
                            tokio::time::sleep(Duration::from_secs(backoff_secs)).await;
                            break;
                        }
                        _ => {}
                    }
                }
            }
        }
    }
}

fn build_status(state: &AppState) -> Result<MonitorStatus, String> {
    let running_started_at = state
        .monitor
        .lock()
        .map_err(|_| "monitor lock poisoned".to_string())?
        .as_ref()
        .map(|handle| handle.started_at_ms);

    let stats = state
        .stats
        .lock()
        .map_err(|_| "stats lock poisoned".to_string())?
        .clone();

    Ok(MonitorStatus {
        running: running_started_at.is_some(),
        started_at_ms: running_started_at,
        stats,
    })
}

#[tauri::command]
async fn start_monitoring(app: AppHandle, state: State<'_, AppState>) -> Result<MonitorStatus, String> {
    {
        let monitor_guard = state
            .monitor
            .lock()
            .map_err(|_| "monitor lock poisoned".to_string())?;
        if monitor_guard.is_some() {
            return build_status(&state);
        }
    }

    let (stop_tx, stop_rx) = watch::channel(false);
    let task = tauri::async_runtime::spawn(run_monitor_loop(
        app,
        stop_rx,
        state.db.clone(),
        state.current.clone(),
        state.stats.clone(),
    ));

    let mut monitor_guard = state
        .monitor
        .lock()
        .map_err(|_| "monitor lock poisoned".to_string())?;
    *monitor_guard = Some(MonitorHandle {
        stop_tx,
        task,
        started_at_ms: now_unix_ms(),
    });

    build_status(&state)
}

#[tauri::command]
async fn stop_monitoring(state: State<'_, AppState>) -> Result<MonitorStatus, String> {
    let maybe_handle = {
        let mut monitor_guard = state
            .monitor
            .lock()
            .map_err(|_| "monitor lock poisoned".to_string())?;
        monitor_guard.take()
    };

    if let Some(handle) = maybe_handle {
        let _ = handle.stop_tx.send(true);
        let _ = handle.task.await;
    }

    let maybe_current = {
        let mut current_guard = state
            .current
            .write()
            .map_err(|_| "current lock poisoned".to_string())?;
        current_guard.take()
    };

    if let Some(current) = maybe_current {
        let mut db_guard = state
            .db
            .lock()
            .map_err(|_| "db lock poisoned".to_string())?;
        db_guard
            .close_current_session(&current, now_unix_ms())
            .map_err(|e| format!("close session failed: {e}"))?;
    }

    build_status(&state)
}

#[tauri::command]
fn monitoring_status(state: State<'_, AppState>) -> Result<MonitorStatus, String> {
    build_status(&state)
}

#[tauri::command]
fn get_current_activity(state: State<'_, AppState>) -> Result<Option<CurrentActivity>, String> {
    let current = state
        .current
        .read()
        .map_err(|_| "current lock poisoned".to_string())?;
    Ok(current.as_ref().map(CurrentActivity::from))
}

#[tauri::command]
fn get_recent_sessions(state: State<'_, AppState>, limit: Option<u32>) -> Result<Vec<SessionRow>, String> {
    let db_guard = state
        .db
        .lock()
        .map_err(|_| "db lock poisoned".to_string())?;
    db_guard
        .recent_sessions(limit.unwrap_or(200))
        .map_err(|e| format!("query sessions failed: {e}"))
}

#[tauri::command]
fn get_usage_summary(
    state: State<'_, AppState>,
    since_unix_ms: Option<i64>,
    limit: Option<u32>,
) -> Result<Vec<UsageRow>, String> {
    let db_guard = state
        .db
        .lock()
        .map_err(|_| "db lock poisoned".to_string())?;
    db_guard
        .usage_since(
            since_unix_ms.unwrap_or_else(|| now_unix_ms() - 86_400_000),
            limit.unwrap_or(50),
        )
        .map_err(|e| format!("query usage failed: {e}"))
}

fn init_state(app: &AppHandle) -> Result<AppState, String> {
    let mut db_path = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("resolve app data dir failed: {e}"))?;
    std::fs::create_dir_all(&db_path).map_err(|e| format!("create app data dir failed: {e}"))?;
    db_path.push("sentry.db");

    let db = Database::open(&db_path)?;
    Ok(AppState {
        db: Arc::new(Mutex::new(db)),
        monitor: Arc::new(Mutex::new(None)),
        current: Arc::new(RwLock::new(None)),
        stats: Arc::new(Mutex::new(MonitorStats::default())),
    })
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .setup(|app| {
            let state = init_state(app.handle())?;
            app.manage(state);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            start_monitoring,
            stop_monitoring,
            monitoring_status,
            get_current_activity,
            get_recent_sessions,
            get_usage_summary
        ])
        .run(tauri::generate_context!())
        .expect("failed to run tauri app");
}
