<script lang="ts">
  import { invoke } from "@tauri-apps/api/core";
  import { onMount } from "svelte";
  import type { CurrentActivity, MonitorStatus, SessionRow, UsageRow } from "./lib/models";

  let status: MonitorStatus | null = null;
  let current: CurrentActivity | null = null;
  let sessions: SessionRow[] = [];
  let usage: UsageRow[] = [];
  let errorMessage = "";
  let isStarting = false;
  let isStopping = false;
  let isInitialLoad = true;
  let refreshInFlight = false;

  let refreshTimer: ReturnType<typeof setInterval> | null = null;

  $: maxUsage = usage.reduce((max, row) => Math.max(max, row.total_duration_ms), 0);

  const formatDuration = (ms: number): string => {
    const totalSeconds = Math.floor(ms / 1000);
    const hours = Math.floor(totalSeconds / 3600);
    const minutes = Math.floor((totalSeconds % 3600) / 60);
    const seconds = totalSeconds % 60;
    if (hours > 0) return `${hours}h ${minutes}m`;
    if (minutes > 0) return `${minutes}m ${seconds}s`;
    return `${seconds}s`;
  };

  const formatDateTime = (ms: number): string => {
    return new Date(ms).toLocaleString();
  };

  const shortName = (path: string): string => {
    const segments = path.split("\\");
    return segments[segments.length - 1] || path;
  };

  const preventWebRefresh = (event: KeyboardEvent) => {
    const key = event.key.toLowerCase();
    const withCmd = event.ctrlKey || event.metaKey;
    const isReload = key === "f5" || (withCmd && key === "r");
    const isHardReload = withCmd && event.shiftKey && key === "r";
    const isSelectAll = withCmd && key === "a";
    if (isReload || isHardReload || isSelectAll) {
      event.preventDefault();
      event.stopPropagation();
    }
  };

  const preventContextMenu = (event: MouseEvent) => {
    event.preventDefault();
  };

  const preventDragSelect = (event: DragEvent) => {
    event.preventDefault();
  };

  async function refreshStatusOnly() {
    status = await invoke<MonitorStatus>("monitoring_status");
    current = await invoke<CurrentActivity | null>("get_current_activity");
  }

  async function refreshData() {
    sessions = await invoke<SessionRow[]>("get_recent_sessions", { limit: 120 });
    usage = await invoke<UsageRow[]>("get_usage_summary", {
      sinceUnixMs: Date.now() - 1000 * 60 * 60 * 24,
      limit: 20
    });
  }

  async function refreshAll() {
    if (refreshInFlight) {
      return;
    }
    refreshInFlight = true;
    try {
      await Promise.all([refreshStatusOnly(), refreshData()]);
      errorMessage = "";
    } catch (error) {
      errorMessage = String(error);
    } finally {
      refreshInFlight = false;
      isInitialLoad = false;
    }
  }

  async function startMonitoring() {
    try {
      isStarting = true;
      status = await invoke<MonitorStatus>("start_monitoring");
      errorMessage = "";
      await refreshAll();
    } catch (error) {
      errorMessage = String(error);
    } finally {
      isStarting = false;
    }
  }

  async function stopMonitoring() {
    try {
      isStopping = true;
      status = await invoke<MonitorStatus>("stop_monitoring");
      errorMessage = "";
      await refreshAll();
    } catch (error) {
      errorMessage = String(error);
    } finally {
      isStopping = false;
    }
  }

  onMount(() => {
    void refreshAll();
    refreshTimer = setInterval(() => {
      void refreshAll();
    }, 2000);

    window.addEventListener("keydown", preventWebRefresh, { capture: true });
    window.addEventListener("contextmenu", preventContextMenu);
    window.addEventListener("dragstart", preventDragSelect);

    return () => {
      if (refreshTimer) {
        clearInterval(refreshTimer);
      }
      window.removeEventListener("keydown", preventWebRefresh, { capture: true });
      window.removeEventListener("contextmenu", preventContextMenu);
      window.removeEventListener("dragstart", preventDragSelect);
    };
  });
</script>

