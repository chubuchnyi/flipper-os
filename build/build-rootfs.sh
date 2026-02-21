#!/bin/bash
# build-rootfs.sh — Build an OSTree-ready arm64 rootfs for Flipper OS.
#
# Usage:
#   sudo ./build/build-rootfs.sh [OPTIONS]
#     --from-tarball <path>   Import existing debian-ospack.tar.gz
#     --kernel-dir <path>     Directory with linux-image-*.deb
#     --output-dir <path>     Output rootfs directory
#     --no-kernel             Skip kernel installation
#
# Requires: root, mmdebstrap, qemu-user-static, binfmt_misc.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_env

# ── Defaults ──────────────────────────────────────────────────────────────────

FROM_TARBALL=""
KERNEL_DIR=""
ROOTFS_DIR="${FLIPPER_DEV}/ostree-work/rootfs"
INSTALL_KERNEL=1

# Minimal base package set (profile-agnostic)
PACKAGES=(
    # Core
    systemd systemd-sysv systemd-resolved systemd-timesyncd udev dbus
    # Boot
    initramfs-tools u-boot-menu libubootenv-tool
    # Network
    iproute2 iw iwd nftables openssh-server curl ca-certificates
    # Filesystem
    e2fsprogs ostree
    # Hardware
    rfkill bluez alsa-utils alsa-ucm-conf firmware-misc-nonfree firmware-realtek
    wireless-regdb
    # User essentials
    sudo locales bash-completion less nano
    # Misc required
    dnsmasq-base rsync usb-modeswitch usbutils pciutils
    iputils-ping wget
)

# ── Argument parsing ──────────────────────────────────────────────────────────

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --from-tarball)
                FROM_TARBALL="$2"; shift 2 ;;
            --kernel-dir)
                KERNEL_DIR="$2"; shift 2 ;;
            --output-dir)
                ROOTFS_DIR="$2"; shift 2 ;;
            --no-kernel)
                INSTALL_KERNEL=0; shift ;;
            -h|--help)
                head -n 12 "${BASH_SOURCE[0]}" | tail -n +2 | sed 's/^# \?//'
                exit 0 ;;
            *)
                die "Unknown option: $1" ;;
        esac
    done
}

# ── Prerequisite checks ──────────────────────────────────────────────────────

check_prereqs() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This script must be run as root (sudo)."
    fi

    require_cmd mmdebstrap "Install with: sudo apt install mmdebstrap"
    require_cmd qemu-aarch64-static "Install with: sudo apt install qemu-user-static"
    require_cmd rsync "Install with: sudo apt install rsync"

    # Check binfmt_misc for arm64 emulation (needed for cross-arch chroot)
    if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
        die "binfmt_misc for aarch64 not registered. Run: sudo systemctl restart binfmt-support"
    fi

    # Debian keyring (needed on Ubuntu hosts for cross-bootstrapping Debian)
    KEYRING="/usr/share/keyrings/debian-archive-keyring.gpg"
    if [ ! -f "$KEYRING" ]; then
        die "Debian archive keyring not found. Install with: sudo apt install debian-archive-keyring"
    fi
}

# ── Step 3: Create rootfs ────────────────────────────────────────────────────

create_rootfs() {
    if [ -n "$FROM_TARBALL" ]; then
        log_info "Extracting rootfs from tarball: $FROM_TARBALL"
        [ -f "$FROM_TARBALL" ] || die "Tarball not found: $FROM_TARBALL"
        mkdir -p "$ROOTFS_DIR"
        tar xf "$FROM_TARBALL" -C "$ROOTFS_DIR"
    else
        log_info "Building rootfs with mmdebstrap (arm64, trixie, minbase)"
        local pkg_list
        pkg_list=$(IFS=,; echo "${PACKAGES[*]}")

        # Remove stale rootfs if present; ensure parent dir exists
        if [ -d "$ROOTFS_DIR" ]; then
            log_warn "Removing existing rootfs: $ROOTFS_DIR"
            rm -rf "$ROOTFS_DIR"
        fi
        mkdir -p "$(dirname "$ROOTFS_DIR")"

        mmdebstrap \
            --architectures=arm64 \
            --variant=minbase \
            --keyring="$KEYRING" \
            --components="main,contrib,non-free,non-free-firmware" \
            --include="$pkg_list" \
            trixie "$ROOTFS_DIR"
    fi

    log_info "Rootfs created at $ROOTFS_DIR"
}

