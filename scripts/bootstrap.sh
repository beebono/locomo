#!/usr/bin/bash
# Required library prebuild bootstrap script

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBS_DIR="$REPO_ROOT/libs"
BUILD_DIR="$REPO_ROOT/.bootstrap-build"
JOBS=$(nproc)

mkdir -p "$LIBS_DIR/lib" "$LIBS_DIR/include" "$BUILD_DIR"

# Strip glibc version suffix for tools that don't understand it
TARGET_TRIPLE="${TARGET%%.*}"

echo "==> Bootstrap: output to $LIBS_DIR"
[ -n "$TARGET" ] && echo "    Cross-compile target: $TARGET"

# Zig wrappers so meson and cmake don't get mad
ZIG_CC=""
ZIG_CXX=""
ZIG_AR=""
if [ -n "$TARGET" ]; then
    ZIG_CC="$BUILD_DIR/zig-cc"
    ZIG_CXX="$BUILD_DIR/zig-cxx"
    ZIG_AR="$BUILD_DIR/zig-ar"

# Fake out meson's version checks since it doesn't know what zig is
# and also don't let it inject the glibc versioning onto the target
    cat > "$ZIG_CC" << EOF
#!/bin/bash
if [[ "\$*" == *"-Wl,--version"* ]]; then
    echo "LLD 16.0.0 (compatible with GNU linkers)"
    exit 0
fi
IS_PROBING=0
for arg in "\$@"; do
    case "\$arg" in
        -v|-E|-dM|--version) IS_PROBING=1 ;;
    esac
done
if [ "\$IS_PROBING" -eq 1 ]; then
    exec zig cc -target $TARGET_TRIPLE "\$@"
else
    exec zig cc -target $TARGET "\$@"
fi
EOF
    cat > "$ZIG_CXX" << EOF
#!/bin/bash
if [[ "\$*" == *"-Wl,--version"* ]]; then
    echo "LLD 16.0.0 (compatible with GNU linkers)"
    exit 0
fi
IS_PROBING=0
for arg in "\$@"; do
    case "\$arg" in
        -v|-E|-dM|--version) IS_PROBING=1 ;;
    esac
done
if [ "\$IS_PROBING" -eq 1 ]; then
    exec zig c++ -target $TARGET_TRIPLE "\$@"
else
    exec zig c++ -target $TARGET "\$@"
fi
EOF

# Zig (LLVM) AR doesn't support the g flag, drop it 
    cat > "$ZIG_AR" << EOF
#!/bin/bash
ARGS=()
for arg in "\$@"; do
    if [[ "\$arg" =~ ^[a-zA-Z]+$ ]]; then
        CLEANED_ARG=\$(echo "\$arg" | tr -d 'g')
        ARGS+=("\$CLEANED_ARG")
    else
        ARGS+=("\$arg")
    fi
done

exec zig ar "\${ARGS[@]}"
EOF
    chmod +x "$ZIG_CC" "$ZIG_CXX" "$ZIG_AR"
fi

cmake_cross_flags() {
    if [ -n "$TARGET" ]; then
        local cpu="${TARGET%%-*}"
        echo "-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=$cpu \
              -DCMAKE_C_COMPILER=$ZIG_CC -DCMAKE_CXX_COMPILER=$ZIG_CXX \
              -DCMAKE_LINKER=$ZIG_CC -DCMAKE_STRIP=/bin/true \
              -DCMAKE_FIND_ROOT_PATH=/usr/lib/${TARGET_TRIPLE} \
              -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
              -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
              -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
              -DPKG_CONFIG_EXECUTABLE=/usr/local/bin/${TARGET_TRIPLE}-pkg-config"
    fi
}


