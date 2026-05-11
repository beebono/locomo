const builtin = @import("builtin");

pub const c = @cImport({
    // Causes compilation errors with Zig's headers
    if (builtin.cpu.arch == .aarch64) {
        @cUndef("__ARM_NEON__");
        @cUndef("__ARM_NEON");
    }

    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
    @cInclude("GLES2/gl2.h");
    @cInclude("GLES2/gl2ext.h");
    @cInclude("ihslib.h");
    @cInclude("ihslib/hid/sdl.h");
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavutil/hwcontext_drm.h");
    @cInclude("libavutil/log.h");
    @cInclude("libavutil/pixdesc.h");
    @cInclude("libavutil/opt.h");
    @cInclude("libswresample/swresample.h");
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
});