<main class="page">
  <section class="hero">
    <p class="eyebrow">Sentry Core Dashboard</p>
    <h1>Windows Activity Monitor</h1>
    <p class="subhead">Zig watcher + Rust host + SQLite timeline</p>

    <div class="hero-actions">
      <button class="btn primary" on:click={startMonitoring} disabled={isStarting || status?.running}>
        {#if isStarting}Starting...{:else}Start Monitoring{/if}
      </button>
      <button class="btn ghost" on:click={stopMonitoring} disabled={isStopping || !status?.running}>
        {#if isStopping}Stopping...{:else}Stop Monitoring{/if}
      </button>
    </div>
  </section>

  <section class="grid">
    <article class="card">
      <h2>Monitor Status</h2>
      <div class="row">
        <span>State</span>
        <strong class:ok={status?.running} class:down={!status?.running}>
          {status?.running ? "Running" : "Stopped"}
        </strong>
      </div>
      <div class="row">
        <span>Started</span>
        <strong>{status?.started_at_ms ? formatDateTime(status.started_at_ms) : "-"}</strong>
      </div>
      <div class="row">
        <span>Parsed Events</span>
        <strong>{status?.stats.parsed_events ?? 0}</strong>
      </div>
      <div class="row">
        <span>Parse Errors</span>
        <strong>{status?.stats.parse_errors ?? 0}</strong>
      </div>
      <div class="row">
        <span>DB Errors</span>
        <strong>{status?.stats.db_errors ?? 0}</strong>
      </div>
      <div class="row">
        <span>Restarts</span>
        <strong>{status?.stats.restarts ?? 0}</strong>
      </div>
      <div class="row">
        <span>Sidecar Failures</span>
        <strong>{status?.stats.sidecar_failures ?? 0}</strong>
      </div>
    </article>

    <article class="card wide">
      <h2>Current Activity</h2>
      {#if current}
        <div class="current-title">{current.window_title || "(untitled window)"}</div>
        <div class="current-meta">{shortName(current.exe_path)}</div>
        <div class="row">
          <span>Started</span>
          <strong>{formatDateTime(current.started_at_ms)}</strong>
        </div>
        <div class="row">
          <span>PID</span>
          <strong>{current.pid}</strong>
        </div>
        <div class="row">
          <span>HWND</span>
          <strong>{current.hwnd}</strong>
        </div>
      {:else}
        <p class="placeholder">No active session captured yet.</p>
      {/if}
    </article>
  </section>

  <section class="grid">
    <article class="card wide">
      <h2>Top Usage (Last 24h)</h2>
      {#if isInitialLoad}
        <p class="placeholder">Loading usage data...</p>
      {:else if usage.length === 0}
        <p class="placeholder">No usage data yet.</p>
      {:else}
        <div class="usage-list">
          {#each usage as row}
            <div class="usage-item">
              <div class="usage-head">
                <span>{row.app_name}</span>
                <strong>{formatDuration(row.total_duration_ms)}</strong>
              </div>
              <div class="usage-track">
                <div
                  class="usage-fill"
                  style={`width: ${maxUsage > 0 ? Math.max(2, Math.round((row.total_duration_ms / maxUsage) * 100)) : 0}%`}
                ></div>
              </div>
            </div>
          {/each}
        </div>
      {/if}
    </article>

    <article class="card">
      <h2>Recent Sessions</h2>
      {#if isInitialLoad}
        <p class="placeholder">Loading recent sessions...</p>
      {:else if sessions.length === 0}
        <p class="placeholder">No timeline entries yet.</p>
      {:else}
        <div class="sessions">
          {#each sessions.slice(0, 6) as row}
            <div class="session-item">
              <p class="session-app">{shortName(row.exe_path)}</p>
              <p class="session-title">{row.window_title || "(untitled window)"}</p>
              <p class="session-meta">{formatDuration(row.duration_ms)} • {formatDateTime(row.start_unix_ms)}</p>
            </div>
          {/each}
        </div>
      {/if}
    </article>
  </section>

  {#if errorMessage}
    <section class="error">
      <strong>Runtime error:</strong> {errorMessage}
    </section>
  {/if}
</main>
