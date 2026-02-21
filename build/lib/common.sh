#!/bin/bash
# Shared library for Flipper OS build scripts.
# Source this file, do not execute directly.

set -euo pipefail

# --- Colors (disabled when not on a terminal) ---
if [ -t 2 ]; then
    _RED='\033[0;31m'
    _YELLOW='\033[0;33m'
    _CYAN='\033[0;36m'
    _RESET='\033[0m'
else
    _RED='' _YELLOW='' _CYAN='' _RESET=''
fi

log_info()  { printf "${_CYAN}[INFO]${_RESET}  %s\n" "$*" >&2; }
log_warn()  { printf "${_YELLOW}[WARN]${_RESET}  %s\n" "$*" >&2; }
log_error() { printf "${_RED}[ERROR]${_RESET} %s\n" "$*" >&2; }

die() { log_error "$@"; exit 1; }

# --- Environment loading ---
load_env() {
    # Under sudo, $HOME is /root — use the invoking user's home instead
    local real_home="$HOME"
    if [ -n "${SUDO_USER:-}" ]; then
        real_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    fi
    local flipper_dev="${FLIPPER_DEV:-$real_home/flipper-one-dev}"
    local env_file="$flipper_dev/.env"
    local versions_env

    # Resolve the repo root (where this script lives: build/lib/common.sh → repo root)
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    versions_env="$REPO_ROOT/configs/versions.env"

    if [ -f "$env_file" ]; then
        # Source .env but skip the "source ~/.cargo/env" line — it is not relevant here
        # shellcheck source=/dev/null
        set -a
        grep -v '^\s*source ' "$env_file" | grep -v '^\s*#' | grep -v '^\s*$' | while IFS= read -r line; do
            eval "$line" 2>/dev/null || true
        done
        set +a
        # Re-export key variables that the eval-in-subshell couldn't set
        export FLIPPER_DEV="$flipper_dev"
        export REPOS="${REPOS:-$flipper_dev/repos}"
        export FLIPPER_BUILD="${FLIPPER_BUILD:-$REPOS/flipperone-linux-build-scripts}"
        export ARCH="${ARCH:-arm64}"
        export BOARD="${BOARD:-rock-4d}"
        export OSTREE_REPO="${OSTREE_REPO:-$flipper_dev/ostree-work/repo}"
        export OUT_DIR="${OUT_DIR:-$flipper_dev/images}"
    else
        log_warn "Environment file not found: $env_file"
        export FLIPPER_DEV="$flipper_dev"
        export BOARD="${BOARD:-rock-4d}"
        export OSTREE_REPO="${OSTREE_REPO:-$flipper_dev/ostree-work/repo}"
    fi

    if [ -f "$versions_env" ]; then
        # shellcheck source=/dev/null
        source "$versions_env"
    else
        log_warn "Versions file not found: $versions_env"
    fi

    export REPO_ROOT
}

# --- Prerequisite checks ---
require_cmd() {
    local cmd="$1"
    local hint="${2:-}"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        if [ -n "$hint" ]; then
            die "Required command '$cmd' not found. $hint"
        else
            die "Required command '$cmd' not found."
        fi
    fi
}

# --- Cleanup bind-mounts inside a chroot ---
cleanup_mounts() {
    local rootfs="$1"
    log_info "Cleaning up bind-mounts in $rootfs"
    for mp in dev/pts dev/shm dev proc sys run; do
        if mountpoint -q "$rootfs/$mp" 2>/dev/null; then
            umount -l "$rootfs/$mp" 2>/dev/null || true
        fi
    done
}
