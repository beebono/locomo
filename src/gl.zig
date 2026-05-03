const std = @import("std");
const c = @import("c.zig").c;
const decode = @import("decode.zig");

pub const PFNEGLCREATEIMAGEKHRPROC = *const fn (
    dpy: c.EGLDisplay,
    ctx: c.EGLContext,
    target: c.EGLenum,
    buffer: c.EGLClientBuffer,
    attrib_list: [*c]const c.EGLint,
) callconv(.c) c.EGLImageKHR;

pub const PFNEGLDESTROYIMAGEKHRPROC = *const fn (
    dpy: c.EGLDisplay,
    image: c.EGLImageKHR,
) callconv(.c) c.EGLBoolean;

pub const PFNGLEGLIMAGETARGETTEXTURE2DOESPROC = *const fn (
    target: c.GLenum,
    image: c.GLeglImageOES,
) callconv(.c) void;

pub const GlCtx = struct {
    egl_display: c.EGLDisplay,
    egl_context: c.EGLContext,
    eglCreateImageKHR: PFNEGLCREATEIMAGEKHRPROC,
    eglDestroyImageKHR: PFNEGLDESTROYIMAGEKHRPROC,
    glEGLImageTargetTexture2DOES: PFNGLEGLIMAGETARGETTEXTURE2DOESPROC,
    has_modifiers: bool,
};

pub fn init() !GlCtx {
    const display = c.eglGetCurrentDisplay();
    const context = c.eglGetCurrentContext();
    if (display == c.EGL_NO_DISPLAY or context == c.EGL_NO_CONTEXT) {
        return error.NoEglContext;
    }

    const exts_raw = c.eglQueryString(display, c.EGL_EXTENSIONS) orelse {
        return error.EglQueryFailed;
    };
    const exts = std.mem.span(exts_raw);
    if (std.mem.indexOf(u8, exts, "EGL_EXT_image_dma_buf_import") == null) {
        return error.NoDmaBufImport;
    }
    const has_modifiers = std.mem.indexOf(u8, exts, "EGL_EXT_image_dma_buf_import_modifiers") != null;

    const create = @as(?PFNEGLCREATEIMAGEKHRPROC, @ptrCast(c.eglGetProcAddress("eglCreateImageKHR"))) orelse return error.MissingEglCreateImageKHR;
    const destroy = @as(?PFNEGLDESTROYIMAGEKHRPROC, @ptrCast(c.eglGetProcAddress("eglDestroyImageKHR"))) orelse return error.MissingEglDestroyImageKHR;
    const tex_target = @as(?PFNGLEGLIMAGETARGETTEXTURE2DOESPROC, @ptrCast(c.eglGetProcAddress("glEGLImageTargetTexture2DOES"))) orelse return error.MissingGlEglImageTarget;

    return .{
        .egl_display = display,
        .egl_context = context,
        .eglCreateImageKHR = create,
        .eglDestroyImageKHR = destroy,
        .glEGLImageTargetTexture2DOES = tex_target,
        .has_modifiers = has_modifiers,
    };
}

// Video renderer

const DRM_FORMAT_MOD_INVALID: u64 = 0x00ffffffffffffff;

inline fn fourcc(a: u8, b: u8, c0: u8, d: u8) u32 {
    return @as(u32, a) | (@as(u32, b) << 8) | (@as(u32, c0) << 16) | (@as(u32, d) << 24);
}

const DRM_FORMAT_R8: u32 = fourcc('R', '8', ' ', ' ');
const DRM_FORMAT_GR88: u32 = fourcc('G', 'R', '8', '8');
const DRM_FORMAT_NV12: u32 = fourcc('N', 'V', '1', '2');

const vert_src: [:0]const u8 =
    \\attribute vec2 a_pos;
    \\attribute vec2 a_uv;
    \\varying vec2 v_uv;
    \\void main() {
    \\    v_uv = a_uv;
    \\    gl_Position = vec4(a_pos, 0.0, 1.0);
    \\}
;

