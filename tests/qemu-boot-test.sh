#!/bin/bash
# qemu-boot-test.sh — Boot Flipper OS image in QEMU aarch64 virt and verify it reaches login.
#
# Usage:
#   ./tests/qemu-boot-test.sh [BOARD]
#   sudo ./tests/qemu-boot-test.sh [BOARD]   (if image extraction needs root)
#
# The script:
#   1. Extracts vmlinuz and initramfs from the image's boot partition
#   2. Boots QEMU virt with direct kernel, initrd, and the image as virtio disk
#   3. Waits for "login:" on serial (ttyAMA0) — timeout 120s
#   4. Reports PASS/FAIL
#
# Environment:
#   FLIPPER_DEV, OUT_DIR — loaded from ~/.flipper-one-dev/.env
#   IMAGE=<path>          — override image path
#   TIMEOUT=<seconds>     — override boot timeout (default: 120)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../build/lib/common.sh
source "$SCRIPT_DIR/../build/lib/common.sh"
load_env

# ── Defaults ──────────────────────────────────────────────────────────────────

BOARD="${1:-${BOARD:-rock-4d}}"
IMAGE="${IMAGE:-${OUT_DIR:-$FLIPPER_DEV/images}/flipper-os-${BOARD}.img}"
BOOT_TIMEOUT="${TIMEOUT:-120}"
QEMU_MEM="4096"

# ── Prerequisite checks ──────────────────────────────────────────────────────

require_cmd qemu-system-aarch64 \
    "Install with: sudo apt install qemu-system-arm"

if [ ! -f "$IMAGE" ]; then
    die "Image not found: $IMAGE (build with: make image BOARD=$BOARD)"
fi

# ── Work directory ────────────────────────────────────────────────────────────

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/flipper-qemu-test.XXXXXX")
SERIAL_LOG="$WORK_DIR/serial.log"
QEMU_PID=""
LOOP_DEV=""

cleanup_test() {
    if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi

    if mountpoint -q "$WORK_DIR/boot" 2>/dev/null; then
        umount "$WORK_DIR/boot" 2>/dev/null || true
    fi

    if [ -n "$LOOP_DEV" ]; then
        losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi

    rm -rf "$WORK_DIR"
}
trap cleanup_test EXIT

# ── Extract boot files from image ────────────────────────────────────────────

extract_boot_files() {
    log_info "Extracting boot files from $IMAGE"

    mkdir -p "$WORK_DIR/boot"

    # Setup loop device and mount boot partition (p1)
    LOOP_DEV=$(losetup -fP --show "$IMAGE")
    udevadm settle --timeout=5 2>/dev/null || sleep 1

    if [ ! -b "${LOOP_DEV}p1" ]; then
        die "Boot partition device not found: ${LOOP_DEV}p1"
    fi

    mount -o ro "${LOOP_DEV}p1" "$WORK_DIR/boot"

    # Parse extlinux.conf for kernel/initrd paths and boot args
    local extlinux="$WORK_DIR/boot/extlinux/extlinux.conf"
    if [ ! -f "$extlinux" ]; then
        die "extlinux.conf not found in boot partition"
    fi

    # Extract paths from extlinux.conf
    local linux_path initrd_path append_line
    linux_path=$(sed -n 's/^[[:space:]]*linux[[:space:]]\+//p' "$extlinux" | head -1)
    initrd_path=$(sed -n 's/^[[:space:]]*initrd[[:space:]]\+//p' "$extlinux" | head -1)
    append_line=$(sed -n 's/^[[:space:]]*append[[:space:]]\+//p' "$extlinux" | head -1)

    if [ -z "$linux_path" ]; then
        die "No linux= line found in extlinux.conf"
    fi

    # Copy vmlinuz
    local vmlinuz_src="$WORK_DIR/boot${linux_path}"
    if [ ! -f "$vmlinuz_src" ]; then
        die "Kernel not found at: $vmlinuz_src"
    fi
    cp "$vmlinuz_src" "$WORK_DIR/vmlinuz"

    # Copy initramfs (optional — boot may work without it for basic smoke test)
    if [ -n "$initrd_path" ] && [ -f "$WORK_DIR/boot${initrd_path}" ]; then
        cp "$WORK_DIR/boot${initrd_path}" "$WORK_DIR/initramfs.img"
    else
        log_warn "No initramfs found — boot may fail without ostree-prepare-root"
    fi

    # Build QEMU boot args: replace hardware console with PL011 (ttyAMA0)
    BOOT_ARGS="$append_line"
    # Replace any console=ttyS* with console=ttyAMA0
    # shellcheck disable=SC2001
    BOOT_ARGS=$(echo "$BOOT_ARGS" | sed 's/console=ttyS[^ ]*/console=ttyAMA0/g')
    # Remove console=tty1 (framebuffer — not available in -nographic mode)
    BOOT_ARGS="${BOOT_ARGS//console=tty1/}"
    # Ensure console=ttyAMA0 is present
    if ! echo "$BOOT_ARGS" | grep -q 'console=ttyAMA0'; then
        BOOT_ARGS="$BOOT_ARGS console=ttyAMA0"
    fi
    # Clean up extra spaces
    BOOT_ARGS=$(echo "$BOOT_ARGS" | tr -s ' ')

    # Unmount and release loop device
    umount "$WORK_DIR/boot"
    losetup -d "$LOOP_DEV"
    LOOP_DEV=""

    log_info "Kernel:  $WORK_DIR/vmlinuz"
    [ -f "$WORK_DIR/initramfs.img" ] && log_info "Initrd:  $WORK_DIR/initramfs.img"
    log_info "Boot args: $BOOT_ARGS"
}

