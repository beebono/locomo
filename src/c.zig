pub const c = @cImport({
    @cUndef("__ARM_NEON__");
    @cUndef("__ARM_NEON");
    @cInclude("ihslib.h");
    @cInclude("ihslib/client.h");
    @cInclude("ihslib/session.h");
    @cInclude("ihslib/hid.h");
    @cInclude("ihslib/hid/sdl.h");
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavutil/frame.h");
    @cInclude("libavutil/imgutils.h");
    @cInclude("libavutil/opt.h");
    @cInclude("libswresample/swresample.h");
});
