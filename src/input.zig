const std = @import("std");
const c = @import("c.zig").c;
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
    last_send_ns: i128 = 0,
    lt_pressed: bool = false,
    rt_pressed: bool = false,

    const deadzone: f32 = 8000.0;
    const max_axis: f32 = 32767.0;
    const max_pixels_per_sec: f32 = 1500.0;
    const exponent: f32 = 2.0;
    const trigger_press_threshold: i16 = 18000;
    const trigger_release_threshold: i16 = 12000;
    const min_send_interval_ns: i128 = 32 * std.time.ns_per_ms;

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
        _ = self;
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

    pub fn tick(self: *MouseState, session: *c.IHS_Session, cursor_state: *CursorState, logical_w: c_int, logical_h: c_int, now_ns: i128) void {
        if (self.last_tick_ns == 0) {
            self.last_tick_ns = now_ns;
            self.last_send_ns = now_ns;
            return;
        }
        const dt_ns = now_ns - self.last_tick_ns;
        self.last_tick_ns = now_ns;
        const dt_s: f32 = @as(f32, @floatFromInt(dt_ns)) / @as(f32, @floatFromInt(std.time.ns_per_s));

        const v = velocity(self.left_x, self.left_y);
        self.accum_x += v.vx * dt_s;
        self.accum_y += v.vy * dt_s;

        if (now_ns - self.last_send_ns < min_send_interval_ns) return;

        const dx: i32 = @intFromFloat(self.accum_x);
        const dy: i32 = @intFromFloat(self.accum_y);
        if (dx != 0 or dy != 0) {
            _ = c.IHS_SessionSendMouseMovement(session, dx, dy);
            cursor_state.predictMotion(dx, dy, logical_w, logical_h);
            self.accum_x -= @as(f32, @floatFromInt(dx));
            self.accum_y -= @as(f32, @floatFromInt(dy));
            self.last_send_ns = now_ns;
        }
    }

    pub fn reset(self: *MouseState, session: *c.IHS_Session) void {
        self.accum_x = 0;
        self.accum_y = 0;
        self.last_tick_ns = 0;
        self.last_send_ns = 0;
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

const PendingImage = struct {
    id: u64,
    width: c_int,
    height: c_int,
    hot_x: c_int,
    hot_y: c_int,
    rgba: []u8,
};

const CursorEvent = union(enum) {
    image: PendingImage,
    delete: u64,
};

const CachedCursor = struct {
    width: c_int,
    height: c_int,
    hot_x: c_int,
    hot_y: c_int,
    texture: *c.SDL_Texture,
};

pub const CursorState = struct {
    allocator: std.mem.Allocator,
    mutex: Io.Mutex,
    pending: std.ArrayListUnmanaged(CursorEvent),
    known_ids: std.AutoHashMap(u64, void),
    cache: std.AutoHashMap(u64, CachedCursor),
    current_id: u64,
    visible: bool,
    x_norm: f32,
    y_norm: f32,

    pub fn init(allocator: std.mem.Allocator) CursorState {
        return .{
            .allocator = allocator,
            .mutex = .init,
            .pending = .empty,
            .known_ids = std.AutoHashMap(u64, void).init(allocator),
            .cache = std.AutoHashMap(u64, CachedCursor).init(allocator),
            .current_id = 0,
            .visible = false,
            .x_norm = 0.5,
            .y_norm = 0.5,
        };
    }

    pub fn predictMotion(self: *CursorState, dx: i32, dy: i32, logical_w: c_int, logical_h: c_int) void {
        if (logical_w <= 0 or logical_h <= 0) return;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const fw: f32 = @floatFromInt(logical_w);
        const fh: f32 = @floatFromInt(logical_h);
        self.x_norm = std.math.clamp(self.x_norm + @as(f32, @floatFromInt(dx)) / fw, 0, 1);
        self.y_norm = std.math.clamp(self.y_norm + @as(f32, @floatFromInt(dy)) / fh, 0, 1);
    }

    pub fn deinit(self: *CursorState) void {
        for (self.pending.items) |ev| switch (ev) {
            .image => |p| self.allocator.free(p.rgba),
            .delete => {},
        };
        self.pending.deinit(self.allocator);
        var it = self.cache.iterator();
        while (it.next()) |e| c.SDL_DestroyTexture(e.value_ptr.texture);
        self.cache.deinit();
        self.known_ids.deinit();
    }

    pub fn render(self: *CursorState, renderer: *c.SDL_Renderer, logical_w: c_int, logical_h: c_int, draw: bool) void {
        // Drain queue + snapshot state under a tiny lock.
        var events: std.ArrayListUnmanaged(CursorEvent) = .empty;
        var cur_id: u64 = 0;
        var visible: bool = false;
        var xn: f32 = 0;
        var yn: f32 = 0;
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            std.mem.swap(std.ArrayListUnmanaged(CursorEvent), &events, &self.pending);
            cur_id = self.current_id;
            visible = self.visible;
            xn = self.x_norm;
            yn = self.y_norm;
        }
        defer events.deinit(self.allocator);

        // Apply events in arrival order so image/delete with same id resolves correctly.
        for (events.items) |*ev| switch (ev.*) {
            .delete => |id| {
                if (self.cache.fetchRemove(id)) |kv| c.SDL_DestroyTexture(kv.value.texture);
            },
            .image => |*p| {
                defer self.allocator.free(p.rgba);
                if (self.cache.fetchRemove(p.id)) |kv| c.SDL_DestroyTexture(kv.value.texture);
                const surface = c.SDL_CreateRGBSurfaceWithFormatFrom(
                    p.rgba.ptr,
                    p.width,
                    p.height,
                    32,
                    p.width * 4,
                    c.SDL_PIXELFORMAT_ARGB8888,
                ) orelse continue;
                defer c.SDL_FreeSurface(surface);
                const tex = c.SDL_CreateTextureFromSurface(renderer, surface) orelse continue;
                _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND);
                self.cache.put(p.id, .{
                    .width = p.width,
                    .height = p.height,
                    .hot_x = p.hot_x,
                    .hot_y = p.hot_y,
                    .texture = tex,
                }) catch {
                    c.SDL_DestroyTexture(tex);
                };
            },
        };

        if (!draw or !visible) return;
        const entry = self.cache.get(cur_id) orelse return;
        const px = @as(c_int, @intFromFloat(xn * @as(f32, @floatFromInt(logical_w)))) - entry.hot_x;
        const py = @as(c_int, @intFromFloat(yn * @as(f32, @floatFromInt(logical_h)))) - entry.hot_y;
        const dst = c.SDL_Rect{ .x = px, .y = py, .w = entry.width, .h = entry.height };
        _ = c.SDL_RenderCopy(renderer, entry.texture, null, &dst);
    }
};