const frag_src: [:0]const u8 =
    \\precision mediump float;
    \\varying vec2 v_uv;
    \\uniform sampler2D u_tex_y;
    \\uniform sampler2D u_tex_uv;
    \\uniform vec4 u_crop;
    \\void main() {
    \\    vec2 uv = v_uv * u_crop.xy + u_crop.zw;
    \\    float y = texture2D(u_tex_y, uv).r;
    \\    vec2 cbcr = texture2D(u_tex_uv, uv).rg - vec2(0.5019608);
    \\    y = (y - 0.0627451) * 1.16438356;
    \\    float r = y + 1.5748 * cbcr.y;
    \\    float g = y - 0.1873 * cbcr.x - 0.4681 * cbcr.y;
    \\    float b = y + 1.8556 * cbcr.x;
    \\    gl_FragColor = vec4(r, g, b, 1.0);
    \\}
;

const quad_verts = [_]f32{
    -1.0, -1.0, 0.0, 1.0,
    1.0,  -1.0, 1.0, 1.0,
    -1.0, 1.0,  0.0, 0.0,
    1.0,  1.0,  1.0, 0.0,
};

pub const GlRect = struct { x: c_int, y: c_int, w: c_int, h: c_int };

pub const VideoRenderer = struct {
    gl: GlCtx,
    program: c.GLuint,
    vbo: c.GLuint,
    tex_y: c.GLuint,
    tex_uv: c.GLuint,
    a_pos: c.GLint,
    a_uv: c.GLint,
    u_tex_y: c.GLint,
    u_tex_uv: c.GLint,
    u_crop: c.GLint,
    in_flight: ?*c.AVFrame,

    pub fn init(gl: GlCtx) !VideoRenderer {
        const vs = try compileShader(c.GL_VERTEX_SHADER, vert_src);
        errdefer c.glDeleteShader(vs);
        const fs = try compileShader(c.GL_FRAGMENT_SHADER, frag_src);
        errdefer c.glDeleteShader(fs);

        const prog = c.glCreateProgram();
        if (prog == 0) return error.GlProgramAlloc;
        errdefer c.glDeleteProgram(prog);
        c.glAttachShader(prog, vs);
        c.glAttachShader(prog, fs);
        c.glLinkProgram(prog);
        var status: c.GLint = 0;
        c.glGetProgramiv(prog, c.GL_LINK_STATUS, &status);
        if (status == 0) {
            var log: [512]u8 = undefined;
            var n: c.GLsizei = 0;
            c.glGetProgramInfoLog(prog, log.len, &n, &log);
            return error.GlLinkFailed;
        }
        c.glDeleteShader(vs);
        c.glDeleteShader(fs);

        var vbo: c.GLuint = 0;
        c.glGenBuffers(1, &vbo);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, vbo);
        c.glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(quad_verts)), &quad_verts, c.GL_STATIC_DRAW);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);

        var texs: [2]c.GLuint = .{ 0, 0 };
        c.glGenTextures(2, &texs);
        for (texs) |t| {
            c.glBindTexture(c.GL_TEXTURE_2D, t);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        }
        c.glBindTexture(c.GL_TEXTURE_2D, 0);

        return .{
            .gl = gl,
            .program = prog,
            .vbo = vbo,
            .tex_y = texs[0],
            .tex_uv = texs[1],
            .a_pos = c.glGetAttribLocation(prog, "a_pos"),
            .a_uv = c.glGetAttribLocation(prog, "a_uv"),
            .u_tex_y = c.glGetUniformLocation(prog, "u_tex_y"),
            .u_tex_uv = c.glGetUniformLocation(prog, "u_tex_uv"),
            .u_crop = c.glGetUniformLocation(prog, "u_crop"),
            .in_flight = null,
        };
    }

    pub fn deinit(self: *VideoRenderer) void {
        if (self.in_flight) |f| {
            var p: ?*c.AVFrame = f;
            c.av_frame_free(&p);
            self.in_flight = null;
        }
        var texs = [_]c.GLuint{ self.tex_y, self.tex_uv };
        c.glDeleteTextures(2, &texs);
        c.glDeleteBuffers(1, &self.vbo);
        c.glDeleteProgram(self.program);
    }

    pub fn drawDrmFrame(
        self: *VideoRenderer,
        av_frame: *c.AVFrame,
        frame_w: u32,
        frame_h: u32,
        crop: decode.Crop,
        viewport: GlRect,
    ) bool {
        const desc: *c.AVDRMFrameDescriptor = @ptrCast(@alignCast(av_frame.data[0]));
        if (desc.nb_layers < 1) {
            self.releaseFrame(av_frame);
            return false;
        }

        const Plane = struct { fd: c_int, offset: isize, pitch: isize, mod: u64, fc: u32 };
        var planes: [2]Plane = undefined;

        if (desc.nb_layers == 1 and desc.layers[0].format == DRM_FORMAT_NV12) {
            const layer = &desc.layers[0];
            if (layer.nb_planes < 2) {
                self.releaseFrame(av_frame);
                return false;
            }
            const fcs = [_]u32{ DRM_FORMAT_R8, DRM_FORMAT_GR88 };
            for (0..2) |i| {
                const p = &layer.planes[i];
                const obj = &desc.objects[@intCast(p.object_index)];
                planes[i] = .{ .fd = obj.fd, .offset = p.offset, .pitch = p.pitch, .mod = obj.format_modifier, .fc = fcs[i] };
            }
        } else if (desc.nb_layers >= 2) {
            for (0..2) |i| {
                const layer = &desc.layers[i];
                if (layer.nb_planes < 1) {
                    self.releaseFrame(av_frame);
                    return false;
                }
                const p = &layer.planes[0];
                const obj = &desc.objects[@intCast(p.object_index)];
                const fc: u32 = if (i == 0) DRM_FORMAT_R8 else DRM_FORMAT_GR88;
                planes[i] = .{ .fd = obj.fd, .offset = p.offset, .pitch = p.pitch, .mod = obj.format_modifier, .fc = fc };
            }
        } else {
            self.releaseFrame(av_frame);
            return false;
        }

        const sizes = [_][2]u32{
            .{ frame_w, frame_h },
            .{ frame_w / 2, frame_h / 2 },
        };
        const tex = [_]c.GLuint{ self.tex_y, self.tex_uv };

        var images: [2]c.EGLImageKHR = .{ null, null };
        defer {
            for (images) |img| {
                if (img != null) _ = self.gl.eglDestroyImageKHR(self.gl.egl_display, img);
            }
        }

        for (0..2) |i| {
            const pl = planes[i];
            var attrs: [16]c.EGLint = undefined;
            var n: usize = 0;
            attrs[n] = c.EGL_WIDTH;
            n += 1;
            attrs[n] = @intCast(sizes[i][0]);
            n += 1;
            attrs[n] = c.EGL_HEIGHT;
            n += 1;
            attrs[n] = @intCast(sizes[i][1]);
            n += 1;
            attrs[n] = c.EGL_LINUX_DRM_FOURCC_EXT;
            n += 1;
            attrs[n] = @bitCast(pl.fc);
            n += 1;
            attrs[n] = c.EGL_DMA_BUF_PLANE0_FD_EXT;
            n += 1;
            attrs[n] = pl.fd;
            n += 1;
            attrs[n] = c.EGL_DMA_BUF_PLANE0_OFFSET_EXT;
            n += 1;
            attrs[n] = @intCast(pl.offset);
            n += 1;
            attrs[n] = c.EGL_DMA_BUF_PLANE0_PITCH_EXT;
            n += 1;
            attrs[n] = @intCast(pl.pitch);
            n += 1;
            if (self.gl.has_modifiers and pl.mod != DRM_FORMAT_MOD_INVALID) {
                attrs[n] = c.EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT;
                n += 1;
                attrs[n] = @bitCast(@as(u32, @truncate(pl.mod)));
                n += 1;
                attrs[n] = c.EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT;
                n += 1;
                attrs[n] = @bitCast(@as(u32, @truncate(pl.mod >> 32)));
                n += 1;
            }
            attrs[n] = c.EGL_NONE;

            const img = self.gl.eglCreateImageKHR(self.gl.egl_display, c.EGL_NO_CONTEXT, c.EGL_LINUX_DMA_BUF_EXT, null, &attrs);
            if (img == null) {
                self.releaseFrame(av_frame);
                return false;
            }
            images[i] = img;

            c.glActiveTexture(@as(c.GLenum, c.GL_TEXTURE0) + @as(c.GLenum, @intCast(i)));
            c.glBindTexture(c.GL_TEXTURE_2D, tex[i]);
            self.gl.glEGLImageTargetTexture2DOES(c.GL_TEXTURE_2D, @ptrCast(img));
        }

        const fw: f32 = @floatFromInt(frame_w);
        const fh: f32 = @floatFromInt(frame_h);
        const cw: f32 = @floatFromInt(frame_w - crop.left - crop.right);
        const ch: f32 = @floatFromInt(frame_h - crop.top - crop.bottom);

        c.glViewport(viewport.x, viewport.y, viewport.w, viewport.h);
        c.glDisable(c.GL_BLEND);
        c.glDisable(c.GL_DEPTH_TEST);
        c.glDisable(c.GL_SCISSOR_TEST);
        c.glUseProgram(self.program);
        c.glUniform1i(self.u_tex_y, 0);
        c.glUniform1i(self.u_tex_uv, 1);
        c.glUniform4f(self.u_crop, cw / fw, ch / fh, @as(f32, @floatFromInt(crop.left)) / fw, @as(f32, @floatFromInt(crop.top)) / fh);

        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        c.glEnableVertexAttribArray(@intCast(self.a_pos));
        c.glVertexAttribPointer(@intCast(self.a_pos), 2, c.GL_FLOAT, c.GL_FALSE, 16, null);
        c.glEnableVertexAttribArray(@intCast(self.a_uv));
        c.glVertexAttribPointer(@intCast(self.a_uv), 2, c.GL_FLOAT, c.GL_FALSE, 16, @ptrFromInt(8));

        c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);

        c.glDisableVertexAttribArray(@intCast(self.a_pos));
        c.glDisableVertexAttribArray(@intCast(self.a_uv));
        c.glActiveTexture(c.GL_TEXTURE0);

        if (self.in_flight) |prev| {
            var p: ?*c.AVFrame = prev;
            c.av_frame_free(&p);
        }
        self.in_flight = av_frame;
        return true;
    }

    fn releaseFrame(_: *VideoRenderer, av_frame: *c.AVFrame) void {
        var p: ?*c.AVFrame = av_frame;
        c.av_frame_free(&p);
    }
};

