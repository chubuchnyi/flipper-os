#!/bin/bash
# shellcheck disable=SC2059  # printf with color variables in format string is intentional
# docker-entrypoint.sh — Flipper OS: build, test, and launch interactive QEMU.
#
# Commands:
#   (default)   Full pipeline: build → test → QEMU
#   build       Build the image only
#   test        Run automated tests only
#   qemu        Launch interactive QEMU only (image must exist)
#   shell       Drop into a bash shell
#   <cmd>       Execute arbitrary command

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────

if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    CYAN='\033[0;36m'
    YELLOW='\033[0;33m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' CYAN='' YELLOW='' BOLD='' RESET=''
fi

info()  { printf "${CYAN}[INFO]${RESET}  %s\n" "$*"; }
ok()    { printf "${GREEN}[ OK ]${RESET}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*"; }
err()   { printf "${RED}[ERR]${RESET}  %s\n" "$*" >&2; }

print_volume_hint() {
    err "Each 'docker run' creates a fresh container — build artifacts don't persist."
    err ""
    err "Option 1 — full pipeline in one command (build + test + qemu):"
    err "  docker run --privileged -it flipper-os"
    err ""
    err "Option 2 — persist artifacts with volumes for separate build/qemu runs:"
    err "  docker run --privileged -it \\"
    err "    -v flipper-os-images:${OUT_DIR} \\"
    err "    -v flipper-os-ostree:${FLIPPER_DEV}/ostree-work \\"
    err "    flipper-os build"
    err ""
    err "  docker run --privileged -it \\"
    err "    -v flipper-os-images:${OUT_DIR} \\"
    err "    flipper-os qemu"
}

# ── Environment ───────────────────────────────────────────────────────────────

export HOME=/root
# shellcheck source=/dev/null
source /root/flipper-one-dev/.env 2>/dev/null || true

export FLIPPER_DEV="${FLIPPER_DEV:-/root/flipper-one-dev}"
export BOARD="${BOARD:-rock-4d}"
export OUT_DIR="${OUT_DIR:-$FLIPPER_DEV/images}"
export OSTREE_REPO="${OSTREE_REPO:-$FLIPPER_DEV/ostree-work/repo}"

IMAGE="$OUT_DIR/flipper-os-${BOARD}.img"

cd "$FLIPPER_DEV/flipper-os"

# ── Ensure loop devices are available ──────────────────────────────────────────
#
# In a fresh container /dev/loop* nodes may not exist even with --privileged.
# The build pipeline creates them implicitly, but qemu-only runs need them for
# losetup to extract kernel/initramfs from the disk image.

ensure_loop_devices() {
    modprobe loop 2>/dev/null || true
    if ! losetup -f &>/dev/null; then
        for i in $(seq 0 7); do
            [ -b "/dev/loop$i" ] || mknod "/dev/loop$i" b 7 "$i" 2>/dev/null || true
        done
    fi
}

# ── Setup binfmt_misc for cross-arch chroot ───────────────────────────────────

