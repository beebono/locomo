const std = @import("std");
const c = @import("c.zig").c;
const Io = std.Io;
const io = std.Options.debug_io;

inline fn alignUp16(v: c_int) c_int {
    return (v + 15) & ~@as(c_int, 15);
}

const SLOT_CAP: usize = 512 * 1024;
const RING_SLOTS: usize = 32;

fn deviceExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

const PacketSlot = struct {
    data: [SLOT_CAP]u8 = undefined,
    len: usize = 0,
    is_keyframe: bool = false,
};

const PacketRing = struct {
    slots: []PacketSlot,
    head: usize, // Write-to
    tail: usize, // Read-from
    count: usize,
    mutex: std.Io.Mutex,
    not_empty: std.Io.Condition,
    shutdown: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !PacketRing {
        const slots = try allocator.alloc(PacketSlot, RING_SLOTS);
        for (slots) |*s| {
            s.len = 0;
            s.is_keyframe = false;
        }
        return .{
            .slots = slots,
            .head = 0,
            .tail = 0,
            .count = 0,
            .mutex = .init,
            .not_empty = .init,
            .shutdown = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PacketRing) void {
        self.allocator.free(self.slots);
    }

    pub fn reset(self: *PacketRing) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.head = 0;
        self.tail = 0;
        self.count = 0;
        self.shutdown = false;
    }

    pub fn tryPush(self: *PacketRing, src: []const u8, is_keyframe: bool) bool {
        if (src.len > SLOT_CAP) return false;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.count == self.slots.len) return false;
        const slot = &self.slots[self.head];
        @memcpy(slot.data[0..src.len], src);
        slot.len = src.len;
        slot.is_keyframe = is_keyframe;
        self.head = (self.head + 1) % self.slots.len;
        self.count += 1;
        self.not_empty.signal(io);
        return true;
    }

    pub fn pop(self: *PacketRing, dst: []u8, is_keyframe: *bool) ?usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.count == 0 and !self.shutdown) {
            self.not_empty.waitUncancelable(io, &self.mutex);
        }
        if (self.count == 0 or self.shutdown) return null;
        const slot = &self.slots[self.tail];
        const n = slot.len;
        @memcpy(dst[0..n], slot.data[0..n]);
        is_keyframe.* = slot.is_keyframe;
        self.tail = (self.tail + 1) % self.slots.len;
        self.count -= 1;
        return n;
    }

    pub fn requestStop(self: *PacketRing) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.shutdown = true;
        self.not_empty.broadcast(io);
    }
};

pub const Crop = struct {
    top: u32 = 0,
    bottom: u32 = 0,
    left: u32 = 0,
    right: u32 = 0,
};

pub const SwFrame = struct {
    y: []u8,
    uv: []u8,
    y_stride: c_int,
    uv_stride: c_int,
    allocator: std.mem.Allocator,
};

pub const DrmFrame = struct {
    av_frame: ?*c.AVFrame,
};

pub const VideoFrame = struct {
    width: u32,
    height: u32,
    crop: Crop,
    payload: union(enum) {
        sw: SwFrame,
        drm: DrmFrame,
    },

    pub fn deinit(self: *VideoFrame) void {
        switch (self.payload) {
            .sw => |*f| {
                f.allocator.free(f.y);
                f.allocator.free(f.uv);
            },
            .drm => |*f| if (f.av_frame) |fr| {
                var p: ?*c.AVFrame = fr;
                c.av_frame_free(&p);
            },
        }
    }

    pub fn takeDrm(self: *VideoFrame) *c.AVFrame {
        const owned = self.payload.drm.av_frame.?;
        self.payload.drm.av_frame = null;
        return owned;
    }
};