// Overlay rendering

const overlay_vert_src: [:0]const u8 =
    \\attribute vec2 a_pos;
    \\varying vec2 v_uv;
    \\uniform vec4 u_dst; // (x0_ndc, y0_ndc_top, x1_ndc, y1_ndc_bottom)
    \\uniform vec4 u_uv;  // (u0, v0, u1, v1)
    \\void main() {
    \\    vec2 pos = mix(u_dst.xy, u_dst.zw, a_pos);
    \\    v_uv = mix(u_uv.xy, u_uv.zw, a_pos);
    \\    gl_Position = vec4(pos, 0.0, 1.0);
    \\}
;

const overlay_frag_src: [:0]const u8 =
    \\precision mediump float;
    \\varying vec2 v_uv;
    \\uniform sampler2D u_tex;
    \\uniform vec4 u_tint;
    \\void main() {
    \\    gl_FragColor = texture2D(u_tex, v_uv) * u_tint;
    \\}
;

const overlay_quad_verts = [_]f32{
    0.0, 1.0,
    1.0, 1.0,
    0.0, 0.0,
    1.0, 0.0,
};

pub const TextureRef = struct {
    handle: c.GLuint,
    width: c_int,
    height: c_int,
};

pub const OverlayRenderer = struct {
    gl: GlCtx,
    program: c.GLuint,
    vbo: c.GLuint,
    white_tex: c.GLuint,
    a_pos: c.GLint,
    u_dst: c.GLint,
    u_uv: c.GLint,
    u_tex: c.GLint,
    u_tint: c.GLint,
    vp_w: c_int = 0,
    vp_h: c_int = 0,

    pub fn init(gl_ctx: GlCtx) !OverlayRenderer {
        const vs = try compileShader(c.GL_VERTEX_SHADER, overlay_vert_src);
        errdefer c.glDeleteShader(vs);
        const fs = try compileShader(c.GL_FRAGMENT_SHADER, overlay_frag_src);
        errdefer c.glDeleteShader(fs);

        const prog = c.glCreateProgram();
        if (prog == 0) return error.GlProgramAlloc;
        errdefer c.glDeleteProgram(prog);
        c.glAttachShader(prog, vs);
        c.glAttachShader(prog, fs);
        c.glLinkProgram(prog);
        var status: c.GLint = 0;
        c.glGetProgramiv(prog, c.GL_LINK_STATUS, &status);
        if (status == 0) {
            var log: [512]u8 = undefined;
            var n: c.GLsizei = 0;
            c.glGetProgramInfoLog(prog, log.len, &n, &log);
            return error.GlLinkFailed;
        }
        c.glDeleteShader(vs);
        c.glDeleteShader(fs);

        var vbo: c.GLuint = 0;
        c.glGenBuffers(1, &vbo);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, vbo);
        c.glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(overlay_quad_verts)), &overlay_quad_verts, c.GL_STATIC_DRAW);

        var white_tex: c.GLuint = 0;
        c.glGenTextures(1, &white_tex);
        c.glBindTexture(c.GL_TEXTURE_2D, white_tex);
        const white_px = [_]u8{ 255, 255, 255, 255 };
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, 1, 1, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, &white_px);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);

        return .{
            .gl = gl_ctx,
            .program = prog,
            .vbo = vbo,
            .white_tex = white_tex,
            .a_pos = c.glGetAttribLocation(prog, "a_pos"),
            .u_dst = c.glGetUniformLocation(prog, "u_dst"),
            .u_uv = c.glGetUniformLocation(prog, "u_uv"),
            .u_tex = c.glGetUniformLocation(prog, "u_tex"),
            .u_tint = c.glGetUniformLocation(prog, "u_tint"),
        };
    }

    pub fn deinit(self: *OverlayRenderer) void {
        c.glDeleteTextures(1, &self.white_tex);
        c.glDeleteBuffers(1, &self.vbo);
        c.glDeleteProgram(self.program);
    }

    pub fn beginFrame(self: *OverlayRenderer, viewport_w: c_int, viewport_h: c_int) void {
        self.vp_w = viewport_w;
        self.vp_h = viewport_h;
        c.glViewport(0, 0, viewport_w, viewport_h);
        c.glDisable(c.GL_SCISSOR_TEST);
        c.glDisable(c.GL_DEPTH_TEST);
        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
        c.glUseProgram(self.program);
        c.glUniform1i(self.u_tex, 0);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        c.glEnableVertexAttribArray(@intCast(self.a_pos));
        c.glVertexAttribPointer(@intCast(self.a_pos), 2, c.GL_FLOAT, c.GL_FALSE, 8, null);
    }

    pub fn drawSolidRect(self: *OverlayRenderer, x: c_int, y: c_int, w: c_int, h: c_int, rgba: [4]f32) void {
        c.glBindTexture(c.GL_TEXTURE_2D, self.white_tex);
        self.drawAt(x, y, w, h, .{ 0, 0, 1, 1 }, rgba);
    }

    pub fn drawTexturedRect(self: *OverlayRenderer, x: c_int, y: c_int, w: c_int, h: c_int, tex: c.GLuint, tint: [4]f32) void {
        c.glBindTexture(c.GL_TEXTURE_2D, tex);
        self.drawAt(x, y, w, h, .{ 0, 0, 1, 1 }, tint);
    }

    fn drawAt(self: *OverlayRenderer, x: c_int, y: c_int, w: c_int, h: c_int, uv: [4]f32, tint: [4]f32) void {
        if (self.vp_w <= 0 or self.vp_h <= 0) return;
        const fvw: f32 = @floatFromInt(self.vp_w);
        const fvh: f32 = @floatFromInt(self.vp_h);
        const x0 = @as(f32, @floatFromInt(x)) / fvw * 2.0 - 1.0;
        const x1 = @as(f32, @floatFromInt(x + w)) / fvw * 2.0 - 1.0;
        const y0 = 1.0 - @as(f32, @floatFromInt(y)) / fvh * 2.0;
        const y1 = 1.0 - @as(f32, @floatFromInt(y + h)) / fvh * 2.0;
        c.glUniform4f(self.u_dst, x0, y0, x1, y1);
        c.glUniform4f(self.u_uv, uv[0], uv[1], uv[2], uv[3]);
        c.glUniform4f(self.u_tint, tint[0], tint[1], tint[2], tint[3]);
        c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
    }
};

