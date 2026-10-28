FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu make bc flex bison libssl-dev libelf-dev \
    device-tree-compiler python3 cpio xz-utils ca-certificates gcc libc6-dev rsync kmod curl git \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /work