pub const DecodeCtx = struct {
    allocator: std.mem.Allocator,

    // Video
    hw_decode: bool,
    codec_id: c.AVCodecID,
    video_codec_ctx: ?*c.AVCodecContext,
    canvas_w: c_int,
    canvas_h: c_int,
    display_w: c_int,
    display_h: c_int,
    req_w: c_int,
    req_h: c_int,
    last_sps_w: c_int,
    last_sps_h: c_int,
    parser: ?*c.AVCodecParserContext,
    av_frame: ?*c.AVFrame,
    av_sw_frame: ?*c.AVFrame,
    pending_frame: ?VideoFrame,
    frame_ready: bool,
    frame_mutex: std.Io.Mutex,
    frame_event: std.Io.Event,
    video_ring: ?PacketRing,
    video_thread: ?std.Thread,
    thread_exited: std.atomic.Value(bool),
    video_lost: std.atomic.Value(bool),
    need_keyframe: std.atomic.Value(bool),
    pending_resize: std.atomic.Value(bool),
    pending_w: std.atomic.Value(i32),
    pending_h: std.atomic.Value(i32),
    force_disconnect: std.atomic.Value(bool),
    submit_stuck_since_ms: i64,
    consecutive_bad_frames: u32,
    manual_resize: bool,

    // Audio
    audio_codec_ctx: ?*c.AVCodecContext,
    audio_swr_ctx: ?*c.SwrContext,
    audio_device: c.SDL_AudioDeviceID,
    audio_max_queue_bytes: u32,

    pub fn init(allocator: std.mem.Allocator, hw_decode: bool) !DecodeCtx {
        c.av_log_set_level(c.AV_LOG_FATAL);
        const ring = try PacketRing.init(allocator);
        return .{
            .allocator = allocator,
            .hw_decode = hw_decode,
            .codec_id = c.AV_CODEC_ID_NONE,
            .video_codec_ctx = null,
            .canvas_w = 0,
            .canvas_h = 0,
            .display_w = 0,
            .display_h = 0,
            .req_w = 0,
            .req_h = 0,
            .last_sps_w = 0,
            .last_sps_h = 0,
            .parser = null,
            .av_frame = null,
            .av_sw_frame = null,
            .pending_frame = null,
            .frame_ready = false,
            .frame_mutex = .init,
            .frame_event = .unset,
            .video_ring = ring,
            .video_thread = null,
            .thread_exited = std.atomic.Value(bool).init(true),
            .video_lost = std.atomic.Value(bool).init(false),
            .need_keyframe = std.atomic.Value(bool).init(false),
            .pending_resize = std.atomic.Value(bool).init(false),
            .pending_w = std.atomic.Value(i32).init(0),
            .pending_h = std.atomic.Value(i32).init(0),
            .force_disconnect = std.atomic.Value(bool).init(false),
            .submit_stuck_since_ms = 0,
            .audio_codec_ctx = null,
            .audio_swr_ctx = null,
            .audio_device = 0,
            .audio_max_queue_bytes = 0,
            .consecutive_bad_frames = 0,
            .manual_resize = false,
        };
    }

    pub fn deinit(self: *DecodeCtx) void {
        self.teardownVideoThread();
        if (self.thread_exited.load(.acquire)) {
            if (self.video_ring) |*r| {
                r.deinit();
                self.video_ring = null;
            }
        }
        if (self.pending_frame) |*f| f.deinit();
        self.pending_frame = null;
        if (self.audio_swr_ctx) |s| c.swr_free(@ptrCast(@constCast(&s)));
        if (self.audio_codec_ctx) |ctx| c.avcodec_free_context(@ptrCast(@constCast(&ctx)));
    }

    fn publish(self: *DecodeCtx, new_frame: VideoFrame) void {
        {
            self.frame_mutex.lockUncancelable(io);
            defer self.frame_mutex.unlock(io);
            if (self.pending_frame) |*old| old.deinit();
            self.pending_frame = new_frame;
            self.frame_ready = true;
        }
        self.frame_event.set(io);
    }

    fn teardownVideoThread(self: *DecodeCtx) void {
        if (self.video_ring) |*r| r.requestStop();
        const join_deadline_ms: i64 = 250;
        const start_ms = std.Io.Clock.awake.now(io).toMilliseconds();
        while (!self.thread_exited.load(.acquire)) {
            if (std.Io.Clock.awake.now(io).toMilliseconds() - start_ms > join_deadline_ms) break;
            io.sleep(.fromNanoseconds(5 * std.time.ns_per_ms), .awake) catch {};
        }
        const exited = self.thread_exited.load(.acquire);
        if (self.video_thread) |t| {
            if (exited) t.join() else t.detach();
            self.video_thread = null;
        }
        if (exited) {
            if (self.av_sw_frame) |f| c.av_frame_free(@ptrCast(@constCast(&f)));
            if (self.av_frame) |f| c.av_frame_free(@ptrCast(@constCast(&f)));
            if (self.parser) |p| c.av_parser_close(p);
            if (self.video_codec_ctx) |cc| c.avcodec_free_context(@ptrCast(@constCast(&cc)));
        }
        self.av_sw_frame = null;
        self.av_frame = null;
        self.parser = null;
        self.video_codec_ctx = null;
    }

    pub fn waitNextFrame(self: *DecodeCtx, out: *VideoFrame, timeout: std.Io.Timeout) bool {
        self.frame_event.waitTimeout(io, timeout) catch {};
        self.frame_event.reset();

        self.frame_mutex.lockUncancelable(io);
        defer self.frame_mutex.unlock(io);
        if (!self.frame_ready) return false;
        out.* = self.pending_frame.?;
        self.pending_frame = null;
        self.frame_ready = false;
        return true;
    }
};

