const std = @import("std");
const c = @import("c.zig").c;
const config = @import("config.zig");
const ui_mod = @import("ui.zig");
const ihs = @import("ihs.zig");
const decode = @import("decode.zig");
const input = @import("input.zig");
const Io = std.Io;
const io = std.Options.debug_io;

const Phase = enum {
    scan,
    pair,
    streaming,
    disconnected,
    settings,
    quit,
};

const SessionCtx = struct {
    disconnected: std.atomic.Value(bool),
    connected: std.atomic.Value(bool),
    settings: *const config.Settings,
    screen_w: i32,
    screen_h: i32,
};

fn onSessionConnected(
    session: ?*c.IHS_Session,
    ctx_ptr: ?*anyopaque,
) callconv(.c) void {
    _ = session;
    const ctx: *SessionCtx = @ptrCast(@alignCast(ctx_ptr.?));
    ctx.connected.store(true, .release);
}

fn effectiveRes(s: *const config.Settings, screen_w: i32, screen_h: i32) struct { w: i32, h: i32 } {
    if (s.width == 0 or s.height == 0) return .{ .w = screen_w, .h = screen_h };
    return .{ .w = @intCast(s.width), .h = @intCast(s.height) };
}

fn logPrint(
    level: c.IHS_LogLevel,
    tag: [*c]const u8,
    message: [*c]const u8,
) callconv(.c) void {
    // IHS log levels are listed backwards in the enum
    // so anything greater than Info is more verbose
    // rather than less, ignore them to reduce noise
    if (level > c.IHS_LogLevelInfo) return;
    const level_name = c.IHS_LogLevelName(level);
    std.debug.print("[IHS.{s} {s}] {s}\n", .{
        std.mem.span(tag),
        std.mem.span(level_name),
        std.mem.span(message),
    });
}

fn onSessionDisconnected(
    session: ?*c.IHS_Session,
    ctx_ptr: ?*anyopaque,
) callconv(.c) void {
    _ = session;
    const ctx: *SessionCtx = @ptrCast(@alignCast(ctx_ptr.?));
    ctx.disconnected.store(true, .release);
}

fn onSessionConfiguring(
    session: ?*c.IHS_Session,
    session_config: ?*c.IHS_SessionConfig,
    ctx_ptr: ?*anyopaque,
) callconv(.c) void {
    _ = session;
    const ctx: *SessionCtx = @ptrCast(@alignCast(ctx_ptr.?));
    const s = ctx.settings;
    const cfg = session_config.?;
    const res = effectiveRes(s, ctx.screen_w, ctx.screen_h);
    cfg.quality = @intCast(s.quality);
    cfg.enableAudio = s.audio_channels != 0;
    cfg.enableHevc = s.enable_hevc;
    cfg.maxBitrateKbps = @intCast(s.max_bandwidth_kbps);
    cfg.audioChannels = @intCast(s.audio_channels);
    cfg.videoWidth = res.w;
    cfg.videoHeight = res.h;
    cfg.maxFramerateNumerator = @intCast(s.framerate_limit);
    cfg.maxFramerateDenominator = if (s.framerate_limit == 0) 0 else @intCast(config.framerate_denominator);
}

var session_callbacks = c.IHS_StreamSessionCallbacks{
    .initialized = null,
    .connecting = null,
    .configuring = onSessionConfiguring,
    .connected = onSessionConnected,
    .disconnected = onSessionDisconnected,
    .finalized = null,
};

const AppState = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    phase: Phase,
    device: config.DeviceConfig,
    paired: ?config.PairedHost,
    settings: config.Settings,
    ui: ui_mod.Ui,
    selected_host: ?c.IHS_HostInfo,
    decode_ctx: decode.DecodeCtx,

    fn clientConfig(self: *const AppState) c.IHS_ClientConfig {
        return .{
            .deviceId = self.device.device_id,
            .secretKey = &self.device.secret_key,
            .deviceName = &self.device.device_name,
        };
    }
};

fn initAppState(allocator: std.mem.Allocator) !AppState {
    const device = try config.loadOrCreate(allocator);
    const paired = try config.loadPaired(allocator);
    const settings = try config.loadSettings(allocator);
    const ui = try ui_mod.Ui.init();

    return AppState{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .phase = .scan,
        .device = device,
        .paired = paired,
        .settings = settings,
        .ui = ui,
        .selected_host = null,
        .decode_ctx = decode.DecodeCtx.init(allocator, settings.hw_decode),
    };
}

fn deinitAppState(state: *AppState) void {
    state.decode_ctx.deinit();
    state.ui.deinit();
    state.arena.deinit();
}

