const std = @import("std");

const mbedtls_sources: []const []const u8 = &.{
    "external/mbedtls/library/aes.c",
    "external/mbedtls/library/aesni.c",
    "external/mbedtls/library/arc4.c",
    "external/mbedtls/library/aria.c",
    "external/mbedtls/library/asn1parse.c",
    "external/mbedtls/library/asn1write.c",
    "external/mbedtls/library/base64.c",
    "external/mbedtls/library/bignum.c",
    "external/mbedtls/library/blowfish.c",
    "external/mbedtls/library/camellia.c",
    "external/mbedtls/library/ccm.c",
    "external/mbedtls/library/certs.c",
    "external/mbedtls/library/chacha20.c",
    "external/mbedtls/library/chachapoly.c",
    "external/mbedtls/library/cipher.c",
    "external/mbedtls/library/cipher_wrap.c",
    "external/mbedtls/library/cmac.c",
    "external/mbedtls/library/constant_time.c",
    "external/mbedtls/library/ctr_drbg.c",
    "external/mbedtls/library/debug.c",
    "external/mbedtls/library/des.c",
    "external/mbedtls/library/dhm.c",
    "external/mbedtls/library/ecdh.c",
    "external/mbedtls/library/ecdsa.c",
    "external/mbedtls/library/ecjpake.c",
    "external/mbedtls/library/ecp.c",
    "external/mbedtls/library/ecp_curves.c",
    "external/mbedtls/library/entropy.c",
    "external/mbedtls/library/entropy_poll.c",
    "external/mbedtls/library/error.c",
    "external/mbedtls/library/gcm.c",
    "external/mbedtls/library/havege.c",
    "external/mbedtls/library/hkdf.c",
    "external/mbedtls/library/hmac_drbg.c",
    "external/mbedtls/library/md.c",
    "external/mbedtls/library/md2.c",
    "external/mbedtls/library/md4.c",
    "external/mbedtls/library/md5.c",
    "external/mbedtls/library/memory_buffer_alloc.c",
    "external/mbedtls/library/mps_reader.c",
    "external/mbedtls/library/mps_trace.c",
    "external/mbedtls/library/net_sockets.c",
    "external/mbedtls/library/nist_kw.c",
    "external/mbedtls/library/oid.c",
    "external/mbedtls/library/padlock.c",
    "external/mbedtls/library/pem.c",
    "external/mbedtls/library/pk.c",
    "external/mbedtls/library/pk_wrap.c",
    "external/mbedtls/library/pkcs11.c",
    "external/mbedtls/library/pkcs12.c",
    "external/mbedtls/library/pkcs5.c",
    "external/mbedtls/library/pkparse.c",
    "external/mbedtls/library/pkwrite.c",
    "external/mbedtls/library/platform.c",
    "external/mbedtls/library/platform_util.c",
    "external/mbedtls/library/poly1305.c",
    "external/mbedtls/library/psa_crypto.c",
    "external/mbedtls/library/psa_crypto_aead.c",
    "external/mbedtls/library/psa_crypto_cipher.c",
    "external/mbedtls/library/psa_crypto_client.c",
    "external/mbedtls/library/psa_crypto_driver_wrappers.c",
    "external/mbedtls/library/psa_crypto_ecp.c",
    "external/mbedtls/library/psa_crypto_hash.c",
    "external/mbedtls/library/psa_crypto_mac.c",
    "external/mbedtls/library/psa_crypto_rsa.c",
    "external/mbedtls/library/psa_crypto_se.c",
    "external/mbedtls/library/psa_crypto_slot_management.c",
    "external/mbedtls/library/psa_crypto_storage.c",
    "external/mbedtls/library/psa_its_file.c",
    "external/mbedtls/library/ripemd160.c",
    "external/mbedtls/library/rsa.c",
    "external/mbedtls/library/rsa_internal.c",
    "external/mbedtls/library/sha1.c",
    "external/mbedtls/library/sha256.c",
    "external/mbedtls/library/sha512.c",
    "external/mbedtls/library/ssl_cache.c",
    "external/mbedtls/library/ssl_ciphersuites.c",
    "external/mbedtls/library/ssl_cli.c",
    "external/mbedtls/library/ssl_cookie.c",
    "external/mbedtls/library/ssl_msg.c",
    "external/mbedtls/library/ssl_srv.c",
    "external/mbedtls/library/ssl_ticket.c",
    "external/mbedtls/library/ssl_tls.c",
    "external/mbedtls/library/ssl_tls13_keys.c",
    "external/mbedtls/library/threading.c",
    "external/mbedtls/library/timing.c",
    "external/mbedtls/library/version.c",
    "external/mbedtls/library/version_features.c",
    "external/mbedtls/library/x509.c",
    "external/mbedtls/library/x509_create.c",
    "external/mbedtls/library/x509_crl.c",
    "external/mbedtls/library/x509_crt.c",
    "external/mbedtls/library/x509_csr.c",
    "external/mbedtls/library/x509write_crt.c",
    "external/mbedtls/library/x509write_csr.c",
    "external/mbedtls/library/xtea.c",
};

