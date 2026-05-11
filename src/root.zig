const std = @import("std");
const c = @import("c.zig").c;
const config = @import("config.zig");
const ui_mod = @import("ui.zig");
const ihs = @import("ihs.zig");
const decode = @import("decode.zig");
const gl = @import("gl.zig");
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
    std.log.info("[locomo - session] Stream connected.", .{});
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
    // so anything greater than is more verbose
    // rather than less, ignore to reduce noise
    if (level > c.IHS_LogLevelWarn) return;
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
    std.log.info("[locomo - session] Stream disconnected.", .{});
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
        .phase = .scan,
        .device = device,
        .paired = paired,
        .settings = settings,
        .ui = ui,
        .selected_host = null,
        .decode_ctx = try decode.DecodeCtx.init(allocator, settings.hw_decode),
    };
}

fn deinitAppState(state: *AppState) void {
    state.decode_ctx.deinit();
    state.ui.deinit();
}

fn drawGlToast(overlay: *gl.OverlayRenderer, text: gl.TextureRef, vp_w: c_int, vp_h: c_int) void {
    const pad_x: c_int = 24;
    const pad_y: c_int = 12;
    const box_w = text.width + pad_x * 2;
    const box_h = text.height + pad_y * 2;
    const x = @divTrunc(vp_w - box_w, 2);
    const y = @divTrunc(vp_h, 24);
    overlay.drawSolidRect(x, y, box_w, box_h, .{ 15.0 / 255.0, 15.0 / 255.0, 30.0 / 255.0, 1.0 });
    overlay.drawTexturedRect(x + pad_x, y + pad_y, text.width, text.height, text.handle, .{ 1, 1, 1, 1 });
}

