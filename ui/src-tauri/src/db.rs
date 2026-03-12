use std::path::Path;

use rusqlite::{Connection, params};

use crate::models::{CurrentSession, SessionRow, SidecarFocusEvent, UsageRow};

pub struct Database {
    conn: Connection,
}

impl Database {
    pub fn open(path: &Path) -> Result<Self, String> {
        let conn = Connection::open(path).map_err(|e| format!("open db failed: {e}"))?;
        conn.pragma_update(None, "journal_mode", "WAL")
            .map_err(|e| format!("set WAL failed: {e}"))?;
        conn.pragma_update(None, "synchronous", "NORMAL")
            .map_err(|e| format!("set synchronous failed: {e}"))?;
        Self::migrate(&conn).map_err(|e| format!("migration failed: {e}"))?;
        Ok(Self { conn })
    }

    fn migrate(conn: &Connection) -> rusqlite::Result<()> {
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS apps (
              id INTEGER PRIMARY KEY,
              exe_path TEXT UNIQUE NOT NULL,
              name TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS windows (
              id INTEGER PRIMARY KEY,
              app_id INTEGER NOT NULL REFERENCES apps(id),
              title TEXT NOT NULL,
              UNIQUE(app_id, title)
            );

            CREATE TABLE IF NOT EXISTS focus_events (
              id INTEGER PRIMARY KEY,
              ts_unix_ms INTEGER NOT NULL,
              app_id INTEGER REFERENCES apps(id),
              window_id INTEGER REFERENCES windows(id),
              pid INTEGER,
              hwnd TEXT
            );

            CREATE TABLE IF NOT EXISTS sessions (
              id INTEGER PRIMARY KEY,
              app_id INTEGER REFERENCES apps(id),
              window_id INTEGER REFERENCES windows(id),
              start_unix_ms INTEGER NOT NULL,
              end_unix_ms INTEGER NOT NULL,
              duration_ms INTEGER NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_focus_events_ts ON focus_events(ts_unix_ms DESC);
            CREATE INDEX IF NOT EXISTS idx_sessions_end ON sessions(end_unix_ms DESC);
            CREATE INDEX IF NOT EXISTS idx_sessions_app ON sessions(app_id);
            "#,
        )?;

        Ok(())
    }

    pub fn ingest_focus_event(
        &mut self,
        event: &SidecarFocusEvent,
        current: &mut Option<CurrentSession>,
    ) -> rusqlite::Result<()> {
        let normalized_exe_path = normalize_exe_path(&event.exe_path, event.pid);
        let normalized_title = normalize_title(&event.window_title);
        let app_name = derive_app_name(&normalized_exe_path);

        let tx = self.conn.transaction()?;
        let app_id = upsert_app(&tx, &normalized_exe_path, &app_name)?;
        let window_id = upsert_window(&tx, app_id, &normalized_title)?;

        tx.execute(
            "INSERT INTO focus_events (ts_unix_ms, app_id, window_id, pid, hwnd) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                event.ts_unix_ms,
                app_id,
                window_id,
                i64::from(event.pid),
                event.hwnd
            ],
        )?;

        if let Some(previous) = current.as_ref() {
            let duration_ms = event.prev_duration_ms.max(0);
            if duration_ms > 0 {
                let end_unix_ms = event.ts_unix_ms;
                let start_unix_ms = end_unix_ms - duration_ms;
                tx.execute(
                    "INSERT INTO sessions (app_id, window_id, start_unix_ms, end_unix_ms, duration_ms) VALUES (?1, ?2, ?3, ?4, ?5)",
                    params![
                        previous.app_id,
                        previous.window_id,
                        start_unix_ms,
                        end_unix_ms,
                        duration_ms
                    ],
                )?;
            }
        }

        tx.commit()?;

        *current = Some(CurrentSession {
            app_id,
            window_id,
            started_at_ms: event.ts_unix_ms,
            pid: event.pid,
            hwnd: event.hwnd.clone(),
            exe_path: normalized_exe_path,
            window_title: normalized_title,
        });

        Ok(())
    }

    pub fn close_current_session(
        &mut self,
        current: &CurrentSession,
        end_unix_ms: i64,
    ) -> rusqlite::Result<()> {
        let duration_ms = (end_unix_ms - current.started_at_ms).max(0);
        if duration_ms == 0 {
            return Ok(());
        }

        self.conn.execute(
            "INSERT INTO sessions (app_id, window_id, start_unix_ms, end_unix_ms, duration_ms) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                current.app_id,
                current.window_id,
                current.started_at_ms,
                end_unix_ms,
                duration_ms
            ],
        )?;