// Callbacks: Video

fn applyExtradata(cc: *c.AVCodecContext, data: ?[]const u8) void {
    const bytes = data orelse return;
    if (bytes.len == 0) return;
    cc.extradata = @ptrCast(c.av_malloc(bytes.len + c.AV_INPUT_BUFFER_PADDING_SIZE));
    if (cc.extradata == null) return;
    @memcpy(cc.extradata[0..bytes.len], bytes);
    @memset(cc.extradata[bytes.len .. bytes.len + c.AV_INPUT_BUFFER_PADDING_SIZE], 0);
    cc.extradata_size = @intCast(bytes.len);
}

fn getDrmFormat(cc: [*c]c.AVCodecContext, fmts: [*c]const c_int) callconv(.c) c_int {
    _ = cc;
    var p = fmts;
    while (p[0] != -1) : (p += 1) {
        if (p[0] == c.AV_PIX_FMT_DRM_PRIME) return p[0];
    }
    return c.AV_PIX_FMT_NONE;
}

fn openCandidate(w: c_int, h: c_int, extradata: ?[]const u8, name: [*:0]const u8, hw_type: c.AVHWDeviceType) ?*c.AVCodecContext {
    const codec = c.avcodec_find_decoder_by_name(name) orelse return null;
    const cc = c.avcodec_alloc_context3(codec) orelse return null;
    cc.*.width = w;
    cc.*.height = h;
    cc.*.flags |= c.AV_CODEC_FLAG_LOW_DELAY;
    applyExtradata(cc, extradata);
    if (hw_type == c.AV_HWDEVICE_TYPE_DRM) {
        if (c.av_hwdevice_ctx_create(&cc.*.hw_device_ctx, hw_type, "/dev/dri/card0", null, 0) < 0) {
            c.avcodec_free_context(@ptrCast(@constCast(&cc)));
            return null;
        }
        cc.*.get_format = getDrmFormat;
        cc.*.pix_fmt = c.AV_PIX_FMT_DRM_PRIME;
    }
    if (hw_type == c.AV_HWDEVICE_TYPE_V4L2REQUEST) {
        if (c.av_hwdevice_ctx_create(&cc.*.hw_device_ctx, hw_type, null, null, 0) < 0) {
            c.avcodec_free_context(@ptrCast(@constCast(&cc)));
            return null;
        }
    }
    if (c.avcodec_open2(cc, codec, null) < 0) {
        c.avcodec_free_context(@ptrCast(@constCast(&cc)));
        return null;
    }
    return cc;
}

fn openSoftware(w: c_int, h: c_int, extradata: ?[]const u8, codec_id: c.AVCodecID) ?*c.AVCodecContext {
    const codec = c.avcodec_find_decoder(codec_id) orelse return null;
    const cc = c.avcodec_alloc_context3(codec) orelse return null;
    cc.*.width = w;
    cc.*.height = h;
    cc.*.flags |= c.AV_CODEC_FLAG_LOW_DELAY;
    applyExtradata(cc, extradata);
    if (c.avcodec_open2(cc, codec, null) < 0) {
        c.avcodec_free_context(@ptrCast(@constCast(&cc)));
        return null;
    }
    return cc;
}

fn selectCodec(ctx: *DecodeCtx, codec_id: c.AVCodecID, hw_decode: bool, w: c_int, h: c_int, extradata: ?[]const u8) ?*c.AVCodecContext {
    const Candidate = struct {
        name: [*:0]const u8,
        hw_type: c.AVHWDeviceType,
        manual_resize: bool,
    };
    const is_hevc = codec_id == c.AV_CODEC_ID_HEVC;
    const hw_candidates: []const Candidate = if (is_hevc) &.{
        .{ .name = "hevc_v4l2m2m", .hw_type = c.AV_HWDEVICE_TYPE_DRM, .manual_resize = true },
        .{ .name = "hevc", .hw_type = c.AV_HWDEVICE_TYPE_V4L2REQUEST, .manual_resize = true },
    } else &.{
        .{ .name = "h264_v4l2m2m", .hw_type = c.AV_HWDEVICE_TYPE_DRM, .manual_resize = true },
        .{ .name = "h264", .hw_type = c.AV_HWDEVICE_TYPE_V4L2REQUEST, .manual_resize = true },
    };
    if (deviceExists("/dev/mpp_service")) {
        const mpp_cand = if (is_hevc) Candidate{
            .name = "hevc_rkmpp",
            .hw_type = c.AV_HWDEVICE_TYPE_RKMPP,
            .manual_resize = false,
        } else Candidate{
            .name = "h264_rkmpp",
            .hw_type = c.AV_HWDEVICE_TYPE_RKMPP,
            .manual_resize = false,
        };
        if (openCandidate(w, h, extradata, mpp_cand.name, mpp_cand.hw_type)) |cc| {
            ctx.manual_resize = mpp_cand.manual_resize;
            return cc;
        }
    }
    if (hw_decode) {
        for (hw_candidates) |cand| {
            if (openCandidate(w, h, extradata, cand.name, cand.hw_type)) |cc| {
                ctx.manual_resize = cand.manual_resize;
                return cc;
            }
        }
        std.log.warn("[locomo] No HW decoder available, falling back to SW\n", .{});
    }
    return openSoftware(w, h, extradata, codec_id);
}