fn computeFrameDst(
    renderer: *c.SDL_Renderer,
    canvas_w: c_int,
    canvas_h: c_int,
    frame_w: c_int,
    frame_h: c_int,
) c.SDL_Rect {
    var lw: c_int = 0;
    var lh: c_int = 0;
    c.SDL_RenderGetLogicalSize(renderer, &lw, &lh);
    if (lw <= 0 or lh <= 0 or canvas_w <= 0 or canvas_h <= 0) {
        return .{ .x = 0, .y = 0, .w = lw, .h = lh };
    }
    const dw = @divTrunc(frame_w * lw, canvas_w);
    const dh = @divTrunc(frame_h * lh, canvas_h);
    return .{
        .x = @divTrunc(lw - dw, 2),
        .y = @divTrunc(lh - dh, 2),
        .w = dw,
        .h = dh,
    };
}

pub fn run(allocator: std.mem.Allocator) !void {
    c.IHS_Init();
    defer c.IHS_Quit();

    var state = try initAppState(allocator);
    defer deinitAppState(&state);

    while (true) {
        switch (state.phase) {
            .scan => scanForHosts(&state),
            .pair => pairWithPin(&state) catch |err| {
                std.log.err("pair error: {}", .{err});
                state.phase = .scan;
            },
            .streaming => beginStreaming(&state) catch |err| {
                std.log.err("streaming error: {}", .{err});
                state.phase = .disconnected;
            },
            .disconnected => {
                state.ui.drawStatus("Disconnected. Press A to return.");
                waitForA(&state);
                state.phase = .scan;
            },
            .settings => {
                settingsScreen(&state);
                state.phase = .scan;
            },
            .quit => break,
        }
    }
}

// Scanning

fn scanForHosts(state: *AppState) void {
    state.ui.host_cursor = 0;

    const cfg = state.clientConfig();
    const paired_client_id: u64 = if (state.paired) |p| p.client_id else 0;

    var disc_ctx = ihs.DiscoveryCtx.init(state.allocator);
    defer disc_ctx.deinit();

    const disc_thread = ihs.startDiscovery(&disc_ctx, cfg, 5000) catch {
        state.ui.drawStatus("Discovery failed to start.");
        io.sleep(.fromNanoseconds(2000 * std.time.ns_per_ms), .awake) catch {};
        return;
    };
    defer disc_thread.join();

    while (true) {
        const hosts = disc_ctx.copyHosts(state.allocator) catch &.{};
        defer if (hosts.len > 0) state.allocator.free(hosts);

        const scanning = !disc_ctx.done.load(.acquire);
        state.ui.drawScanScreen(hosts, paired_client_id, scanning);

        const ev = state.ui.pollEvents();
        switch (ev) {
            .quit => {
                state.phase = .quit;
                disc_ctx.stop();
                return;
            },
            .button_start => {
                state.phase = .settings;
                disc_ctx.stop();
                return;
            },
            .button_b => {
                if (confirmQuit(state)) {
                    state.phase = .quit;
                    disc_ctx.stop();
                    return;
                }
            },
            .dpad_up => state.ui.moveScanCursor(-1, hosts.len),
            .dpad_down => state.ui.moveScanCursor(1, hosts.len),
            .button_a => {
                const idx = state.ui.selectedHostIndex();
                if (idx < hosts.len) {
                    state.selected_host = hosts[idx];
                    disc_ctx.stop();
                    state.phase = if (state.paired != null and state.selected_host.?.clientId == state.paired.?.client_id)
                        .streaming
                    else
                        .pair;
                    return;
                } else if (disc_ctx.done.load(.acquire)) {
                    disc_ctx.stop();
                    return;
                }
            },
            else => {},
        }

        io.sleep(.fromNanoseconds(16 * std.time.ns_per_ms), .awake) catch {};
    }
}

// Pairing

