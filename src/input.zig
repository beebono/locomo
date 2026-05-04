const std = @import("std");
const c = @import("c.zig").c;
const gl = @import("gl.zig");
const config = @import("config.zig");
const Io = std.Io;
const io = std.Options.debug_io;

pub fn init(session: *c.IHS_Session) void {
    const provider = c.IHS_HIDProviderSDLCreateManaged() orelse return;
    c.IHS_SessionHIDAddProvider(session, provider);
    _ = c.IHS_SessionHIDNotifyDeviceChange(session);
}

pub fn swapButton(button: u8, swap: config.ButtonSwap) u8 {
    const ab = swap == .ab or swap == .all;
    const xy = swap == .xy or swap == .all;
    return switch (button) {
        c.SDL_CONTROLLER_BUTTON_A => if (ab) c.SDL_CONTROLLER_BUTTON_B else button,
        c.SDL_CONTROLLER_BUTTON_B => if (ab) c.SDL_CONTROLLER_BUTTON_A else button,
        c.SDL_CONTROLLER_BUTTON_X => if (xy) c.SDL_CONTROLLER_BUTTON_Y else button,
        c.SDL_CONTROLLER_BUTTON_Y => if (xy) c.SDL_CONTROLLER_BUTTON_X else button,
        else => button,
    };
}

pub const Event = enum {
    none,
    dpad_up,
    dpad_down,
    dpad_left,
    dpad_right,
    button_a,
    button_b,
    button_start,
    quit,
};

pub fn pollEvents(swap: config.ButtonSwap) Event {
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event) != 0) {
        switch (event.type) {
            c.SDL_QUIT => return .quit,
            c.SDL_CONTROLLERDEVICEADDED => {
                _ = c.SDL_GameControllerOpen(event.cdevice.which);
            },
            c.SDL_CONTROLLERBUTTONDOWN => {
                const btn = swapButton(event.cbutton.button, swap);
                if (btn == c.SDL_CONTROLLER_BUTTON_DPAD_UP) return .dpad_up;
                if (btn == c.SDL_CONTROLLER_BUTTON_DPAD_DOWN) return .dpad_down;
                if (btn == c.SDL_CONTROLLER_BUTTON_DPAD_LEFT) return .dpad_left;
                if (btn == c.SDL_CONTROLLER_BUTTON_DPAD_RIGHT) return .dpad_right;
                if (btn == c.SDL_CONTROLLER_BUTTON_A) return .button_a;
                if (btn == c.SDL_CONTROLLER_BUTTON_B) return .button_b;
                if (btn == c.SDL_CONTROLLER_BUTTON_START) return .button_start;
            },
            c.SDL_KEYDOWN => {
                const sym = event.key.keysym.sym;
                if (sym == c.SDLK_UP) return .dpad_up;
                if (sym == c.SDLK_DOWN) return .dpad_down;
                if (sym == c.SDLK_LEFT) return .dpad_left;
                if (sym == c.SDLK_RIGHT) return .dpad_right;
                if (sym == c.SDLK_RETURN or sym == c.SDLK_z) return .button_a;
                if (sym == c.SDLK_x or sym == c.SDLK_ESCAPE) return .button_b;
                if (sym == c.SDLK_s) return .button_start;
            },
            else => {},
        }
    }
    return .none;
}

pub fn handleEvent(session: *c.IHS_Session, event: *const c.SDL_Event, swap: config.ButtonSwap) bool {
    if (swap != .none and (event.type == c.SDL_CONTROLLERBUTTONDOWN or event.type == c.SDL_CONTROLLERBUTTONUP)) {
        var remapped = event.*;
        remapped.cbutton.button = swapButton(event.cbutton.button, swap);
        return c.IHS_HIDHandleSDLEvent(session, &remapped);
    }
    return c.IHS_HIDHandleSDLEvent(session, event);
}

