# Flipper OS — Development & Testing Container
#
# Builds the complete Flipper OS image and launches QEMU for interactive testing.
#
# Build:
#   docker build -t flipper-os .
#
# Run (full pipeline: build → test → interactive QEMU):
#   docker run --privileged -it flipper-os
#
# Run (QEMU only, requires prior build):
#   docker run --privileged -it flipper-os qemu
#
# Run (build only, no tests/QEMU):
#   docker run --privileged -it flipper-os build
#
# Run (drop into shell):
#   docker run --privileged -it flipper-os shell
#
# Persist build artifacts between runs (avoids rebuilding):
#   docker volume create flipper-os-data
#   docker run --privileged -it \
#     -v flipper-os-data:/root/flipper-one-dev/images \
#     -v flipper-os-data-ostree:/root/flipper-one-dev/ostree-work \
#     flipper-os
#
# NOTE: --privileged is required for losetup, mount, chroot, and binfmt_misc.

FROM ubuntu:24.04

LABEL maintainer="Flipper OS Team"
LABEL description="Flipper OS build environment with QEMU testing"

ENV DEBIAN_FRONTEND=noninteractive
ENV FLIPPER_DEV=/root/flipper-one-dev
ENV REPOS=/root/flipper-one-dev/repos
ENV ARCH=arm64
ENV CROSS_COMPILE=aarch64-linux-gnu-
ENV BOARD=rock-4d
ENV OSTREE_REPO=/root/flipper-one-dev/ostree-work/repo
ENV OUT_DIR=/root/flipper-one-dev/images
ENV FLIPPER_BUILD=/root/flipper-one-dev/repos/flipperone-linux-build-scripts
ENV PATH="/root/.cargo/bin:${PATH}"

# ── 1. System packages ───────────────────────────────────────────────────────

