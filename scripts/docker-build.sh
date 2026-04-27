#!/usr/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="locomo-builder"

# Cross compilation triplet envvar
TARGET="${TARGET:-aarch64-linux-gnu}"
ZIG_TARGET="${TARGET:+-Dtarget=$TARGET}"

docker build -t "$IMAGE" "$REPO_ROOT/docker"

docker run --rm \
    -v "$REPO_ROOT:/work" \
    -e "TARGET=$TARGET" \
    -e "JOBS=${JOBS:-$(nproc)}" \
    -e "ZIG_GLOBAL_CACHE_DIR=/work/.zig-cache" \
    -u "$(id -u):$(id -g)" \
    "$IMAGE" \
    bash -c "scripts/bootstrap.sh && zig build $ZIG_TARGET"