pub const MouseState = struct {
    left_x: i16 = 0,
    left_y: i16 = 0,
    right_x: i16 = 0,
    right_y: i16 = 0,
    last_tick_ns: i128 = 0,
    last_sent_x: f32 = -1,
    last_sent_y: f32 = -1,
    wheel_accum_x: f32 = 0,
    wheel_accum_y: f32 = 0,
    lt_pressed: bool = false,
    rt_pressed: bool = false,

    const deadzone: f32 = 8000.0;
    const max_axis: f32 = 32767.0;
    const max_pixels_per_sec: f32 = 1200.0;
    const max_wheel_ticks_per_sec: f32 = 15.0;
    const exponent: f32 = 2.0;
    const trigger_press_threshold: i16 = 18000;
    const trigger_release_threshold: i16 = 12000;

    pub fn observe(self: *MouseState, session: *c.IHS_Session, event: *const c.SDL_Event) void {
        if (event.type != c.SDL_CONTROLLERAXISMOTION) return;
        switch (event.caxis.axis) {
            c.SDL_CONTROLLER_AXIS_LEFTX => self.left_x = event.caxis.value,
            c.SDL_CONTROLLER_AXIS_LEFTY => self.left_y = event.caxis.value,
            c.SDL_CONTROLLER_AXIS_RIGHTX => self.right_x = event.caxis.value,
            c.SDL_CONTROLLER_AXIS_RIGHTY => self.right_y = event.caxis.value,
            c.SDL_CONTROLLER_AXIS_TRIGGERLEFT => updateTrigger(session, event.caxis.value, &self.lt_pressed, c.IHS_MOUSE_BUTTON_RIGHT),
            c.SDL_CONTROLLER_AXIS_TRIGGERRIGHT => updateTrigger(session, event.caxis.value, &self.rt_pressed, c.IHS_MOUSE_BUTTON_LEFT),
            else => {},
        }
    }

    fn updateTrigger(session: *c.IHS_Session, value: i16, state: *bool, button: c_uint) void {
        if (!state.* and value >= trigger_press_threshold) {
            state.* = true;
            _ = c.IHS_SessionSendMouseDown(session, button);
        } else if (state.* and value <= trigger_release_threshold) {
            state.* = false;
            _ = c.IHS_SessionSendMouseUp(session, button);
        }
    }

    pub fn isMouseModeAxisEvent(event: *const c.SDL_Event) bool {
        if (event.type != c.SDL_CONTROLLERAXISMOTION) return false;
        return switch (event.caxis.axis) {
            c.SDL_CONTROLLER_AXIS_LEFTX,
            c.SDL_CONTROLLER_AXIS_LEFTY,
            c.SDL_CONTROLLER_AXIS_RIGHTX,
            c.SDL_CONTROLLER_AXIS_RIGHTY,
            c.SDL_CONTROLLER_AXIS_TRIGGERLEFT,
            c.SDL_CONTROLLER_AXIS_TRIGGERRIGHT,
            => true,
            else => false,
        };
    }

    fn shapedVelocity(raw_x: i16, raw_y: i16, max_speed: f32) struct { vx: f32, vy: f32 } {
        const fx: f32 = @floatFromInt(raw_x);
        const fy: f32 = @floatFromInt(raw_y);
        const mag = @sqrt(fx * fx + fy * fy);
        if (mag < deadzone) return .{ .vx = 0, .vy = 0 };
        const clamped = @min(mag, max_axis);
        const norm = (clamped - deadzone) / (max_axis - deadzone);
        const shaped = std.math.pow(f32, norm, exponent);
        const speed = shaped * max_speed;
        return .{ .vx = (fx / mag) * speed, .vy = (fy / mag) * speed };
    }

    pub fn tick(self: *MouseState, session: *c.IHS_Session, cursor_state: *CursorState, host_w: c_int, host_h: c_int, now_ns: i128) void {
        if (self.last_tick_ns == 0) {
            self.last_tick_ns = now_ns;
            return;
        }
        const dt_ns = now_ns - self.last_tick_ns;
        self.last_tick_ns = now_ns;
        const dt_s: f32 = @as(f32, @floatFromInt(dt_ns)) / @as(f32, @floatFromInt(std.time.ns_per_s));

        const cursor_v = shapedVelocity(self.left_x, self.left_y, max_pixels_per_sec);
        const pos = cursor_state.applyMotion(cursor_v.vx * dt_s, cursor_v.vy * dt_s, host_w, host_h);
        if (pos.x_norm != self.last_sent_x or pos.y_norm != self.last_sent_y) {
            _ = c.IHS_SessionSendMousePosition(session, pos.x_norm, pos.y_norm);
            self.last_sent_x = pos.x_norm;
            self.last_sent_y = pos.y_norm;
        }

        const wheel_v = shapedVelocity(self.right_x, self.right_y, max_wheel_ticks_per_sec);
        self.wheel_accum_x += wheel_v.vx * dt_s;
        self.wheel_accum_y += wheel_v.vy * dt_s;
        while (self.wheel_accum_y <= -1) : (self.wheel_accum_y += 1) {
            _ = c.IHS_SessionSendMouseWheel(session, c.IHS_MOUSE_WHEEL_UP);
        }
        while (self.wheel_accum_y >= 1) : (self.wheel_accum_y -= 1) {
            _ = c.IHS_SessionSendMouseWheel(session, c.IHS_MOUSE_WHEEL_DOWN);
        }
        while (self.wheel_accum_x <= -1) : (self.wheel_accum_x += 1) {
            _ = c.IHS_SessionSendMouseWheel(session, c.IHS_MOUSE_WHEEL_LEFT);
        }
        while (self.wheel_accum_x >= 1) : (self.wheel_accum_x -= 1) {
            _ = c.IHS_SessionSendMouseWheel(session, c.IHS_MOUSE_WHEEL_RIGHT);
        }
        if (wheel_v.vx == 0 and wheel_v.vy == 0) {
            self.wheel_accum_x = 0;
            self.wheel_accum_y = 0;
        }
    }

    pub fn reset(self: *MouseState, session: *c.IHS_Session, cursor_state: *CursorState) void {
        self.last_tick_ns = 0;
        self.last_sent_x = -1;
        self.last_sent_y = -1;
        self.wheel_accum_x = 0;
        self.wheel_accum_y = 0;
        cursor_state.releaseToHost();
        if (self.lt_pressed) {
            _ = c.IHS_SessionSendMouseUp(session, c.IHS_MOUSE_BUTTON_RIGHT);
            self.lt_pressed = false;
        }
        if (self.rt_pressed) {
            _ = c.IHS_SessionSendMouseUp(session, c.IHS_MOUSE_BUTTON_LEFT);
            self.rt_pressed = false;
        }
    }
};

