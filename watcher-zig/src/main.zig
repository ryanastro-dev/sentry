const std = @import("std");
const c = @cImport({
    @cInclude("windows.h");
});

const poll_interval_ns: u64 = 150 * std.time.ns_per_ms;
const fallback_poll_ms: i64 = 1_000;

var foreground_changed = std.atomic.Value(bool).init(true);

const Snapshot = struct {
    hwnd: usize,
    pid: u32,
    exe_path: []u8,
    window_title: []u8,

    fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.exe_path);
        allocator.free(self.window_title);
        self.* = undefined;
    }
};

fn winEventCallback(
    _: c.HWINEVENTHOOK,
    _: c.DWORD,
    _: c.HWND,
    _: c.LONG,
    _: c.LONG,
    _: c.DWORD,
    _: c.DWORD,
) callconv(.winapi) void {
    foreground_changed.store(true, .seq_cst);
}

fn hookThreadMain() void {
    const flags: c.DWORD = c.WINEVENT_OUTOFCONTEXT | c.WINEVENT_SKIPOWNPROCESS;
    const hook_foreground = c.SetWinEventHook(
        c.EVENT_SYSTEM_FOREGROUND,
        c.EVENT_SYSTEM_FOREGROUND,
        null,
        winEventCallback,
        0,
        0,
        flags,
    );
    const hook_title = c.SetWinEventHook(
        c.EVENT_OBJECT_NAMECHANGE,
        c.EVENT_OBJECT_NAMECHANGE,
        null,
        winEventCallback,
        0,
        0,
        flags,
    );

    if (hook_foreground == null and hook_title == null) {
        return;
    }

    defer {
        if (hook_foreground != null) _ = c.UnhookWinEvent(hook_foreground);
        if (hook_title != null) _ = c.UnhookWinEvent(hook_title);
    }

    var msg: c.MSG = undefined;
    while (c.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageW(&msg);
    }
}

fn utf16SliceToUtf8Alloc(allocator: std.mem.Allocator, input: []const u16) ![]u8 {
    if (input.len == 0) return allocator.dupe(u8, "");
    return std.unicode.utf16LeToUtf8Alloc(allocator, input);
}

fn computePrevDuration(now_ms: i64, previous_started_ms: i64) i64 {
    if (previous_started_ms <= 0) return 0;
    return @max(0, now_ms - previous_started_ms);
}

fn queryProcessExePathUtf8(allocator: std.mem.Allocator, process: c.HANDLE) ![]u8 {
    var path_utf16_small: [1024]u16 = [_]u16{0} ** 1024;
    var path_len: c.DWORD = @intCast(path_utf16_small.len);
    if (c.QueryFullProcessImageNameW(process, 0, @ptrCast(&path_utf16_small[0]), &path_len) != 0 and path_len > 0) {
        return utf16SliceToUtf8Alloc(allocator, path_utf16_small[0..@as(usize, @intCast(path_len))]);
    }

    const last_error = c.GetLastError();
    if (last_error == c.ERROR_INSUFFICIENT_BUFFER and path_len > path_utf16_small.len and path_len <= 32768) {
        const needed_len: usize = @intCast(path_len);
        const path_utf16_dynamic = try allocator.alloc(u16, needed_len);
        defer allocator.free(path_utf16_dynamic);

        var dynamic_path_len: c.DWORD = @intCast(path_utf16_dynamic.len);
        if (c.QueryFullProcessImageNameW(process, 0, path_utf16_dynamic.ptr, &dynamic_path_len) != 0 and dynamic_path_len > 0) {
            return utf16SliceToUtf8Alloc(allocator, path_utf16_dynamic[0..@as(usize, @intCast(dynamic_path_len))]);
        }
    }

    return allocator.dupe(u8, "");
}

