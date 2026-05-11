const std = @import("std");
const Io = std.Io;
const io = std.Options.debug_io;

pub const DeviceConfig = struct {
    device_id: u64,
    secret_key: [32]u8,
    device_name: [64]u8,
};

pub const PairedHost = struct {
    hostname: [64]u8,
    client_id: u64,
    instance_id: u64,
    steam_id: u64,
};

pub const ButtonSwap = enum { none, ab, xy, all };

pub const Settings = struct {
    quality: u32 = 2,
    width: u32 = 0,
    height: u32 = 0,
    audio_channels: u32 = 2,
    max_bandwidth_kbps: i32 = -1,
    framerate_limit: u32 = 0,
    enable_hevc: bool = false,
    hw_decode: bool = true,
    button_swap: ButtonSwap = .none,
};

pub const ButtonSwapOption = struct { value: ButtonSwap, label: [:0]const u8 };
pub const button_swap_options = [_]ButtonSwapOption{
    .{ .value = .none, .label = "None" },
    .{ .value = .ab, .label = "Swap A-B" },
    .{ .value = .xy, .label = "Swap X-Y" },
    .{ .value = .all, .label = "Swap All" },
};

pub const QualityOption = struct { quality_preset: u32, label: [:0]const u8 };
pub const ResolutionOption = struct { width: u32, height: u32, label: [:0]const u8 };
pub const BandwidthOption = struct { kbps: i32, label: [:0]const u8 };
pub const AudioOption = struct { channels: u32, label: [:0]const u8 };
pub const FramerateOption = struct { framerate_numerator: u32, label: [:0]const u8 };

pub const quality_options = [_]QualityOption{
    .{ .quality_preset = 1, .label = "Fast" },
    .{ .quality_preset = 2, .label = "Balanced" },
    .{ .quality_preset = 3, .label = "Beautiful" },
};

pub const resolution_options = [_]ResolutionOption{
    .{ .width = 0, .height = 0, .label = "Native" },
    .{ .width = 852, .height = 480, .label = "852x480" },
    .{ .width = 1280, .height = 720, .label = "1280x720" },
    .{ .width = 1600, .height = 900, .label = "1600x900" },
    .{ .width = 1920, .height = 1080, .label = "1920x1080" },
    .{ .width = 2560, .height = 1440, .label = "2560x1440" },
    .{ .width = 3840, .height = 2160, .label = "3840x2160" },
};

pub const bandwidth_options = [_]BandwidthOption{
    .{ .kbps = -1, .label = "Automatic" },
    .{ .kbps = 5000, .label = "5 Mbps" },
    .{ .kbps = 10000, .label = "10 Mbps" },
    .{ .kbps = 15000, .label = "15 Mbps" },
    .{ .kbps = 20000, .label = "20 Mbps" },
    .{ .kbps = 30000, .label = "30 Mbps" },
    .{ .kbps = 50000, .label = "50 Mbps" },
    .{ .kbps = 100000, .label = "100 Mbps" },
    .{ .kbps = 0, .label = "Unlimited" },
};

pub const audio_options = [_]AudioOption{
    .{ .channels = 0, .label = "No Audio" },
    .{ .channels = 1, .label = "Mono" },
    .{ .channels = 2, .label = "Stereo" },
};

pub const framerate_options = [_]FramerateOption{
    .{ .framerate_numerator = 0, .label = "Automatic" },
    .{ .framerate_numerator = 3000, .label = "30 FPS" },
    .{ .framerate_numerator = 6000, .label = "60 FPS" },
    .{ .framerate_numerator = 12000, .label = "120 FPS" },
    .{ .framerate_numerator = 24000, .label = "240 FPS" },
};
pub const framerate_denominator = 100;

const DeviceJson = struct { device_id: u64, secret_key: [32]u8, device_name: []const u8 };
const PairedJson = struct { hostname: []const u8, client_id: u64, instance_id: u64, steam_id: u64 };

fn configDir(allocator: std.mem.Allocator) ![]const u8 {
    const exe_dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(exe_dir);
    return std.fs.path.join(allocator, &.{ exe_dir, "config" });
}

fn readFileToEnd(allocator: std.mem.Allocator, file: std.Io.File) ![]const u8 {
    const stat = try file.stat(io);
    const size = std.math.cast(usize, stat.size);
    var read_buf: [4096]u8 = undefined;
    var reader = std.Io.File.Reader.init(file, io, &read_buf);
    return try std.Io.Reader.readAlloc(&reader.interface, allocator, size.?);
}

pub fn loadOrCreate(allocator: std.mem.Allocator) !DeviceConfig {
    const dir_path = try configDir(allocator);
    defer allocator.free(dir_path);

    const conf_dir = try Io.Dir.createDirPathOpen(std.Io.Dir.cwd(), io, dir_path, .{});
    defer Io.Dir.close(conf_dir, io);

    if (Io.Dir.openFile(conf_dir, io, "device.json", .{})) |file| {
        defer file.close(io);
        const data = readFileToEnd(allocator, file) catch {
            std.log.warn("[locomo - settings] Failed to access device.json, regenerating. May require new pair request to hosts.", .{});
            return generateAndSave(allocator, conf_dir);
        };
        defer allocator.free(data);
        const parsed = std.json.parseFromSlice(DeviceJson, allocator, data, .{}) catch {
            std.log.warn("[locomo - settings] Failed to parse device.json, regenerating. May require new pair request to hosts.", .{});
            return generateAndSave(allocator, conf_dir);
        };
        defer parsed.deinit();
        return fromDeviceJson(parsed.value);
    } else |_| {
        return generateAndSave(allocator, conf_dir);
    }
}

