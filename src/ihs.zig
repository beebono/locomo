const std = @import("std");
const Io = std.Io;
const io = std.Options.debug_io;
const c = @import("c.zig").c;

// Host Discovery

pub const DiscoveryCtx = struct {
    allocator: std.mem.Allocator,
    mutex: std.atomic.Mutex,
    hosts: std.ArrayList(c.IHS_HostInfo),
    done: std.atomic.Value(bool),
    should_stop: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator) DiscoveryCtx {
        return .{
            .allocator = allocator,
            .mutex = .unlocked,
            .hosts = std.ArrayList(c.IHS_HostInfo).empty,
            .done = std.atomic.Value(bool).init(false),
            .should_stop = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *DiscoveryCtx) void {
        self.hosts.deinit(self.allocator);
    }

    pub fn stop(self: *DiscoveryCtx) void {
        self.should_stop.store(true, .release);
    }

    pub fn copyHosts(self: *DiscoveryCtx, allocator: std.mem.Allocator) ![]c.IHS_HostInfo {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();
        return allocator.dupe(c.IHS_HostInfo, self.hosts.items);
    }
};

const DiscoveryArgs = struct {
    ctx: *DiscoveryCtx,
    cfg: c.IHS_ClientConfig,
    timeout_ms: u64,
};

fn onHostDiscovered(
    client: ?*c.IHS_Client,
    info: ?*const c.IHS_HostInfo,
    ctx_ptr: ?*anyopaque,
) callconv(.c) void {
    _ = client;
    const ctx: *DiscoveryCtx = @ptrCast(@alignCast(ctx_ptr.?));
    while (!ctx.mutex.tryLock()) {}
    defer ctx.mutex.unlock();
    for (ctx.hosts.items) |existing| {
        if (existing.clientId == info.?.clientId) return;
    }
    ctx.hosts.append(ctx.allocator, info.?.*) catch {};
}

var discovery_callbacks = c.IHS_ClientDiscoveryCallbacks{
    .discovered = onHostDiscovered,
};