fn captureSnapshot(allocator: std.mem.Allocator) !Snapshot {
    const hwnd = c.GetForegroundWindow();
    const hwnd_as_usize: usize = if (hwnd != null) @intFromPtr(hwnd) else 0;

    var pid_raw: c.DWORD = 0;
    if (hwnd != null) {
        _ = c.GetWindowThreadProcessId(hwnd, &pid_raw);
    }

    var title_utf16: [512]u16 = [_]u16{0} ** 512;
    const title_len: c_int = if (hwnd != null)
        c.GetWindowTextW(hwnd, @ptrCast(&title_utf16[0]), @as(c_int, @intCast(title_utf16.len)))
    else
        0;

    const title_slice: []const u16 = if (title_len > 0)
        title_utf16[0..@as(usize, @intCast(title_len))]
    else
        &[_]u16{};
    const title_utf8 = try utf16SliceToUtf8Alloc(allocator, title_slice);

    var exe_utf8: []u8 = try allocator.dupe(u8, "");
    if (pid_raw != 0) {
        const process = c.OpenProcess(c.PROCESS_QUERY_LIMITED_INFORMATION, c.FALSE, pid_raw);
        if (process != null) {
            defer _ = c.CloseHandle(process);
            allocator.free(exe_utf8);
            exe_utf8 = try queryProcessExePathUtf8(allocator, process);
        }
    }

    return Snapshot{
        .hwnd = hwnd_as_usize,
        .pid = @intCast(pid_raw),
        .exe_path = exe_utf8,
        .window_title = title_utf8,
    };
}

pub fn main() !void {
    if (std.Thread.spawn(.{}, hookThreadMain, .{})) |thread| {
        thread.detach();
    } else |_| {
        // Hook failures are tolerated because fallback polling is always active.
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout_file = std.fs.File.stdout();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var previous_hwnd: usize = 0;
    var previous_title: []u8 = try allocator.dupe(u8, "");
    defer allocator.free(previous_title);
    var previous_started_ms: i64 = 0;
    var emitted_first_event = false;
    var last_fallback_poll_ms: i64 = 0;

    while (true) {
        const now_ms: i64 = std.time.milliTimestamp();
        const event_triggered = foreground_changed.swap(false, .seq_cst);
        const fallback_due = last_fallback_poll_ms == 0 or (now_ms - last_fallback_poll_ms) >= fallback_poll_ms;
        if (!(event_triggered or fallback_due)) {
            std.Thread.sleep(poll_interval_ns);
            continue;
        }

        var snapshot = captureSnapshot(allocator) catch |err| {
            std.log.err("captureSnapshot failed: {s}", .{@errorName(err)});
            std.Thread.sleep(poll_interval_ns);
            continue;
        };
        defer snapshot.deinit(allocator);
        last_fallback_poll_ms = now_ms;

        const changed = !emitted_first_event or
            snapshot.hwnd != previous_hwnd or
            !std.mem.eql(u8, snapshot.window_title, previous_title);

        if (changed) {
            const prev_duration_ms: i64 = computePrevDuration(now_ms, previous_started_ms);
            var hwnd_buf: [20]u8 = undefined;
            const hwnd_hex = try std.fmt.bufPrint(&hwnd_buf, "0x{X}", .{snapshot.hwnd});

            var out: std.io.Writer.Allocating = .init(allocator);
            defer out.deinit();

            try std.json.Stringify.value(.{
                .ts_unix_ms = now_ms,
                .event = "focus_changed",
                .hwnd = hwnd_hex,
                .pid = snapshot.pid,
                .exe_path = snapshot.exe_path,
                .window_title = snapshot.window_title,
                .prev_duration_ms = prev_duration_ms,
            }, .{}, &out.writer);
            try stdout.writeAll(out.written());
            try stdout.writeAll("\n");
            try stdout.flush();

            allocator.free(previous_title);
            previous_title = try allocator.dupe(u8, snapshot.window_title);
            previous_hwnd = snapshot.hwnd;
            previous_started_ms = now_ms;
            emitted_first_event = true;
        }

        std.Thread.sleep(poll_interval_ns);
    }
}

test "computePrevDuration clamps and computes" {
    try std.testing.expectEqual(@as(i64, 0), computePrevDuration(1000, 0));
    try std.testing.expectEqual(@as(i64, 250), computePrevDuration(1250, 1000));
    try std.testing.expectEqual(@as(i64, 0), computePrevDuration(500, 1000));
}

test "utf16SliceToUtf8Alloc converts ascii and empty" {
    const allocator = std.testing.allocator;
    const empty = try utf16SliceToUtf8Alloc(allocator, &[_]u16{});
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);

    const title_utf16 = [_]u16{ 'T', 'e', 's', 't' };
    const title_utf8 = try utf16SliceToUtf8Alloc(allocator, &title_utf16);
    defer allocator.free(title_utf8);
    try std.testing.expectEqualStrings("Test", title_utf8);
}