build_sdl2() {
    echo ""
    echo "==> Building SDL2..."

    local src="$REPO_ROOT/external/SDL2"
    local build="$BUILD_DIR/SDL2"

    mkdir -p "$build"

    local pkg_config_env=()
    if [ -n "$TARGET" ]; then
        pkg_config_env=(env PKG_CONFIG_LIBDIR="/usr/lib/${TARGET_TRIPLE}/pkgconfig:/usr/share/pkgconfig")
    fi

    # shellcheck disable=SC2046
    "${pkg_config_env[@]}" cmake -S "$src" -B "$build" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$LIBS_DIR" \
        -DSDL_TEST=OFF -DSDL_RPATH=OFF \
        $(cmake_cross_flags)

    cmake --build "$build" --parallel "$JOBS"
    cmake --install "$build"

    echo "    SDL2 done."
}

build_sdl2_ttf() {
    echo ""
    echo "==> Building SDL2_ttf..."

    local src="$REPO_ROOT/external/SDL2_ttf"
    local build="$BUILD_DIR/SDL2_ttf"

    mkdir -p "$build"

    # shellcheck disable=SC2046
    cmake -S "$src" -B "$build" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$LIBS_DIR" \
        -DBUILD_SHARED_LIBS=OFF -DSDL2_DIR="$LIBS_DIR/lib/cmake/SDL2" \
        -DSDL2TTF_SAMPLES=OFF -DSDL2TTF_INSTALL=ON -DSDL2TTF_VENDORED=ON \
        $(cmake_cross_flags)

    cmake --build "$build" --parallel "$JOBS"
    cmake --install "$build"

    echo "    SDL2_ttf done."
}

build_udev_zero() {
    echo ""
    echo "==> Building udev-zero..."

    local src="$REPO_ROOT/external/libudev-zero"

    local make_flags=()
    if [ -n "$TARGET" ]; then
        make_flags+=(CC="$ZIG_CC" AR="$ZIG_AR")
    fi

    # shellcheck disable=SC2046
    make -C "$src" \
        "${make_flags[@]+"${make_flags[@]}"}" \
        PREFIX="$LIBS_DIR" \
        install-static

    echo "    udev-zero done."
}

build_rkmpp() {
    echo ""
    echo "==> Building rkmpp..."

    local src="$REPO_ROOT/external/rkmpp"
    local build="$BUILD_DIR/rkmpp"

    mkdir -p "$build"

    # shellcheck disable=SC2046
    cmake -S "$src" -B "$build" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$LIBS_DIR" \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_TEST=OFF \
        $(cmake_cross_flags)

    cmake --build "$build" --parallel "$JOBS"
    cmake --install "$build"

    echo "    rkmpp done."
}

build_libdrm() {
    echo ""
    echo "==> Building libdrm..."

    local src="$REPO_ROOT/external/libdrm"
    local build="$BUILD_DIR/libdrm"

    local meson_args=(
        --prefix="$LIBS_DIR"
        --buildtype=release
        --default-library=static
        -Dintel=disabled
        -Dradeon=disabled
        -Damdgpu=disabled
        -Dnouveau=disabled
        -Dvmwgfx=disabled
        -Domap=disabled
        -Dexynos=disabled
        -Dfreedreno=disabled
        -Dtegra=disabled
        -Dvc4=disabled
        -Detnaviv=disabled
        -Dcairo-tests=disabled
        -Dman-pages=disabled
        -Dvalgrind=disabled
        -Dtests=false
        -Dudev=false
    )

    if [ -n "$TARGET" ]; then
        local cross_file="$BUILD_DIR/meson-cross.ini"
        local cpu="${TARGET%%-*}"
        cat > "$cross_file" << EOF
[binaries]
c = '$ZIG_CC'
cpp = '$ZIG_CXX'
ar = '$ZIG_AR'
strip = '/bin/true'
pkg-config = '/usr/local/bin/${TARGET_TRIPLE}-pkg-config'

[host_machine]
system = 'linux'
cpu_family = '$cpu'
cpu = '$cpu'
endian = 'little'
EOF
        meson_args+=(--cross-file="$cross_file")
    fi

    meson setup "$build" "$src" "${meson_args[@]}"
    ninja -C "$build" -j"$JOBS"
    ninja -C "$build" install

    echo "    libdrm done."
}

