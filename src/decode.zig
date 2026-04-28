const std = @import("std");
const c = @import("c.zig").c;
const io = std.Options.debug_io;

const SLOT_CAP: usize = 512 * 1024;
const RING_SLOTS: usize = 32;

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
        if (self.count == 0) return null;
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

pub const VideoFrame = struct {
    y: []u8,
    u: []u8,
    v: []u8,
    width: u32,
    height: u32,
    y_stride: c_int,
    u_stride: c_int,
    v_stride: c_int,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *VideoFrame) void {
        self.allocator.free(self.y);
        self.allocator.free(self.u);
        self.allocator.free(self.v);
    }
};

pub const DecodeCtx = struct {
    allocator: std.mem.Allocator,

    // Video
    video_codec_ctx: ?*c.AVCodecContext,
    video_sws_ctx: ?*c.SwsContext,
    av_frame: ?*c.AVFrame,
    av_yuv_frame: ?*c.AVFrame,
    pending_frame: ?VideoFrame,
    frame_ready: std.atomic.Value(bool),
    video_ring: ?PacketRing,
    video_thread: ?std.Thread,
    video_lost: std.atomic.Value(bool),

    // Audio
    audio_codec_ctx: ?*c.AVCodecContext,
    audio_swr_ctx: ?*c.SwrContext,
    audio_device: c.SDL_AudioDeviceID,
    audio_resample_buf: [*c]u8,
    audio_resample_buf_size: c_int,

    pub fn init(allocator: std.mem.Allocator) DecodeCtx {
        return .{
            .allocator = allocator,
            .video_codec_ctx = null,
            .video_sws_ctx = null,
            .av_frame = null,
            .av_yuv_frame = null,
            .pending_frame = null,
            .frame_ready = std.atomic.Value(bool).init(false),
            .video_ring = null,
            .video_thread = null,
            .video_lost = std.atomic.Value(bool).init(false),
            .audio_codec_ctx = null,
            .audio_swr_ctx = null,
            .audio_device = 0,
            .audio_resample_buf = null,
            .audio_resample_buf_size = 0,
        };
    }

    pub fn deinit(self: *DecodeCtx) void {
        if (self.video_ring) |*r| r.requestStop();
        if (self.video_thread) |t| {
            t.join();
            self.video_thread = null;
        }
        if (self.video_ring) |*r| {
            r.deinit();
            self.video_ring = null;
        }
        if (self.pending_frame) |*f| f.deinit();
        self.pending_frame = null;
        if (self.av_yuv_frame) |f| c.av_frame_free(@ptrCast(@constCast(&f)));
        if (self.av_frame) |f| c.av_frame_free(@ptrCast(@constCast(&f)));
        if (self.video_sws_ctx) |s| c.sws_freeContext(s);
        if (self.video_codec_ctx) |ctx| c.avcodec_free_context(@ptrCast(@constCast(&ctx)));
        if (self.audio_swr_ctx) |s| c.swr_free(@ptrCast(@constCast(&s)));
        if (self.audio_codec_ctx) |ctx| c.avcodec_free_context(@ptrCast(@constCast(&ctx)));
        if (self.audio_resample_buf != null) {
            _ = c.av_free(self.audio_resample_buf);
        }
    }

    pub fn getNextFrame(self: *DecodeCtx, out: *VideoFrame) bool {
        if (!self.frame_ready.load(.acquire)) return false;
        out.* = self.pending_frame.?;
        self.pending_frame = null;
        self.frame_ready.store(false, .release);
        return true;
    }
};

