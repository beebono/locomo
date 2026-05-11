const std = @import("std");
const c = @import("c.zig").c;
const config = @import("config.zig");
const gl = @import("gl.zig");

const FONT_OTF = @embedFile("assets/Asap-Medium.otf");
const FONT_BIG = 64;
const FONT_SMALL = 48;

const COLOR_BG = c.SDL_Color{ .r = 15, .g = 15, .b = 30, .a = 255 };
const COLOR_FG = c.SDL_Color{ .r = 220, .g = 220, .b = 220, .a = 255 };
const COLOR_SEL = c.SDL_Color{ .r = 80, .g = 140, .b = 240, .a = 255 };
const COLOR_DIM = c.SDL_Color{ .r = 100, .g = 100, .b = 120, .a = 255 };
const COLOR_ERR = c.SDL_Color{ .r = 220, .g = 60, .b = 60, .a = 255 };

pub const PinStatus = enum { idle, waiting, denied, failed };

// Layout reference: design at 1920x1080, use unit scaling based on this
const DESIGN_H: f32 = 1080.0;
const DESIGN_SAFE_W: f32 = 1920.0;

pub const Ui = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    logical_w: c_int = 1280,
    logical_h: c_int = 720,
    unit: f32 = 1.0,
    safe_w: c_int = 1280,
    safe_x: c_int = 0,
    font: *c.TTF_Font,
    font_small: *c.TTF_Font,
    gl_ctx: ?gl.GlCtx = null,

    // Tracked screen states
    host_cursor: usize = 0,
    pin_status: PinStatus = .idle,
    settings_row: u8 = 0,

    pub fn init() !Ui {
        if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_GAMECONTROLLER | c.SDL_INIT_AUDIO) != 0)
            return error.SDLInitFailed;
        errdefer c.SDL_Quit();

        if (c.TTF_Init() != 0) return error.TTFInitFailed;
        errdefer c.TTF_Quit();

        var dm: c.SDL_DisplayMode = undefined;
        const display_idx: c_int = 0;
        const have_dm = c.SDL_GetCurrentDisplayMode(display_idx, &dm) == 0;
        if (!have_dm) std.log.warn("[locomo - render] Couldn't detect display mode, defaulting to 1280x720.", .{});
        const screen_w: c_int = if (have_dm) dm.w else 1280;
        const screen_h: c_int = if (have_dm) dm.h else 720;
        if (have_dm) std.log.info("[locomo - render] Detected resolution: {}x{}", .{ screen_w, screen_h });

        const window = c.SDL_CreateWindow(
            "Locomo",
            c.SDL_WINDOWPOS_CENTERED,
            c.SDL_WINDOWPOS_CENTERED,
            screen_w,
            screen_h,
            c.SDL_WINDOW_SHOWN | c.SDL_WINDOW_FULLSCREEN_DESKTOP,
        ) orelse return error.CreateWindowFailed;
        errdefer c.SDL_DestroyWindow(window);

        _ = c.SDL_SetHint(c.SDL_HINT_RENDER_DRIVER, "opengles2");
        const renderer = c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_ACCELERATED) orelse
            return error.CreateRendererFailed;

        const gl_ctx: ?gl.GlCtx = gl.init() catch blk: {
            std.log.warn("[locomo - render] Failed to start HW renderer, HW decode will not work.", .{});
            break :blk null;
        };
        errdefer c.SDL_DestroyRenderer(renderer);
        _ = c.SDL_RenderSetLogicalSize(renderer, screen_w, screen_h);

        var ci: c_int = 0;
        while (ci < c.SDL_NumJoysticks()) : (ci += 1) {
            if (c.SDL_IsGameController(ci) != 0) _ = c.SDL_GameControllerOpen(ci);
        }

        const min_dim: f32 = @floatFromInt(@min(screen_w, screen_h));
        const unit: f32 = min_dim / DESIGN_H;
        const safe_w_f = @min(@as(f32, @floatFromInt(screen_w)), unit * DESIGN_SAFE_W);
        const safe_w: c_int = @intFromFloat(@round(safe_w_f));
        const safe_x: c_int = @divTrunc(screen_w - safe_w, 2);

        const size_big = @as(c_int, @intFromFloat(@round(FONT_BIG * unit)));
        const font = c.TTF_OpenFontRW(c.SDL_RWFromConstMem(FONT_OTF.ptr, FONT_OTF.len), 1, size_big) orelse return error.OpenFontFailed;
        errdefer c.TTF_CloseFont(font);

        const size_small = @as(c_int, @intFromFloat(@round(FONT_SMALL * unit)));
        const font_small = c.TTF_OpenFontRW(c.SDL_RWFromConstMem(FONT_OTF.ptr, FONT_OTF.len), 1, size_small) orelse return error.OpenFontFailed;

        return Ui{
            .window = window,
            .renderer = renderer,
            .logical_w = screen_w,
            .logical_h = screen_h,
            .unit = unit,
            .safe_w = safe_w,
            .safe_x = safe_x,
            .font = font,
            .font_small = font_small,
            .gl_ctx = gl_ctx,
        };
    }

    inline fn u(self: *const Ui, n: f32) c_int {
        return @intFromFloat(@round(self.unit * n));
    }

    pub fn recreateRenderer(self: *Ui) !void {
        c.SDL_DestroyRenderer(self.renderer);
        _ = c.SDL_SetHint(c.SDL_HINT_RENDER_DRIVER, "opengles2");
        const renderer = c.SDL_CreateRenderer(self.window, -1, c.SDL_RENDERER_ACCELERATED) orelse
            return error.CreateRendererFailed;
        _ = c.SDL_RenderSetLogicalSize(renderer, self.logical_w, self.logical_h);
        self.renderer = renderer;
        self.gl_ctx = gl.init() catch blk: {
            break :blk null;
        };
    }

    pub fn deinit(self: *Ui) void {
        c.TTF_CloseFont(self.font_small);
        c.TTF_CloseFont(self.font);
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.TTF_Quit();
        c.SDL_Quit();
    }

    fn clear(self: *Ui) void {
        _ = c.SDL_SetRenderDrawColor(self.renderer, COLOR_BG.r, COLOR_BG.g, COLOR_BG.b, 255);
        _ = c.SDL_RenderClear(self.renderer);
    }

    fn present(self: *Ui) void {
        c.SDL_RenderPresent(self.renderer);
    }

    fn renderText(self: *Ui, text: [:0]const u8, x: i32, y: i32, color: c.SDL_Color, font: *c.TTF_Font) void {
        const surface = c.TTF_RenderUTF8_Blended(font, text.ptr, color) orelse return;
        defer c.SDL_FreeSurface(surface);
        const tex = c.SDL_CreateTextureFromSurface(self.renderer, surface) orelse return;
        defer c.SDL_DestroyTexture(tex);
        var w: i32 = 0;
        var h: i32 = 0;
        _ = c.SDL_QueryTexture(tex, null, null, &w, &h);
        const dst = c.SDL_Rect{ .x = x, .y = y, .w = w, .h = h };
        _ = c.SDL_RenderCopy(self.renderer, tex, null, &dst);
    }

    fn renderTextCentered(self: *Ui, text: [:0]const u8, y: i32, color: c.SDL_Color, font: *c.TTF_Font) void {
        const surface = c.TTF_RenderUTF8_Blended(font, text.ptr, color) orelse return;
        defer c.SDL_FreeSurface(surface);
        const tex = c.SDL_CreateTextureFromSurface(self.renderer, surface) orelse return;
        defer c.SDL_DestroyTexture(tex);
        var w: i32 = 0;
        var h: i32 = 0;
        _ = c.SDL_QueryTexture(tex, null, null, &w, &h);
        const x = @divTrunc(self.logical_w - w, 2);
        const dst = c.SDL_Rect{ .x = x, .y = y, .w = w, .h = h };
        _ = c.SDL_RenderCopy(self.renderer, tex, null, &dst);
    }

    fn drawRect(self: *Ui, x: i32, y: i32, w: i32, h: i32, col: c.SDL_Color) void {
        _ = c.SDL_SetRenderDrawColor(self.renderer, col.r, col.g, col.b, col.a);
        const r = c.SDL_Rect{ .x = x, .y = y, .w = w, .h = h };
        _ = c.SDL_RenderFillRect(self.renderer, &r);
    }

    pub fn drawToast(self: *Ui, text: [:0]const u8) void {
        var tw: c_int = 0;
        var th: c_int = 0;
        _ = c.TTF_SizeUTF8(self.font_small, text.ptr, &tw, &th);
        const pad_x: c_int = self.u(24);
        const pad_y: c_int = self.u(12);
        const box_w = tw + pad_x * 2;
        const box_h = th + pad_y * 2;
        const x = @divTrunc(self.logical_w - box_w, 2);
        const y = self.u(45);
        self.drawRect(x, y, box_w, box_h, c.SDL_Color{ .r = 15, .g = 15, .b = 30, .a = 255 });
        self.drawRectOutline(x, y, box_w, box_h, COLOR_DIM);
        self.renderText(text, x + pad_x, y + pad_y, COLOR_FG, self.font_small);
    }

    fn drawRectOutline(self: *Ui, x: i32, y: i32, w: i32, h: i32, col: c.SDL_Color) void {
        _ = c.SDL_SetRenderDrawColor(self.renderer, col.r, col.g, col.b, col.a);
        const r = c.SDL_Rect{ .x = x, .y = y, .w = w, .h = h };
        _ = c.SDL_RenderDrawRect(self.renderer, &r);
    }

    // Screen: Host Scanning

    pub fn drawScanScreen(
        self: *Ui,
        hosts: []const c.IHS_HostInfo,
        scanning: bool,
    ) void {
        self.clear();
        self.renderTextCentered("LOCOMO", self.u(60), COLOR_FG, self.font);

        if (scanning) {
            self.renderTextCentered("Scanning for Steam hosts...", self.u(135), COLOR_DIM, self.font_small);
        } else if (hosts.len == 0) {
            self.renderTextCentered("No hosts found.  Press A to scan again.", self.u(135), COLOR_DIM, self.font_small);
        }

        const list_y: i32 = self.u(216);
        const row_h: i32 = self.u(90);
        const row_indent: i32 = self.safe_x + self.u(80);
        const row_bg_x: i32 = self.safe_x + self.u(40);
        const row_bg_w: i32 = self.safe_w - self.u(80);
        for (hosts, 0..) |host, i| {
            const y = list_y + @as(i32, @intCast(i)) * row_h;
            const is_sel = (i == self.host_cursor);

            if (is_sel) {
                self.drawRect(row_bg_x, y - self.u(6), row_bg_w, row_h - self.u(4), .{ .r = 30, .g = 50, .b = 100, .a = 255 });
            }

            var name_buf: [80]u8 = undefined;
            const name_len = std.mem.indexOfScalar(u8, &host.hostname, 0) orelse host.hostname.len;
            const name = host.hostname[0..name_len];
            const label = std.fmt.bufPrintZ(&name_buf, "{s}", .{name}) catch continue;
            const col = if (is_sel) COLOR_SEL else COLOR_FG;
            self.renderText(label, row_indent, y, col, self.font);
        }

        self.renderTextCentered("DPAD to navigate  A to connect  START for settings", self.logical_h - self.u(90), COLOR_DIM, self.font_small);
        self.present();
    }

    pub fn moveScanCursor(self: *Ui, delta: i32, host_count: usize) void {
        if (host_count == 0) return;
        const n: i32 = @intCast(host_count);
        var cur: i32 = @intCast(self.host_cursor);
        cur = @mod(cur + delta + n, n);
        self.host_cursor = @intCast(cur);
    }

    pub fn selectedHostIndex(self: *const Ui) usize {
        return self.host_cursor;
    }

    // Screen: Statuses

    pub fn drawStatus(self: *Ui, msg: [:0]const u8) void {
        self.clear();
        self.renderTextCentered(msg, @divTrunc(self.logical_h, 2) - self.u(16), COLOR_FG, self.font);
        self.present();
    }

    // Screen: PIN

    pub fn resetPin(self: *Ui) void {
        self.pin_status = .idle;
    }

    pub fn drawPinDisplay(self: *Ui, pin: *const [4]u8) void {
        self.clear();
        self.renderTextCentered("Pairing...", self.u(90), COLOR_FG, self.font);
        self.renderTextCentered("Type the PIN shown below into Steam on your PC.", self.u(180), COLOR_DIM, self.font_small);

        const slot_w: i32 = self.u(90);
        const slot_h: i32 = self.u(110);
        const gap: i32 = self.u(20);
        const total_w = 4 * slot_w + 3 * gap;
        const start_x = @divTrunc(self.logical_w - total_w, 2);
        const slot_y: i32 = self.u(360);

        for (pin, 0..) |digit, i| {
            const x = start_x + @as(i32, @intCast(i)) * (slot_w + gap);
            self.drawRect(x, slot_y, slot_w, slot_h, .{ .r = 20, .g = 40, .b = 80, .a = 255 });
            self.drawRectOutline(x, slot_y, slot_w, slot_h, COLOR_SEL);
            var dbuf: [4]u8 = undefined;
            const dstr = std.fmt.bufPrintZ(&dbuf, "{c}", .{digit}) catch continue;
            const surf = c.TTF_RenderUTF8_Blended(self.font, dstr.ptr, COLOR_FG) orelse continue;
            defer c.SDL_FreeSurface(surf);
            const tex = c.SDL_CreateTextureFromSurface(self.renderer, surf) orelse continue;
            defer c.SDL_DestroyTexture(tex);
            var tw: i32 = 0;
            var th: i32 = 0;
            _ = c.SDL_QueryTexture(tex, null, null, &tw, &th);
            const cx = x + @divTrunc(slot_w - tw, 2);
            const cy = slot_y + @divTrunc(slot_h - th, 2);
            _ = c.SDL_RenderCopy(self.renderer, tex, null, &c.SDL_Rect{ .x = cx, .y = cy, .w = tw, .h = th });
        }

        const status_y: i32 = self.u(540);
        switch (self.pin_status) {
            .idle, .waiting => self.renderTextCentered("Waiting for PC confirmation...  B = cancel", status_y, COLOR_DIM, self.font_small),
            .denied => self.renderTextCentered("PIN denied.", status_y, COLOR_ERR, self.font_small),
            .failed => self.renderTextCentered("Pairing failed.", status_y, COLOR_ERR, self.font_small),
        }
        self.present();
    }

    // Screen: Settings

    pub fn drawSettingsScreen(self: *Ui, s: config.Settings) void {
        self.clear();
        self.renderTextCentered("Settings", self.u(90), COLOR_FG, self.font);

        const rows = [_][:0]const u8{ "Quality Preset", "Resolution", "Bandwidth Limit", "Framerate Limit", "Audio Type", "H.265 / HEVC (WIP)", "HW Decode", "Button Swap" };
        const start_y: i32 = self.u(240);
        const row_h: i32 = self.u(90);
        const label_x: i32 = self.safe_x + self.u(120);
        const value_x: i32 = self.safe_x + self.safe_w - self.u(560);

        for (rows, 0..) |row_name, i| {
            const y = start_y + @as(i32, @intCast(i)) * row_h;
            const is_sel = (i == self.settings_row);
            const label_col = if (is_sel) COLOR_SEL else COLOR_FG;

            self.renderText(row_name, label_x, y, label_col, self.font);

            var vbuf: [32]u8 = undefined;
            const val: [:0]const u8 = switch (i) {
                0 => blk: {
                    const qi = qualityIndex(s.quality);
                    break :blk config.quality_options[qi].label;
                },
                1 => blk: {
                    const ri = resIndex(s.width, s.height);
                    const opt = config.resolution_options[ri];
                    if (opt.width == 0 or opt.height == 0) {
                        break :blk std.fmt.bufPrintZ(&vbuf, "{s} ({d}x{d})", .{ opt.label, self.logical_w, self.logical_h }) catch opt.label;
                    }
                    break :blk opt.label;
                },
                2 => blk: {
                    const bi = bwIndex(s.max_bandwidth_kbps);
                    break :blk config.bandwidth_options[bi].label;
                },
                3 => blk: {
                    const fi = frIndex(s.framerate_limit);
                    break :blk config.framerate_options[fi].label;
                },
                4 => blk: {
                    const ai = audioIndex(s.audio_channels);
                    break :blk config.audio_options[ai].label;
                },
                5 => blk: {
                    break :blk if (s.enable_hevc) "On" else "Off";
                },
                6 => blk: {
                    break :blk if (s.hw_decode) "On" else "Off";
                },
                7 => blk: {
                    const bsi = buttonSwapIndex(s.button_swap);
                    break :blk config.button_swap_options[bsi].label;
                },
                else => std.fmt.bufPrintZ(&vbuf, "", .{}) catch "",
            };

            self.renderText(val, value_x, y, label_col, self.font);
        }

        self.renderTextCentered("DPAD Up/Down = select  Left/Right/A = value  B = save", self.logical_h - self.u(90), COLOR_DIM, self.font_small);
        self.present();
    }

    pub fn settingsMoveRow(self: *Ui, delta: i32) void {
        const r: i32 = @intCast(self.settings_row);
        self.settings_row = @intCast(@mod(r + delta + 8, 8));
    }

    pub fn settingsAdjust(self: *Ui, s: *config.Settings, delta: i32) void {
        switch (self.settings_row) {
            0 => {
                const n: i32 = @intCast(config.quality_options.len);
                var qi: i32 = @intCast(qualityIndex(s.quality));
                qi = @mod(qi + delta + n, n);
                s.quality = config.quality_options[@intCast(qi)].quality_preset;
            },
            1 => {
                const n: i32 = @intCast(config.resolution_options.len);
                var ri: i32 = @intCast(resIndex(s.width, s.height));
                ri = @mod(ri + delta + n, n);
                const opt = config.resolution_options[@intCast(ri)];
                s.width = opt.width;
                s.height = opt.height;
            },
            2 => {
                const n: i32 = @intCast(config.bandwidth_options.len);
                var bi: i32 = @intCast(bwIndex(s.max_bandwidth_kbps));
                bi = @mod(bi + delta + n, n);
                s.max_bandwidth_kbps = config.bandwidth_options[@intCast(bi)].kbps;
            },
            3 => {
                const n: i32 = @intCast(config.framerate_options.len);
                var fi: i32 = @intCast(frIndex(s.framerate_limit));
                fi = @mod(fi + delta + n, n);
                s.framerate_limit = config.framerate_options[@intCast(fi)].framerate_numerator;
            },
            4 => {
                const n: i32 = @intCast(config.audio_options.len);
                var ai: i32 = @intCast(audioIndex(s.audio_channels));
                ai = @mod(ai + delta + n, n);
                s.audio_channels = config.audio_options[@intCast(ai)].channels;
            },
            5 => {
                s.enable_hevc = !s.enable_hevc;
            },
            6 => {
                s.hw_decode = !s.hw_decode;
            },
            7 => {
                const n: i32 = @intCast(config.button_swap_options.len);
                var bsi: i32 = @intCast(buttonSwapIndex(s.button_swap));
                bsi = @mod(bsi + delta + n, n);
                s.button_swap = config.button_swap_options[@intCast(bsi)].value;
            },
            else => {},
        }
    }

    fn buttonSwapIndex(v: config.ButtonSwap) usize {
        for (config.button_swap_options, 0..) |o, i| {
            if (o.value == v) return i;
        }
        return 0;
    }

    fn qualityIndex(quality: u32) usize {
        for (config.quality_options, 0..) |o, i| {
            if (o.quality_preset == quality) return i;
        }
        return 1;
    }

    fn resIndex(w: u32, h: u32) usize {
        for (config.resolution_options, 0..) |o, i| {
            if (o.width == w and o.height == h) return i;
        }
        return 0;
    }

    fn bwIndex(kbps: i32) usize {
        for (config.bandwidth_options, 0..) |o, i| {
            if (o.kbps == kbps) return i;
        }
        return 0;
    }

    fn frIndex(framerateNumerator: u32) usize {
        for (config.framerate_options, 0..) |o, i| {
            if (o.framerate_numerator == framerateNumerator) return i;
        }
        return 0;
    }

    fn audioIndex(channels: u32) usize {
        for (config.audio_options, 0..) |o, i| {
            if (o.channels == channels) return i;
        }
        return config.audio_options.len - 1;
    }
};
