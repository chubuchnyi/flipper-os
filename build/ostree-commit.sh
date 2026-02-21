#!/bin/bash
# ostree-commit.sh — Commit a prepared rootfs into the OSTree repository.
#
# Usage:
#   ./build/ostree-commit.sh [OPTIONS]
#     --rootfs <path>      Path to rootfs (default: $FLIPPER_DEV/ostree-work/rootfs)
#     --repo <path>        OSTree repo (default: $OSTREE_REPO)
#     --branch <ref>       Branch name (default: flipper-os/base/latest)
#     --version <string>   Version string for metadata

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_env

# ── Defaults ──────────────────────────────────────────────────────────────────

ROOTFS_DIR="${FLIPPER_DEV}/ostree-work/rootfs"
REPO="${OSTREE_REPO}"
BRANCH="flipper-os/base/latest"
VERSION=""

# ── Argument parsing ──────────────────────────────────────────────────────────

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --rootfs)
                ROOTFS_DIR="$2"; shift 2 ;;
            --repo)
                REPO="$2"; shift 2 ;;
            --branch)
                BRANCH="$2"; shift 2 ;;
            --version)
                VERSION="$2"; shift 2 ;;
            -h|--help)
                head -n 10 "${BASH_SOURCE[0]}" | tail -n +2 | sed 's/^# \?//'
                exit 0 ;;
            *)
                die "Unknown option: $1" ;;
        esac
    done
}

# ── Prerequisite checks ──────────────────────────────────────────────────────

check_prereqs() {
    require_cmd ostree "Install with: sudo apt install ostree"

    if [ ! -d "$ROOTFS_DIR" ]; then
        die "Rootfs directory not found: $ROOTFS_DIR"
    fi
}

# ── Init repo if needed ──────────────────────────────────────────────────────

init_repo() {
    if [ ! -d "$REPO/objects" ]; then
        log_info "Initializing OSTree repository at $REPO"
        mkdir -p "$REPO"
        ostree init --mode=archive --repo="$REPO"
    else
        log_info "Using existing OSTree repo: $REPO"
    fi
}

# ── Validate rootfs for OSTree ────────────────────────────────────────────────

validate_rootfs() {
    log_info "Validating rootfs for OSTree commit"
    local errors=0

    if [ ! -d "$ROOTFS_DIR/usr/etc" ]; then
        log_error "Missing /usr/etc — run build-rootfs.sh first"
        errors=$((errors + 1))
    fi

    for link in home opt srv mnt media root ostree; do
        if [ ! -L "$ROOTFS_DIR/$link" ]; then
            log_error "/$link is not a symlink — OSTree transformation incomplete"
            errors=$((errors + 1))
        fi
    done

    if [ ! -d "$ROOTFS_DIR/sysroot" ]; then
        log_error "Missing /sysroot"
        errors=$((errors + 1))
    fi

    if [ "$errors" -gt 0 ]; then
        die "Rootfs validation failed. Run build/build-rootfs.sh first."
    fi

    log_info "Rootfs validation passed"
}

# ── Commit ────────────────────────────────────────────────────────────────────

commit() {
    local build_date
    build_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local git_commit="unknown"
    if command -v git >/dev/null 2>&1 && [ -d "$REPO_ROOT/.git" ]; then
        git_commit="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
    fi

    # Detect kernel version
    local kver="none"
    if compgen -G "$ROOTFS_DIR/usr/lib/modules/*/vmlinuz" >/dev/null 2>&1; then
        kver="$(basename "$(dirname "$(find "$ROOTFS_DIR/usr/lib/modules" -name vmlinuz -print -quit)")")"
    fi

    # Auto-generate version if not specified
    if [ -z "$VERSION" ]; then
        VERSION="dev-$(date -u +%Y%m%d.%H%M%S)"
    fi

    log_info "Committing rootfs to $BRANCH"
    log_info "  Version: $VERSION"
    log_info "  Kernel:  $kver"
    log_info "  Board:   ${BOARD}"

    ostree commit \
        --repo="$REPO" \
        --branch="$BRANCH" \
        --tree=dir="$ROOTFS_DIR" \
        --subject="Flipper OS $VERSION" \
        --body="Build: $build_date, board: ${BOARD}, kernel: $kver" \
        --add-metadata-string="version=$VERSION" \
        --add-metadata-string="flipper-os.build-date=$build_date" \
        --add-metadata-string="flipper-os.arch=arm64" \
        --add-metadata-string="flipper-os.board=${BOARD}" \
        --add-metadata-string="flipper-os.git-commit=$git_commit" \
        --add-metadata-string="flipper-os.kernel-version=$kver"

    log_info "Commit complete"
}

# ── Verify ────────────────────────────────────────────────────────────────────

verify() {
    log_info "Verifying commit"

    echo ""
    log_info "--- OSTree log ($BRANCH) ---"
    ostree log --repo="$REPO" "$BRANCH" | head -20
    echo ""

    log_info "--- Root listing ---"
    ostree ls --repo="$REPO" "$BRANCH" /
    echo ""

    local checksum
    checksum="$(ostree rev-parse --repo="$REPO" "$BRANCH")"
    log_info "Commit checksum: $checksum"
}

# ── Update summary ────────────────────────────────────────────────────────────

update_summary() {
    log_info "Updating OSTree summary"
    ostree summary --update --repo="$REPO"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"
    check_prereqs
    init_repo

    log_info "=== OSTree commit ==="
    log_info "Rootfs: $ROOTFS_DIR"
    log_info "Repo:   $REPO"
    log_info "Branch: $BRANCH"

    validate_rootfs
    commit
    verify
    update_summary

    log_info "=== OSTree commit complete ==="
}

main "$@"