// Callbacks: Video

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

    const sw_codec = c.avcodec_find_decoder(codec_id) orelse return -1;

    // Try hardware decoder if enabled, fall back to software otherwise
    // TODO: Add hw/sw decode setting
    const codec_ctx: *c.AVCodecContext = hw: {
        const hw_name: [*c]const u8 = if (codec_id == c.AV_CODEC_ID_HEVC) "hevc_v4l2m2m" else "h264_v4l2m2m";
        if (c.avcodec_find_decoder_by_name(hw_name)) |hw_codec| {
            if (c.avcodec_alloc_context3(hw_codec)) |hw_ctx| {
                hw_ctx.*.width = @intCast(cfg.width);
                hw_ctx.*.height = @intCast(cfg.height);
                if (cfg.codecDataLen > 0 and cfg.codecData != null) {
                    hw_ctx.*.extradata = @ptrCast(c.av_malloc(cfg.codecDataLen + c.AV_INPUT_BUFFER_PADDING_SIZE));
                    if (hw_ctx.*.extradata != null) {
                        @memcpy(hw_ctx.*.extradata[0..cfg.codecDataLen], cfg.codecData[0..cfg.codecDataLen]);
                        @memset(hw_ctx.*.extradata[cfg.codecDataLen .. cfg.codecDataLen + c.AV_INPUT_BUFFER_PADDING_SIZE], 0);
                        hw_ctx.*.extradata_size = @intCast(cfg.codecDataLen);
                    }
                }
                _ = c.av_hwdevice_ctx_create(&hw_ctx.*.hw_device_ctx, c.AV_HWDEVICE_TYPE_DRM, "/dev/dri/card0", null, 0);
                if (c.avcodec_open2(hw_ctx, hw_codec, null) == 0) break :hw hw_ctx;
                c.avcodec_free_context(@ptrCast(@constCast(&hw_ctx)));
            }
        }
        const sw_ctx = c.avcodec_alloc_context3(sw_codec) orelse return -1;
        sw_ctx.*.width = @intCast(cfg.width);
        sw_ctx.*.height = @intCast(cfg.height);
        if (cfg.codecDataLen > 0 and cfg.codecData != null) {
            sw_ctx.*.extradata = @ptrCast(c.av_malloc(cfg.codecDataLen + c.AV_INPUT_BUFFER_PADDING_SIZE));
            if (sw_ctx.*.extradata != null) {
                @memcpy(sw_ctx.*.extradata[0..cfg.codecDataLen], cfg.codecData[0..cfg.codecDataLen]);
                @memset(sw_ctx.*.extradata[cfg.codecDataLen .. cfg.codecDataLen + c.AV_INPUT_BUFFER_PADDING_SIZE], 0);
                sw_ctx.*.extradata_size = @intCast(cfg.codecDataLen);
            }
        }
        if (c.avcodec_open2(sw_ctx, sw_codec, null) < 0) {
            c.avcodec_free_context(@ptrCast(@constCast(&sw_ctx)));
            return -1;
        }
        break :hw sw_ctx;
    };

    ctx.video_codec_ctx = codec_ctx;
    ctx.av_frame = c.av_frame_alloc();
    ctx.av_yuv_frame = c.av_frame_alloc();

    ctx.video_ring = PacketRing.init(ctx.allocator) catch {
        c.avcodec_free_context(@ptrCast(@constCast(&codec_ctx)));
        ctx.video_codec_ctx = null;
        return -1;
    };
    ctx.video_thread = std.Thread.spawn(.{}, videoDecodeThread, .{ctx}) catch {
        ctx.video_ring.?.deinit();
        ctx.video_ring = null;
        c.avcodec_free_context(@ptrCast(@constCast(&codec_ctx)));
        ctx.video_codec_ctx = null;
        return -1;
    };

    return 0;
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

    if (!ring.tryPush(data_ptr[0..data_len], is_keyframe)) {
        ctx.video_lost.store(true, .release);
        return c.IHS_StreamVideoSubmitReportLost;
    }
    return c.IHS_StreamVideoSubmitOK;
}

fn drainDecoder(ctx: *DecodeCtx) bool {
    const codec_ctx = ctx.video_codec_ctx orelse return false;
    const av_frame = ctx.av_frame orelse return false;
    const yuv_frame = ctx.av_yuv_frame orelse return false;

    var produced = false;
    while (true) {
        const ret = c.avcodec_receive_frame(codec_ctx, av_frame);
        if (ret != 0) break;
        defer c.av_frame_unref(av_frame);
        produced = true;

        const w = av_frame.width;
        const h = av_frame.height;

        const sws = c.sws_getCachedContext(
            ctx.video_sws_ctx,
            w,
            h,
            av_frame.format,
            w,
            h,
            c.AV_PIX_FMT_YUV420P,
            c.SWS_BILINEAR,
            null,
            null,
            null,
        );
        ctx.video_sws_ctx = sws;
        if (sws == null) continue;

        c.av_frame_unref(yuv_frame);
        yuv_frame.width = w;
        yuv_frame.height = h;
        yuv_frame.format = c.AV_PIX_FMT_YUV420P;
        if (c.av_frame_get_buffer(yuv_frame, 1) < 0) continue;
        _ = c.sws_scale(sws, @ptrCast(&av_frame.data), @ptrCast(&av_frame.linesize), 0, h, @ptrCast(&yuv_frame.data), @ptrCast(&yuv_frame.linesize));

        const y_sz: usize = @intCast(yuv_frame.linesize[0] * h);
        const u_sz: usize = @intCast(yuv_frame.linesize[1] * @divTrunc(h, 2));
        const v_sz: usize = @intCast(yuv_frame.linesize[2] * @divTrunc(h, 2));

        const plane_y = ctx.allocator.alloc(u8, y_sz) catch {
            c.av_frame_unref(yuv_frame);
            continue;
        };
        const plane_u = ctx.allocator.alloc(u8, u_sz) catch {
            ctx.allocator.free(plane_y);
            c.av_frame_unref(yuv_frame);
            continue;
        };
        const plane_v = ctx.allocator.alloc(u8, v_sz) catch {
            ctx.allocator.free(plane_y);
            ctx.allocator.free(plane_u);
            c.av_frame_unref(yuv_frame);
            continue;
        };

        const new_frame = VideoFrame{
            .y = plane_y,
            .u = plane_u,
            .v = plane_v,
            .width = @intCast(w),
            .height = @intCast(h),
            .y_stride = yuv_frame.linesize[0],
            .u_stride = yuv_frame.linesize[1],
            .v_stride = yuv_frame.linesize[2],
            .allocator = ctx.allocator,
        };

        @memcpy(new_frame.y, yuv_frame.data[0][0..y_sz]);
        @memcpy(new_frame.u, yuv_frame.data[1][0..u_sz]);
        @memcpy(new_frame.v, yuv_frame.data[2][0..v_sz]);
        c.av_frame_unref(yuv_frame);

        if (ctx.frame_ready.load(.acquire)) {
            ctx.allocator.free(new_frame.y);
            ctx.allocator.free(new_frame.u);
            ctx.allocator.free(new_frame.v);
        } else {
            ctx.pending_frame = new_frame;
            ctx.frame_ready.store(true, .release);
        }
    }
    return produced;
}

