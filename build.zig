const std = @import("std");

const ihslib_sources: []const []const u8 = &.{
    "external/ihslib/src/base.c",
    "external/ihslib/src/crc32.c",
    "external/ihslib/src/crc32c.c",
    "external/ihslib/src/ihs_arraylist.c",
    "external/ihslib/src/ihs_buffer.c",
    "external/ihslib/src/ihs_enumeration.c",
    "external/ihslib/src/ihs_enumeration_array.c",
    "external/ihslib/src/ihs_enumeration_ll.c",
    "external/ihslib/src/ihs_ip.c",
    "external/ihslib/src/ihs_queue.c",
    "external/ihslib/src/ihs_timer.c",
    "external/ihslib/src/client/authorization.c",
    "external/ihslib/src/client/client.c",
    "external/ihslib/src/client/discovery.c",
    "external/ihslib/src/client/streaming.c",
    "external/ihslib/src/crypto/impl_mbedtls.c",
    "external/ihslib/src/hid/device.c",
    "external/ihslib/src/hid/manager.c",
    "external/ihslib/src/hid/provider.c",
    "external/ihslib/src/hid/report.c",
    "external/ihslib/src/hid/sdl/src/sdl_hid_device.c",
    "external/ihslib/src/hid/sdl/src/sdl_hid_enumerator_common.c",
    "external/ihslib/src/hid/sdl/src/sdl_hid_enumerator_managed.c",
    "external/ihslib/src/hid/sdl/src/sdl_hid_enumerator_unmanaged.c",
    "external/ihslib/src/hid/sdl/src/sdl_hid_event.c",
    "external/ihslib/src/hid/sdl/src/sdl_hid_feature_report.c",
    "external/ihslib/src/hid/sdl/src/sdl_hid_manager.c",
    "external/ihslib/src/hid/sdl/src/sdl_hid_provider.c",
    "external/ihslib/src/hid/sdl/src/sdl_hid_report.c",
    "external/ihslib/src/hid/sdl/src/sdl_hid_utils.c",
    "external/ihslib/src/hid/sdl/src/sdl_hid_write.c",
    "external/ihslib/src/platforms/ihs_ip_posix.c",
    "external/ihslib/src/platforms/ihs_udp_posix.c",
    "external/ihslib/src/platforms/ihs_thread_sdl.c",
    "external/ihslib/src/protobuf/discovery.pb-c.c",
    "external/ihslib/src/protobuf/hiddevices.pb-c.c",
    "external/ihslib/src/protobuf/pb_utils.c",
    "external/ihslib/src/protobuf/remoteplay.pb-c.c",
    "external/ihslib/src/session/callbacks.c",
    "external/ihslib/src/session/frame.c",
    "external/ihslib/src/session/frame_crypto.c",
    "external/ihslib/src/session/packet.c",
    "external/ihslib/src/session/retransmission.c",
    "external/ihslib/src/session/session.c",
    "external/ihslib/src/session/window.c",
    "external/ihslib/src/session/channels/channel.c",
    "external/ihslib/src/session/channels/ch_control.c",
    "external/ihslib/src/session/channels/ch_control_audio.c",
    "external/ihslib/src/session/channels/ch_control_authentication.c",
    "external/ihslib/src/session/channels/ch_control_keepalive.c",
    "external/ihslib/src/session/channels/ch_control_negotiation.c",
    "external/ihslib/src/session/channels/ch_control_video.c",
    "external/ihslib/src/session/channels/ch_data.c",
    "external/ihslib/src/session/channels/ch_data_audio.c",
    "external/ihslib/src/session/channels/ch_discovery.c",
    "external/ihslib/src/session/channels/ch_stats.c",
    "external/ihslib/src/session/channels/control/control_cursor.c",
    "external/ihslib/src/session/channels/control/control_hid.c",
    "external/ihslib/src/session/channels/control/control_input_kbd.c",
    "external/ihslib/src/session/channels/control/control_input_mouse.c",
    "external/ihslib/src/session/channels/control/control_input_touch.c",
    "external/ihslib/src/session/channels/video/ch_data_video.c",
    "external/ihslib/src/session/channels/video/frame_h264.c",
    "external/ihslib/src/session/channels/video/frame_hevc.c",
    "external/ihslib/src/session/channels/video/partial_frames.c",
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
        }),
    });

    const mod = exe.root_module;

    // Multiarch/Cross handling
    if (target.result.cpu.arch == .aarch64) {
        mod.addLibraryPath(.{ .cwd_relative = "/usr/lib/aarch64-linux-gnu" });
    }

    // Includes
    mod.addIncludePath(b.path("external/ihslib/include"));
    mod.addIncludePath(b.path("external/ihslib/src"));
    mod.addIncludePath(b.path("external/ihslib/src/hid/sdl/include"));
    mod.addIncludePath(b.path("external/ihslib/src/hid/sdl/src"));
    mod.addIncludePath(b.path("libs/include"));
    mod.addIncludePath(b.path("libs/include/SDL2"));

    // ihslib pre-compilation
    mod.addCSourceFiles(.{
        .files = ihslib_sources,
        .flags = &.{ "-std=gnu11", "-DIHS_CRYPTO_MBEDTLS" },
    });

    // Bootstrap built libraries
    mod.addObjectFile(b.path("libs/lib/libSDL2.so"));
    mod.addObjectFile(b.path("libs/lib/libSDL2_ttf.so"));
    mod.addObjectFile(b.path("libs/lib/librockchip_mpp.so"));
    mod.addObjectFile(b.path("libs/lib/libavcodec.a"));
    mod.addObjectFile(b.path("libs/lib/libavformat.a"));
    mod.addObjectFile(b.path("libs/lib/libavutil.a"));
    mod.addObjectFile(b.path("libs/lib/libswresample.a"));
    mod.addObjectFile(b.path("libs/lib/libswscale.a"));
    mod.addObjectFile(b.path("libs/lib/libmbedcrypto.a"));
    mod.addObjectFile(b.path("libs/lib/libprotobuf-c.a"));

    // System libraries
    mod.linkSystemLibrary("drm", .{});
    mod.linkSystemLibrary("m", .{});
    mod.linkSystemLibrary("dl", .{});
    mod.linkSystemLibrary("pthread", .{});
    mod.link_libc = true;

    b.installFile("assets/Asap-Medium.otf", "bin/assets/Asap-Medium.otf");
    b.installFile("libs/lib/libSDL2-2.0.so.0", "bin/lib/libSDL2-2.0.so.0");
    b.installFile("libs/lib/libSDL2_ttf-2.0.so.0", "bin/lib/libSDL2_ttf-2.0.so.0");
    b.installFile("libs/lib/librockchip_mpp.so.1", "bin/lib/librockchip_mpp.so.1");
    b.installFile("scripts/launcher/locomo.sh", "bin/locomo.sh");
    const install_step = b.addInstallArtifact(exe, .{});

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
