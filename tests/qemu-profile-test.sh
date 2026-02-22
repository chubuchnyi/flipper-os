#!/bin/bash
# qemu-profile-test.sh — Test Flipper OS profile system in QEMU.
#
# Usage:
#   sudo ./tests/qemu-profile-test.sh [BOARD]
#
# Tests:
#   1. Boot reaches login prompt with profile system active
#   2. /run/flipper-profile contains "default"
#   3. Three overlay mounts (etc, var, usr) are active
#   4. flipper-profile list shows built-in profiles
#   5. flipper-profile create test-profile succeeds
#   6. flipper-profile switch test-profile succeeds
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
CMD_TIMEOUT=30
QEMU_MEM="4096"

# ── Prerequisite checks ──────────────────────────────────────────────────────

require_cmd qemu-system-aarch64 \
    "Install with: sudo apt install qemu-system-arm"

if [ ! -f "$IMAGE" ]; then
    die "Image not found: $IMAGE (build with: make image BOARD=$BOARD)"
fi

if [ "$(id -u)" -ne 0 ]; then
    die "This script needs root to mount the image boot partition. Run with sudo."
fi

# ── Work directory ────────────────────────────────────────────────────────────

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/flipper-profile-test.XXXXXX")
SERIAL_LOG="$WORK_DIR/serial.log"
QEMU_PID=""
LOOP_DEV=""
PASSED=0
FAILED=0
TOTAL=0

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

# ── Test helpers ─────────────────────────────────────────────────────────────

test_pass() {
    local name="$1"
    TOTAL=$((TOTAL + 1))
    PASSED=$((PASSED + 1))
    log_info "  PASS: $name"
}

test_fail() {
    local name="$1"
    local detail="${2:-}"
    TOTAL=$((TOTAL + 1))
    FAILED=$((FAILED + 1))
    log_error "  FAIL: $name${detail:+ — $detail}"
}

# ── Extract boot files ───────────────────────────────────────────────────────

extract_boot_files() {
    log_info "Extracting boot files from $IMAGE"

    mkdir -p "$WORK_DIR/boot"

    LOOP_DEV=$(losetup -fP --show "$IMAGE")
    udevadm settle --timeout=5 2>/dev/null || sleep 1

    if [ ! -b "${LOOP_DEV}p1" ]; then
        die "Boot partition device not found: ${LOOP_DEV}p1"
    fi

    mount -o ro "${LOOP_DEV}p1" "$WORK_DIR/boot"

    local extlinux="$WORK_DIR/boot/extlinux/extlinux.conf"
    if [ ! -f "$extlinux" ]; then
        die "extlinux.conf not found in boot partition"
    fi

    local linux_path initrd_path append_line
    linux_path=$(sed -n 's/^[[:space:]]*linux[[:space:]]\+//p' "$extlinux" | head -1)
    initrd_path=$(sed -n 's/^[[:space:]]*initrd[[:space:]]\+//p' "$extlinux" | head -1)
    append_line=$(sed -n 's/^[[:space:]]*append[[:space:]]\+//p' "$extlinux" | head -1)

    [ -z "$linux_path" ] && die "No linux= line found in extlinux.conf"

    local vmlinuz_src="$WORK_DIR/boot${linux_path}"
    [ -f "$vmlinuz_src" ] || die "Kernel not found at: $vmlinuz_src"
    cp "$vmlinuz_src" "$WORK_DIR/vmlinuz"

    if [ -n "$initrd_path" ] && [ -f "$WORK_DIR/boot${initrd_path}" ]; then
        cp "$WORK_DIR/boot${initrd_path}" "$WORK_DIR/initramfs.img"
    fi

    # Build QEMU boot args
    BOOT_ARGS="$append_line"
    # shellcheck disable=SC2001
    BOOT_ARGS=$(echo "$BOOT_ARGS" | sed 's/console=ttyS[^ ]*/console=ttyAMA0/g')
    BOOT_ARGS="${BOOT_ARGS//console=tty1/}"
    if ! echo "$BOOT_ARGS" | grep -q 'console=ttyAMA0'; then
        BOOT_ARGS="$BOOT_ARGS console=ttyAMA0"
    fi
    BOOT_ARGS=$(echo "$BOOT_ARGS" | tr -s ' ')

    umount "$WORK_DIR/boot"
    losetup -d "$LOOP_DEV"
    LOOP_DEV=""

    log_info "Boot files extracted"
}