fn discoveryThread(args: DiscoveryArgs) void {
    const client = c.IHS_ClientCreate(&args.cfg) orelse return;
    c.IHS_ClientSetDiscoveryCallbacks(client, &discovery_callbacks, args.ctx);
    _ = c.IHS_ClientStartDiscovery(client, 2000);

    const deadline_ns = Io.Clock.awake.now(io).toNanoseconds() + @as(i128, @intCast(args.timeout_ms)) * std.time.ns_per_ms;
    while (!args.ctx.should_stop.load(.acquire) and Io.Clock.awake.now(io).toNanoseconds() < deadline_ns) {
        io.sleep(.fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch {};
    }

    _ = c.IHS_ClientStopDiscovery(client);
    c.IHS_ClientStop(client);
    c.IHS_ClientThreadedJoin(client);
    c.IHS_ClientDestroy(client);
    args.ctx.done.store(true, .release);
}

pub fn startDiscovery(ctx: *DiscoveryCtx, cfg: c.IHS_ClientConfig, timeout_ms: u64) !std.Thread {
    const args = DiscoveryArgs{ .ctx = ctx, .cfg = cfg, .timeout_ms = timeout_ms };
    return std.Thread.spawn(.{}, discoveryThread, .{args});
}

// Authorization

pub const AuthResult = enum { success, denied, failed };

pub const AuthCtx = struct {
    done: std.atomic.Value(bool),
    cancel: std.atomic.Value(bool),
    client: std.atomic.Value(?*c.IHS_Client),
    result: AuthResult,
    steam_id: u64,

    pub fn init() AuthCtx {
        return .{
            .done = std.atomic.Value(bool).init(false),
            .cancel = std.atomic.Value(bool).init(false),
            .client = std.atomic.Value(?*c.IHS_Client).init(null),
            .result = .failed,
            .steam_id = 0,
        };
    }

    pub fn stop(self: *AuthCtx) void {
        self.cancel.store(true, .release);
        if (self.client.load(.acquire)) |client| {
            c.IHS_ClientStop(client);
        }
    }
};

const AuthArgs = struct {
    ctx: *AuthCtx,
    cfg: c.IHS_ClientConfig,
    host: c.IHS_HostInfo,
    pin: [5]u8,
};

fn onAuthSuccess(
    client: ?*c.IHS_Client,
    host: ?*const c.IHS_HostInfo,
    steam_id: u64,
    ctx_ptr: ?*anyopaque,
) callconv(.c) void {
    _ = host;
    const ctx: *AuthCtx = @ptrCast(@alignCast(ctx_ptr.?));
    ctx.steam_id = steam_id;
    ctx.result = .success;
    ctx.done.store(true, .release);
    c.IHS_ClientStop(client.?);
}

fn onAuthFailed(
    client: ?*c.IHS_Client,
    host: ?*const c.IHS_HostInfo,
    result: c.IHS_AuthorizationResult,
    ctx_ptr: ?*anyopaque,
) callconv(.c) void {
    _ = host;
    const ctx: *AuthCtx = @ptrCast(@alignCast(ctx_ptr.?));
    ctx.result = if (result == c.IHS_AuthorizationDenied) .denied else .failed;
    ctx.done.store(true, .release);
    c.IHS_ClientStop(client.?);
}

var auth_callbacks = c.IHS_ClientAuthorizationCallbacks{
    .progress = null,
    .success = onAuthSuccess,
    .failed = onAuthFailed,
};

fn authThread(args: AuthArgs) void {
    const client = c.IHS_ClientCreate(&args.cfg) orelse {
        args.ctx.result = .failed;
        args.ctx.done.store(true, .release);
        return;
    };
    args.ctx.client.store(client, .release);
    if (args.ctx.cancel.load(.acquire)) {
        c.IHS_ClientDestroy(client);
        args.ctx.done.store(true, .release);
        return;
    }
    c.IHS_ClientSetAuthorizationCallbacks(client, &auth_callbacks, args.ctx);
    _ = c.IHS_ClientStartDiscovery(client, 0);
    var auth_host = args.host;
    _ = c.IHS_ClientAuthorizationRequest(client, &auth_host, &args.pin);
    c.IHS_ClientThreadedJoin(client);
    c.IHS_ClientDestroy(client);
}

pub fn startAuthorize(ctx: *AuthCtx, cfg: c.IHS_ClientConfig, host: c.IHS_HostInfo, pin: *const [4]u8) !std.Thread {
    var pin5: [5]u8 = undefined;
    @memcpy(pin5[0..4], pin);
    pin5[4] = 0;
    const args = AuthArgs{ .ctx = ctx, .cfg = cfg, .host = host, .pin = pin5 };
    return std.Thread.spawn(.{}, authThread, .{args});
}

// Stream Requests

pub const StreamResult = enum { success, failed, unauthorized };

pub const StreamRequestCtx = struct {
    done: std.atomic.Value(bool),
    result: StreamResult,
    session_info: c.IHS_SessionInfo,

    pub fn init() StreamRequestCtx {
        return .{
            .done = std.atomic.Value(bool).init(false),
            .result = .failed,
            .session_info = std.mem.zeroes(c.IHS_SessionInfo),
        };
    }
};

const StreamArgs = struct {
    ctx: *StreamRequestCtx,
    cfg: c.IHS_ClientConfig,
    host: c.IHS_HostInfo,
    pin: [16]u8,
    width: i32,
    height: i32,
    audio_channels: i32,
};

fn onStreamSuccess(
    client: ?*c.IHS_Client,
    host: ?*const c.IHS_HostInfo,
    address: ?*const c.IHS_SocketAddress,
    session_key: [*c]const u8,
    session_key_len: usize,
    ctx_ptr: ?*anyopaque,
) callconv(.c) void {
    _ = host;
    const ctx: *StreamRequestCtx = @ptrCast(@alignCast(ctx_ptr.?));
    ctx.session_info.address = address.?.*;
    ctx.session_info.sessionKeyLen = session_key_len;
    const copy_len = @min(session_key_len, 32);
    @memcpy(ctx.session_info.sessionKey[0..copy_len], session_key[0..copy_len]);
    ctx.result = .success;
    ctx.done.store(true, .release);
    c.IHS_ClientStop(client.?);
}

fn onStreamFailed(
    client: ?*c.IHS_Client,
    host: ?*const c.IHS_HostInfo,
    result: c.IHS_StreamingResult,
    ctx_ptr: ?*anyopaque,
) callconv(.c) void {
    _ = host;
    const ctx: *StreamRequestCtx = @ptrCast(@alignCast(ctx_ptr.?));
    ctx.result = if (result == c.IHS_StreamingUnauthorized) .unauthorized else .failed;
    ctx.done.store(true, .release);
    c.IHS_ClientStop(client.?);
}

var stream_callbacks = c.IHS_ClientStreamingCallbacks{
    .progress = null,
    .success = onStreamSuccess,
    .failed = onStreamFailed,
};

fn streamRequestThread(args: StreamArgs) void {
    const client = c.IHS_ClientCreate(&args.cfg) orelse {
        args.ctx.result = .failed;
        args.ctx.done.store(true, .release);
        return;
    };
    c.IHS_ClientSetStreamingCallbacks(client, &stream_callbacks, args.ctx);

    var req = std.mem.zeroes(c.IHS_StreamingRequest);
    @memcpy(&req.pin, &args.pin);
    req.streamingEnable.video = true;
    req.streamingEnable.audio = args.audio_channels != 0;
    req.streamingEnable.input = true;
    req.maxResolution.x = args.width;
    req.maxResolution.y = args.height;
    req.audioChannelCount = args.audio_channels;
    req.streamingInterface = c.IHS_StreamInterfaceBigPicture;

    var host = args.host;
    if (!c.IHS_ClientStreamingRequest(client, &host, &req)) {
        std.log.err("[locomo - session] Host actively refused the stream connection.", .{});
        args.ctx.result = .failed;
        args.ctx.done.store(true, .release);
        c.IHS_ClientDestroy(client);
        return;
    }

    c.IHS_ClientThreadedJoin(client);
    c.IHS_ClientDestroy(client);
}

pub fn startStreamRequest(
    ctx: *StreamRequestCtx,
    cfg: c.IHS_ClientConfig,
    host: c.IHS_HostInfo,
    pin: [16]u8,
    width: i32,
    height: i32,
    audio_channels: i32,
) !std.Thread {
    const args = StreamArgs{ .ctx = ctx, .cfg = cfg, .host = host, .pin = pin, .width = width, .height = height, .audio_channels = audio_channels };
    return std.Thread.spawn(.{}, streamRequestThread, .{args});
}
