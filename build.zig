const std = @import("std");

const ihslib_sources: []const []const u8 = &.{
    "base.c",
    "crc32.c",
    "crc32c.c",
    "ihs_arraylist.c",
    "ihs_buffer.c",
    "ihs_enumeration.c",
    "ihs_enumeration_array.c",
    "ihs_enumeration_ll.c",
    "ihs_ip.c",
    "ihs_queue.c",
    "ihs_timer.c",
    "client/authorization.c",
    "client/client.c",
    "client/discovery.c",
    "client/streaming.c",
    "crypto/impl_mbedtls.c",
    "hid/device.c",
    "hid/manager.c",
    "hid/provider.c",
    "hid/report.c",
    "hid/sdl/src/sdl_hid_device.c",
    "hid/sdl/src/sdl_hid_enumerator_common.c",
    "hid/sdl/src/sdl_hid_enumerator_managed.c",
    "hid/sdl/src/sdl_hid_enumerator_unmanaged.c",
    "hid/sdl/src/sdl_hid_event.c",
    "hid/sdl/src/sdl_hid_feature_report.c",
    "hid/sdl/src/sdl_hid_manager.c",
    "hid/sdl/src/sdl_hid_provider.c",
    "hid/sdl/src/sdl_hid_report.c",
    "hid/sdl/src/sdl_hid_utils.c",
    "hid/sdl/src/sdl_hid_write.c",
    "platforms/ihs_ip_posix.c",
    "platforms/ihs_udp_posix.c",
    "platforms/ihs_thread_sdl.c",
    "protobuf/discovery.pb-c.c",
    "protobuf/hiddevices.pb-c.c",
    "protobuf/pb_utils.c",
    "protobuf/remoteplay.pb-c.c",
    "session/callbacks.c",
    "session/frame.c",
    "session/frame_crypto.c",
    "session/packet.c",
    "session/retransmission.c",
    "session/session.c",
    "session/window.c",
    "session/channels/channel.c",
    "session/channels/ch_control.c",
    "session/channels/ch_control_audio.c",
    "session/channels/ch_control_authentication.c",
    "session/channels/ch_control_keepalive.c",
    "session/channels/ch_control_negotiation.c",
    "session/channels/ch_control_video.c",
    "session/channels/ch_data.c",
    "session/channels/ch_data_audio.c",
    "session/channels/ch_discovery.c",
    "session/channels/ch_stats.c",
    "session/channels/control/control_cursor.c",
    "session/channels/control/control_hid.c",
    "session/channels/control/control_input_kbd.c",
    "session/channels/control/control_input_mouse.c",
    "session/channels/control/control_input_touch.c",
    "session/channels/video/ch_data_video.c",
    "session/channels/video/frame_h264.c",
    "session/channels/video/frame_hevc.c",
    "session/channels/video/partial_frames.c",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "locomo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = true,
        }),
    });
    exe.lto = .thin;
    exe.link_gc_sections = true;

    const mod = exe.root_module;

    // mbedTLS
    const mbedtls_dep = b.dependency("mbedtls", .{
        .target = target,
        .optimize = optimize,
    });
    const mbedtls_lib = mbedtls_dep.artifact("mbedtls");

    // protobuf-c
    const protobufc_dep = b.dependency("protobuf_c", .{
        .target = target,
        .optimize = optimize,
    });
    const protobufc_lib = protobufc_dep.artifact("protobuf_c");

    // SDL2
    const sdl_dep = b.dependency("SDL", .{
        .target = target,
        .optimize = optimize,
    });
    const sdl_lib = sdl_dep.artifact("SDL2-2.0");
    sdl_lib.root_module.strip = true;
    mod.linkLibrary(sdl_lib);

    // SDL2_ttf
    const sdlttf_dep = b.dependency("SDL_ttf", .{
        .target = target,
        .optimize = optimize,
    });
    const sdlttf_lib = sdlttf_dep.artifact("SDL2_ttf");
    mod.linkLibrary(sdlttf_lib);

    // ihslib
    const ihslib_upstream = b.dependency("ihslib", .{});
    const ihslib = b.addLibrary(.{
        .name = "ihslib",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    ihslib.root_module.addIncludePath(ihslib_upstream.path("src"));
    ihslib.root_module.addIncludePath(ihslib_upstream.path("src/hid/sdl/include"));
    ihslib.root_module.addIncludePath(ihslib_upstream.path("include"));
    ihslib.root_module.linkLibrary(mbedtls_lib);
    ihslib.root_module.linkLibrary(protobufc_lib);
    ihslib.root_module.linkLibrary(sdl_lib);
    ihslib.root_module.addIncludePath(protobufc_dep.path("."));
    ihslib.root_module.addCSourceFiles(.{
        .root = ihslib_upstream.path("src"),
        .files = ihslib_sources,
        .flags = &.{ "-std=gnu11", "-DIHS_CRYPTO_MBEDTLS" },
    });
    mod.addIncludePath(ihslib_upstream.path("include"));
    mod.addIncludePath(ihslib_upstream.path("src/hid/sdl/include"));
    mod.linkLibrary(ihslib);

    // ffmpeg
    const ffmpeg_dep = b.dependency("ffmpeg", .{
        .target = target,
        .optimize = optimize,
    });
    const ffmpeg_lib = ffmpeg_dep.artifact("ffmpeg");
    const mpp_lib = ffmpeg_dep.artifact("rockchip_mpp");
    mod.linkLibrary(ffmpeg_lib);
    mod.linkLibrary(mpp_lib);

    // System libraries
    mod.linkSystemLibrary("EGL", .{});
    mod.linkSystemLibrary("GLESv2", .{});

    // Multiarch/Cross handling
    if (target.result.cpu.arch == .aarch64) {
        mod.addLibraryPath(.{ .cwd_relative = "/usr/lib/aarch64-linux-gnu" });
        mod.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
        mod.addSystemIncludePath(.{ .cwd_relative = "/usr/include/drm" });

        sdl_lib.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib/aarch64-linux-gnu" });
        sdl_lib.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
        sdl_lib.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include/drm" });

        sdlttf_lib.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib/aarch64-linux-gnu" });
        sdlttf_lib.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });

        ihslib.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib/aarch64-linux-gnu" });
        ihslib.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    }

    const install_step = b.addInstallArtifact(exe, .{});
    const install_sdl_lib = b.addInstallFile(sdl_lib.getEmittedBin(), "lib/libSDL2.so.2");
    const install_mpp_lib = b.addInstallFile(mpp_lib.getEmittedBin(), "lib/librockchip_mpp.so.1");
    b.getInstallStep().dependOn(&install_sdl_lib.step);
    b.getInstallStep().dependOn(&install_mpp_lib.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run locomo");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    const msg = b.addSystemCommand(&.{
        "echo",
        "Build complete! Files are under ./zig-out/bin/",
    });
    msg.step.dependOn(&install_step.step);
    b.getInstallStep().dependOn(&msg.step);
}