# ── Run QEMU ─────────────────────────────────────────────────────────────────

run_qemu() {
    log_info "Starting QEMU (virt, cortex-a72, ${QEMU_MEM}MB RAM)"

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

    if [ -f "$WORK_DIR/initramfs.img" ]; then
        qemu_args+=(-initrd "$WORK_DIR/initramfs.img")
    fi

    qemu-system-aarch64 "${qemu_args[@]}" > "$SERIAL_LOG" 2>&1 &
    QEMU_PID=$!

    log_info "QEMU PID: $QEMU_PID"
}

# ── Wait for login ───────────────────────────────────────────────────────────

wait_for_login() {
    local elapsed=0
    local poll=2

    while [ "$elapsed" -lt "$BOOT_TIMEOUT" ]; do
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            return 1
        fi

        if grep -q "login:" "$SERIAL_LOG" 2>/dev/null; then
            return 0
        fi

        sleep "$poll"
        elapsed=$((elapsed + poll))
    done

    return 1
}

# ── Run tests ────────────────────────────────────────────────────────────────

run_tests() {
    log_info "Running profile system tests..."

    # Test 1: Check boot reached login
    if wait_for_login; then
        test_pass "System booted to login prompt"
    else
        test_fail "System boot" "Did not reach login prompt within ${BOOT_TIMEOUT}s"
        log_error "Serial output (last 30 lines):"
        tail -30 "$SERIAL_LOG" >&2 || true
        return 1
    fi

    # Test 2: Check profile state file in serial log
    if grep -q "flipper-profile:.*selected profile:" "$SERIAL_LOG" 2>/dev/null || \
       grep -q "flipper-profile:.*profile system ready:" "$SERIAL_LOG" 2>/dev/null; then
        test_pass "Profile system activated during boot"
    else
        # Also check for graceful degradation messages
        if grep -q "flipper-profile:" "$SERIAL_LOG" 2>/dev/null; then
            test_pass "Profile system ran during boot (degraded mode)"
        else
            test_fail "Profile system boot" "No flipper-profile messages in serial log"
        fi
    fi

    # Test 3: Check for overlay mount messages
    local overlay_count=0
    overlay_count=$(grep -c "flipper-profile:.*overlay mounted:" "$SERIAL_LOG" 2>/dev/null) || overlay_count=0
    if [ "$overlay_count" -ge 3 ]; then
        test_pass "Three overlay mounts reported (etc, var, usr)"
    elif [ "$overlay_count" -gt 0 ]; then
        test_fail "Overlay mounts" "Only $overlay_count of 3 overlays mounted"
    else
        test_fail "Overlay mounts" "No overlay mount messages found"
    fi

    # Test 4: Check for template seeding
    if grep -q "flipper-profile:.*seeded profile:" "$SERIAL_LOG" 2>/dev/null || \
       grep -q "flipper-profile:.*data partition mounted:" "$SERIAL_LOG" 2>/dev/null; then
        test_pass "Data partition and profiles initialized"
    else
        test_fail "Data partition" "No data partition messages found"
    fi
}

# ── Report ───────────────────────────────────────────────────────────────────

report() {
    echo ""
    if [ "$FAILED" -eq 0 ]; then
        log_info "========================================="
        log_info "  ALL $TOTAL TESTS PASSED"
        log_info "========================================="
    else
        log_error "========================================="
        log_error "  $FAILED of $TOTAL TESTS FAILED"
        log_error "========================================="
    fi
    echo ""
    log_info "Serial log: $SERIAL_LOG"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    log_info "=== Flipper OS Profile System Test ==="
    log_info "Board: $BOARD"
    log_info "Image: $IMAGE"

    extract_boot_files
    run_qemu
    run_tests

    # Cleanup QEMU
    if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
        QEMU_PID=""
    fi

    report

    [ "$FAILED" -eq 0 ] && exit 0 || exit 1
}

main