fn videoStart(
    session: ?*c.IHS_Session,
    config: ?*const c.IHS_StreamVideoConfig,
    ctx_ptr: ?*anyopaque,
) callconv(.c) c_int {
    _ = session;
    const ctx: *DecodeCtx = @ptrCast(@alignCast(ctx_ptr.?));
    const cfg = config.?;

    const codec_id: c.AVCodecID = switch (cfg.codec) {
        c.IHS_StreamVideoCodecHEVC => c.AV_CODEC_ID_HEVC,
        else => c.AV_CODEC_ID_H264,
    };
    ctx.codec_id = codec_id;

    const extradata: ?[]const u8 = if (cfg.codecDataLen > 0 and cfg.codecData != null)
        cfg.codecData[0..cfg.codecDataLen]
    else
        null;
    const width = alignUp16(@intCast(cfg.width));
    const height = alignUp16(@intCast(cfg.height));
    const codec_ctx = selectCodec(ctx, codec_id, ctx.hw_decode, width, height, extradata) orelse return -1;

    ctx.video_codec_ctx = codec_ctx;
    ctx.canvas_w = width;
    ctx.canvas_h = height;
    ctx.display_w = @intCast(cfg.width);
    ctx.display_h = @intCast(cfg.height);
    ctx.req_w = width;
    ctx.req_h = height;
    ctx.parser = c.av_parser_init(@intCast(codec_id));
    ctx.av_frame = c.av_frame_alloc();
    ctx.av_sw_frame = c.av_frame_alloc();

    if (ctx.video_ring) |*r| r.reset();
    ctx.thread_exited.store(false, .release);
    ctx.video_thread = std.Thread.spawn(.{}, videoDecodeThread, .{ctx}) catch {
        c.avcodec_free_context(@ptrCast(@constCast(&codec_ctx)));
        ctx.video_codec_ctx = null;
        return -1;
    };

    return 0;
}

fn videoSetCaptureSize(
    session: ?*c.IHS_Session,
    width: c_int,
    height: c_int,
    ctx_ptr: ?*anyopaque,
) callconv(.c) c_int {
    _ = session;
    const ctx: *DecodeCtx = @ptrCast(@alignCast(ctx_ptr.?));
    ctx.canvas_w = width;
    ctx.canvas_h = height;
    ctx.display_w = width;
    ctx.display_h = height;
    ctx.pending_w.store(alignUp16(@intCast(width)), .release);
    ctx.pending_h.store(alignUp16(@intCast(height)), .release);
    ctx.pending_resize.store(true, .release);
    ctx.video_lost.store(true, .release);
    ctx.need_keyframe.store(true, .release);
    return 0;
}

fn tripFailsafe(ctx: *DecodeCtx, now_ms: i64) bool {
    const failsafe_ms: i64 = 1000;
    if (ctx.submit_stuck_since_ms == 0) {
        ctx.submit_stuck_since_ms = now_ms;
        return false;
    }
    return now_ms - ctx.submit_stuck_since_ms > failsafe_ms;
}

fn videoSubmit(
    session: ?*c.IHS_Session,
    data: ?*c.IHS_Buffer,
    flags: c.IHS_StreamVideoFrameFlag,
    ctx_ptr: ?*anyopaque,
) callconv(.c) c.IHS_StreamVideoSubmitResult {
    _ = session;
    const ctx: *DecodeCtx = @ptrCast(@alignCast(ctx_ptr.?));
    const ring = if (ctx.video_ring) |*r| r else return c.IHS_StreamVideoSubmitError;

    const buf = data.?;
    const data_ptr = c.IHS_BufferPointer(buf);
    const data_len = buf.size;
    const is_keyframe = (flags & c.IHS_StreamVideoFrameKeyFrame) != 0;
    const now_ms = std.Io.Clock.awake.now(io).toMilliseconds();

    if (ctx.need_keyframe.load(.acquire)) {
        if (!is_keyframe) {
            if (tripFailsafe(ctx, now_ms)) ctx.force_disconnect.store(true, .release);
            return c.IHS_StreamVideoSubmitReportLost;
        }
        ctx.need_keyframe.store(false, .release);
    }

    if (!ring.tryPush(data_ptr[0..data_len], is_keyframe)) {
        ctx.video_lost.store(true, .release);
        ctx.need_keyframe.store(true, .release);
        if (tripFailsafe(ctx, now_ms)) ctx.force_disconnect.store(true, .release);
        return c.IHS_StreamVideoSubmitReportLost;
    }

    ctx.submit_stuck_since_ms = 0;
    return c.IHS_StreamVideoSubmitOK;
}

