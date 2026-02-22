#!/bin/bash
# build-image.sh — Build a bootable GPT disk image from an OSTree commit.
#
# Usage:
#   sudo ./build/build-image.sh [OPTIONS] [BOARD]
#     --ostree-repo <path>   OSTree repo (default: $OSTREE_REPO)
#     --branch <ref>         OSTree branch (default: flipper-os/base/latest)
#     --output <path>        Output .img file
#     --image-size <size>    Image size (default: 7600M)
#     --sysroot-size <size>  Sysroot partition size in MiB (default: 3072)
#     --boot-size <size>     Boot partition size in MiB (default: 256)
#     --uboot-bin <path>     Path to u-boot-rockchip.bin
#     --no-uboot             Skip U-Boot installation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_env

# ── Defaults ──────────────────────────────────────────────────────────────────

OSTREE_REPO_PATH="${OSTREE_REPO}"
BRANCH="flipper-os/base/latest"
IMG_FILE=""
IMAGE_SIZE="7600M"
BOOT_SIZE_MIB=256
SYSROOT_SIZE_MIB=3072
UBOOT_BIN=""
SKIP_UBOOT=0

# Populated at runtime
LOOP_DEV=""
DEPLOY_MODE=""  # "admin" or "checkout"
WORK_DIR=""
SYSROOT_MNT=""
BOOT_MNT=""
DATA_MNT=""

# ── Argument parsing ──────────────────────────────────────────────────────────

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --ostree-repo)   OSTREE_REPO_PATH="$2"; shift 2 ;;
            --branch)        BRANCH="$2"; shift 2 ;;
            --output)        IMG_FILE="$2"; shift 2 ;;
            --image-size)    IMAGE_SIZE="$2"; shift 2 ;;
            --sysroot-size)  SYSROOT_SIZE_MIB="$2"; shift 2 ;;
            --boot-size)     BOOT_SIZE_MIB="$2"; shift 2 ;;
            --uboot-bin)     UBOOT_BIN="$2"; shift 2 ;;
            --no-uboot)      SKIP_UBOOT=1; shift ;;
            -h|--help)
                head -n 14 "${BASH_SOURCE[0]}" | tail -n +2 | sed 's/^# \?//'
                exit 0 ;;
            -*)
                die "Unknown option: $1" ;;
            *)
                BOARD="$1"; shift ;;
        esac
    done

    BOARD="${BOARD:-rock-4d}"

    if [ -z "$IMG_FILE" ]; then
        mkdir -p "${OUT_DIR:-$FLIPPER_DEV/images}"
        IMG_FILE="${OUT_DIR:-$FLIPPER_DEV/images}/flipper-os-${BOARD}.img"
    fi
}

# ── Prerequisite checks ──────────────────────────────────────────────────────

check_prereqs() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This script must be run as root (sudo)."
    fi

    require_cmd sfdisk    "Install with: sudo apt install fdisk"
    require_cmd mkfs.ext4 "Install with: sudo apt install e2fsprogs"
    require_cmd losetup   "Install with: sudo apt install mount"
    require_cmd ostree    "Install with: sudo apt install ostree"
    require_cmd truncate  "Install with: sudo apt install coreutils"

    if [ ! -d "$OSTREE_REPO_PATH/objects" ]; then
        die "OSTree repo not found at $OSTREE_REPO_PATH. Run build-rootfs.sh + ostree-commit.sh first."
    fi

    if ! ostree rev-parse --repo="$OSTREE_REPO_PATH" "$BRANCH" >/dev/null 2>&1; then
        die "Branch '$BRANCH' not found in repo $OSTREE_REPO_PATH"
    fi
}

# ── Find U-Boot binary ───────────────────────────────────────────────────────

find_uboot() {
    if [ "$SKIP_UBOOT" -eq 1 ]; then
        return
    fi

    if [ -n "$UBOOT_BIN" ] && [ -f "$UBOOT_BIN" ]; then
        log_info "Using U-Boot binary: $UBOOT_BIN"
        return
    fi

    local search_paths=(
        "${REPOS:-}/rk3576-linux-build/out/u-boot/${BOARD}/u-boot-rockchip.bin"
        "${REPOS:-}/flipperone-linux-build-scripts/prebuilt/u-boot/${BOARD}/u-boot-rockchip.bin"
        "${FLIPPER_DEV}/u-boot-rockchip.bin"
    )

    for p in "${search_paths[@]}"; do
        if [ -f "$p" ]; then
            UBOOT_BIN="$p"
            log_info "Found U-Boot binary: $UBOOT_BIN"
            return
        fi
    done

    log_warn "U-Boot binary not found. Image will not be directly bootable on hardware."
    log_warn "Use --uboot-bin <path> or --no-uboot to suppress this warning."
}

