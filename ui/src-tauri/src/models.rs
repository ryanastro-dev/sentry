use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize)]
pub struct SidecarFocusEvent {
    pub ts_unix_ms: i64,
    pub event: String,
    pub hwnd: String,
    pub pid: u32,
    pub exe_path: String,
    pub window_title: String,
    pub prev_duration_ms: i64,
}

#[derive(Debug, Clone)]
pub struct CurrentSession {
    pub app_id: i64,
    pub window_id: i64,
    pub started_at_ms: i64,
    pub pid: u32,
    pub hwnd: String,
    pub exe_path: String,
    pub window_title: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct CurrentActivity {
    pub started_at_ms: i64,
    pub pid: u32,
    pub hwnd: String,
    pub exe_path: String,
    pub window_title: String,
}

impl From<&CurrentSession> for CurrentActivity {
    fn from(value: &CurrentSession) -> Self {
        Self {
            started_at_ms: value.started_at_ms,
            pid: value.pid,
            hwnd: value.hwnd.clone(),
            exe_path: value.exe_path.clone(),
            window_title: value.window_title.clone(),
        }
    }
}

#[derive(Debug, Default, Clone, Serialize)]
pub struct MonitorStats {
    pub parsed_events: u64,
    pub parse_errors: u64,
    pub db_errors: u64,
    pub restarts: u64,
    pub sidecar_failures: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct MonitorStatus {
    pub running: bool,
    pub started_at_ms: Option<i64>,
    pub stats: MonitorStats,
}

#[derive(Debug, Clone, Serialize)]
pub struct SessionRow {
    pub exe_path: String,
    pub window_title: String,
    pub start_unix_ms: i64,
    pub end_unix_ms: i64,
    pub duration_ms: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct UsageRow {
    pub exe_path: String,
    pub app_name: String,
    pub total_duration_ms: i64,
    pub session_count: i64,
}