fn populateFrame(ctx: *DecodeCtx) bool {
    const av_frame = ctx.av_frame orelse return false;
    const sw_frame = ctx.av_sw_frame orelse return false;
    defer c.av_frame_unref(av_frame);

    if (ctx.hw_decode and av_frame.format != c.AV_PIX_FMT_DRM_PRIME) {
        std.log.warn("[locomo] HW decode was set, but received a non-DRM frame. Falling back to SW decode.\n", .{});
        ctx.hw_decode = false;
        rebuildCodec(ctx, ctx.canvas_w, ctx.canvas_h);
        return false;
    }

    if (av_frame.format == c.AV_PIX_FMT_DRM_PRIME) {
        const cloned = c.av_frame_clone(av_frame) orelse return false;
        const w = av_frame.width;
        const h = av_frame.height;
        const new_frame = VideoFrame{
            .width = @intCast(w),
            .height = @intCast(h),
            .crop = .{
                .top = 0,
                .bottom = if (ctx.display_h > 0 and ctx.display_h < h) @intCast(h - ctx.display_h) else 0,
                .left = 0,
                .right = if (ctx.display_w > 0 and ctx.display_w < w) @intCast(w - ctx.display_w) else 0,
            },
            .payload = .{ .drm = .{ .av_frame = cloned } },
        };
        ctx.publish(new_frame);
        return true;
    }

    const is_hw = av_frame.hw_frames_ctx != null;
    if (is_hw) {
        c.av_frame_unref(sw_frame);
        if (c.av_hwframe_transfer_data(sw_frame, av_frame, 0) < 0) return false;
    }
    const src: *c.AVFrame = if (is_hw) sw_frame else av_frame;
    defer if (is_hw) c.av_frame_unref(sw_frame);

    const w = src.width;
    const h = src.height;

    const uv_h = @divTrunc(h, 2);
    const y_stride = src.linesize[0];
    const y_sz: usize = @intCast(y_stride * h);

    const plane_y = ctx.allocator.alloc(u8, y_sz) catch return false;
    @memcpy(plane_y, src.data[0][0..y_sz]);

    var uv_stride: c_int = 0;
    var plane_uv: []u8 = undefined;
    switch (src.format) {
        c.AV_PIX_FMT_NV12 => {
            uv_stride = src.linesize[1];
            const uv_sz: usize = @intCast(uv_stride * uv_h);
            plane_uv = ctx.allocator.alloc(u8, uv_sz) catch {
                ctx.allocator.free(plane_y);
                return false;
            };
            @memcpy(plane_uv, src.data[1][0..uv_sz]);
        },
        c.AV_PIX_FMT_YUV420P => {
            uv_stride = w;
            const uv_sz: usize = @intCast(uv_stride * uv_h);
            plane_uv = ctx.allocator.alloc(u8, uv_sz) catch {
                ctx.allocator.free(plane_y);
                return false;
            };
            const u_stride: usize = @intCast(src.linesize[1]);
            const v_stride: usize = @intCast(src.linesize[2]);
            const half_w: usize = @intCast(@divTrunc(w, 2));
            const dst_stride: usize = @intCast(uv_stride);
            var row: usize = 0;
            while (row < @as(usize, @intCast(uv_h))) : (row += 1) {
                const u_row = src.data[1][row * u_stride ..];
                const v_row = src.data[2][row * v_stride ..];
                const dst = plane_uv[row * dst_stride ..];
                var col: usize = 0;
                while (col < half_w) : (col += 1) {
                    dst[col * 2] = u_row[col];
                    dst[col * 2 + 1] = v_row[col];
                }
            }
        },
        else => {
            ctx.allocator.free(plane_y);
            return false;
        },
    }

    // Don't allow garbage frames to render
    if (std.mem.allEqual(u8, plane_uv, 0)) {
        ctx.allocator.free(plane_y);
        ctx.allocator.free(plane_uv);
        return false;
    }

    const new_frame = VideoFrame{
        .width = @intCast(w),
        .height = @intCast(h),
        .crop = .{
            .top = 0,
            .bottom = if (ctx.display_h > 0 and ctx.display_h < h) @intCast(h - ctx.display_h) else 0,
            .left = 0,
            .right = if (ctx.display_w > 0 and ctx.display_w < w) @intCast(w - ctx.display_w) else 0,
        },
        .payload = .{ .sw = .{
            .y = plane_y,
            .uv = plane_uv,
            .y_stride = y_stride,
            .uv_stride = uv_stride,
            .allocator = ctx.allocator,
        } },
    };
    ctx.publish(new_frame);
    return true;
}

