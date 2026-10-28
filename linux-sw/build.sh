#!/bin/bash
# Build OpenSBI + Linux + DTB + /init (base variant -> out/) in the flute-rv32-build docker image
# (docker build -t flute-rv32-build docker).  The kernel tree and build trees live in the
# case-sensitive docker volume flute-linux-src (macOS file systems are case-insensitive).
# The build itself is build-native.sh, which CI runs directly in the ci/Dockerfile image.
set -e
W=$(cd "$(dirname "$0")" && pwd)
docker run --rm -v flute-linux-src:/src -v "$W":/work flute-rv32-build \
  env LINUX_SRC=/src/linux BUILD_ROOT=/src/build /work/build-native.sh base
