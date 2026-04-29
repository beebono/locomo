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
        -DSDL_STATIC=OFF -DSDL_SHARED=ON -DSDL_TEST=OFF -DSDL_RPATH=OFF \
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
        -DSDL2TTF_SAMPLES=OFF -DSDL2TTF_INSTALL=ON -DSDL2TTF_VENDORED=ON \
        -DSDL2_DIR="$LIBS_DIR/lib/cmake/SDL2" \
        $(cmake_cross_flags)

    cmake --build "$build" --parallel "$JOBS"
    cmake --install "$build"

    echo "    SDL2_ttf done."
}

build_mbedtls() {
    echo ""
    echo "==> Building mbedTLS..."

    local version="2.28.8"
    local tarball="$BUILD_DIR/mbedtls-${version}.tar.bz2"
    local src="$BUILD_DIR/mbedtls-${version}"
    local build="$BUILD_DIR/mbedtls-build"

    if [ ! -d "$src" ]; then
        [ -f "$tarball" ] || \
            curl -fsSL "https://github.com/Mbed-TLS/mbedtls/releases/download/v${version}/mbedtls-${version}.tar.bz2" \
                -o "$tarball"
        tar -xjf "$tarball" -C "$BUILD_DIR"
    fi

    mkdir -p "$build"

    # shellcheck disable=SC2046
    cmake -S "$src" -B "$build" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$LIBS_DIR" \
        -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF \
        -DUSE_SHARED_MBEDTLS_LIBRARY=OFF -DUSE_STATIC_MBEDTLS_LIBRARY=ON \
        $(cmake_cross_flags)

    cmake --build "$build" --parallel "$JOBS"
    cmake --install "$build"

    echo "    mbedTLS done."
}

build_protobuf_c() {
    echo ""
    echo "==> Building protobuf-c..."

    local version="1.5.0"
    local tarball="$BUILD_DIR/protobuf-c-${version}.tar.gz"
    local src="$BUILD_DIR/protobuf-c-${version}"

    if [ ! -d "$src" ]; then
        if [ ! -f "$tarball" ]; then
            curl -fsSL "https://github.com/protobuf-c/protobuf-c/releases/download/v${version}/protobuf-c-${version}.tar.gz" \
                -o "$tarball"
        fi
        tar -xzf "$tarball" -C "$BUILD_DIR"
    fi

    cd "$src"

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

build_ffmpeg() {
    echo ""
    echo "==> Building FFmpeg..."

    local src="$REPO_ROOT/external/ffmpeg"
    local build="$BUILD_DIR/ffmpeg"

    mkdir -p "$build"
    cd "$build"

    local cross_prefix_flags=()
    if [ -n "$TARGET" ]; then
        cross_prefix_flags+=(
            "--cross-prefix=${TARGET}-"
            "--arch=${TARGET%%-*}"
            "--target-os=linux"
            "--enable-cross-compile"
        )
    fi

    "$src/configure" \
        --prefix="$LIBS_DIR" --bindir="$BUILD_DIR/ffmpeg-bin" \
        --enable-static --disable-shared \
        --disable-everything \
        --enable-protocol=rtp --enable-protocol=udp --enable-protocol=tcp \
        --enable-demuxer=rtsp --enable-demuxer=rtp \
        --enable-demuxer=h264 --enable-demuxer=hevc \
        --enable-parser=h264 --enable-parser=hevc \
        --enable-parser=aac --enable-parser=opus \
        --enable-decoder=h264 --enable-decoder=hevc \
        --enable-decoder=aac --enable-decoder=opus \
        --enable-v4l2-m2m \
        --disable-avdevice --disable-avfilter \
        --disable-doc --disable-programs \
        --enable-pic --enable-optimizations \
        --extra-cflags="-I$LIBS_DIR/include" --extra-ldflags="-L$LIBS_DIR/lib" \
        "${cross_prefix_flags[@]+"${cross_prefix_flags[@]}"}"

    make -j"$JOBS"
    make install

    echo "    FFmpeg done."
}

check_deps
build_sdl2
build_sdl2_ttf
build_mbedtls
build_protobuf_c
build_ffmpeg

echo ""
echo "==> Bootstrap complete. Libraries placed in $LIBS_DIR"