fn drainFrames(ctx: *DecodeCtx, codec_ctx: ?*c.AVCodecContext) bool {
    while (!ctx.force_disconnect.load(.acquire)) {
        const r = c.avcodec_receive_frame(codec_ctx, ctx.av_frame);
        if (r == 0) {
            if (populateFrame(ctx)) {
                ctx.consecutive_bad_frames = 0;
            } else {
                ctx.consecutive_bad_frames += 1;
                if (ctx.consecutive_bad_frames >= 30) {
                    ctx.force_disconnect.store(true, .release);
                }
            }
            continue;
        }
        if (r == c.AVERROR(c.EAGAIN) or r == c.AVERROR_EOF) break;
        // Actual error receiving frame
        return false;
    }
    return true;
}

fn rebuildCodec(ctx: *DecodeCtx, w: c_int, h: c_int) void {
    if (ctx.video_codec_ctx) |old| {
        _ = c.avcodec_send_packet(old, null);
        _ = c.avcodec_receive_frame(old, ctx.av_frame);
        var old_mut: ?*c.AVCodecContext = old;
        c.avcodec_free_context(&old_mut);
    }
    ctx.video_codec_ctx = null;
    const aligned_w = alignUp16(@intCast(w));
    const aligned_h = alignUp16(@intCast(h));
    const cc = selectCodec(ctx, ctx.codec_id, ctx.hw_decode, aligned_w, aligned_h, null) orelse return;
    ctx.video_codec_ctx = cc;
    ctx.req_w = aligned_w;
    ctx.req_h = aligned_h;
    ctx.consecutive_bad_frames = 0;
}

fn videoDecodeThread(ctx: *DecodeCtx) void {
    defer ctx.thread_exited.store(true, .release);
    const ring = if (ctx.video_ring) |*r| r else return;

    const scratch = ctx.allocator.alloc(u8, SLOT_CAP) catch return;
    defer ctx.allocator.free(scratch);

    var waiting_for_keyframe = true;

    while (!ctx.force_disconnect.load(.acquire)) {
        var is_keyframe: bool = false;
        const n = ring.pop(scratch, &is_keyframe) orelse return;

        if (ctx.video_lost.swap(false, .acq_rel)) waiting_for_keyframe = true;

        if (ctx.parser) |parser| {
            if (ctx.video_codec_ctx) |cc| {
                var out_data: [*c]u8 = null;
                var out_size: c_int = 0;
                _ = c.av_parser_parse2(
                    parser,
                    cc,
                    &out_data,
                    &out_size,
                    scratch.ptr,
                    @intCast(n),
                    c.AV_NOPTS_VALUE,
                    c.AV_NOPTS_VALUE,
                    0,
                );
                if (parser.*.width > 0 and parser.*.height > 0) {
                    ctx.last_sps_w = alignUp16(parser.*.width);
                    ctx.last_sps_h = alignUp16(parser.*.height);
                }
            }
        }

        if (waiting_for_keyframe) {
            if (!is_keyframe) continue;
            if (ctx.pending_resize.load(.acquire)) {
                const new_w = ctx.pending_w.load(.acquire);
                const new_h = ctx.pending_h.load(.acquire);
                const dims_changed = new_w != ctx.req_w or new_h != ctx.req_h;
                if (dims_changed and ctx.manual_resize) {
                    rebuildCodec(ctx, new_w, new_h);
                    ctx.need_keyframe.store(true, .release);
                    continue;
                }
            }
            if (ctx.video_codec_ctx) |cc| c.avcodec_flush_buffers(cc);
            ctx.pending_resize.store(false, .release);
            waiting_for_keyframe = false;
        }

        const codec_ctx = ctx.video_codec_ctx orelse return;

        const pkt = c.av_packet_alloc() orelse continue;
        defer c.av_packet_free(@ptrCast(@constCast(&pkt)));
        if (c.av_new_packet(pkt, @intCast(n)) < 0) continue;
        @memcpy(pkt.*.data[0..n], scratch[0..n]);
        if (is_keyframe) pkt.*.flags |= c.AV_PKT_FLAG_KEY;

        var send_retries: u32 = 0;
        send: while (!ctx.force_disconnect.load(.acquire)) {
            const sret = c.avcodec_send_packet(codec_ctx, pkt);
            if (sret == 0) break :send;
            if (sret == c.AVERROR(c.EAGAIN)) {
                if (drainFrames(ctx, codec_ctx)) {
                    send_retries += 1;
                    if (send_retries < 4) continue :send;
                    // Secondary failsafe, shouldn't need a full codec rebuild here
                    waiting_for_keyframe = true;
                    ctx.need_keyframe.store(true, .release);
                    continue;
                }
            }
            if (ctx.manual_resize) {
                const fb_w = if (ctx.last_sps_w > 0) ctx.last_sps_w else ctx.canvas_w;
                const fb_h = if (ctx.last_sps_h > 0) ctx.last_sps_h else ctx.canvas_h;
                rebuildCodec(ctx, fb_w, fb_h);
            } else {
                if (ctx.video_codec_ctx) |cc| c.avcodec_flush_buffers(cc);
            }
            waiting_for_keyframe = true;
            ctx.need_keyframe.store(true, .release);
            continue;
        }

        _ = drainFrames(ctx, codec_ctx);
    }
}