const cursor_rgba = @embedFile("assets/right_ptr.rgba");
const cursor_w: c_int = 24;
const cursor_h: c_int = 24;
const cursor_hot_x: c_int = 1;
const cursor_hot_y: c_int = 1;

pub const CursorState = struct {
    mutex: Io.Mutex,
    x_norm: f32,
    y_norm: f32,
    host_authoritative: bool,
    texture: c.GLuint,
    sdl_texture: ?*c.SDL_Texture,

    pub fn init() CursorState {
        return .{
            .mutex = .init,
            .x_norm = 0.5,
            .y_norm = 0.5,
            .host_authoritative = true,
            .texture = 0,
            .sdl_texture = null,
        };
    }

    pub fn releaseToHost(self: *CursorState) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.host_authoritative = true;
    }

    pub fn recenter(self: *CursorState) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.x_norm = 0.5;
        self.y_norm = 0.5;
        self.host_authoritative = false;
    }

    pub fn applyMotion(self: *CursorState, fdx: f32, fdy: f32, host_w: c_int, host_h: c_int) struct { x_norm: f32, y_norm: f32 } {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (host_w > 0 and host_h > 0) {
            const fw: f32 = @floatFromInt(host_w);
            const fh: f32 = @floatFromInt(host_h);
            self.x_norm = std.math.clamp(self.x_norm + fdx / fw, 0, 1);
            self.y_norm = std.math.clamp(self.y_norm + fdy / fh, 0, 1);
        }
        self.host_authoritative = false;
        return .{ .x_norm = self.x_norm, .y_norm = self.y_norm };
    }

    pub fn deinit(self: *CursorState) void {
        if (self.texture != 0) {
            var t = self.texture;
            c.glDeleteTextures(1, &t);
            self.texture = 0;
        }
        if (self.sdl_texture) |t| {
            c.SDL_DestroyTexture(t);
            self.sdl_texture = null;
        }
    }

    pub fn renderSdl(self: *CursorState, renderer: *c.SDL_Renderer, video_rect: c.SDL_Rect, host_w: c_int, host_h: c_int, draw: bool) void {
        var xn: f32 = 0;
        var yn: f32 = 0;
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            xn = self.x_norm;
            yn = self.y_norm;
        }

        if (!draw) return;
        if (video_rect.w <= 0 or video_rect.h <= 0 or host_w <= 0 or host_h <= 0) return;

        if (self.sdl_texture == null) {
            const tex = c.SDL_CreateTexture(
                renderer,
                c.SDL_PIXELFORMAT_ABGR8888,
                c.SDL_TEXTUREACCESS_STATIC,
                cursor_w,
                cursor_h,
            ) orelse return;
            _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND);
            _ = c.SDL_UpdateTexture(tex, null, cursor_rgba.ptr, cursor_w * 4);
            self.sdl_texture = tex;
        }

        const sx: f32 = @as(f32, @floatFromInt(video_rect.w)) / @as(f32, @floatFromInt(host_w));
        const sy: f32 = @as(f32, @floatFromInt(video_rect.h)) / @as(f32, @floatFromInt(host_h));
        const cx_f: f32 = @as(f32, @floatFromInt(video_rect.x)) + xn * @as(f32, @floatFromInt(video_rect.w));
        const cy_f: f32 = @as(f32, @floatFromInt(video_rect.y)) + yn * @as(f32, @floatFromInt(video_rect.h));
        const dst = c.SDL_Rect{
            .x = @intFromFloat(cx_f - @as(f32, @floatFromInt(cursor_hot_x)) * sx),
            .y = @intFromFloat(cy_f - @as(f32, @floatFromInt(cursor_hot_y)) * sy),
            .w = @intFromFloat(@as(f32, @floatFromInt(cursor_w)) * sx),
            .h = @intFromFloat(@as(f32, @floatFromInt(cursor_h)) * sy),
        };
        _ = c.SDL_RenderCopy(renderer, self.sdl_texture, null, &dst);
    }

    pub fn render(self: *CursorState, overlay: *gl.OverlayRenderer, video_rect: gl.GlRect, host_w: c_int, host_h: c_int, draw: bool) void {
        if (self.texture == 0) {
            self.texture = gl.uploadRgba(cursor_rgba.ptr, cursor_w, cursor_h, null);
        }

        var xn: f32 = 0;
        var yn: f32 = 0;
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            xn = self.x_norm;
            yn = self.y_norm;
        }

        if (!draw) return;
        if (video_rect.w <= 0 or video_rect.h <= 0 or host_w <= 0 or host_h <= 0) return;
        const sx: f32 = @as(f32, @floatFromInt(video_rect.w)) / @as(f32, @floatFromInt(host_w));
        const sy: f32 = @as(f32, @floatFromInt(video_rect.h)) / @as(f32, @floatFromInt(host_h));
        const cx_f: f32 = @as(f32, @floatFromInt(video_rect.x)) + xn * @as(f32, @floatFromInt(video_rect.w));
        const cy_f: f32 = @as(f32, @floatFromInt(video_rect.y)) + yn * @as(f32, @floatFromInt(video_rect.h));
        const px: c_int = @intFromFloat(cx_f - @as(f32, @floatFromInt(cursor_hot_x)) * sx);
        const py: c_int = @intFromFloat(cy_f - @as(f32, @floatFromInt(cursor_hot_y)) * sy);
        const pw: c_int = @intFromFloat(@as(f32, @floatFromInt(cursor_w)) * sx);
        const ph: c_int = @intFromFloat(@as(f32, @floatFromInt(cursor_h)) * sy);
        overlay.drawTexturedRect(px, py, pw, ph, self.texture, .{ 1, 1, 1, 1 });
    }
};