fn computeGlViewport(
    renderer: *c.SDL_Renderer,
    cropped_w: c_int,
    cropped_h: c_int,
    canvas_w: c_int,
    canvas_h: c_int,
) gl.GlRect {
    var ow: c_int = 0;
    var oh: c_int = 0;
    _ = c.SDL_GetRendererOutputSize(renderer, &ow, &oh);
    if (ow <= 0 or oh <= 0 or canvas_w <= 0 or canvas_h <= 0) {
        return .{ .x = 0, .y = 0, .w = ow, .h = oh };
    }
    const dw = @divTrunc(cropped_w * ow, canvas_w);
    const dh = @divTrunc(cropped_h * oh, canvas_h);
    const x = @divTrunc(ow - dw, 2);
    const top_y = @divTrunc(oh - dh, 2);
    return .{ .x = x, .y = oh - (top_y + dh), .w = dw, .h = dh };
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

    std.log.info("[locomo] Application start. All aboard!", .{});
    while (true) {
        switch (state.phase) {
            .scan => scanForHosts(&state),
            .pair => pairWithPin(&state) catch |err| {
                std.log.err("[locomo] Pairing reported error: {}", .{err});
                state.phase = .scan;
            },
            .streaming => beginStreaming(&state) catch |err| {
                std.log.err("[locomo] Stream reported error: {}", .{err});
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
            .quit => {
                std.log.info("[locomo] Application close. Please disembark.", .{});
                break;
            },
        }
    }
}

// Scanning

fn scanForHosts(state: *AppState) void {
    state.ui.host_cursor = 0;
    const cfg = state.clientConfig();
    var disc_ctx = ihs.DiscoveryCtx.init(state.allocator);
    defer disc_ctx.deinit();

    const disc_thread = ihs.startDiscovery(&disc_ctx, cfg, 5000) catch {
        std.log.err("[locomo - scan] Host discovery thread failed to start.", .{});
        state.ui.drawStatus("Discovery failed to start.");
        io.sleep(.fromNanoseconds(2000 * std.time.ns_per_ms), .awake) catch {};
        return;
    };
    defer disc_thread.join();

    while (true) {
        const hosts = disc_ctx.copyHosts(state.allocator) catch &.{};
        defer if (hosts.len > 0) state.allocator.free(hosts);

        const scanning = !disc_ctx.done.load(.acquire);
        state.ui.drawScanScreen(hosts, scanning);

        const ev = input.pollEvents(state.settings.button_swap);
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
            // rescan when no hosts are available
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
                } else if (idx >= hosts.len and disc_ctx.done.load(.acquire)) {
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
        switch (input.pollEvents(state.settings.button_swap)) {
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
    state.decode_ctx.force_disconnect.store(false, .release);

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
        std.log.err("[locomo - session] Internal IHSlib error when creating session.", .{});
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
    var cursor_state = input.CursorState.init();
    defer cursor_state.deinit();

    c.IHS_SessionSetSessionCallbacks(session, &session_callbacks, &sess_ctx);
    c.IHS_SessionSetVideoCallbacks(session, &decode.video_callbacks, &state.decode_ctx);
    c.IHS_SessionSetAudioCallbacks(session, &decode.audio_callbacks, &state.decode_ctx);
    c.IHS_SessionSetInputCallbacks(session, &input.cursor_callbacks, &cursor_state);

    state.ui.drawStatus("Connecting...");
    if (!c.IHS_SessionConnect(session)) {
        std.log.err("[locomo - session] Network error when conneting to host.", .{});
        state.ui.drawStatus("Session connect failed.");
        io.sleep(.fromNanoseconds(2000 * std.time.ns_per_ms), .awake) catch {};
        state.phase = .disconnected;
        return;
    }

    // Flag to defer gamepad input passthrough until connected or else the
    // Host will immediately refuse the connection thinking something went wrong.
    var hid_initialized = false;

    // Heartbeat to suppress Steam's idle-gamepad timeout
    const heartbeat_interval_ns: i128 = 30 * std.time.ns_per_s;
    const recent_input_window_ns: i128 = 30 * std.time.ns_per_s;
    var last_input_ns: i128 = Io.Clock.awake.now(io).toNanoseconds();
    var last_heartbeat_ns: i128 = last_input_ns;

    var texture: ?*c.SDL_Texture = null;
    var tex_w: u32 = 0;
    var tex_h: u32 = 0;
    defer if (texture) |t| c.SDL_DestroyTexture(t);

    var video_renderer: ?gl.VideoRenderer = null;
    defer if (video_renderer) |*vr| vr.deinit();

    var overlay: ?gl.OverlayRenderer = null;
    defer if (overlay) |*o| o.deinit();

    var toast1_tex: ?gl.TextureRef = null;
    var toast2_tex: ?gl.TextureRef = null;
    defer {
        if (toast1_tex) |t| {
            var h = t.handle;
            c.glDeleteTextures(1, &h);
        }
        if (toast2_tex) |t| {
            var h = t.handle;
            c.glDeleteTextures(1, &h);
        }
    }

    var chords: input.ChordTracker = .{};
    var mouse_state: input.MouseState = .{};
    var mouse_mode: bool = false;
    var last_host_w: c_int = 0;
    var last_host_h: c_int = 0;
    var last_video_rect: gl.GlRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

    const toast_duration_ns: i128 = 4 * std.time.ns_per_s;
    const toast1_until_ns: i128 = Io.Clock.awake.now(io).toNanoseconds() + toast_duration_ns;
    const toast2_until_ns: i128 = Io.Clock.awake.now(io).toNanoseconds() + (toast_duration_ns * 2);
    const toast_text_tip1: [:0]const u8 = if (state.ui.logical_w >= 1600) "Hold Start + Select and double-tap the X Button to disconnect" else "Start+Select+(X x2): Quit";
    const toast_text_tip2: [:0]const u8 = if (state.ui.logical_w >= 1600) "Hold Start + Select and click Left Stick to toggle mouse mode" else "Start+Select+L3: Mouse Mode";

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
            if (chords.observe(&event, state.settings.button_swap)) |action| switch (action) {
                .disconnect => {
                    std.log.info("[locomo - session] Disconnect chord triggered, ending stream.", .{});
                    c.IHS_SessionDisconnect(session);
                    break;
                },
                .toggle_mouse => {
                    mouse_mode = !mouse_mode;
                    std.log.info("[locomo - session] Mouse mode set to {}.", .{mouse_mode});
                    mouse_state.reset(session, &cursor_state);
                },
            };
            if (mouse_mode) mouse_state.observe(session, &event);
            if (mouse_mode and input.MouseState.isMouseModeAxisEvent(&event)) {
                continue;
            }
            if (input.handleEvent(session, &event, state.settings.button_swap)) {
                last_input_ns = Io.Clock.awake.now(io).toNanoseconds();
            }
        }

        if (state.phase == .quit) {
            std.log.info("[locomo - session] Application is closing, ending stream.", .{});
            break;
        } else if (state.decode_ctx.force_disconnect.load(.acquire)) {
            std.log.err("[locomo - decode] Encountered unrecoverable video error, ending stream.", .{});
            break;
        }

        if (mouse_mode) {
            mouse_state.tick(session, &cursor_state, last_host_w, last_host_h, Io.Clock.awake.now(io).toNanoseconds());
        }

        if (hid_initialized) {
            const now_ns = Io.Clock.awake.now(io).toNanoseconds();
            if (now_ns - last_heartbeat_ns >= heartbeat_interval_ns) {
                if (now_ns - last_input_ns <= recent_input_window_ns) {
                    _ = c.IHS_SessionHIDNotifyDeviceChange(session);
                }
                last_heartbeat_ns = now_ns;
            }
        }

        const got_frame = state.decode_ctx.waitNextFrame(&frame, .{ .duration = .{ .raw = .fromMilliseconds(8), .clock = .awake } });
        if (got_frame) {
            _ = c.SDL_SetRenderDrawColor(state.ui.renderer, 0, 0, 0, 255);
            _ = c.SDL_RenderClear(state.ui.renderer);

            switch (frame.payload) {
                .sw => |*sw| {
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
                        _ = c.SDL_UpdateNVTexture(t, null, sw.y.ptr, sw.y_stride, sw.uv.ptr, sw.uv_stride);
                        const crop_l: c_int = @intCast(frame.crop.left);
                        const crop_t: c_int = @intCast(frame.crop.top);
                        const cropped_w: c_int = @as(c_int, @intCast(frame.width)) - crop_l - @as(c_int, @intCast(frame.crop.right));
                        const cropped_h: c_int = @as(c_int, @intCast(frame.height)) - crop_t - @as(c_int, @intCast(frame.crop.bottom));
                        const src_rect = c.SDL_Rect{ .x = crop_l, .y = crop_t, .w = cropped_w, .h = cropped_h };
                        const dst = computeFrameDst(state.ui.renderer, res.w, res.h, cropped_w, cropped_h);
                        _ = c.SDL_RenderCopy(state.ui.renderer, t, &src_rect, &dst);
                        if (cropped_w != last_host_w or cropped_h != last_host_h) {
                            cursor_state.recenter();
                        }
                        last_host_w = cropped_w;
                        last_host_h = cropped_h;
                        cursor_state.renderSdl(state.ui.renderer, dst, last_host_w, last_host_h, mouse_mode);
                    }
                },
                .drm => {
                    if (video_renderer == null) {
                        if (state.ui.gl_ctx) |gctx| {
                            video_renderer = gl.VideoRenderer.init(gctx) catch blk: {
                                std.log.err("[locomo - render] Failed to create HW renderer. Video will not display.", .{});
                                break :blk null;
                            };
                            if (video_renderer != null) {
                                overlay = gl.OverlayRenderer.init(gctx) catch blk: {
                                    std.log.err("[locomo - render] Failed to create Overlay renderer. Mouse mode and toasts will not display.", .{});
                                    break :blk null;
                                };
                                if (overlay != null) {
                                    toast1_tex = gl.uploadText(state.ui.font_small, toast_text_tip1, .{ .r = 220, .g = 220, .b = 220, .a = 255 });
                                    toast2_tex = gl.uploadText(state.ui.font_small, toast_text_tip2, .{ .r = 220, .g = 220, .b = 220, .a = 255 });
                                }
                            }
                        }
                    }
                    if (video_renderer) |*vr| {
                        _ = c.SDL_RenderFlush(state.ui.renderer);
                        const cropped_w: c_int = @as(c_int, @intCast(frame.width)) - @as(c_int, @intCast(frame.crop.left)) - @as(c_int, @intCast(frame.crop.right));
                        const cropped_h: c_int = @as(c_int, @intCast(frame.height)) - @as(c_int, @intCast(frame.crop.top)) - @as(c_int, @intCast(frame.crop.bottom));
                        const vp = computeGlViewport(state.ui.renderer, cropped_w, cropped_h, res.w, res.h);
                        if (cropped_w != last_host_w or cropped_h != last_host_h) {
                            cursor_state.recenter();
                        }
                        last_host_w = cropped_w;
                        last_host_h = cropped_h;
                        _ = vr.drawDrmFrame(frame.takeDrm(), frame.width, frame.height, frame.crop, vp);

                        if (overlay) |*o| {
                            var ow: c_int = 0;
                            var oh: c_int = 0;
                            _ = c.SDL_GetRendererOutputSize(state.ui.renderer, &ow, &oh);
                            o.beginFrame(ow, oh);
                            last_video_rect = .{ .x = vp.x, .y = oh - (vp.y + vp.h), .w = vp.w, .h = vp.h };
                            cursor_state.render(o, last_video_rect, last_host_w, last_host_h, mouse_mode);
                            const now_ns = Io.Clock.awake.now(io).toNanoseconds();
                            const active_toast: ?gl.TextureRef =
                                if (now_ns < toast1_until_ns) toast1_tex else if (now_ns < toast2_until_ns) toast2_tex else null;
                            if (active_toast) |t| drawGlToast(o, t, ow, oh);
                        }
                    }
                },
            }
            if (frame.payload == .sw) {
                // SW path uses SDL for overlays
                const now_ns = Io.Clock.awake.now(io).toNanoseconds();
                if (now_ns < toast1_until_ns) {
                    state.ui.drawToast(toast_text_tip1);
                } else if (now_ns < toast2_until_ns) {
                    state.ui.drawToast(toast_text_tip2);
                }
            }

            c.SDL_RenderPresent(state.ui.renderer);

            frame.deinit();
        }
    }

    c.IHS_SessionDisconnect(session);
    c.IHS_SessionThreadedJoin(session);

    if (video_renderer) |*vr| {
        vr.deinit();
        video_renderer = null;
    }
    state.ui.recreateRenderer() catch {};

    if (state.phase != .quit) state.phase = .disconnected;
}

// Settings

fn settingsScreen(state: *AppState) void {
    state.ui.settings_row = 0;
    var s = state.settings;

    while (true) {
        state.ui.drawSettingsScreen(s);
        switch (input.pollEvents(state.settings.button_swap)) {
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
        switch (input.pollEvents(state.settings.button_swap)) {
            .button_a, .quit => return,
            else => {},
        }
        io.sleep(.fromNanoseconds(16 * std.time.ns_per_ms), .awake) catch {};
    }
}

fn confirmQuit(state: *AppState) bool {
    state.ui.drawStatus("Press Start to quit or B to resume.");
    while (true) {
        switch (input.pollEvents(state.settings.button_swap)) {
            .button_start, .quit => return true,
            .button_b => return false,
            else => {},
        }
        io.sleep(.fromNanoseconds(16 * std.time.ns_per_ms), .awake) catch {};
    }
}