pub fn uploadRgba(pixels: [*]const u8, w: c_int, h: c_int, prev: ?c.GLuint) c.GLuint {
    const tex = prev orelse blk: {
        var t: c.GLuint = 0;
        c.glGenTextures(1, &t);
        break :blk t;
    };
    c.glBindTexture(c.GL_TEXTURE_2D, tex);
    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, w, h, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, pixels);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    return tex;
}

pub fn uploadBgra(allocator: std.mem.Allocator, pixels: []const u8, w: c_int, h: c_int, prev: ?c.GLuint) !c.GLuint {
    const px_count: usize = @intCast(w * h);
    if (pixels.len < px_count * 4) return error.BufferTooSmall;
    const tmp = try allocator.alloc(u8, px_count * 4);
    defer allocator.free(tmp);
    var i: usize = 0;
    while (i < px_count) : (i += 1) {
        tmp[i * 4 + 0] = pixels[i * 4 + 2]; // R <- B
        tmp[i * 4 + 1] = pixels[i * 4 + 1]; // G <- G
        tmp[i * 4 + 2] = pixels[i * 4 + 0]; // B <- R
        tmp[i * 4 + 3] = pixels[i * 4 + 3]; // A <- A
    }
    return uploadRgba(tmp.ptr, w, h, prev);
}