fn videoDecodeThread(ctx: *DecodeCtx) void {
    const codec_ctx = ctx.video_codec_ctx orelse return;
    const ring = if (ctx.video_ring) |*r| r else return;

    const scratch = ctx.allocator.alloc(u8, SLOT_CAP) catch return;
    defer ctx.allocator.free(scratch);

    var waiting_for_keyframe = true;

    while (true) {
        var is_keyframe: bool = false;
        const n = ring.pop(scratch, &is_keyframe) orelse return;

        if (ctx.video_lost.swap(false, .acq_rel)) waiting_for_keyframe = true;

        if (waiting_for_keyframe) {
            if (!is_keyframe) continue;
            c.avcodec_flush_buffers(codec_ctx);
            waiting_for_keyframe = false;
        }

        const pkt = c.av_packet_alloc() orelse continue;
        defer c.av_packet_free(@ptrCast(@constCast(&pkt)));
        if (c.av_new_packet(pkt, @intCast(n)) < 0) continue;
        @memcpy(pkt.*.data[0..n], scratch[0..n]);
        if (is_keyframe) pkt.*.flags |= c.AV_PKT_FLAG_KEY;

        const eagain: c_int = -@as(c_int, @intCast(c.EAGAIN));
        send: while (true) {
            const ret = c.avcodec_send_packet(codec_ctx, pkt);
            if (ret == 0) break :send;
            if (ret == eagain) {
                _ = drainDecoder(ctx);
                continue;
            }
            waiting_for_keyframe = true;
            break :send;
        }

        _ = drainDecoder(ctx);
    }
}

fn videoStop(
    session: ?*c.IHS_Session,
    ctx_ptr: ?*anyopaque,
) callconv(.c) void {
    _ = session;
    const ctx: *DecodeCtx = @ptrCast(@alignCast(ctx_ptr.?));

    if (ctx.video_ring) |*r| r.requestStop();
    if (ctx.video_thread) |t| {
        t.join();
        ctx.video_thread = null;
    }
    if (ctx.video_ring) |*r| {
        r.deinit();
        ctx.video_ring = null;
    }

    if (ctx.av_yuv_frame) |f| {
        c.av_frame_free(@ptrCast(@constCast(&f)));
        ctx.av_yuv_frame = null;
    }
    if (ctx.av_frame) |f| {
        c.av_frame_free(@ptrCast(@constCast(&f)));
        ctx.av_frame = null;
    }
    if (ctx.video_sws_ctx) |s| {
        c.sws_freeContext(s);
        ctx.video_sws_ctx = null;
    }
    if (ctx.video_codec_ctx) |cc| {
        c.avcodec_free_context(@ptrCast(@constCast(&cc)));
        ctx.video_codec_ctx = null;
    }
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
    want.samples = 1024;

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
    .setCaptureSize = null,
};

pub const audio_callbacks = c.IHS_StreamAudioCallbacks{
    .start = audioStart,
    .submit = audioSubmit,
    .stop = audioStop,
};