fn cbShowCursor(
    session: ?*c.IHS_Session,
    x: f32,
    y: f32,
    ctx_ptr: ?*anyopaque,
) callconv(.c) void {
    _ = session;
    const self: *CursorState = @ptrCast(@alignCast(ctx_ptr.?));
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    if (!self.host_authoritative) return;
    self.x_norm = std.math.clamp(x, 0, 1);
    self.y_norm = std.math.clamp(y, 0, 1);
}

pub var cursor_callbacks = c.IHS_StreamInputCallbacks{
    .showCursor = cbShowCursor,
};

pub const ChordAction = enum { disconnect, toggle_mouse };

pub const ChordTracker = struct {
    start_held: bool = false,
    back_held: bool = false,
    last_x_press_ms: i64 = 0,

    const double_tap_window_ms: i64 = 400;

    pub fn observe(self: *ChordTracker, event: *const c.SDL_Event, swap: config.ButtonSwap) ?ChordAction {
        switch (event.type) {
            c.SDL_CONTROLLERBUTTONDOWN => {
                const button = swapButton(event.cbutton.button, swap);
                switch (button) {
                    c.SDL_CONTROLLER_BUTTON_START => self.start_held = true,
                    c.SDL_CONTROLLER_BUTTON_BACK => self.back_held = true,
                    c.SDL_CONTROLLER_BUTTON_X => {
                        if (!(self.start_held and self.back_held)) return null;
                        const now = Io.Clock.awake.now(io).toMilliseconds();
                        if (self.last_x_press_ms != 0 and now - self.last_x_press_ms <= double_tap_window_ms) {
                            self.last_x_press_ms = 0;
                            return .disconnect;
                        }
                        self.last_x_press_ms = now;
                    },
                    c.SDL_CONTROLLER_BUTTON_LEFTSTICK => {
                        if (self.start_held and self.back_held) return .toggle_mouse;
                    },
                    else => {},
                }
            },
            c.SDL_CONTROLLERBUTTONUP => {
                const button = swapButton(event.cbutton.button, swap);
                switch (button) {
                    c.SDL_CONTROLLER_BUTTON_START => self.start_held = false,
                    c.SDL_CONTROLLER_BUTTON_BACK => self.back_held = false,
                    else => {},
                }
            },
            else => {},
        }
        return null;
    }
};