# ── Step 4: Install kernel ───────────────────────────────────────────────────

install_kernel() {
    if [ "$INSTALL_KERNEL" -eq 0 ]; then
        log_info "Skipping kernel installation (--no-kernel)"
        return
    fi

    # Auto-detect kernel dir: look in upstream build output or FLIPPER_DEV
    if [ -z "$KERNEL_DIR" ]; then
        local search_dirs=(
            "${FLIPPER_DEV}/kernel-debs"
            "${FLIPPER_DEV}/repos/flipper-linux-kernel/debian/output"
        )
        for d in "${search_dirs[@]}"; do
            if compgen -G "$d/linux-image-*.deb" >/dev/null 2>&1; then
                KERNEL_DIR="$d"
                break
            fi
        done
    fi

    if [ -z "$KERNEL_DIR" ] || ! compgen -G "$KERNEL_DIR/linux-image-*.deb" >/dev/null 2>&1; then
        log_warn "No kernel .deb found. Skipping kernel installation."
        log_warn "Use --kernel-dir <path> to provide kernel packages."
        return
    fi

    log_info "Installing kernel from $KERNEL_DIR"

    # Copy .deb(s) into rootfs temporarily
    local tmp_debs="$ROOTFS_DIR/tmp/kernel-debs"
    mkdir -p "$tmp_debs"
    cp "$KERNEL_DIR"/linux-image-*.deb "$tmp_debs/"

    setup_chroot "$ROOTFS_DIR"
    # shellcheck disable=SC2064
    trap "cleanup_mounts '$ROOTFS_DIR'" EXIT

    chroot "$ROOTFS_DIR" bash -c 'dpkg -i /tmp/kernel-debs/linux-image-*.deb'

    # Ensure vmlinuz is placed where OSTree/u-boot-menu expects it
    local kver
    kver=$(chroot "$ROOTFS_DIR" bash -c 'ls /lib/modules/ | head -1')
    if [ -n "$kver" ]; then
        local vmlinuz="$ROOTFS_DIR/boot/vmlinuz-$kver"
        local moddir="$ROOTFS_DIR/usr/lib/modules/$kver"
        if [ -f "$vmlinuz" ] && [ -d "$moddir" ]; then
            cp "$vmlinuz" "$moddir/vmlinuz"
            log_info "Kernel $kver: vmlinuz copied to /usr/lib/modules/$kver/vmlinuz"
        fi
    fi

    rm -rf "$tmp_debs"
    cleanup_mounts "$ROOTFS_DIR"
    trap - EXIT

    log_info "Kernel installation complete"
}

# ── Step 5: Apply overlays ───────────────────────────────────────────────────

apply_overlays() {
    local overlay_root="${FLIPPER_BUILD}/overlays"
    if [ ! -d "$overlay_root" ]; then
        log_warn "Overlay directory not found: $overlay_root — skipping"
        return
    fi

    log_info "Applying base overlays from $overlay_root"

    # configs → /etc (only hardware/system items, NOT desktop/profile stuff)
    local configs_src="$overlay_root/configs"
    if [ -d "$configs_src" ]; then
        rsync -a \
            --exclude='sddm.conf.d' \
            --exclude='wireplumber' \
            --exclude='polkit-1' \
            --exclude='xdg' \
            --exclude='wpa_supplicant' \
            --exclude='repart.d' \
            "$configs_src/" "$ROOTFS_DIR/etc/"
    fi

    # Exclude profile-specific systemd units
    rm -f "$ROOTFS_DIR/etc/systemd/system/usbc-router.target" 2>/dev/null || true
    rm -f "$ROOTFS_DIR/etc/systemd/user/plasma-kwin_wayland.service.d/override.conf" 2>/dev/null || true
    rm -rf "$ROOTFS_DIR/etc/systemd/user" 2>/dev/null || true

    # usr/local/bin scripts
    if [ -d "$overlay_root/usr/local/bin" ]; then
        rsync -a "$overlay_root/usr/local/bin/" "$ROOTFS_DIR/usr/local/bin/"
        chmod +x "$ROOTFS_DIR/usr/local/bin/"*.sh 2>/dev/null || true
    fi

    # usr/sbin (u-boot-update)
    if [ -d "$overlay_root/usr/sbin" ]; then
        rsync -a "$overlay_root/usr/sbin/" "$ROOTFS_DIR/usr/sbin/"
        chmod +x "$ROOTFS_DIR/usr/sbin/u-boot-update" 2>/dev/null || true
    fi

    # usr/share (u-boot-menu, alsa ucm2)
    if [ -d "$overlay_root/usr/share" ]; then
        rsync -a "$overlay_root/usr/share/" "$ROOTFS_DIR/usr/share/"
    fi

    # Firmware
    if [ -d "$overlay_root/firmware" ]; then
        rsync -a "$overlay_root/firmware/" "$ROOTFS_DIR/usr/lib/firmware/"
    fi

    log_info "Overlays applied"
}