fn generateAndSave(allocator: std.mem.Allocator, dir_path: Io.Dir) !DeviceConfig {
    var cfg: DeviceConfig = undefined;
    const rng_impl: std.Random.IoSource = .{ .io = io };
    const rng = rng_impl.interface();
    cfg.device_id = rng.int(u64);
    io.random(&cfg.secret_key);
    @memset(&cfg.device_name, 0);
    const name = "Locomo";
    @memcpy(cfg.device_name[0..name.len], name);

    try saveDeviceConfig(allocator, dir_path, cfg);
    return cfg;
}

fn saveDeviceConfig(allocator: std.mem.Allocator, dir_path: Io.Dir, cfg: DeviceConfig) !void {
    const name_len = std.mem.indexOfScalar(u8, &cfg.device_name, 0) orelse 64;
    const j = DeviceJson{
        .device_id = cfg.device_id,
        .secret_key = cfg.secret_key,
        .device_name = cfg.device_name[0..name_len],
    };
    var buf = std.ArrayList(u8).empty;
    var buf_writer = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
    defer buf_writer.deinit();
    var sj: std.json.Stringify = .{ .writer = &buf_writer.writer, .options = .{} };
    try sj.write(j);
    var result = buf_writer.toArrayList();
    defer result.deinit(allocator);

    const file = try Io.Dir.createFile(dir_path, io, "device.json", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, result.items);
}

fn fromDeviceJson(j: DeviceJson) DeviceConfig {
    var cfg: DeviceConfig = undefined;
    cfg.device_id = j.device_id;
    cfg.secret_key = j.secret_key;
    @memset(&cfg.device_name, 0);
    const copy_len = @min(j.device_name.len, 63);
    @memcpy(cfg.device_name[0..copy_len], j.device_name[0..copy_len]);
    return cfg;
}

pub fn loadPaired(allocator: std.mem.Allocator) !?PairedHost {
    const dir_path = try configDir(allocator);
    defer allocator.free(dir_path);

    const conf_dir = Io.Dir.createDirPathOpen(std.Io.Dir.cwd(), io, dir_path, .{}) catch return null;
    defer Io.Dir.close(conf_dir, io);

    const file = Io.Dir.openFile(conf_dir, io, "paired.json", .{}) catch return null;
    defer file.close(io);
    const data = readFileToEnd(allocator, file) catch return null;
    defer allocator.free(data);
    const parsed = std.json.parseFromSlice(PairedJson, allocator, data, .{}) catch return null;
    defer parsed.deinit();
    return fromPairedJson(parsed.value);
}

pub fn savePaired(allocator: std.mem.Allocator, host: PairedHost) !void {
    const dir_path = try configDir(allocator);
    defer allocator.free(dir_path);

    const conf_dir = try Io.Dir.createDirPathOpen(std.Io.Dir.cwd(), io, dir_path, .{});
    defer Io.Dir.close(conf_dir, io);

    const name_len = std.mem.indexOfScalar(u8, &host.hostname, 0) orelse 64;
    const j = PairedJson{
        .hostname = host.hostname[0..name_len],
        .client_id = host.client_id,
        .instance_id = host.instance_id,
        .steam_id = host.steam_id,
    };
    var buf = std.ArrayList(u8).empty;
    var buf_writer = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
    defer buf_writer.deinit();
    var sj: std.json.Stringify = .{ .writer = &buf_writer.writer, .options = .{} };
    try sj.write(j);
    var result = buf_writer.toArrayList();
    defer result.deinit(allocator);

    const file = try Io.Dir.createFile(conf_dir, io, "paired.json", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, result.items);
}

fn fromPairedJson(j: PairedJson) PairedHost {
    var h: PairedHost = undefined;
    @memset(&h.hostname, 0);
    const copy_len = @min(j.hostname.len, 63);
    @memcpy(h.hostname[0..copy_len], j.hostname[0..copy_len]);
    h.client_id = j.client_id;
    h.instance_id = j.instance_id;
    h.steam_id = j.steam_id;
    return h;
}

pub fn loadSettings(allocator: std.mem.Allocator) !Settings {
    const dir_path = try configDir(allocator);
    defer allocator.free(dir_path);

    const conf_dir = Io.Dir.createDirPathOpen(std.Io.Dir.cwd(), io, dir_path, .{}) catch return Settings{};
    defer Io.Dir.close(conf_dir, io);

    const file = Io.Dir.openFile(conf_dir, io, "settings.json", .{}) catch return Settings{};
    defer file.close(io);
    const data = readFileToEnd(allocator, file) catch return Settings{};
    defer allocator.free(data);
    const parsed = std.json.parseFromSlice(Settings, allocator, data, .{}) catch {
        std.log.warn("[locomo - settings] Invalid value(s) parsed from settings.json, resetting to defaults.", .{});
        const defaults = Settings{};
        saveSettings(allocator, defaults) catch {};
        return defaults;
    };
    defer parsed.deinit();
    return parsed.value;
}

pub fn saveSettings(allocator: std.mem.Allocator, s: Settings) !void {
    const dir_path = try configDir(allocator);
    defer allocator.free(dir_path);

    const conf_dir = try Io.Dir.createDirPathOpen(std.Io.Dir.cwd(), io, dir_path, .{});
    defer Io.Dir.close(conf_dir, io);

    var buf = std.ArrayList(u8).empty;
    var buf_writer = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
    defer buf_writer.deinit();
    var sj: std.json.Stringify = .{ .writer = &buf_writer.writer, .options = .{} };
    try sj.write(s);

    const file = try Io.Dir.createFile(conf_dir, io, "settings.json", .{});
    defer file.close(io);
    var result = buf_writer.toArrayList();
    defer result.deinit(allocator);
    try file.writeStreamingAll(io, result.items);
}