setup_binfmt() {
    info "Setting up binfmt_misc for ARM64 emulation..."

    # Mount binfmt_misc filesystem if not already mounted
    if [ ! -f /proc/sys/fs/binfmt_misc/register ]; then
        mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
    fi

    # Enable ARM64 QEMU handler
    update-binfmts --enable qemu-aarch64 2>/dev/null || true

    if [ -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
        ok "binfmt_misc: ARM64 handler registered"
    else
        warn "binfmt_misc: ARM64 handler not found"
        warn "Cross-arch chroot (mmdebstrap) may fail."
        warn "On host, run: docker run --privileged --rm tonistiigi/binfmt --install all"
    fi
}

# ── Build pipeline ────────────────────────────────────────────────────────────

build_all() {
    if [ -f "$IMAGE" ]; then
        ok "Image already exists: $IMAGE"
        info "Skipping build. Delete the image to force rebuild."
        return 0
    fi

    local start_time=$SECONDS

    printf "\n${BOLD}══════════════════════════════════════════${RESET}\n"
    printf "${BOLD}  Flipper OS — Full Build Pipeline${RESET}\n"
    printf "${BOLD}══════════════════════════════════════════${RESET}\n\n"

    # Step 1: Kernel
    printf "\n${BOLD}── Step 1/4: Kernel ──${RESET}\n\n"
    info "Building ARM64 kernel (this takes 20-40 minutes)..."
    ./build/build-kernel.sh
    ok "Kernel build complete"

    # Step 2: Rootfs
    printf "\n${BOLD}── Step 2/4: Rootfs ──${RESET}\n\n"
    info "Building OSTree-ready rootfs via mmdebstrap..."
    ./build/build-rootfs.sh
    ok "Rootfs build complete"

    # Step 3: OSTree commit
    printf "\n${BOLD}── Step 3/4: OSTree Commit ──${RESET}\n\n"
    info "Committing rootfs to OSTree repository..."
    ./build/ostree-commit.sh
    ok "OSTree commit complete"

    # Step 4: Disk image
    printf "\n${BOLD}── Step 4/4: Disk Image ──${RESET}\n\n"
    info "Building GPT disk image..."
    ./build/build-image.sh "$BOARD"
    ok "Disk image complete: $IMAGE"

    local elapsed=$(( SECONDS - start_time ))
    local min=$(( elapsed / 60 ))
    local sec=$(( elapsed % 60 ))
    printf "\n${GREEN}${BOLD}Build finished in ${min}m ${sec}s${RESET}\n\n"
}

# ── Run tests ─────────────────────────────────────────────────────────────────

run_tests() {
    if [ ! -f "$IMAGE" ]; then
        err "Image not found: $IMAGE"
        print_volume_hint
        return 1
    fi

    ensure_loop_devices

    printf "\n${BOLD}══════════════════════════════════════════${RESET}\n"
    printf "${BOLD}  Running Automated Tests${RESET}\n"
    printf "${BOLD}══════════════════════════════════════════${RESET}\n\n"

    local passed=0
    local failed=0

    # Test 1: Boot test
    info "Test 1/2: QEMU boot test (systemd reaches login prompt)..."
    if ./tests/qemu-boot-test.sh "$BOARD"; then
        ok "Boot test PASSED"
        passed=$((passed + 1))
    else
        warn "Boot test FAILED"
        failed=$((failed + 1))
    fi

    # Test 2: Profile system test
    info "Test 2/2: Profile system test (overlays, CLI, create/switch)..."
    if ./tests/qemu-profile-test.sh "$BOARD"; then
        ok "Profile test PASSED"
        passed=$((passed + 1))
    else
        warn "Profile test FAILED"
        failed=$((failed + 1))
    fi

    printf "\n${BOLD}Results: ${passed} passed, ${failed} failed${RESET}\n\n"

    if [ "$failed" -gt 0 ]; then
        warn "Some tests failed. The image may still boot — launching QEMU anyway."
    fi
}

# ── Launch interactive QEMU ──────────────────────────────────────────────────

launch_qemu() {
    if [ ! -f "$IMAGE" ]; then
        err "Image not found: $IMAGE"
        print_volume_hint
        exit 1
    fi

    info "Extracting boot files from image..."
    ensure_loop_devices

    local work_dir
    work_dir=$(mktemp -d /tmp/flipper-qemu.XXXXXX)
    # shellcheck disable=SC2064  # work_dir is already set; expand now is intentional
    trap "umount '$work_dir/boot' 2>/dev/null || true; rm -rf '$work_dir'" EXIT

    mkdir -p "$work_dir/boot"

    # Extract boot partition (p1) to a temp file, then mount it.
    # This avoids losetup partition nodes (unreliable in Docker) and
    # "overlapping loop device" errors from stale host-level loop devices
    # that persist across container runs on Docker volumes.
    local p1_start p1_sectors
    p1_start=$(partx --show -n 1 -g -o START "$IMAGE" 2>/dev/null | tr -d ' ')
    p1_sectors=$(partx --show -n 1 -g -o SECTORS "$IMAGE" 2>/dev/null | tr -d ' ')

    if [ -z "$p1_start" ] || [ -z "$p1_sectors" ]; then
        err "Cannot read boot partition offset from: $IMAGE"
        exit 1
    fi

    dd if="$IMAGE" of="$work_dir/boot.img" \
        bs=512 skip="$p1_start" count="$p1_sectors" status=none 2>/dev/null
    mount -o ro,loop "$work_dir/boot.img" "$work_dir/boot"

    # Parse extlinux.conf for kernel, initrd, and boot args
    local extlinux="$work_dir/boot/extlinux/extlinux.conf"
    if [ ! -f "$extlinux" ]; then
        umount "$work_dir/boot" 2>/dev/null || true
        err "extlinux.conf not found in boot partition"
        exit 1
    fi

    local linux_path initrd_path boot_args
    linux_path=$(sed -n 's/^[[:space:]]*linux[[:space:]]\+//p' "$extlinux" | head -1)
    initrd_path=$(sed -n 's/^[[:space:]]*initrd[[:space:]]\+//p' "$extlinux" | head -1)
    boot_args=$(sed -n 's/^[[:space:]]*append[[:space:]]\+//p' "$extlinux" | head -1)

    if [ -z "$linux_path" ]; then
        umount "$work_dir/boot" 2>/dev/null || true
        err "No kernel path found in extlinux.conf"
        exit 1
    fi

    cp "$work_dir/boot${linux_path}" "$work_dir/vmlinuz"
    if [ -n "$initrd_path" ] && [ -f "$work_dir/boot${initrd_path}" ]; then
        cp "$work_dir/boot${initrd_path}" "$work_dir/initramfs.img"
    fi

    # Fix console for QEMU virt: replace hardware serial with PL011
    # shellcheck disable=SC2001
    boot_args=$(echo "$boot_args" | sed 's/console=ttyS[^ ]*/console=ttyAMA0/g')
    boot_args="${boot_args//console=tty1/}"
    if ! echo "$boot_args" | grep -q 'console=ttyAMA0'; then
        boot_args="$boot_args console=ttyAMA0"
    fi
    boot_args=$(echo "$boot_args" | tr -s ' ')

    # Release boot partition mount before launching QEMU
    umount "$work_dir/boot"
    # shellcheck disable=SC2064
    trap "rm -rf '$work_dir'" EXIT

    ok "Boot files extracted"
    info "Kernel:    $work_dir/vmlinuz"
    [ -f "$work_dir/initramfs.img" ] && info "Initrd:    $work_dir/initramfs.img"
    info "Boot args: $boot_args"

    # Print welcome banner
    printf "\n"
    printf "${BOLD}╔═══════════════════════════════════════════════╗${RESET}\n"
    printf "${BOLD}║     Flipper OS — Interactive QEMU Session     ║${RESET}\n"
    printf "${BOLD}╠═══════════════════════════════════════════════╣${RESET}\n"
    printf "${BOLD}║${RESET}                                               ${BOLD}║${RESET}\n"
    printf "${BOLD}║${RESET}  Login:  ${GREEN}root / root${RESET}  or  ${GREEN}user / user${RESET}       ${BOLD}║${RESET}\n"
    printf "${BOLD}║${RESET}  Exit:   ${YELLOW}Ctrl-A X${RESET}                            ${BOLD}║${RESET}\n"
    printf "${BOLD}║${RESET}                                               ${BOLD}║${RESET}\n"
    printf "${BOLD}║${RESET}  Try these commands after login:               ${BOLD}║${RESET}\n"
    printf "${BOLD}║${RESET}    ${CYAN}flipper-profile list${RESET}                       ${BOLD}║${RESET}\n"
    printf "${BOLD}║${RESET}    ${CYAN}flipper-profile info${RESET}                       ${BOLD}║${RESET}\n"
    printf "${BOLD}║${RESET}    ${CYAN}flipper-profile create my-profile${RESET}           ${BOLD}║${RESET}\n"
    printf "${BOLD}║${RESET}    ${CYAN}flipper-profile switch my-profile${RESET}           ${BOLD}║${RESET}\n"
    printf "${BOLD}║${RESET}    ${CYAN}mount | grep overlay${RESET}                       ${BOLD}║${RESET}\n"
    printf "${BOLD}║${RESET}                                               ${BOLD}║${RESET}\n"
    printf "${BOLD}╚═══════════════════════════════════════════════╝${RESET}\n"
    printf "\n"

    # Build QEMU arguments
    local qemu_args=(
        -M virt
        -cpu cortex-a72
        -m 4096
        -nographic
        -kernel "$work_dir/vmlinuz"
        -drive "file=$IMAGE,format=raw,if=virtio,snapshot=on"
        -append "$boot_args"
    )

    if [ -f "$work_dir/initramfs.img" ]; then
        qemu_args+=(-initrd "$work_dir/initramfs.img")
    fi

    # exec replaces the entrypoint process — QEMU gets stdin/stdout directly
    exec qemu-system-aarch64 "${qemu_args[@]}"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    local cmd="${1:-all}"

    printf "\n${BOLD}Flipper OS Docker Environment${RESET}\n"
    printf "Board: ${BOARD}    Image: ${IMAGE}\n\n"

    case "$cmd" in
        all)
            setup_binfmt
            build_all
            run_tests
            launch_qemu
            ;;
        build)
            setup_binfmt
            build_all
            ok "Build complete."
            info "Run with 'qemu' argument to start interactive session."
            ;;
        test)
            setup_binfmt
            run_tests
            ;;
        qemu)
            launch_qemu
            ;;
        shell|bash)
            exec /bin/bash
            ;;
        *)
            # Pass through: execute arbitrary command
            exec "$@"
            ;;
    esac
}

main "$@"