RUN apt-get update && apt-get install -y --no-install-recommends \
    # Core build tools
    git build-essential sudo ca-certificates \
    # Cross-compilation toolchain
    gcc-aarch64-linux-gnu g++-aarch64-linux-gnu binutils-aarch64-linux-gnu \
    # Kernel build dependencies
    bc bison flex libssl-dev libgnutls28-dev \
    python3-dev python3-libfdt python3-setuptools python3-pyelftools \
    swig device-tree-compiler u-boot-tools \
    # Kernel .deb packaging — native (host amd64) deps required by bindeb-pkg:
    #   debhelper-compat (= 12) → debhelper
    #   kmod                    → kmod
    #   libdw-dev:native        → libdw-dev
    #   libelf-dev:native       → libelf-dev
    debhelper kmod libdw-dev libelf-dev \
    # Rootfs & disk image tools
    mmdebstrap qemu-user-static binfmt-support debootstrap \
    debian-archive-keyring \
    dosfstools e2fsprogs parted gdisk kpartx \
    pigz squashfs-tools \
    curl wget rsync mtools fdisk \
    # OSTree
    ostree libostree-dev \
    # Build systems
    pkg-config meson ninja-build cmake \
    # Linting
    shellcheck \
    # Python
    python3-pip python3-venv \
    # QEMU system emulation (for booting the built image)
    qemu-system-arm \
    # Misc tools needed by build scripts
    udev file cpio \
    && rm -rf /var/lib/apt/lists/*

# dpkg-buildpackage wrapper: add -d to skip build-dep check for cross-builds.
#
# `make bindeb-pkg` calls `dpkg-buildpackage -a arm64` which then runs
# dpkg-checkbuilddeps and requires libssl-dev:arm64 (target arch). In reality
# the build only needs the host (amd64) libssl-dev — already installed above —
# because sign-file and similar host tools are compiled for the build machine.
# Setting up arm64 multiarch to satisfy a phantom dep is unnecessary; -d is
# the correct flag for cross-compilation where host tools satisfy the dep.
# /usr/local/bin is ahead of /usr/bin in PATH so this wrapper takes precedence.
RUN printf '#!/bin/sh\nexec /usr/bin/dpkg-buildpackage -d "$@"\n' \
    > /usr/local/bin/dpkg-buildpackage \
    && chmod +x /usr/local/bin/dpkg-buildpackage

RUN wget https://imagemagick.org/archive/ImageMagick.tar.gz \
    && tar xvf ImageMagick.tar.gz \ 
    && cd ImageMagick-7* \ 
    && ./configure \ 
    && make -j$(nproc) \ 
    && sudo make install \ 
    && sudo ldconfig \ 
    && cd .. && rm -rf ImageMagick*

# ── 2. Rust toolchain + zeekstd ──────────────────────────────────────────────

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
    && . /root/.cargo/env \
    && cargo install --git https://github.com/rorosen/zeekstd.git zeekstd_cli \
    && install -m 755 /root/.cargo/bin/zeekstd /usr/local/bin/

# ── 3. Create workspace ──────────────────────────────────────────────────────

RUN mkdir -p \
    ${FLIPPER_DEV}/repos \
    ${FLIPPER_DEV}/toolchain \
    ${FLIPPER_DEV}/images \
    ${FLIPPER_DEV}/rootfs \
    ${FLIPPER_DEV}/ostree-work \
    ${FLIPPER_DEV}/kernel-build

# ── 4. Clone required repositories ───────────────────────────────────────────
#
# Only repos needed for the build pipeline. Reference repos are skipped.

# Flipper build scripts (dev branch)
RUN git clone https://github.com/flipperdevices/flipperone-linux-build-scripts.git \
        ${REPOS}/flipperone-linux-build-scripts \
    && cd ${REPOS}/flipperone-linux-build-scripts \
    && git checkout dev

# RK3576 build output structure
RUN git clone https://github.com/flipperdevices/rk3576-linux-build.git \
        ${REPOS}/rk3576-linux-build

# Kernel source (large: ~2 GB — cached in Docker layer for faster rebuilds)
RUN git clone --depth=1 https://github.com/flipperdevices/flipper-linux-kernel.git \
        ${FLIPPER_DEV}/kernel-build/linux

# ── 5. Environment file ──────────────────────────────────────────────────────

RUN printf '%s\n' \
    'export FLIPPER_DEV="$HOME/flipper-one-dev"' \
    'export REPOS="$FLIPPER_DEV/repos"' \
    'export ARCH=arm64' \
    'export CROSS_COMPILE=aarch64-linux-gnu-' \
    'export INSTALL_MOD_PATH="$FLIPPER_DEV/rootfs"' \
    'export FLIPPER_BUILD="$REPOS/flipperone-linux-build-scripts"' \
    'export FLIPPER_UBOOT="$REPOS/flipper-u-boot"' \
    'export FLIPPER_KERNEL="$REPOS/flipper-linux-kernel"' \
    'export FLIPPER_TESTS="$REPOS/rk3576-linux-tests"' \
    'export RK3576_BUILD="$REPOS/rk3576-linux-build"' \
    'export KERNEL_DEBS="$REPOS/rk3576-linux-build/out/linux"' \
    'export UBOOT_BINARY="$REPOS/rk3576-linux-build/out/u-boot/flipper-one/u-boot-rockchip.bin"' \
    'export OSTREE_REPO="$FLIPPER_DEV/ostree-work/repo"' \
    'export BOARD=rock-4d' \
    'export OUT_DIR="$FLIPPER_DEV/images"' \
    'source "$HOME/.cargo/env" 2>/dev/null || true' \
    'export PATH="$FLIPPER_DEV/toolchain/bin:$PATH"' \
    > ${FLIPPER_DEV}/.env

# ── 6. Copy Flipper OS source ────────────────────────────────────────────────

COPY . ${FLIPPER_DEV}/flipper-os

# ── 7. Entrypoint ────────────────────────────────────────────────────────────

RUN chmod +x ${FLIPPER_DEV}/flipper-os/docker-entrypoint.sh \
    && ln -sf ${FLIPPER_DEV}/flipper-os/docker-entrypoint.sh \
              /usr/local/bin/docker-entrypoint.sh

WORKDIR ${FLIPPER_DEV}/flipper-os

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD []
