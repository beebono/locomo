const std = @import("std");
const c = @import("c.zig").c;
const gl = @import("gl.zig");
const Io = std.Io;
const io = std.Options.debug_io;

var hid_provider: ?*c.IHS_HIDProvider = null;

pub fn init(session: *c.IHS_Session) void {
    const provider = c.IHS_HIDProviderSDLCreateManaged() orelse return;
    hid_provider = provider;
    c.IHS_SessionHIDAddProvider(session, provider);
    _ = c.IHS_SessionHIDNotifyDeviceChange(session);
}

pub fn deinit() void {
    // Freeing already handled by session, just remove the reference.
    hid_provider = null;
}

pub fn handleEvent(session: *c.IHS_Session, event: *const c.SDL_Event) bool {
    return c.IHS_HIDHandleSDLEvent(session, event);
}

pub const MouseState = struct {
    left_x: i16 = 0,
    left_y: i16 = 0,
    accum_x: f32 = 0,
    accum_y: f32 = 0,
    last_tick_ns: i128 = 0,
    lt_pressed: bool = false,
    rt_pressed: bool = false,
    was_moving: bool = false,

    const deadzone: f32 = 8000.0;
    const max_axis: f32 = 32767.0;
    const max_pixels_per_sec: f32 = 1500.0;
    const exponent: f32 = 2.0;
    const trigger_press_threshold: i16 = 18000;
    const trigger_release_threshold: i16 = 12000;

    pub fn observe(self: *MouseState, session: *c.IHS_Session, event: *const c.SDL_Event) void {
        if (event.type != c.SDL_CONTROLLERAXISMOTION) return;
        switch (event.caxis.axis) {
            c.SDL_CONTROLLER_AXIS_LEFTX => self.left_x = event.caxis.value,
            c.SDL_CONTROLLER_AXIS_LEFTY => self.left_y = event.caxis.value,
            c.SDL_CONTROLLER_AXIS_TRIGGERLEFT => self.updateTrigger(session, event.caxis.value, &self.lt_pressed, c.IHS_MOUSE_BUTTON_RIGHT),
            c.SDL_CONTROLLER_AXIS_TRIGGERRIGHT => self.updateTrigger(session, event.caxis.value, &self.rt_pressed, c.IHS_MOUSE_BUTTON_LEFT),
            else => {},
        }
    }

    fn updateTrigger(self: *MouseState, session: *c.IHS_Session, value: i16, state: *bool, button: c_uint) void {
        if (!state.* and value >= trigger_press_threshold) {
            state.* = true;
            self.flushMotion(session);
            _ = c.IHS_SessionSendMouseDown(session, button);
        } else if (state.* and value <= trigger_release_threshold) {
            state.* = false;
            self.flushMotion(session);
            _ = c.IHS_SessionSendMouseUp(session, button);
        }
    }

    fn flushMotion(self: *MouseState, session: *c.IHS_Session) void {
        const dx: i32 = @intFromFloat(self.accum_x);
        const dy: i32 = @intFromFloat(self.accum_y);
        if (dx != 0 or dy != 0) _ = c.IHS_SessionSendMouseMovement(session, dx, dy);
        self.accum_x = 0;
        self.accum_y = 0;
    }

    pub fn isMouseModeAxisEvent(event: *const c.SDL_Event) bool {
        if (event.type != c.SDL_CONTROLLERAXISMOTION) return false;
        return switch (event.caxis.axis) {
            c.SDL_CONTROLLER_AXIS_LEFTX,
            c.SDL_CONTROLLER_AXIS_LEFTY,
            c.SDL_CONTROLLER_AXIS_TRIGGERLEFT,
            c.SDL_CONTROLLER_AXIS_TRIGGERRIGHT,
            => true,
            else => false,
        };
    }

    fn velocity(raw_x: i16, raw_y: i16) struct { vx: f32, vy: f32 } {
        const fx: f32 = @floatFromInt(raw_x);
        const fy: f32 = @floatFromInt(raw_y);
        const mag = @sqrt(fx * fx + fy * fy);
        if (mag < deadzone) return .{ .vx = 0, .vy = 0 };
        const clamped = @min(mag, max_axis);
        const norm = (clamped - deadzone) / (max_axis - deadzone);
        const shaped = std.math.pow(f32, norm, exponent);
        const speed = shaped * max_pixels_per_sec;
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

        const v = velocity(self.left_x, self.left_y);
        const moving = v.vx != 0 or v.vy != 0;

        if (moving) {
            const fdx = v.vx * dt_s;
            const fdy = v.vy * dt_s;
            const applied = cursor_state.predictMotion(fdx, fdy, host_w, host_h);
            self.accum_x += applied.dx;
            self.accum_y += applied.dy;
            self.was_moving = true;
        } else if (self.was_moving) {
            self.flushMotion(session);
            self.was_moving = false;
        }
    }

    pub fn reset(self: *MouseState, session: *c.IHS_Session) void {
        self.accum_x = 0;
        self.accum_y = 0;
        self.last_tick_ns = 0;
        self.was_moving = false;
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

const cursor_rgba = @embedFile("cursor/right_ptr.rgba");
const cursor_w: c_int = 24;
const cursor_h: c_int = 24;
const cursor_hot_x: c_int = 1;
const cursor_hot_y: c_int = 1;

pub const CursorState = struct {
    mutex: Io.Mutex,
    visible: bool,
    x_norm: f32,
    y_norm: f32,
    texture: c.GLuint,

    pub fn init() CursorState {
        return .{
            .mutex = .init,
            .visible = false,
            .x_norm = 0.5,
            .y_norm = 0.5,
            .texture = 0,
        };
    }

    pub fn predictMotion(self: *CursorState, fdx: f32, fdy: f32, host_w: c_int, host_h: c_int) struct { dx: f32, dy: f32 } {
        if (host_w <= 0 or host_h <= 0) return .{ .dx = 0, .dy = 0 };
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const fw: f32 = @floatFromInt(host_w);
        const fh: f32 = @floatFromInt(host_h);
        const old_x = self.x_norm;
        const old_y = self.y_norm;
        self.x_norm = std.math.clamp(self.x_norm + fdx / fw, 0, 1);
        self.y_norm = std.math.clamp(self.y_norm + fdy / fh, 0, 1);
        return .{ .dx = (self.x_norm - old_x) * fw, .dy = (self.y_norm - old_y) * fh };
    }

    pub fn deinit(self: *CursorState) void {
        if (self.texture != 0) {
            var t = self.texture;
            c.glDeleteTextures(1, &t);
            self.texture = 0;
        }
    }

    pub fn render(self: *CursorState, overlay: *gl.OverlayRenderer, video_rect: gl.GlRect, host_w: c_int, host_h: c_int, draw: bool) void {
        if (self.texture == 0) {
            self.texture = gl.uploadRgba(cursor_rgba.ptr, cursor_w, cursor_h, null);
        }

        var visible: bool = false;
        var xn: f32 = 0;
        var yn: f32 = 0;
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            visible = self.visible;
            xn = self.x_norm;
            yn = self.y_norm;
        }

        if (!draw or !visible) return;
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

fn cbSetCursor(
    session: ?*c.IHS_Session,
    cursor_id: u64,
    ctx_ptr: ?*anyopaque,
) callconv(.c) bool {
    _ = session;
    _ = cursor_id;
    _ = ctx_ptr;
    return true;
}

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
    self.visible = true;
    self.x_norm = std.math.clamp(x, 0, 1);
    self.y_norm = std.math.clamp(y, 0, 1);
}

fn cbHideCursor(
    session: ?*c.IHS_Session,
    ctx_ptr: ?*anyopaque,
) callconv(.c) void {
    _ = session;
    const self: *CursorState = @ptrCast(@alignCast(ctx_ptr.?));
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    self.visible = false;
}

pub var cursor_callbacks = c.IHS_StreamInputCallbacks{
    .setCursor = cbSetCursor,
    .showCursor = cbShowCursor,
    .hideCursor = cbHideCursor,
};

pub const ChordAction = enum { disconnect, toggle_mouse };

pub const ChordTracker = struct {
    start_held: bool = false,
    back_held: bool = false,
    last_x_press_ms: i64 = 0,

    const double_tap_window_ms: i64 = 400;

    pub fn observe(self: *ChordTracker, event: *const c.SDL_Event) ?ChordAction {
        switch (event.type) {
            c.SDL_CONTROLLERBUTTONDOWN => {
                switch (event.cbutton.button) {
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
                switch (event.cbutton.button) {
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