fn videoStop(
    session: ?*c.IHS_Session,
    ctx_ptr: ?*anyopaque,
) callconv(.c) void {
    _ = session;
    const ctx: *DecodeCtx = @ptrCast(@alignCast(ctx_ptr.?));
    ctx.teardownVideoThread();
}

// Callbacks: Audio

fn audioStart(
    session: ?*c.IHS_Session,
    config: ?*const c.IHS_StreamAudioConfig,
    ctx_ptr: ?*anyopaque,
) callconv(.c) c_int {
    _ = session;
    const ctx: *DecodeCtx = @ptrCast(@alignCast(ctx_ptr.?));
    const cfg = config.?;

    const codec_id: c.AVCodecID = switch (cfg.codec) {
        c.IHS_StreamAudioCodecOpus => c.AV_CODEC_ID_OPUS,
        c.IHS_StreamAudioCodecAAC => c.AV_CODEC_ID_AAC,
        c.IHS_StreamAudioCodecVorbis => c.AV_CODEC_ID_VORBIS,
        c.IHS_StreamAudioCodecMP3 => c.AV_CODEC_ID_MP3,
        else => c.AV_CODEC_ID_PCM_S16LE,
    };

    const codec = c.avcodec_find_decoder(codec_id) orelse return -1;
    const codec_ctx = c.avcodec_alloc_context3(codec) orelse return -1;
    codec_ctx.*.sample_rate = @intCast(cfg.frequency);
    c.av_channel_layout_default(&codec_ctx.*.ch_layout, @intCast(cfg.channels));

    if (cfg.codecDataLen > 0 and cfg.codecData != null) {
        codec_ctx.*.extradata = @ptrCast(c.av_malloc(cfg.codecDataLen + c.AV_INPUT_BUFFER_PADDING_SIZE));
        if (codec_ctx.*.extradata != null) {
            @memcpy(codec_ctx.*.extradata[0..cfg.codecDataLen], cfg.codecData[0..cfg.codecDataLen]);
            @memset(codec_ctx.*.extradata[cfg.codecDataLen .. cfg.codecDataLen + c.AV_INPUT_BUFFER_PADDING_SIZE], 0);
            codec_ctx.*.extradata_size = @intCast(cfg.codecDataLen);
        }
    }

    if (c.avcodec_open2(codec_ctx, codec, null) < 0) {
        c.avcodec_free_context(@ptrCast(@constCast(&codec_ctx)));
        return -1;
    }
    ctx.audio_codec_ctx = codec_ctx;

    var want = std.mem.zeroes(c.SDL_AudioSpec);
    want.freq = @intCast(cfg.frequency);
    want.format = c.AUDIO_S16SYS;
    want.channels = 2;
    want.samples = 512;

    // Prevent audio from queueing up too much
    ctx.audio_max_queue_bytes = @intCast((cfg.frequency * 4 * 80) / 1000);

    ctx.audio_device = c.SDL_OpenAudioDevice(null, 0, &want, null, 0);
    if (ctx.audio_device == 0) {
        c.avcodec_free_context(@ptrCast(@constCast(&codec_ctx)));
        ctx.audio_codec_ctx = null;
        return -1;
    }
    c.SDL_PauseAudioDevice(ctx.audio_device, 0);

    const swr = c.swr_alloc();
    if (swr == null) return 0;
    var in_layout: c.AVChannelLayout = undefined;
    var out_layout: c.AVChannelLayout = undefined;
    c.av_channel_layout_default(&in_layout, @intCast(cfg.channels));
    c.av_channel_layout_default(&out_layout, 2);
    _ = c.av_opt_set_chlayout(swr, "in_chlayout", &in_layout, 0);
    _ = c.av_opt_set_chlayout(swr, "out_chlayout", &out_layout, 0);
    _ = c.av_opt_set_int(swr, "in_sample_rate", @intCast(cfg.frequency), 0);
    _ = c.av_opt_set_int(swr, "out_sample_rate", @intCast(cfg.frequency), 0);
    _ = c.av_opt_set_sample_fmt(swr, "in_sample_fmt", codec_ctx.*.sample_fmt, 0);
    _ = c.av_opt_set_sample_fmt(swr, "out_sample_fmt", c.AV_SAMPLE_FMT_S16, 0);
    if (c.swr_init(swr) < 0) {
        c.swr_free(@ptrCast(@constCast(&swr)));
    } else {
        ctx.audio_swr_ctx = swr;
    }
    return 0;
}

