#!/usr/bin/bash
# Required library prebuild bootstrap script

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBS_DIR="$REPO_ROOT/libs"
BUILD_DIR="$REPO_ROOT/.bootstrap-build"
JOBS=$(nproc)

mkdir -p "$LIBS_DIR/lib" "$LIBS_DIR/include" "$BUILD_DIR"

echo "==> Bootstrap: output to $LIBS_DIR"
[ -n "$TARGET" ] && echo "    Cross-compile target: $TARGET"

check_deps() {
    local missing=()
    for cmd in cmake make nasm pkg-config curl; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "ERROR: Missing required tools: ${missing[*]}"
        exit 1
    fi
}

cross_flags() {
    [ -n "$TARGET" ] && echo "--host=$TARGET" || true
}

cmake_cross_flags() {
    if [ -n "$TARGET" ]; then
        local system="Linux"
        local cpu="${TARGET%%-*}"
        echo "-DCMAKE_SYSTEM_NAME=$system -DCMAKE_SYSTEM_PROCESSOR=$cpu \
              -DCMAKE_C_COMPILER=${TARGET}-gcc \
              -DCMAKE_CXX_COMPILER=${TARGET}-g++ \
              -DCMAKE_FIND_ROOT_PATH=/usr/lib/${TARGET} \
              -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
              -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
              -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
              -DPKG_CONFIG_EXECUTABLE=/usr/local/bin/${TARGET}-pkg-config"
    fi
}

build_mbedtls() {
    echo ""
    echo "==> Building mbedTLS..."

    local src="$REPO_ROOT/external/mbedtls"
    local build="$BUILD_DIR/mbedtls-build"

    mkdir -p "$build"

    # shellcheck disable=SC2046
    cmake -S "$src" -B "$build" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$LIBS_DIR" \
        -DBUILD_SHARED_LIBS=OFF -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF \
        -DUSE_SHARED_MBEDTLS_LIBRARY=OFF -DUSE_STATIC_MBEDTLS_LIBRARY=ON \
        $(cmake_cross_flags)

    cmake --build "$build" --parallel "$JOBS"
    cmake --install "$build"

    echo "    mbedTLS done."
}

build_protobuf_c() {
    echo ""
    echo "==> Building protobuf-c..."

    local src="$REPO_ROOT/external/protobuf-c"

    cd "$src"

    ./autogen.sh

    # shellcheck disable=SC2046
    ./configure \
        --prefix="$LIBS_DIR" \
        --disable-shared \
        --enable-static \
        --disable-protoc \
        $(cross_flags)

    make -j"$JOBS"
    make install
    cd "$REPO_ROOT"

    echo "    protobuf-c done."
}

build_sdl2() {
    echo ""
    echo "==> Building SDL2..."

    local src="$REPO_ROOT/external/SDL2"
    local build="$BUILD_DIR/SDL2"

    mkdir -p "$build"

    local pkg_config_env=()
    if [ -n "$TARGET" ]; then
        pkg_config_env=(env PKG_CONFIG_LIBDIR="/usr/lib/${TARGET}/pkgconfig:/usr/share/pkgconfig")
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
        make_flags+=(CC="${TARGET}-gcc" AR="${TARGET}-ar")
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
        -DCMAKE_C_FLAGS="-mno-outline-atomics" -DCMAKE_CXX_FLAGS="-mno-outline-atomics" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$LIBS_DIR" \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_TEST=OFF \
        $(cmake_cross_flags)

    cmake --build "$build" --parallel "$JOBS"
    cmake --install "$build"

    echo "    rkmpp done."
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
            "--cross-prefix=${TARGET}-"
            "--arch=${TARGET%%-*}"
            "--target-os=linux"
            "--enable-cross-compile"
        )
        pkg_config_path="$pkg_config_path:/usr/lib/${TARGET}/pkgconfig:/usr/share/pkgconfig"
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
        --extra-cflags="-I$LIBS_DIR/include -I/opt/linux-uapi/include" \
        --extra-ldflags="-L$LIBS_DIR/lib" \
        "${cross_prefix_flags[@]+"${cross_prefix_flags[@]}"}"

    make -j"$JOBS"
    make install

    echo "    FFmpeg done."
}

check_deps
build_mbedtls
build_protobuf_c
build_sdl2
build_sdl2_ttf
build_udev_zero
build_rkmpp
build_ffmpeg

echo ""
echo "==> Bootstrap complete. Libraries placed in $LIBS_DIR"