# ── Run QEMU ─────────────────────────────────────────────────────────────────

run_qemu() {
    log_info "Starting QEMU (virt, cortex-a72, ${QEMU_MEM}MB RAM)"
    log_info "Timeout: ${BOOT_TIMEOUT}s"

    local qemu_args=(
        -M virt
        -cpu cortex-a72
        -m "$QEMU_MEM"
        -nographic
        -no-reboot
        -kernel "$WORK_DIR/vmlinuz"
        -drive "file=$IMAGE,format=raw,if=virtio,snapshot=on"
        -append "$BOOT_ARGS"
    )

    # Add initramfs if available
    if [ -f "$WORK_DIR/initramfs.img" ]; then
        qemu_args+=(-initrd "$WORK_DIR/initramfs.img")
    fi

    qemu-system-aarch64 "${qemu_args[@]}" > "$SERIAL_LOG" 2>&1 &
    QEMU_PID=$!

    log_info "QEMU PID: $QEMU_PID"
}

# ── Wait for login prompt ────────────────────────────────────────────────────

wait_for_boot() {
    local elapsed=0
    local poll_interval=2

    while [ "$elapsed" -lt "$BOOT_TIMEOUT" ]; do
        # Check if QEMU is still running
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            log_error "QEMU exited unexpectedly"
            log_error "Serial output (last 30 lines):"
            tail -30 "$SERIAL_LOG" >&2 || true
            return 1
        fi

        # Check for login prompt (systemd reached multi-user target)
        if grep -q "login:" "$SERIAL_LOG" 2>/dev/null; then
            return 0
        fi

        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))
    done

    log_error "Timeout after ${BOOT_TIMEOUT}s waiting for login prompt"
    log_error "Serial output (last 50 lines):"
    tail -50 "$SERIAL_LOG" >&2 || true
    return 1
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    log_info "=== Flipper OS QEMU boot test ==="
    log_info "Board: $BOARD"
    log_info "Image: $IMAGE"

    if [ "$(id -u)" -ne 0 ]; then
        die "This script needs root to mount the image boot partition. Run with sudo."
    fi

    extract_boot_files
    run_qemu

    if wait_for_boot; then
        # Kill QEMU gracefully
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
        QEMU_PID=""

        echo ""
        log_info "========================================="
        log_info "  PASS — systemd reached login prompt"
        log_info "========================================="
        echo ""
        log_info "Full serial log: $SERIAL_LOG"
        exit 0
    else
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
        QEMU_PID=""

        echo ""
        log_error "========================================="
        log_error "  FAIL — boot did not reach login prompt"
        log_error "========================================="
        echo ""
        log_info "Full serial log: $SERIAL_LOG"
        exit 1
    fi
}

main
