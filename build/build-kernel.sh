#!/bin/bash
# build-kernel.sh — Build kernel with Flipper OS config fragments.
#
# Wraps upstream flipperone-linux-build-scripts/build-kernel-mainline.sh,
# injecting our kernel config fragments (OSTree, QEMU virt support, etc.)
# without modifying the upstream repository.
#
# Usage:
#   ./build/build-kernel.sh [OPTIONS]
#     --clean         Remove kernel source and rebuild from scratch
#     --output <dir>  Override kernel output directory
#     -h, --help      Show this help
#
# Environment:
#   FLIPPER_DEV, REPOS, FLIPPER_BUILD — loaded from ~/.flipper-one-dev/.env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_env

# ── Defaults ──────────────────────────────────────────────────────────────────

KEEP_SRC_MODE="update"
KERNEL_OUT_DIR="${REPOS}/rk3576-linux-build/out/linux"
KERNEL_SRC_DIR="${FLIPPER_DEV}/kernel-build/linux"

# ── Argument parsing ──────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
    case "$1" in
        --clean)     KEEP_SRC_MODE="no"; shift ;;
        --output)    KERNEL_OUT_DIR="$2"; shift 2 ;;
        -h|--help)
            head -n 15 "${BASH_SOURCE[0]}" | tail -n +2 | sed 's/^# \?//'
            exit 0 ;;
        *)  die "Unknown option: $1" ;;
    esac
done

# ── Prerequisite checks ──────────────────────────────────────────────────────

require_cmd aarch64-linux-gnu-gcc \
    "Install with: sudo apt install gcc-aarch64-linux-gnu"
require_cmd make "Install with: sudo apt install build-essential"
require_cmd git  "Install with: sudo apt install git"

UPSTREAM_DIR="${FLIPPER_BUILD}"
UPSTREAM_SCRIPT="$UPSTREAM_DIR/build-kernel-mainline.sh"

if [ ! -f "$UPSTREAM_SCRIPT" ]; then
    die "Upstream build script not found: $UPSTREAM_SCRIPT"
fi

# ── Merge config fragments ───────────────────────────────────────────────────

MERGED_CONFIGS=$(mktemp -d "${TMPDIR:-/tmp}/flipper-kconfigs.XXXXXX")
cleanup_configs() { rm -rf "$MERGED_CONFIGS"; }
trap cleanup_configs EXIT

log_info "Merging kernel config fragments"

# 1. Copy upstream fragments
if [ -d "$UPSTREAM_DIR/configs/linux" ]; then
    cp "$UPSTREAM_DIR/configs/linux/"* "$MERGED_CONFIGS/"
    # shellcheck disable=SC2012
    log_info "  upstream: $(ls "$UPSTREAM_DIR/configs/linux/" | tr '\n' ' ')"
else
    log_warn "No upstream config fragments found at $UPSTREAM_DIR/configs/linux"
fi

# 2. Overlay our Flipper OS fragments (overrides upstream if same name)
for frag in "$REPO_ROOT/configs/kernel/fragments/"*; do
    [ -f "$frag" ] || continue
    cp "$frag" "$MERGED_CONFIGS/"
    log_info "  + $(basename "$frag")"
done

# shellcheck disable=SC2012
log_info "Merged fragments: $(ls "$MERGED_CONFIGS/" | tr '\n' ' ')"

# ── Build kernel ─────────────────────────────────────────────────────────────

log_info "=== Building kernel ==="
log_info "Upstream scripts: $UPSTREAM_DIR"
log_info "Kernel source:    $KERNEL_SRC_DIR"
log_info "Output:           $KERNEL_OUT_DIR"

mkdir -p "$KERNEL_OUT_DIR"
mkdir -p "$(dirname "$KERNEL_SRC_DIR")"

# Run upstream build script from its directory (for relative path deps like
# the boot logo ppm), but redirect kernel source and output outside repos/.
cd "$UPSTREAM_DIR"

CONFIGS="$MERGED_CONFIGS" \
LINUX_DIR="$KERNEL_SRC_DIR" \
LINUX_OUT="$KERNEL_OUT_DIR" \
KEEP_SRC="$KEEP_SRC_MODE" \
    bash "$UPSTREAM_SCRIPT"

log_info "=== Kernel build complete ==="
log_info "Output: $KERNEL_OUT_DIR"
log_info "Debs:"
ls -1 "$KERNEL_OUT_DIR"/linux-image-*.deb 2>/dev/null || log_warn "No kernel .deb found"