# ── Cleanup (trap handler) ───────────────────────────────────────────────────

cleanup() {
    log_info "Cleaning up..."

    for mnt in "${DATA_MNT:-}" "${BOOT_MNT:-}" "${SYSROOT_MNT:-}"; do
        if [ -n "$mnt" ] && mountpoint -q "$mnt" 2>/dev/null; then
            umount -l "$mnt" 2>/dev/null || true
        fi
    done

    if [ -n "${LOOP_DEV:-}" ]; then
        losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi

    if [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}

# ── Step 4: Create raw image ─────────────────────────────────────────────────

create_image() {
    log_info "Creating raw image: $IMG_FILE ($IMAGE_SIZE)"
    mkdir -p "$(dirname "$IMG_FILE")"
    truncate -s "$IMAGE_SIZE" "$IMG_FILE"
}

# ── Step 5: Partition image ──────────────────────────────────────────────────

partition_image() {
    log_info "Partitioning image (GPT)"

    # Calculate sector counts (512-byte sectors)
    local boot_start_mib=16
    local boot_sectors=$(( BOOT_SIZE_MIB * 2048 ))
    local sysroot_sectors=$(( SYSROOT_SIZE_MIB * 2048 ))
    local boot_start_sectors=$(( boot_start_mib * 2048 ))

    sfdisk "$IMG_FILE" <<EOF
label: gpt
unit: sectors
sector-size: 512

start=${boot_start_sectors}, size=${boot_sectors}, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="boot"
size=${sysroot_sectors}, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="sysroot"
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="data"
EOF
}

# ── Step 6: Setup loop device ────────────────────────────────────────────────

setup_loop() {
    LOOP_DEV=$(losetup -fP --show "$IMG_FILE")
    log_info "Loop device: $LOOP_DEV"

    # Wait for partition devices to appear
    udevadm settle --timeout=5 2>/dev/null || sleep 1

    if [ ! -b "${LOOP_DEV}p1" ]; then
        die "Partition devices did not appear (${LOOP_DEV}p1 missing)"
    fi
}

# ── Step 7: Format partitions ────────────────────────────────────────────────

format_partitions() {
    log_info "Formatting partitions"

    # boot: disable metadata_csum for U-Boot ext4 driver compatibility
    mkfs.ext4 -F -q -L boot    -O ^metadata_csum "${LOOP_DEV}p1"
    mkfs.ext4 -F -q -L sysroot                   "${LOOP_DEV}p2"
    mkfs.ext4 -F -q -L data                      "${LOOP_DEV}p3"
}

# ── Step 8: Mount partitions ─────────────────────────────────────────────────

mount_partitions() {
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/flipper-image.XXXXXX")
    SYSROOT_MNT="$WORK_DIR/sysroot"
    DATA_MNT="$WORK_DIR/data"

    mkdir -p "$SYSROOT_MNT" "$DATA_MNT"
    mount "${LOOP_DEV}p2" "$SYSROOT_MNT"

    # Mount boot INSIDE sysroot so ostree admin deploy places files there
    mkdir -p "$SYSROOT_MNT/boot"
    mount "${LOOP_DEV}p1" "$SYSROOT_MNT/boot"
    BOOT_MNT="$SYSROOT_MNT/boot"

    mount "${LOOP_DEV}p3" "$DATA_MNT"
}

# ── Step 9: Deploy OSTree ────────────────────────────────────────────────────

deploy_ostree() {
    log_info "Deploying OSTree commit to sysroot"

    # 1. Initialize OSTree sysroot structure
    ostree admin init-fs --modern "$SYSROOT_MNT"

    # 2. Initialize a bare repo on sysroot
    #    Build repo is archive-z2; sysroot needs bare for hardlinked deployments
    ostree init --repo="$SYSROOT_MNT/ostree/repo" --mode=bare

    # 3. Pull commit from build repo into sysroot repo
    log_info "Pulling commit from build repo..."
    ostree pull-local --repo="$SYSROOT_MNT/ostree/repo" "$OSTREE_REPO_PATH" "$BRANCH"

    # 4. Create stateroot
    ostree admin os-init --sysroot="$SYSROOT_MNT" flipper-os

    # 5. Deploy
    log_info "Running ostree admin deploy..."
    if ostree admin deploy \
        --sysroot="$SYSROOT_MNT" \
        --os=flipper-os \
        --no-merge \
        --karg-none \
        --karg="root=LABEL=sysroot" \
        --karg="rw" \
        --karg="rootwait" \
        --karg="console=ttyS0,1500000n8" \
        --karg="console=tty1" \
        --karg="audit=0" \
        "$BRANCH" 2>&1; then
        DEPLOY_MODE="admin"
    else
        # Fallback: ostree admin deploy fails without a kernel in the commit.
        # Use ostree checkout for development/testing (image won't be bootable).
        log_warn "ostree admin deploy failed (likely no kernel in commit)"
        log_warn "Falling back to ostree checkout — image will NOT be bootable"
        DEPLOY_MODE="checkout"

        local checksum
        checksum=$(ostree rev-parse --repo="$SYSROOT_MNT/ostree/repo" "$BRANCH")
        local deploy_dest="$SYSROOT_MNT/ostree/deploy/flipper-os/deploy/${checksum}.0"

        # ostree checkout creates the target dir — ensure parent exists but target does not
        mkdir -p "$(dirname "$deploy_dest")"
        rm -rf "$deploy_dest"
        ostree checkout --repo="$SYSROOT_MNT/ostree/repo" "$BRANCH" "$deploy_dest"

        # Create var directory for the stateroot
        mkdir -p "$SYSROOT_MNT/ostree/deploy/flipper-os/var"
    fi

    # Verify deployment exists
    local deploy_dir="$SYSROOT_MNT/ostree/deploy/flipper-os/deploy"
    if [ ! -d "$deploy_dir" ] || [ -z "$(ls -A "$deploy_dir")" ]; then
        die "OSTree deployment directory is empty: $deploy_dir"
    fi

    local deploy_name
    deploy_name=$(find "$deploy_dir" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | head -1)
    log_info "Deployment: $deploy_name"
}

# ── Step 10: Setup boot partition ─────────────────────────────────────────────

setup_boot() {
    log_info "Setting up boot partition (extlinux.conf)"

    # Find kernel version from the deployment
    local deploy_path
    deploy_path=$(find "$SYSROOT_MNT/ostree/deploy/flipper-os/deploy" \
                       -maxdepth 1 -mindepth 1 -type d | head -1)

    local kver=""
    if [ -d "$deploy_path/usr/lib/modules" ] && [ -n "$(ls -A "$deploy_path/usr/lib/modules" 2>/dev/null)" ]; then
        kver=$(find "$deploy_path/usr/lib/modules/" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | head -1)
    fi

    if [ -z "$kver" ]; then
        log_warn "No kernel in deployment — boot partition will be incomplete"
        log_warn "Rebuild rootfs with --kernel-dir to get a bootable image"
    fi

    # Generate extlinux.conf from BLS entry (created by ostree admin deploy)
    generate_extlinux "$kver"
}

generate_extlinux() {
    local kver="$1"
    local bls_linux="" bls_initrd="" bls_options=""

    # Try reading BLS entry created by ostree admin deploy
    local bls_entry=""
    if [ -d "$BOOT_MNT/loader/entries" ]; then
        bls_entry=$(find "$BOOT_MNT/loader/entries" -name "*.conf" | head -1 || true)
    fi

    if [ -n "$bls_entry" ] && [ -f "$bls_entry" ]; then
        bls_linux=$(grep "^linux " "$bls_entry" | awk '{print $2}')
        bls_initrd=$(grep "^initrd " "$bls_entry" | awk '{print $2}' || true)
        bls_options=$(sed -n 's/^options //p' "$bls_entry")
        log_info "BLS entry found: $bls_entry"
    else
        log_warn "No BLS entry found — constructing extlinux.conf manually"

        # Find ostree boot dir (if admin deploy partially succeeded or checkout placed files)
        local ostree_boot_dir=""
        if [ -d "$BOOT_MNT/ostree" ]; then
            ostree_boot_dir=$(find "$BOOT_MNT/ostree" -maxdepth 1 -mindepth 1 -type d | head -1 || true)
        fi

        if [ -n "$ostree_boot_dir" ]; then
            local boot_subdir
            boot_subdir=$(basename "$ostree_boot_dir")
            bls_linux="/ostree/$boot_subdir/vmlinuz"
            bls_initrd="/ostree/$boot_subdir/initramfs.img"
        else
            bls_linux="/vmlinuz"
            bls_initrd="/initramfs.img"
            log_warn "No kernel found in boot partition"
        fi

        # Get deploy checksum for ostree= karg
        local deploy_checksum
        deploy_checksum=$(find "$SYSROOT_MNT/ostree/deploy/flipper-os/deploy" \
                               -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | head -1)
        bls_options="root=LABEL=sysroot rw rootwait console=ttyS0,1500000n8 console=tty1 audit=0 ostree=/ostree/deploy/flipper-os/deploy/$deploy_checksum"
    fi

    # Determine FDT directory
    local fdt_line=""
    if [ -n "$kver" ]; then
        local deploy_name
        deploy_name=$(find "$SYSROOT_MNT/ostree/deploy/flipper-os/deploy" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | head -1)
        local dtb_src="$SYSROOT_MNT/ostree/deploy/flipper-os/deploy/$deploy_name/usr/lib/linux-image-$kver"
        if [ -d "$dtb_src" ]; then
            local dtb_dest="$BOOT_MNT/dtbs/$kver"
            mkdir -p "$dtb_dest"
            rsync -a "$dtb_src/" "$dtb_dest/"
            fdt_line="    fdtdir /dtbs/$kver/rockchip/"
        fi
    fi

    # Ensure ostree= is present in boot options
    if ! echo "$bls_options" | grep -q 'ostree='; then
        local deploy_checksum
        deploy_checksum=$(find "$SYSROOT_MNT/ostree/deploy/flipper-os/deploy" \
                               -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | head -1)
        if [ -n "$deploy_checksum" ]; then
            bls_options="$bls_options ostree=/ostree/deploy/flipper-os/deploy/$deploy_checksum"
            log_info "Added ostree= to boot options"
        fi
    fi

    mkdir -p "$BOOT_MNT/extlinux"
    cat > "$BOOT_MNT/extlinux/extlinux.conf" <<EOF
## /extlinux/extlinux.conf
## Generated by Flipper OS build-image.sh

default l0
menu title Flipper OS
prompt 1
timeout 50

label l0
    menu label Flipper OS ${kver:-unknown}
    linux ${bls_linux}
EOF

    if [ -n "$bls_initrd" ]; then
        echo "    initrd ${bls_initrd}" >> "$BOOT_MNT/extlinux/extlinux.conf"
    fi

    if [ -n "$fdt_line" ]; then
        echo "$fdt_line" >> "$BOOT_MNT/extlinux/extlinux.conf"
    fi

    echo "    append ${bls_options}" >> "$BOOT_MNT/extlinux/extlinux.conf"

    log_info "extlinux.conf written"
    log_info "Boot options: $bls_options"
}

# ── Step 11: Setup data partition ─────────────────────────────────────────────

setup_data() {
    log_info "Initializing data partition"
    mkdir -p "$DATA_MNT/profiles"
    mkdir -p "$DATA_MNT/flatpak"
    mkdir -p "$DATA_MNT/shared"
}

# ── Step 13: Install U-Boot ──────────────────────────────────────────────────

install_uboot() {
    if [ "$SKIP_UBOOT" -eq 1 ]; then
        log_info "Skipping U-Boot installation (--no-uboot)"
        return
    fi

    if [ -z "${UBOOT_BIN:-}" ] || [ ! -f "${UBOOT_BIN:-}" ]; then
        log_warn "U-Boot binary not available — image will not boot on hardware"
        return
    fi

    log_info "Installing U-Boot from $UBOOT_BIN"

    # u-boot-rockchip.bin (combined TPL+SPL+U-Boot) goes at sector 64 (32KB)
    # This matches Rockchip BootROM expectations
    dd if="$UBOOT_BIN" of="$IMG_FILE" seek=64 conv=notrunc bs=512 status=none

    log_info "U-Boot installed at sector 64"
}

# ── Step 14: Verify image ────────────────────────────────────────────────────

verify_image() {
    log_info "Verifying image"
    sfdisk -l "$IMG_FILE" 2>&1 | grep -E '(Disk |Device|flipper)' || true

    local actual_size
    actual_size=$(stat --format="%s" "$IMG_FILE")
    log_info "Image size: $(( actual_size / 1024 / 1024 ))MB"

    if [ "$DEPLOY_MODE" = "checkout" ]; then
        log_warn "Image built with ostree checkout fallback (no kernel in commit)"
        log_warn "Image is NOT bootable. Rebuild rootfs with kernel for a bootable image."
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"
    check_prereqs
    find_uboot

    log_info "=== Flipper OS image build ==="
    log_info "Board:       $BOARD"
    log_info "OSTree repo: $OSTREE_REPO_PATH"
    log_info "Branch:      $BRANCH"
    log_info "Image:       $IMG_FILE"
    log_info "Image size:  $IMAGE_SIZE"

    trap cleanup EXIT

    create_image
    partition_image
    setup_loop
    format_partitions
    mount_partitions
    deploy_ostree
    setup_boot
    setup_data

    # Unmount and detach before writing U-Boot to the raw image
    log_info "Syncing and unmounting..."
    sync
    umount "$DATA_MNT"
    umount "$BOOT_MNT"
    umount "$SYSROOT_MNT"
    losetup -d "$LOOP_DEV"
    LOOP_DEV=""  # Prevent cleanup from trying again

    install_uboot
    verify_image

    log_info "=== Image build complete ==="
    log_info "Output: $IMG_FILE"
    log_info "Flash with: dd if=$IMG_FILE of=/dev/sdX bs=4M status=progress"
}

main "$@"
