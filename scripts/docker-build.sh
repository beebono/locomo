#!/usr/bin/bash
# Main docker-based locomo build script

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="locomo-builder"
TARGET="${TARGET:-aarch64-linux-gnu}"

docker build -t "$IMAGE" "$REPO_ROOT/docker"

docker run --rm \
    -v "$REPO_ROOT:/work" \
    -e "TARGET=$TARGET" \
    -e "ZIG_GLOBAL_CACHE_DIR=/work/.zig-cache" \
    -u "$(id -u):$(id -g)" \
    "$IMAGE" \
    bash -c "scripts/bootstrap.sh && zig build -Dtarget=$TARGET -Doptimize=ReleaseFast"