fn audioSubmit(
    session: ?*c.IHS_Session,
    data: ?*c.IHS_Buffer,
    ctx_ptr: ?*anyopaque,
) callconv(.c) c_int {
    _ = session;
    const ctx: *DecodeCtx = @ptrCast(@alignCast(ctx_ptr.?));
    const codec_ctx = ctx.audio_codec_ctx orelse return 0;

    const buf = data.?;
    const data_ptr = c.IHS_BufferPointer(buf);
    const data_len = buf.size;

    const pkt = c.av_packet_alloc() orelse return 0;
    defer c.av_packet_free(@ptrCast(@constCast(&pkt)));
    if (c.av_new_packet(pkt, @intCast(data_len)) < 0) return 0;
    @memcpy(pkt.*.data[0..data_len], data_ptr[0..data_len]);

    if (c.avcodec_send_packet(codec_ctx, pkt) < 0) return 0;

    const frame = c.av_frame_alloc() orelse return 0;
    defer c.av_frame_free(@ptrCast(@constCast(&frame)));

    while (c.avcodec_receive_frame(codec_ctx, frame) == 0) {
        // If the queue has grown past the cap, drop it to resync to "now".
        if (c.SDL_GetQueuedAudioSize(ctx.audio_device) > ctx.audio_max_queue_bytes) {
            c.SDL_ClearQueuedAudio(ctx.audio_device);
        }
        if (ctx.audio_swr_ctx) |swr| {
            const out_samples = c.swr_get_out_samples(swr, frame.*.nb_samples);
            var out_buf: [*c]u8 = null;
            var out_linesize: c_int = 0;
            if (c.av_samples_alloc(&out_buf, &out_linesize, 2, out_samples, c.AV_SAMPLE_FMT_S16, 0) >= 0) {
                const converted = c.swr_convert(swr, &out_buf, out_samples, @ptrCast(@constCast(&frame.*.data)), frame.*.nb_samples);
                if (converted > 0) {
                    const byte_count: usize = @intCast(converted * 2 * @sizeOf(c_short));
                    _ = c.SDL_QueueAudio(ctx.audio_device, out_buf, @intCast(byte_count));
                }
                c.av_free(out_buf);
            }
        } else {
            if (frame.*.format == c.AV_SAMPLE_FMT_S16) {
                const byte_count: usize = @intCast(frame.*.nb_samples * frame.*.ch_layout.nb_channels * @sizeOf(c_short));
                _ = c.SDL_QueueAudio(ctx.audio_device, &frame.*.data[0], @intCast(byte_count));
            }
        }
        c.av_frame_unref(frame);
    }
    return 0;
}

fn audioStop(
    session: ?*c.IHS_Session,
    ctx_ptr: ?*anyopaque,
) callconv(.c) void {
    _ = session;
    const ctx: *DecodeCtx = @ptrCast(@alignCast(ctx_ptr.?));
    if (ctx.audio_device != 0) {
        c.SDL_CloseAudioDevice(ctx.audio_device);
        ctx.audio_device = 0;
    }
    if (ctx.audio_swr_ctx) |s| {
        c.swr_free(@ptrCast(@constCast(&s)));
        ctx.audio_swr_ctx = null;
    }
    if (ctx.audio_codec_ctx) |cc| {
        c.avcodec_free_context(@ptrCast(@constCast(&cc)));
        ctx.audio_codec_ctx = null;
    }
}

// Exported callbacks

pub const video_callbacks = c.IHS_StreamVideoCallbacks{
    .start = videoStart,
    .submit = videoSubmit,
    .stop = videoStop,
    .setCaptureSize = videoSetCaptureSize,
};

pub const audio_callbacks = c.IHS_StreamAudioCallbacks{
    .start = audioStart,
    .submit = audioSubmit,
    .stop = audioStop,
};
