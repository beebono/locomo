FROM ubuntu:24.04

ARG ZIG_VERSION=0.16.0
ARG DEBIAN_FRONTEND=noninteractive

RUN dpkg --add-architecture arm64 && \
    printf '\
Types: deb\n\
URIs: http://archive.ubuntu.com/ubuntu/\n\
Suites: noble noble-updates noble-backports\n\
Components: main restricted universe multiverse\n\
Architectures: amd64\n\
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n\
\n\
Types: deb\n\
URIs: http://security.ubuntu.com/ubuntu/\n\
Suites: noble-security\n\
Components: main restricted universe multiverse\n\
Architectures: amd64\n\
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n\
\n\
Types: deb\n\
URIs: http://ports.ubuntu.com/ubuntu-ports\n\
Suites: noble noble-updates noble-security\n\
Components: main restricted universe multiverse\n\
Architectures: arm64\n\
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n\
' > /etc/apt/sources.list.d/ubuntu.sources

RUN apt-get update && apt-get install -y \
    curl xz-utils wayland-scanner++ \
    libdbus-1-dev:arm64 libibus-1.0-dev:arm64 \
    libdrm-dev:arm64 libpulse-dev:arm64 libasound2-dev:arm64 \
    libegl-dev:arm64 libgles-dev:arm64 libgbm-dev:arm64 \
    libwayland-dev:arm64 libwayland-egl-backend-dev:arm64 \
    libxkbcommon-dev:arm64 libx11-dev:arm64 libxext-dev:arm64 \
    libxrandr-dev:arm64 libxcursor-dev:arm64 libxi-dev:arm64 \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /opt && \
    ln -s /opt/zig-x86_64-linux-${ZIG_VERSION}/zig /usr/local/bin/zig

WORKDIR /work