# ── Step 6: Configure system ─────────────────────────────────────────────────

configure_system() {
    log_info "Configuring system"

    setup_chroot "$ROOTFS_DIR"
    # shellcheck disable=SC2064
    trap "cleanup_mounts '$ROOTFS_DIR'" EXIT

    chroot "$ROOTFS_DIR" bash -c '
        # Locale
        sed -i "s/^# en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
        locale-gen
        echo "LANG=en_US.UTF-8" > /etc/default/locale

        # Default user
        if ! id -u user >/dev/null 2>&1; then
            useradd -s /bin/bash -F -m user
            echo "user:user" | chpasswd
            gpasswd -a user sudo
        fi

        # Hostname (will be overwritten by set-hostname-and-banner at first boot)
        echo "flipper-os" > /etc/hostname

        # Enable services
        systemctl enable systemd-resolved 2>/dev/null || true
        systemctl enable systemd-timesyncd 2>/dev/null || true
        systemctl enable ssh 2>/dev/null || true
        systemctl enable iwd 2>/dev/null || true

        if [ -f /etc/systemd/system/set-hostname-and-banner.service ]; then
            systemctl enable set-hostname-and-banner.service 2>/dev/null || true
        fi

        if [ -f /etc/systemd/system/usb-ncm-gadget.service ]; then
            systemctl enable usb-ncm-gadget.service 2>/dev/null || true
        fi
    '

    # os-release additions
    local git_info="unknown"
    if command -v git >/dev/null 2>&1 && [ -d "$REPO_ROOT/.git" ]; then
        git_info="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    fi
    cat >> "$ROOTFS_DIR/etc/os-release" <<EOF
BUILD_GIT="$git_info"
FLIPPER_OS_VERSION="dev"
EOF

    # Add sbin to user PATH (single quotes intentional — literal $PATH for .bashrc)
    # shellcheck disable=SC2016
    printf '\nexport PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin\n' >> "$ROOTFS_DIR/home/user/.bashrc"

    cleanup_mounts "$ROOTFS_DIR"
    trap - EXIT

    log_info "System configured"
}

# ── Step 7: OSTree transformation ────────────────────────────────────────────