fn cbSetCursor(
    session: ?*c.IHS_Session,
    cursor_id: u64,
    ctx_ptr: ?*anyopaque,
) callconv(.c) bool {
    _ = session;
    const self: *CursorState = @ptrCast(@alignCast(ctx_ptr.?));
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    self.current_id = cursor_id;
    return self.known_ids.contains(cursor_id);
}

fn cbDeleteCursor(
    session: ?*c.IHS_Session,
    cursor_id: u64,
    ctx_ptr: ?*anyopaque,
) callconv(.c) bool {
    _ = session;
    const self: *CursorState = @ptrCast(@alignCast(ctx_ptr.?));
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    _ = self.known_ids.remove(cursor_id);
    self.pending.append(self.allocator, .{ .delete = cursor_id }) catch {};
    return true;
}

fn cbCursorImage(
    session: ?*c.IHS_Session,
    image_ptr: ?*const c.IHS_StreamInputCursorImage,
    ctx_ptr: ?*anyopaque,
) callconv(.c) void {
    _ = session;
    const self: *CursorState = @ptrCast(@alignCast(ctx_ptr.?));
    const img = image_ptr.?;
    if (img.imageLen == 0) return;
    const copy = self.allocator.alloc(u8, img.imageLen) catch return;
    @memcpy(copy, img.image[0..img.imageLen]);

    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    self.known_ids.put(img.cursorId, {}) catch {};
    self.pending.append(self.allocator, .{ .image = .{
        .id = img.cursorId,
        .width = img.width,
        .height = img.height,
        .hot_x = img.hotX,
        .hot_y = img.hotY,
        .rgba = copy,
    } }) catch self.allocator.free(copy);
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
    self.x_norm = x;
    self.y_norm = y;
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
    .deleteCursor = cbDeleteCursor,
    .cursorImage = cbCursorImage,
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
