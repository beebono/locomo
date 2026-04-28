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
    reconnect_prompt,
    pair,
    streaming,
    disconnected,
    settings,
    quit,
};

const SessionCtx = struct {
    disconnected: std.atomic.Value(bool),
    connected: std.atomic.Value(bool),
    enable_hevc: bool,
    max_bandwidth_kbps: u32,
};

fn onSessionConnected(
    session: ?*c.IHS_Session,
    ctx_ptr: ?*anyopaque,
) callconv(.c) void {
    _ = session;
    const ctx: *SessionCtx = @ptrCast(@alignCast(ctx_ptr.?));
    ctx.connected.store(true, .release);
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
    const cfg = session_config.?;
    cfg.enableAudio = true;
    cfg.enableHevc = ctx.enable_hevc;
    cfg.maxBitrateKbps = ctx.max_bandwidth_kbps;
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
        .decode_ctx = decode.DecodeCtx.init(allocator),
    };
}

fn deinitAppState(state: *AppState) void {
    state.decode_ctx.deinit();
    state.ui.deinit();
    state.arena.deinit();
}

pub fn run(allocator: std.mem.Allocator) !void {
    c.IHS_Init();
    defer c.IHS_Quit();

    var state = try initAppState(allocator);
    defer deinitAppState(&state);

    while (true) {
        switch (state.phase) {
            .scan => scanForHosts(&state),
            .reconnect_prompt => reconnectPrompt(&state),
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
            .dpad_up => state.ui.moveScanCursor(-1, hosts.len),
            .dpad_down => state.ui.moveScanCursor(1, hosts.len),
            .button_a => {
                const idx = state.ui.selectedHostIndex();
                if (idx < hosts.len) {
                    state.selected_host = hosts[idx];
                    disc_ctx.stop();
                    const sel = state.selected_host.?;
                    if (state.paired) |p| {
                        state.phase = if (sel.clientId == p.client_id) .reconnect_prompt else .pair;
                    } else {
                        state.phase = .pair;
                    }
                    return;
                }
            },
            else => {},
        }

        if (disc_ctx.done.load(.acquire) and hosts.len == 0) {
            state.ui.drawStatus("No hosts found. Press A to rescan.");
            waitForA(state);
            return;
        }

        io.sleep(.fromNanoseconds(16 * std.time.ns_per_ms), .awake) catch {};
    }
}

// Reconnect prompt - TODO: Reevaluate need for this... Probably better to not display paired state and only attempt to re-pair if reconnect fails?

fn reconnectPrompt(state: *AppState) void {
    state.ui.reconnect_choice = .reconnect;
    const p = state.paired.?;
    const name_len = std.mem.indexOfScalar(u8, &p.hostname, 0) orelse p.hostname.len;
    const hostname = p.hostname[0..name_len];

    while (true) {
        state.ui.drawReconnectScreen(hostname);
        switch (state.ui.pollEvents()) {
            .quit => {
                state.phase = .quit;
                return;
            },
            .dpad_left, .dpad_right => state.ui.reconnectToggle(),
            .button_a => {
                state.phase = switch (state.ui.reconnect_choice) {
                    .reconnect => .streaming,
                    .new_pair => .pair,
                };
                return;
            },
            .button_b => {
                state.phase = .scan;
                return;
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
        const ev = state.ui.pollEvents();
        if (ev == .quit) {
            state.phase = .quit;
            auth_thread.join();
            return;
        }
        if (ev == .button_b) {
            state.phase = .scan;
            auth_thread.join();
            return;
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

    state.ui.drawStatus("Requesting stream...");
    var stream_ctx = ihs.StreamRequestCtx.init();
    const stream_thread = try ihs.startStreamRequest(
        &stream_ctx,
        cfg,
        host,
        std.mem.zeroes([16]u8),
        @intCast(state.settings.width),
        @intCast(state.settings.height),
    );
    stream_thread.join();

    if (stream_ctx.result != .success) {
        const msg: [:0]const u8 = switch (stream_ctx.result) {
            .unauthorized => "Stream request rejected: not authorized.",
            else => "Stream request failed.",
        };
        state.ui.drawStatus(msg);
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
        .enable_hevc = state.settings.enable_hevc,
        .max_bandwidth_kbps = state.settings.max_bandwidth_kbps,
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

    // Gamepad input passthrough, defer until connected or Host immediately
    // refuses the connection thinking something went wrong.
    var hid_initialized = false;
    defer if (hid_initialized) input.deinit();

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
            _ = input.handleEvent(session, &event);
        }
        if (state.phase == .quit) break;

        if (state.decode_ctx.getNextFrame(&frame)) {
            if (texture == null or frame.width != tex_w or frame.height != tex_h) {
                if (texture) |t| c.SDL_DestroyTexture(t);
                texture = c.SDL_CreateTexture(
                    state.ui.renderer,
                    c.SDL_PIXELFORMAT_IYUV,
                    c.SDL_TEXTUREACCESS_STREAMING,
                    @intCast(frame.width),
                    @intCast(frame.height),
                );
                tex_w = frame.width;
                tex_h = frame.height;
            }
            if (texture) |t| {
                _ = c.SDL_UpdateYUVTexture(t, null, frame.y.ptr, frame.y_stride, frame.u.ptr, frame.u_stride, frame.v.ptr, frame.v_stride);
            }
            frame.deinit();
        }

        _ = c.SDL_SetRenderDrawColor(state.ui.renderer, 0, 0, 0, 255);
        _ = c.SDL_RenderClear(state.ui.renderer);
        if (texture) |t| _ = c.SDL_RenderCopy(state.ui.renderer, t, null, null);
        c.SDL_RenderPresent(state.ui.renderer);
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
                config.saveSettings(state.allocator, s) catch {};
                return;
            },
            .dpad_up => state.ui.settingsMoveRow(-1),
            .dpad_down => state.ui.settingsMoveRow(1),
            .dpad_left => state.ui.settingsAdjust(&s, -1),
            .dpad_right => state.ui.settingsAdjust(&s, 1),
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
