FROM ubuntu:20.04

ARG ZIG_VERSION=0.16.0
ARG DEBIAN_FRONTEND=noninteractive

RUN dpkg --add-architecture arm64

RUN sed -i 's/^deb /deb [arch=amd64] /' /etc/apt/sources.list && \
    echo "deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports focal main restricted universe multiverse\n\
deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports focal-updates main restricted universe multiverse\n\
deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports focal-security main restricted universe multiverse" \
    >> /etc/apt/sources.list

RUN apt-get update && apt-get install -y \
    build-essential cmake make nasm pkg-config git curl xz-utils \
    gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
    libdbus-1-dev:arm64 libibus-1.0-dev:arm64 libudev-dev:arm64 \
    libegl-dev:arm64 libgles-dev:arm64 \
    libdrm-dev:arm64 libgbm-dev:arm64 libpulse-dev:arm64 \
    libwayland-dev:arm64 libwayland-egl-backend-dev:arm64 \
    libxkbcommon-dev:arm64 libx11-dev:arm64 libxext-dev:arm64 \
    libxrandr-dev:arm64 libxcursor-dev:arm64 libxi-dev:arm64 \
    && rm -rf /var/lib/apt/lists/*

# Cross pkg-config wrapper for aarch64
# Preserves PKG_CONFIG_LIBDIR from the caller (for local libs) and appends system paths.
RUN printf '#!/bin/sh\nPKG_CONFIG_PATH="" PKG_CONFIG_LIBDIR="${PKG_CONFIG_LIBDIR:+$PKG_CONFIG_LIBDIR:}/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig" pkg-config "$@"\n' \
    > /usr/local/bin/aarch64-linux-gnu-pkg-config && \
    chmod +x /usr/local/bin/aarch64-linux-gnu-pkg-config

RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /opt && \
    ln -s /opt/zig-x86_64-linux-${ZIG_VERSION}/zig /usr/local/bin/zig

WORKDIR /work
