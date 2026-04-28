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

pub const Settings = struct {
    width: u32 = 1280,
    height: u32 = 720,
    max_bandwidth_kbps: u32 = 0,
    enable_hevc: bool = false,
};

const DeviceJson = struct { device_id: u64, secret_key: [32]u8, device_name: []const u8 };
const PairedJson = struct { hostname: []const u8, client_id: u64, instance_id: u64, steam_id: u64 };

fn configDir(allocator: std.mem.Allocator) ![]const u8 {
    const home_ptr = std.c.getenv("HOME") orelse return error.HomeNotSet;
    const home = std.mem.span(home_ptr);
    return std.fs.path.join(allocator, &.{ home, ".config", "locomo" });
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

    try Io.Dir.cwd().createDirPath(io, dir_path);

    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "device.json" });
    defer allocator.free(file_path);

    if (Io.Dir.openFileAbsolute(io, file_path, .{})) |file| {
        defer file.close(io);
        const data = try readFileToEnd(allocator, file);
        defer allocator.free(data);
        const parsed = std.json.parseFromSlice(DeviceJson, allocator, data, .{}) catch {
            return generateAndSave(allocator, file_path);
        };
        defer parsed.deinit();
        return fromDeviceJson(parsed.value);
    } else |_| {
        return generateAndSave(allocator, file_path);
    }
}

fn generateAndSave(allocator: std.mem.Allocator, file_path: []const u8) !DeviceConfig {
    var cfg: DeviceConfig = undefined;
    const rng_impl: std.Random.IoSource = .{ .io = io };
    const rng = rng_impl.interface();
    cfg.device_id = rng.int(u64);
    io.random(&cfg.secret_key);
    @memset(&cfg.device_name, 0);
    const name = "Locomo";
    @memcpy(cfg.device_name[0..name.len], name);

    try saveDeviceConfig(allocator, file_path, cfg);
    return cfg;
}

fn saveDeviceConfig(allocator: std.mem.Allocator, file_path: []const u8, cfg: DeviceConfig) !void {
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

    const file = try Io.Dir.createFileAbsolute(io, file_path, .{});
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
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "paired.json" });
    defer allocator.free(file_path);

    const file = Io.Dir.openFileAbsolute(io, file_path, .{}) catch return null;
    defer file.close(io);
    const data = try readFileToEnd(allocator, file);
    defer allocator.free(data);
    const parsed = std.json.parseFromSlice(PairedJson, allocator, data, .{}) catch return null;
    defer parsed.deinit();
    return fromPairedJson(parsed.value);
}

pub fn savePaired(allocator: std.mem.Allocator, host: PairedHost) !void {
    const dir_path = try configDir(allocator);
    defer allocator.free(dir_path);
    try Io.Dir.cwd().createDirPath(io, dir_path);
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "paired.json" });
    defer allocator.free(file_path);

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

    const file = try Io.Dir.createFileAbsolute(io, file_path, .{});
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
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "settings.json" });
    defer allocator.free(file_path);

    const file = Io.Dir.openFileAbsolute(io, file_path, .{}) catch return Settings{};
    defer file.close(io);
    const data = readFileToEnd(allocator, file) catch return Settings{};
    defer allocator.free(data);
    const parsed = std.json.parseFromSlice(Settings, allocator, data, .{}) catch return Settings{};
    defer parsed.deinit();
    return parsed.value;
}

pub fn saveSettings(allocator: std.mem.Allocator, s: Settings) !void {
    const dir_path = try configDir(allocator);
    defer allocator.free(dir_path);
    try Io.Dir.cwd().createDirPath(io, dir_path);
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "settings.json" });
    defer allocator.free(file_path);

    var buf = std.ArrayList(u8).empty;
    var buf_writer = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
    defer buf_writer.deinit();
    var sj: std.json.Stringify = .{ .writer = &buf_writer.writer, .options = .{} };
    try sj.write(s);

    const file = try Io.Dir.createFileAbsolute(io, file_path, .{});
    defer file.close(io);
    var result = buf_writer.toArrayList();
    defer result.deinit(allocator);
    try file.writeStreamingAll(io, result.items);
}
