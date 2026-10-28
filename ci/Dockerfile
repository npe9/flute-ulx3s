# CI / build image for the ULX3S Flute SoC: everything the Makefile, the simulators and the Linux
# software build need, from public sources only.
#   docker build -t flute-ci ci/            (amd64; GitHub publishes ghcr.io/npe9/flute-ci)
FROM ubuntu:24.04

ARG BSC_VERSION=2025.01.1
ARG VERILATOR_VERSION=v5.052
ARG OSS_CAD_SUITE=2026-10-01

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git ca-certificates curl xz-utils python3 python3-venv gawk perl make \
      autoconf flex bison help2man libfl2 libfl-dev zlib1g-dev ccache \
      libgmp10 tcl \
      gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf \
      gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu device-tree-compiler \
      bc libssl-dev libelf-dev cpio rsync kmod \
 && rm -rf /var/lib/apt/lists/*

# Bluespec compiler (official release build).
RUN curl -fsSL https://github.com/B-Lang-org/bsc/releases/download/${BSC_VERSION}/bsc-${BSC_VERSION}-ubuntu-24.04.tar.gz \
      | tar -xz -C /opt && mv /opt/bsc-${BSC_VERSION}-ubuntu-24.04 /opt/bsc

# Yosys, nextpnr-ecp5, ecppack, iverilog (dated oss-cad-suite build).
RUN d=$(echo ${OSS_CAD_SUITE} | tr -d -); \
    curl -fsSL https://github.com/YosysHQ/oss-cad-suite-build/releases/download/${OSS_CAD_SUITE}/oss-cad-suite-linux-x64-$d.tgz \
      | tar -xz -C /opt

# Verilator pinned to the version the strict harnesses were validated with (x-initial/seed
# behavior is version-sensitive); goes on PATH ahead of oss-cad-suite's.
RUN git clone -q --depth 1 -b ${VERILATOR_VERSION} https://github.com/verilator/verilator /tmp/verilator \
 && cd /tmp/verilator && autoconf && ./configure --prefix=/opt/verilator \
 && make -j$(nproc) && make install && rm -rf /tmp/verilator

ENV PATH=/opt/verilator/bin:/opt/bsc/bin:$PATH:/opt/oss-cad-suite/bin
WORKDIR /work