apply_ffmpeg_patches() {
    local src="$REPO_ROOT/external/ffmpeg"
    local patches_dir="$REPO_ROOT/patches"
    local marker="$src/.patches-applied"

    [ -d "$patches_dir" ] || return 0
    if [ -f "$marker" ]; then
        echo "    FFmpeg patches already applied (remove $marker to re-apply)."
        return 0
    fi

    echo ""
    echo "==> Applying FFmpeg patches..."
    for p in "$patches_dir"/ffmpeg-*.patch; do
        [ -e "$p" ] || continue
        echo "    Applying $(basename "$p")"
        (cd "$src" && patch -p1 --no-backup-if-mismatch < "$p")
    done
    touch "$marker"
}

build_ffmpeg() {
    apply_ffmpeg_patches

    echo ""
    echo "==> Building FFmpeg..."

    local src="$REPO_ROOT/external/ffmpeg"
    local build="$BUILD_DIR/ffmpeg"

    mkdir -p "$build"
    cd "$build"

    local cross_prefix_flags=()
    local pkg_config_path="$LIBS_DIR/lib/pkgconfig"
    if [ -n "$TARGET" ]; then
        cross_prefix_flags+=(
            "--cc=$ZIG_CC"
            "--cxx=$ZIG_CXX"
            "--ar=$ZIG_AR"
            "--arch=${TARGET%%-*}"
            "--target-os=linux"
            "--enable-cross-compile"
        )
        pkg_config_path="$pkg_config_path:/usr/lib/${TARGET_TRIPLE}/pkgconfig:/usr/share/pkgconfig"
    fi

    PKG_CONFIG_LIBDIR="$pkg_config_path" PKG_CONFIG_PATH="$pkg_config_path" \
    "$src/configure" \
        --prefix="$LIBS_DIR" --bindir="$BUILD_DIR/ffmpeg-bin" \
        --enable-static --disable-shared \
        --disable-doc --disable-programs \
        --disable-everything --disable-swscale \
        --disable-avdevice --disable-avfilter \
        --enable-protocol=rtp --enable-protocol=udp --enable-protocol=tcp \
        --enable-demuxer=rtsp --enable-demuxer=rtp \
        --enable-demuxer=h264 --enable-demuxer=hevc \
        --enable-parser=h264 --enable-parser=hevc \
        --enable-parser=aac --enable-parser=opus \
        --enable-decoder=h264 --enable-decoder=hevc \
        --enable-decoder=h264_v4l2m2m --enable-decoder=hevc_v4l2m2m \
        --enable-decoder=h264_rkmpp --enable-decoder=hevc_rkmpp \
        --enable-decoder=aac --enable-decoder=opus \
        --enable-hwaccel=h264_v4l2request --enable-hwaccel=hevc_v4l2request \
        --enable-v4l2-m2m --enable-v4l2-request \
        --enable-version3 --enable-rkmpp \
        --enable-libdrm --enable-libudev \
        --enable-pic --enable-optimizations \
        --extra-cflags="-I$LIBS_DIR/include" \
        --extra-ldflags="-L$LIBS_DIR/lib -L/usr/lib/${TARGET_TRIPLE}" \
        "${cross_prefix_flags[@]+"${cross_prefix_flags[@]}"}"

    # Zig headers don't have these, but configure thinks we do...
    sed -i 's/^#define HAVE_SYSCTL 1/#define HAVE_SYSCTL 0/' config.h
    sed -i 's/^#define HAVE_SYSCTLBYNAME 1/#define HAVE_SYSCTLBYNAME 0/' config.h

    make -j"$JOBS"
    make install

    echo "    FFmpeg done."
}

build_sdl2
build_sdl2_ttf
build_udev_zero
build_rkmpp
build_libdrm
build_ffmpeg

echo ""
echo "==> Bootstrap complete. Libraries placed in $LIBS_DIR"