fn pairWithPin(state: *AppState) !void {
    const host = state.selected_host orelse return error.NoHost;

    var rng = std.Random.DefaultPrng.init(@as(u64, @bitCast(std.Io.Clock.real.now(io).toMilliseconds())));
    var pin: [4]u8 = undefined;
    for (&pin) |*d| d.* = '0' + @as(u8, @intCast(rng.random().intRangeLessThan(u8, 0, 10)));

    state.ui.resetPin();
    state.ui.pin_status = .waiting;

    var auth_ctx = ihs.AuthCtx.init();
    const cfg = state.clientConfig();
    const auth_thread = try ihs.startAuthorize(&auth_ctx, cfg, host, &pin);

    while (!auth_ctx.done.load(.acquire)) {
        state.ui.drawPinDisplay(&pin);
        switch (state.ui.pollEvents()) {
            .quit => {
                state.phase = .quit;
                auth_ctx.stop();
                auth_thread.join();
                return;
            },
            .button_b => {
                state.phase = .scan;
                auth_ctx.stop();
                auth_thread.join();
                return;
            },
            else => {},
        }
        io.sleep(.fromNanoseconds(16 * std.time.ns_per_ms), .awake) catch {};
    }
    auth_thread.join();

    switch (auth_ctx.result) {
        .success => {
            var paired_host = std.mem.zeroes(config.PairedHost);
            @memcpy(paired_host.hostname[0..host.hostname.len], &host.hostname);
            paired_host.client_id = host.clientId;
            paired_host.instance_id = host.instanceId;
            paired_host.steam_id = auth_ctx.steam_id;
            state.paired = paired_host;
            try config.savePaired(state.allocator, paired_host);
            state.phase = .streaming;
        },
        .denied => {
            state.ui.pin_status = .denied;
            state.ui.drawPinDisplay(&pin);
            io.sleep(.fromNanoseconds(1500 * std.time.ns_per_ms), .awake) catch {};
            state.phase = .scan;
        },
        .failed => {
            state.ui.pin_status = .failed;
            state.ui.drawPinDisplay(&pin);
            io.sleep(.fromNanoseconds(1500 * std.time.ns_per_ms), .awake) catch {};
            state.phase = .scan;
        },
    }
}

// Streaming

fn beginStreaming(state: *AppState) !void {
    const host = state.selected_host orelse return error.NoHost;
    const cfg = state.clientConfig();

    const res = effectiveRes(&state.settings, state.ui.logical_w, state.ui.logical_h);

    state.ui.drawStatus("Requesting stream...");
    var stream_ctx = ihs.StreamRequestCtx.init();
    const stream_thread = try ihs.startStreamRequest(
        &stream_ctx,
        cfg,
        host,
        std.mem.zeroes([16]u8),
        res.w,
        res.h,
        @intCast(state.settings.audio_channels),
    );
    stream_thread.join();

    if (stream_ctx.result != .success) {
        if (stream_ctx.result == .unauthorized) {
            state.phase = .pair;
            return;
        }
        state.ui.drawStatus("Stream request failed.");
        io.sleep(.fromNanoseconds(2000 * std.time.ns_per_ms), .awake) catch {};
        state.phase = .disconnected;
        return;
    }

    var session_info = stream_ctx.session_info;
    const session = c.IHS_SessionCreate(&cfg, &session_info) orelse {
        state.ui.drawStatus("Failed to create session.");
        io.sleep(.fromNanoseconds(2000 * std.time.ns_per_ms), .awake) catch {};
        state.phase = .disconnected;
        return;
    };
    c.IHS_SessionSetLogFunction(session, logPrint);
    defer c.IHS_SessionDestroy(session);

    var sess_ctx = SessionCtx{
        .disconnected = std.atomic.Value(bool).init(false),
        .connected = std.atomic.Value(bool).init(false),
        .settings = &state.settings,
        .screen_w = state.ui.logical_w,
        .screen_h = state.ui.logical_h,
    };
    c.IHS_SessionSetSessionCallbacks(session, &session_callbacks, &sess_ctx);
    c.IHS_SessionSetVideoCallbacks(session, &decode.video_callbacks, &state.decode_ctx);
    c.IHS_SessionSetAudioCallbacks(session, &decode.audio_callbacks, &state.decode_ctx);

    state.ui.drawStatus("Connecting...");
    if (!c.IHS_SessionConnect(session)) {
        state.ui.drawStatus("Session connect failed.");
        io.sleep(.fromNanoseconds(2000 * std.time.ns_per_ms), .awake) catch {};
        state.phase = .disconnected;
        return;
    }

    // Gamepad input passthrough, defer until connected or else the
    // Host will immediately refuse the connection thinking something went wrong.
    var hid_initialized = false;
    defer if (hid_initialized) input.deinit();

    // Heartbeat to suppress Steam's idle-gamepad timeout when the user is
    // active but holding a steady state (no deltas to send).
    const heartbeat_interval_ns: i128 = 30 * std.time.ns_per_s;
    const recent_input_window_ns: i128 = 30 * std.time.ns_per_s;
    var last_input_ns: i128 = Io.Clock.awake.now(io).toNanoseconds();
    var last_heartbeat_ns: i128 = last_input_ns;

    var texture: ?*c.SDL_Texture = null;
    var tex_w: u32 = 0;
    var tex_h: u32 = 0;
    defer if (texture) |t| c.SDL_DestroyTexture(t);

    var frame: decode.VideoFrame = undefined;
    while (!sess_ctx.disconnected.load(.acquire)) {
        if (!hid_initialized and sess_ctx.connected.load(.acquire)) {
            input.init(session);
            hid_initialized = true;
        }
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            if (event.type == c.SDL_QUIT) {
                state.phase = .quit;
                c.IHS_SessionDisconnect(session);
                break;
            }
            if (input.handleEvent(session, &event)) {
                last_input_ns = Io.Clock.awake.now(io).toNanoseconds();
            }
        }
        if (state.phase == .quit) break;

        if (hid_initialized) {
            const now_ns = Io.Clock.awake.now(io).toNanoseconds();
            if (now_ns - last_heartbeat_ns >= heartbeat_interval_ns) {
                if (now_ns - last_input_ns <= recent_input_window_ns) {
                    _ = c.IHS_SessionHIDNotifyDeviceChange(session);
                }
                last_heartbeat_ns = now_ns;
            }
        }

        if (state.decode_ctx.getNextFrame(&frame)) {
            if (texture == null or frame.width != tex_w or frame.height != tex_h) {
                if (texture) |t| c.SDL_DestroyTexture(t);
                texture = c.SDL_CreateTexture(
                    state.ui.renderer,
                    c.SDL_PIXELFORMAT_NV12,
                    c.SDL_TEXTUREACCESS_STREAMING,
                    @intCast(frame.width),
                    @intCast(frame.height),
                );
                tex_w = frame.width;
                tex_h = frame.height;
            }
            if (texture) |t| {
                _ = c.SDL_UpdateNVTexture(t, null, frame.y.ptr, frame.y_stride, frame.uv.ptr, frame.uv_stride);
            }

            _ = c.SDL_SetRenderDrawColor(state.ui.renderer, 0, 0, 0, 255);
            _ = c.SDL_RenderClear(state.ui.renderer);
            if (texture) |t| {
                const dst = computeFrameDst(
                    state.ui.renderer,
                    res.w,
                    res.h,
                    @intCast(frame.width),
                    @intCast(frame.height),
                );
                _ = c.SDL_RenderCopy(state.ui.renderer, t, null, &dst);
            }
            c.SDL_RenderPresent(state.ui.renderer);

            frame.deinit();
        } else {
            _ = c.SDL_SetRenderDrawColor(state.ui.renderer, 0, 0, 0, 255);
            _ = c.SDL_RenderClear(state.ui.renderer);
            if (texture) |t| {
                const dst = computeFrameDst(
                    state.ui.renderer,
                    res.w,
                    res.h,
                    @intCast(frame.width),
                    @intCast(frame.height),
                );
                _ = c.SDL_RenderCopy(state.ui.renderer, t, null, &dst);
            }
            c.SDL_RenderPresent(state.ui.renderer);
        }
    }

    c.IHS_SessionDisconnect(session);
    c.IHS_SessionThreadedJoin(session);

    if (state.phase != .quit) state.phase = .disconnected;
}