/// Render text via SDL_ttf into a GL RGBA texture.
pub fn uploadText(font: *c.TTF_Font, text: [:0]const u8, color: c.SDL_Color) ?TextureRef {
    const surface = c.TTF_RenderUTF8_Blended(font, text.ptr, color) orelse return null;
    defer c.SDL_FreeSurface(surface);
    const rgba_surface = c.SDL_ConvertSurfaceFormat(surface, c.SDL_PIXELFORMAT_ABGR8888, 0) orelse return null;
    defer c.SDL_FreeSurface(rgba_surface);
    const w: c_int = rgba_surface.*.w;
    const h: c_int = rgba_surface.*.h;
    const pitch: c_int = rgba_surface.*.pitch;
    if (pitch != w * 4) return null; // unexpected padding; bail rather than corrupt
    const pixels: [*]const u8 = @ptrCast(rgba_surface.*.pixels.?);
    const tex = uploadRgba(pixels, w, h, null);
    return .{ .handle = tex, .width = w, .height = h };
}

fn compileShader(kind: c.GLenum, src: [:0]const u8) !c.GLuint {
    const sh = c.glCreateShader(kind);
    if (sh == 0) return error.GlShaderAlloc;
    var ptr: [*c]const u8 = src.ptr;
    var len: c.GLint = @intCast(src.len);
    c.glShaderSource(sh, 1, &ptr, &len);
    c.glCompileShader(sh);
    var status: c.GLint = 0;
    c.glGetShaderiv(sh, c.GL_COMPILE_STATUS, &status);
    if (status == 0) {
        var log: [512]u8 = undefined;
        var n: c.GLsizei = 0;
        c.glGetShaderInfoLog(sh, log.len, &n, &log);
        c.glDeleteShader(sh);
        return error.GlShaderCompile;
    }
    return sh;
}