        Ok(())
    }

    pub fn recent_sessions(&self, limit: u32) -> rusqlite::Result<Vec<SessionRow>> {
        let mut stmt = self.conn.prepare(
            r#"
            SELECT a.exe_path, w.title, s.start_unix_ms, s.end_unix_ms, s.duration_ms
            FROM sessions s
            LEFT JOIN apps a ON a.id = s.app_id
            LEFT JOIN windows w ON w.id = s.window_id
            ORDER BY s.end_unix_ms DESC
            LIMIT ?1
            "#,
        )?;

        let iter = stmt.query_map(params![i64::from(limit)], |row| {
            Ok(SessionRow {
                exe_path: row.get::<_, Option<String>>(0)?.unwrap_or_default(),
                window_title: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                start_unix_ms: row.get(2)?,
                end_unix_ms: row.get(3)?,
                duration_ms: row.get(4)?,
            })
        })?;

        iter.collect()
    }

    pub fn usage_since(&self, since_unix_ms: i64, limit: u32) -> rusqlite::Result<Vec<UsageRow>> {
        let mut stmt = self.conn.prepare(
            r#"
            SELECT
                COALESCE(a.exe_path, '') AS exe_path,
                COALESCE(a.name, 'unknown') AS app_name,
                SUM(s.duration_ms) AS total_duration_ms,
                COUNT(s.id) AS session_count
            FROM sessions s
            LEFT JOIN apps a ON a.id = s.app_id
            WHERE s.end_unix_ms >= ?1
            GROUP BY a.exe_path, a.name
            ORDER BY total_duration_ms DESC
            LIMIT ?2
            "#,
        )?;

        let iter = stmt.query_map(params![since_unix_ms, i64::from(limit)], |row| {
            Ok(UsageRow {
                exe_path: row.get(0)?,
                app_name: row.get(1)?,
                total_duration_ms: row.get(2)?,
                session_count: row.get(3)?,
            })
        })?;

        iter.collect()
    }
}

fn upsert_app(tx: &rusqlite::Transaction<'_>, exe_path: &str, name: &str) -> rusqlite::Result<i64> {
    tx.execute(
        "INSERT INTO apps (exe_path, name) VALUES (?1, ?2)
         ON CONFLICT(exe_path) DO NOTHING",
        params![exe_path, name],
    )?;

    tx.query_row(
        "SELECT id FROM apps WHERE exe_path = ?1",
        params![exe_path],
        |row| row.get(0),
    )
}

fn upsert_window(
    tx: &rusqlite::Transaction<'_>,
    app_id: i64,
    title: &str,
) -> rusqlite::Result<i64> {
    tx.execute(
        "INSERT INTO windows (app_id, title) VALUES (?1, ?2)
         ON CONFLICT(app_id, title) DO NOTHING",
        params![app_id, title],
    )?;

    tx.query_row(
        "SELECT id FROM windows WHERE app_id = ?1 AND title = ?2",
        params![app_id, title],
        |row| row.get(0),
    )
}

fn normalize_exe_path(exe_path: &str, pid: u32) -> String {
    let trimmed = exe_path.trim();
    if trimmed.is_empty() {
        format!("unknown://pid/{pid}")
    } else {
        trimmed.to_string()
    }
}

fn normalize_title(title: &str) -> String {
    title.trim().to_string()
}

fn derive_app_name(exe_path: &str) -> String {
    let path = Path::new(exe_path);
    match path.file_name().and_then(|x| x.to_str()) {
        Some(file) if !file.is_empty() => file.to_string(),
        _ => "unknown".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn temp_db_path(name: &str) -> (tempfile::TempDir, PathBuf) {
        let dir = tempfile::Builder::new()
            .prefix(&format!("sentry-{name}-"))
            .tempdir()
            .expect("create temp dir");
        let path = dir.path().join("sentry.db");
        (dir, path)
    }

    #[test]
    fn ingest_focus_events_creates_session() {
        let (_tmp, path) = temp_db_path("ingest");
        let mut db = Database::open(&path).expect("db open");
        let mut current = None;

        let e1 = SidecarFocusEvent {
            ts_unix_ms: 1_000,
            event: "focus_changed".to_string(),
            hwnd: "0x1".to_string(),
            pid: 111,
            exe_path: r"C:\Apps\alpha.exe".to_string(),
            window_title: "Alpha".to_string(),
            prev_duration_ms: 0,
        };
        db.ingest_focus_event(&e1, &mut current).expect("ingest e1");

        let e2 = SidecarFocusEvent {
            ts_unix_ms: 4_000,
            event: "focus_changed".to_string(),
            hwnd: "0x2".to_string(),
            pid: 222,
            exe_path: r"C:\Apps\beta.exe".to_string(),
            window_title: "Beta".to_string(),
            prev_duration_ms: 3_000,
        };
        db.ingest_focus_event(&e2, &mut current).expect("ingest e2");

        let sessions = db.recent_sessions(10).expect("query");
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].duration_ms, 3_000);
        assert_eq!(sessions[0].start_unix_ms, 1_000);
        assert_eq!(sessions[0].end_unix_ms, 4_000);
    }

    #[test]
    fn close_current_session_persists_duration() {
        let (_tmp, path) = temp_db_path("close");
        let mut db = Database::open(&path).expect("db open");
        let mut current = None;

        let e1 = SidecarFocusEvent {
            ts_unix_ms: 2_000,
            event: "focus_changed".to_string(),
            hwnd: "0xAA".to_string(),
            pid: 333,
            exe_path: r"C:\Apps\gamma.exe".to_string(),
            window_title: "Gamma".to_string(),
            prev_duration_ms: 0,
        };
        db.ingest_focus_event(&e1, &mut current).expect("ingest e1");

        let active = current.expect("current exists");
        db.close_current_session(&active, 8_000)
            .expect("close current");

        let sessions = db.recent_sessions(10).expect("query");
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].duration_ms, 6_000);

        let usage = db.usage_since(0, 10).expect("usage");
        assert_eq!(usage.len(), 1);
        assert_eq!(usage[0].total_duration_ms, 6_000);
    }
}