// Settings

fn settingsScreen(state: *AppState) void {
    state.ui.settings_row = 0;
    var s = state.settings;

    while (true) {
        state.ui.drawSettingsScreen(s);
        switch (state.ui.pollEvents()) {
            .quit => {
                state.phase = .quit;
                return;
            },
            .button_b, .button_start => {
                state.settings = s;
                state.decode_ctx.hw_decode = s.hw_decode;
                config.saveSettings(state.allocator, s) catch {};
                return;
            },
            .dpad_up => state.ui.settingsMoveRow(-1),
            .dpad_down => state.ui.settingsMoveRow(1),
            .dpad_left => state.ui.settingsAdjust(&s, -1),
            .dpad_right, .button_a => state.ui.settingsAdjust(&s, 1),
            else => {},
        }
        io.sleep(.fromNanoseconds(16 * std.time.ns_per_ms), .awake) catch {};
    }
}

// Button helpers

fn waitForA(state: *AppState) void {
    while (true) {
        switch (state.ui.pollEvents()) {
            .button_a, .quit => return,
            else => {},
        }
        io.sleep(.fromNanoseconds(16 * std.time.ns_per_ms), .awake) catch {};
    }
}

fn waitForAorB(state: *AppState) ui_mod.UiEvent {
    while (true) {
        const ev = state.ui.pollEvents();
        switch (ev) {
            .button_a, .button_b, .quit => return ev,
            else => {},
        }
        io.sleep(.fromNanoseconds(16 * std.time.ns_per_ms), .awake) catch {};
    }
}

fn confirmQuit(state: *AppState) bool {
    state.ui.drawStatus("Press Start to quit or B to resume.");
    while (true) {
        switch (state.ui.pollEvents()) {
            .button_start, .quit => return true,
            .button_b => return false,
            else => {},
        }
        io.sleep(.fromNanoseconds(16 * std.time.ns_per_ms), .awake) catch {};
    }
}