transform_for_ostree() {
    log_info "Transforming rootfs for OSTree"

    # 1. Move /etc → /usr/etc (3-way merge base)
    if [ -d "$ROOTFS_DIR/etc" ] && [ ! -d "$ROOTFS_DIR/usr/etc" ]; then
        mv "$ROOTFS_DIR/etc" "$ROOTFS_DIR/usr/etc"
    elif [ -d "$ROOTFS_DIR/etc" ] && [ -d "$ROOTFS_DIR/usr/etc" ]; then
        # Merge into existing /usr/etc
        rsync -a "$ROOTFS_DIR/etc/" "$ROOTFS_DIR/usr/etc/"
        rm -rf "${ROOTFS_DIR:?}/etc"
    fi

    # 2. Create required directories
    mkdir -p "$ROOTFS_DIR/sysroot"
    mkdir -p "$ROOTFS_DIR/var/home" \
             "$ROOTFS_DIR/var/opt" \
             "$ROOTFS_DIR/var/srv" \
             "$ROOTFS_DIR/var/mnt" \
             "$ROOTFS_DIR/var/roothome" \
             "$ROOTFS_DIR/var/log" \
             "$ROOTFS_DIR/var/tmp"

    # 3. Replace directories with symlinks
    # Remove existing dirs/files first, then create symlinks
    local -A symlinks=(
        [home]="var/home"
        [opt]="var/opt"
        [srv]="var/srv"
        [mnt]="var/mnt"
        [media]="run/media"
        [root]="var/roothome"
        [ostree]="sysroot/ostree"
    )

    for name in "${!symlinks[@]}"; do
        local target="${symlinks[$name]}"
        local path="$ROOTFS_DIR/$name"

        # Move any existing content to the target
        if [ -d "$path" ] && [ ! -L "$path" ]; then
            local dest="$ROOTFS_DIR/$target"
            mkdir -p "$dest"
            if [ "$(ls -A "$path" 2>/dev/null)" ]; then
                rsync -a "$path/" "$dest/"
            fi
            rm -rf "$path"
        elif [ -L "$path" ]; then
            rm -f "$path"
        fi

        ln -sf "$target" "$path"
    done

    # 4. Empty machine-id for systemd first-boot
    : > "$ROOTFS_DIR/usr/etc/machine-id"

    # 5. Remove machine-id from /var if present (systemd will populate it)
    rm -f "$ROOTFS_DIR/var/lib/dbus/machine-id" 2>/dev/null || true

    # 6. Clean /dev — OSTree cannot commit device nodes; devtmpfs is mounted at boot
    find "$ROOTFS_DIR/dev" -mindepth 1 -delete 2>/dev/null || true

    # 7. Clean up caches and transient data
    rm -rf "$ROOTFS_DIR/var/cache/apt/archives"/*.deb
    rm -rf "$ROOTFS_DIR/var/cache/apt/"*.bin
    rm -rf "$ROOTFS_DIR/var/lib/apt/lists"/*
    rm -rf "$ROOTFS_DIR/var/log"/*.log
    rm -rf "$ROOTFS_DIR/var/log/apt"
    rm -f  "$ROOTFS_DIR/var/log/dpkg.log"
    rm -f  "$ROOTFS_DIR/var/log/alternatives.log"
    rm -rf "$ROOTFS_DIR/tmp"/*

    # 7. Make rootfs world-readable so ostree commit works without sudo.
    #    File ownership is preserved in OSTree metadata regardless of host permissions.
    chmod -R a+rX "$ROOTFS_DIR"

    log_info "OSTree transformation complete"
}

# ── Step 8: Validate rootfs ──────────────────────────────────────────────────

validate_rootfs() {
    log_info "Validating rootfs structure"
    local errors=0

    # /usr/etc must exist
    if [ ! -d "$ROOTFS_DIR/usr/etc" ]; then
        log_error "Missing /usr/etc"
        errors=$((errors + 1))
    fi

    # /etc must NOT be a real directory
    if [ -d "$ROOTFS_DIR/etc" ] && [ ! -L "$ROOTFS_DIR/etc" ]; then
        log_error "/etc is a real directory — OSTree transformation failed"
        errors=$((errors + 1))
    fi

    # Required symlinks
    for link in home opt srv mnt media root ostree; do
        if [ ! -L "$ROOTFS_DIR/$link" ]; then
            log_error "/$link is not a symlink"
            errors=$((errors + 1))
        fi
    done

    # /sysroot must exist
    if [ ! -d "$ROOTFS_DIR/sysroot" ]; then
        log_error "Missing /sysroot"
        errors=$((errors + 1))
    fi

    # Machine-id must be empty
    if [ -f "$ROOTFS_DIR/usr/etc/machine-id" ] && [ -s "$ROOTFS_DIR/usr/etc/machine-id" ]; then
        log_error "/usr/etc/machine-id is not empty"
        errors=$((errors + 1))
    fi

    # Kernel check (non-fatal)
    if ! compgen -G "$ROOTFS_DIR/usr/lib/modules/*/vmlinuz" >/dev/null 2>&1; then
        log_warn "No kernel found in /usr/lib/modules/*/vmlinuz"
    fi

    if [ "$errors" -gt 0 ]; then
        die "Validation failed with $errors error(s)"
    fi

    log_info "Rootfs validation passed"
}

# ── Helpers ───────────────────────────────────────────────────────────────────

setup_chroot() {
    local rootfs="$1"
    mount --bind /dev  "$rootfs/dev"
    mount --bind /dev/pts "$rootfs/dev/pts"
    mount --bind /proc "$rootfs/proc"
    mount --bind /sys  "$rootfs/sys"
    mount --bind /run  "$rootfs/run" 2>/dev/null || true
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"
    check_prereqs

    log_info "=== Flipper OS rootfs build ==="
    log_info "Output: $ROOTFS_DIR"

    create_rootfs
    install_kernel
    apply_overlays
    configure_system
    transform_for_ostree
    validate_rootfs

    log_info "=== Rootfs build complete ==="
    log_info "Next step: ./build/ostree-commit.sh --rootfs $ROOTFS_DIR"
}

main "$@"
