const std = @import("std");
const c = @import("c.zig").c;
const config = @import("config.zig");

const WINDOW_W = 1280;
const WINDOW_H = 720;
const FONT_SIZE = 28;
const FONT_SMALL = 20;

const COLOR_BG = c.SDL_Color{ .r = 15, .g = 15, .b = 30, .a = 255 };
const COLOR_FG = c.SDL_Color{ .r = 220, .g = 220, .b = 220, .a = 255 };
const COLOR_SEL = c.SDL_Color{ .r = 80, .g = 140, .b = 240, .a = 255 };
const COLOR_DIM = c.SDL_Color{ .r = 100, .g = 100, .b = 120, .a = 255 };
const COLOR_OK = c.SDL_Color{ .r = 80, .g = 200, .b = 100, .a = 255 };
const COLOR_ERR = c.SDL_Color{ .r = 220, .g = 60, .b = 60, .a = 255 };

pub const UiEvent = enum {
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

pub const PinStatus = enum { idle, waiting, denied, failed };
pub const ReconnectChoice = enum { reconnect, new_pair };
pub const ResOption = enum { r720, r1080, r1440 };

pub const Ui = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    font: *c.TTF_Font,
    font_small: *c.TTF_Font,

    // Tracked screen states
    host_cursor: usize = 0,
    pin_status: PinStatus = .idle,
    reconnect_choice: ReconnectChoice = .reconnect,
    settings_row: u8 = 0,

    pub fn init() !Ui {
        if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_GAMECONTROLLER | c.SDL_INIT_AUDIO) != 0)
            return error.SDLInitFailed;
        errdefer c.SDL_Quit();

        if (c.TTF_Init() != 0) return error.TTFInitFailed;
        errdefer c.TTF_Quit();

        const window = c.SDL_CreateWindow(
            "Locomo",
            c.SDL_WINDOWPOS_CENTERED,
            c.SDL_WINDOWPOS_CENTERED,
            WINDOW_W,
            WINDOW_H,
            c.SDL_WINDOW_SHOWN | c.SDL_WINDOW_FULLSCREEN_DESKTOP,
        ) orelse return error.CreateWindowFailed;
        errdefer c.SDL_DestroyWindow(window);

        const renderer = c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_ACCELERATED | c.SDL_RENDERER_PRESENTVSYNC) orelse
            return error.CreateRendererFailed;
        errdefer c.SDL_DestroyRenderer(renderer);
        _ = c.SDL_RenderSetLogicalSize(renderer, WINDOW_W, WINDOW_H);

        var ci: c_int = 0;
        while (ci < c.SDL_NumJoysticks()) : (ci += 1) {
            if (c.SDL_IsGameController(ci) != 0) _ = c.SDL_GameControllerOpen(ci);
        }

        const font = c.TTF_OpenFont("assets/Asap-Medium.otf", FONT_SIZE) orelse return error.OpenFontFailed;
        errdefer c.TTF_CloseFont(font);

        const font_small = c.TTF_OpenFont("assets/Asap-Medium.otf", FONT_SMALL) orelse return error.OpenFontFailed;

        return Ui{
            .window = window,
            .renderer = renderer,
            .font = font,
            .font_small = font_small,
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

    pub fn pollEvents(self: *Ui) UiEvent {
        _ = self;
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => return .quit,
                c.SDL_CONTROLLERDEVICEADDED => {
                    _ = c.SDL_GameControllerOpen(event.cdevice.which);
                },
                c.SDL_CONTROLLERBUTTONDOWN => {
                    const btn = event.cbutton.button;
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
                    if (sym == c.SDLK_RETURN) return .button_start;
                },
                else => {},
            }
        }
        return .none;
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
        const x = @divTrunc(WINDOW_W - w, 2);
        const dst = c.SDL_Rect{ .x = x, .y = y, .w = w, .h = h };
        _ = c.SDL_RenderCopy(self.renderer, tex, null, &dst);
    }

    fn drawRect(self: *Ui, x: i32, y: i32, w: i32, h: i32, col: c.SDL_Color) void {
        _ = c.SDL_SetRenderDrawColor(self.renderer, col.r, col.g, col.b, col.a);
        const r = c.SDL_Rect{ .x = x, .y = y, .w = w, .h = h };
        _ = c.SDL_RenderFillRect(self.renderer, &r);
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
        paired_client_id: u64,
        scanning: bool,
    ) void {
        self.clear();
        self.renderTextCentered("Steam In-Home Streaming", 40, COLOR_FG, self.font);

        if (scanning) {
            self.renderTextCentered("Scanning for Steam hosts...", 100, COLOR_DIM, self.font_small);
        } else if (hosts.len == 0) {
            self.renderTextCentered("No hosts found.", 100, COLOR_DIM, self.font_small);
        }

        const list_y: i32 = 160;
        const row_h: i32 = 56;
        for (hosts, 0..) |host, i| {
            const y = list_y + @as(i32, @intCast(i)) * row_h;
            const is_sel = (i == self.host_cursor);
            const is_paired = (host.clientId == paired_client_id);

            if (is_sel) {
                self.drawRect(60, y - 6, WINDOW_W - 120, row_h - 4, .{ .r = 30, .g = 50, .b = 100, .a = 255 });
            }

            var name_buf: [80]u8 = undefined;
            const name_len = std.mem.indexOfScalar(u8, &host.hostname, 0) orelse host.hostname.len;
            const name = host.hostname[0..name_len];
            const label = if (is_paired)
                std.fmt.bufPrintZ(&name_buf, "{s}  [paired]", .{name}) catch continue
            else
                std.fmt.bufPrintZ(&name_buf, "{s}", .{name}) catch continue;

            const col = if (is_sel) COLOR_SEL else COLOR_FG;
            self.renderText(label, 80, y, col, self.font);
        }

        self.renderTextCentered("DPAD to navigate  A to connect  START for settings", WINDOW_H - 50, COLOR_DIM, self.font_small);
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
        self.renderTextCentered(msg, @divTrunc(WINDOW_H, 2) - 14, COLOR_FG, self.font);
        self.present();
    }

    // Screen: Reconnect - TODO: Reevaluate need for this... see similar in root.zig

    pub fn drawReconnectScreen(self: *Ui, hostname: []const u8) void {
        self.clear();
        var hbuf: [80]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&hbuf, "Reconnect to {s}?", .{hostname}) catch {
            self.renderTextCentered("Reconnect?", 200, COLOR_FG, self.font);
            self.drawReconnectOptions();
            return;
        };
        self.renderTextCentered(msg, 200, COLOR_FG, self.font);
        self.drawReconnectOptions();
        self.present();
    }

    fn drawReconnectOptions(self: *Ui) void {
        const btn_w: i32 = 220;
        const btn_h: i32 = 60;
        const gap: i32 = 40;
        const total = btn_w * 2 + gap;
        const bx = @divTrunc(WINDOW_W - total, 2);
        const by: i32 = 320;

        const yes_col: c.SDL_Color = if (self.reconnect_choice == .reconnect) COLOR_SEL else COLOR_DIM;
        const new_col: c.SDL_Color = if (self.reconnect_choice == .new_pair) COLOR_SEL else COLOR_DIM;

        self.drawRectOutline(bx, by, btn_w, btn_h, yes_col);
        self.renderText("Reconnect", bx + 30, by + 15, yes_col, self.font);
        self.drawRectOutline(bx + btn_w + gap, by, btn_w, btn_h, new_col);
        self.renderText("New Pair", bx + btn_w + gap + 30, by + 15, new_col, self.font);
        self.renderTextCentered("DPAD Left/Right to choose  A to confirm", WINDOW_H - 50, COLOR_DIM, self.font_small);
    }

    pub fn reconnectToggle(self: *Ui) void {
        self.reconnect_choice = switch (self.reconnect_choice) {
            .reconnect => .new_pair,
            .new_pair => .reconnect,
        };
    }

    // Screen: PIN

    pub fn resetPin(self: *Ui) void {
        self.pin_status = .idle;
    }

    pub fn drawPinDisplay(self: *Ui, pin: *const [4]u8) void {
        self.clear();
        self.renderTextCentered("Pairing — enter this PIN on your PC", 60, COLOR_FG, self.font);
        self.renderTextCentered("Type the PIN shown below into Steam, then wait.", 110, COLOR_DIM, self.font_small);

        const slot_w: i32 = 90;
        const slot_h: i32 = 110;
        const gap: i32 = 20;
        const total_w = 4 * slot_w + 3 * gap;
        const start_x = @divTrunc(WINDOW_W - total_w, 2);
        const slot_y: i32 = 200;

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

        const status_y: i32 = 360;
        switch (self.pin_status) {
            .idle, .waiting => self.renderTextCentered("Waiting for PC confirmation...  B = cancel", status_y, COLOR_DIM, self.font_small),
            .denied => self.renderTextCentered("PIN denied.", status_y, COLOR_ERR, self.font_small),
            .failed => self.renderTextCentered("Pairing failed.", status_y, COLOR_ERR, self.font_small),
        }
        self.present();
    }

    // Screen: Settings

    const res_labels = [_][:0]const u8{ "1280x720", "1920x1080", "2560x1440" };
    const bw_labels = [_][:0]const u8{ "5 Mbps", "10 Mbps", "20 Mbps", "30 Mbps", "Unlimited" };
    const bw_values = [_]u32{ 5000, 10000, 20000, 30000, 0 };

    pub fn drawSettingsScreen(self: *Ui, s: config.Settings) void {
        self.clear();
        self.renderTextCentered("Settings", 50, COLOR_FG, self.font);

        const rows = [_][:0]const u8{ "Resolution", "Max Bandwidth", "H.265 / HEVC" };
        const start_y: i32 = 160;
        const row_h: i32 = 80;

        for (rows, 0..) |row_name, i| {
            const y = start_y + @as(i32, @intCast(i)) * row_h;
            const is_sel = (i == self.settings_row);
            const label_col = if (is_sel) COLOR_SEL else COLOR_FG;

            self.renderText(row_name, 100, y, label_col, self.font);

            var vbuf: [32]u8 = undefined;
            const val: [:0]const u8 = switch (i) {
                0 => blk: {
                    const ri = resIndex(s.width, s.height);
                    break :blk res_labels[ri];
                },
                1 => blk: {
                    const bi = bwIndex(s.max_bandwidth_kbps);
                    break :blk bw_labels[bi];
                },
                2 => blk: {
                    break :blk if (s.enable_hevc) "On" else "Off";
                },
                else => std.fmt.bufPrintZ(&vbuf, "", .{}) catch "",
            };

            self.renderText(val, WINDOW_W - 300, y, label_col, self.font);
        }

        self.renderTextCentered("DPAD Up/Down = row  Left/Right = value  B = save", WINDOW_H - 50, COLOR_DIM, self.font_small);
        self.present();
    }

    pub fn settingsMoveRow(self: *Ui, delta: i32) void {
        const r: i32 = @intCast(self.settings_row);
        self.settings_row = @intCast(@mod(r + delta + 3, 3));
    }

    pub fn settingsAdjust(self: *Ui, s: *config.Settings, delta: i32) void {
        switch (self.settings_row) {
            0 => {
                var ri: i32 = @intCast(resIndex(s.width, s.height));
                ri = @mod(ri + delta + 3, 3);
                switch (ri) {
                    0 => {
                        s.width = 1280;
                        s.height = 720;
                    },
                    1 => {
                        s.width = 1920;
                        s.height = 1080;
                    },
                    2 => {
                        s.width = 2560;
                        s.height = 1440;
                    },
                    else => {},
                }
            },
            1 => {
                var bi: i32 = @intCast(bwIndex(s.max_bandwidth_kbps));
                bi = @mod(bi + delta + 5, 5);
                s.max_bandwidth_kbps = bw_values[@intCast(bi)];
            },
            2 => {
                s.enable_hevc = !s.enable_hevc;
            },
            else => {},
        }
    }

    fn resIndex(w: u32, h: u32) usize {
        if (w == 1920 and h == 1080) return 1;
        if (w == 2560 and h == 1440) return 2;
        return 0;
    }

    fn bwIndex(kbps: u32) usize {
        for (bw_values, 0..) |v, i| {
            if (v == kbps) return i;
        }
        return bw_values.len - 1;
    }
};