const libudev_sources: []const []const u8 = &.{
    "external/libudev-zero/udev.c",
    "external/libudev-zero/udev_list.c",
    "external/libudev-zero/udev_device.c",
    "external/libudev-zero/udev_monitor.c",
    "external/libudev-zero/udev_enumerate.c",
};

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
            .strip = true,
        }),
    });

    const mod = exe.root_module;

    // Multiarch/Cross handling
    if (target.result.cpu.arch == .aarch64) {
        mod.addLibraryPath(.{ .cwd_relative = "/usr/lib/aarch64-linux-gnu" });
        mod.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    }

    // mbedTLS
    const mbedtls_mod = b.createModule(.{ .target = target, .optimize = optimize });
    mbedtls_mod.addIncludePath(b.path("external/mbedtls/include"));
    mbedtls_mod.addCSourceFiles(.{ .files = mbedtls_sources, .flags = &.{} });
    mbedtls_mod.link_libc = true;
    const mbedtls = b.addLibrary(.{
        .name = "mbedcrypto",
        .linkage = .static,
        .root_module = mbedtls_mod,
    });

    // protobuf-c
    const protobuf_c_mod = b.createModule(.{ .target = target, .optimize = optimize });
    protobuf_c_mod.addIncludePath(b.path("external/protobuf-c"));
    protobuf_c_mod.addCSourceFiles(.{
        .files = &.{"external/protobuf-c/protobuf-c/protobuf-c.c"},
        .flags = &.{},
    });
    protobuf_c_mod.link_libc = true;
    const protobuf_c = b.addLibrary(.{
        .name = "protobuf-c",
        .linkage = .static,
        .root_module = protobuf_c_mod,
    });

    // libudev-zero
    const libudev_mod = b.createModule(.{ .target = target, .optimize = optimize });
    libudev_mod.addIncludePath(b.path("external/libudev-zero"));
    libudev_mod.addCSourceFiles(.{
        .files = libudev_sources,
        .flags = &.{ "-std=c99", "-D_XOPEN_SOURCE=700" },
    });
    libudev_mod.link_libc = true;
    const libudev = b.addLibrary(.{
        .name = "udev",
        .linkage = .static,
        .root_module = libudev_mod,
    });

    // Includes
    mod.addIncludePath(b.path("external/ihslib/include"));
    mod.addIncludePath(b.path("external/ihslib/src"));
    mod.addIncludePath(b.path("external/ihslib/src/hid/sdl/include"));
    mod.addIncludePath(b.path("external/ihslib/src/hid/sdl/src"));
    mod.addIncludePath(b.path("external/mbedtls/include"));
    mod.addIncludePath(b.path("external/protobuf-c"));
    mod.addIncludePath(b.path("libs/include"));
    mod.addIncludePath(b.path("libs/include/SDL2"));

    // ihslib pre-compilation
    mod.addCSourceFiles(.{
        .files = ihslib_sources,
        .flags = &.{ "-std=gnu11", "-DIHS_CRYPTO_MBEDTLS" },
    });

    // Zig-built libraries
    mod.linkLibrary(mbedtls);
    mod.linkLibrary(protobuf_c);
    mod.linkLibrary(libudev);

    // Bootstrap built libraries
    mod.addObjectFile(b.path("libs/lib/libSDL2.so"));
    mod.addObjectFile(b.path("libs/lib/libSDL2_ttf.a"));
    mod.addObjectFile(b.path("libs/lib/libfreetype.a"));
    mod.addObjectFile(b.path("libs/lib/librockchip_mpp.a"));
    mod.addObjectFile(b.path("libs/lib/libavcodec.a"));
    mod.addObjectFile(b.path("libs/lib/libavformat.a"));
    mod.addObjectFile(b.path("libs/lib/libavutil.a"));
    mod.addObjectFile(b.path("libs/lib/libswresample.a"));
    mod.addObjectFile(b.path("libs/lib/libdrm.a"));

    // System libraries
    mod.linkSystemLibrary("EGL", .{});
    mod.linkSystemLibrary("GLESv2", .{});

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
