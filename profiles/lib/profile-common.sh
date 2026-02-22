#!/bin/bash
# profile-common.sh — Shared library for Flipper OS profile system.
# Source this file, do not execute directly.
#
# Used by: flipper-profile CLI, flipper-profiled daemon.
# NOT used by initramfs scripts (they are POSIX sh / busybox).

# ── Constants ─────────────────────────────────────────────────────────────────

DATA_DIR="/data"
PROFILES_DIR="$DATA_DIR/profiles"
TEMPLATES_DIR="/usr/share/flipper-os/templates"
RUN_PROFILE="/run/flipper-profile"
RUN_STATUS="/run/flipper-profile-status"
NEXT_PROFILE_FILE="$DATA_DIR/.next-profile"
LAST_PROFILE_FILE="$DATA_DIR/.last-profile"

# Valid profile name: lowercase alphanumeric + hyphens, 1-32 chars
PROFILE_NAME_RE='^[a-z0-9][a-z0-9-]{0,31}$'

# Reserved names that cannot be used for profiles
RESERVED_NAMES="lost+found shared flatpak"

# ── Logging ───────────────────────────────────────────────────────────────────

if [ -t 2 ]; then
    _P_RED='\033[0;31m'
    _P_YELLOW='\033[0;33m'
    _P_CYAN='\033[0;36m'
    _P_RESET='\033[0m'
else
    _P_RED='' _P_YELLOW='' _P_CYAN='' _P_RESET=''
fi

log_info()  { printf "${_P_CYAN}[INFO]${_P_RESET}  %s\n" "$*" >&2; }
log_warn()  { printf "${_P_YELLOW}[WARN]${_P_RESET}  %s\n" "$*" >&2; }
log_error() { printf "${_P_RED}[ERROR]${_P_RESET} %s\n" "$*" >&2; }

die() { log_error "$@"; exit 1; }

# ── JSON helpers (no jq dependency) ───────────────────────────────────────────

# json_get <file> <key> — extract a string value from a flat JSON file
json_get() {
    local file="$1" key="$2"
    sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$file" | head -1
}

# json_get_int <file> <key> — extract an integer value from a flat JSON file
json_get_int() {
    local file="$1" key="$2"
    sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$file" | head -1
}

# ── Profile queries ───────────────────────────────────────────────────────────

# profile_exists <name> — check if a profile directory exists
profile_exists() {
    local name="$1"
    [ -d "$PROFILES_DIR/$name" ] && [ -f "$PROFILES_DIR/$name/.profile.json" ]
}

# profile_type <name> — return "built-in" or "user"
profile_type() {
    local name="$1"
    json_get "$PROFILES_DIR/$name/.profile.json" "type"
}

# profile_template <name> — return template name or empty
profile_template() {
    local name="$1"
    json_get "$PROFILES_DIR/$name/.profile.json" "template"
}

# current_profile — return the currently running profile name
current_profile() {
    if [ -f "$RUN_PROFILE" ]; then
        cat "$RUN_PROFILE"
    else
        echo ""
    fi
}

# ── Name validation ──────────────────────────────────────────────────────────

# profile_validate_name <name> — validate profile name, die on error
profile_validate_name() {
    local name="$1"

    if [ -z "$name" ]; then
        die "Profile name cannot be empty"
    fi

    if ! echo "$name" | grep -qE "$PROFILE_NAME_RE"; then
        die "Invalid profile name '$name': must match $PROFILE_NAME_RE"
    fi

    # Check reserved names
    for reserved in $RESERVED_NAMES; do
        if [ "$name" = "$reserved" ]; then
            die "Profile name '$name' is reserved"
        fi
    done

    # Disallow names starting with dot or tmp-
    case "$name" in
        .*|tmp-*)
            die "Profile name '$name' is not allowed (starts with . or tmp-)"
            ;;
    esac
}

# ── Random name generation ────────────────────────────────────────────────────

# generate_random_name — output "profile-XXXX" using /dev/urandom
generate_random_name() {
    local suffix
    suffix=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 4)
    echo "profile-${suffix}"
}

# ── Atomic operations ────────────────────────────────────────────────────────

# atomic_write <file> <content> — write to .tmp then mv (crash-safe)
atomic_write() {
    local file="$1" content="$2"
    local tmp="${file}.tmp.$$"
    printf '%s\n' "$content" > "$tmp"
    mv -f "$tmp" "$file"
}

# ── Size helpers ──────────────────────────────────────────────────────────────

# profile_size_bytes <name> — total size of profile upper/ directory
profile_size_bytes() {
    local name="$1"
    local upper="$PROFILES_DIR/$name/upper"
    if [ -d "$upper" ]; then
        du -sb "$upper" 2>/dev/null | cut -f1
    else
        echo "0"
    fi
}

# human_size <bytes> — convert bytes to human-readable (KB/MB/GB)
human_size() {
    local bytes="$1"
    if [ "$bytes" -ge 1073741824 ]; then
        echo "$(( bytes / 1073741824 ))GB"
    elif [ "$bytes" -ge 1048576 ]; then
        echo "$(( bytes / 1048576 ))MB"
    elif [ "$bytes" -ge 1024 ]; then
        echo "$(( bytes / 1024 ))KB"
    else
        echo "${bytes}B"
    fi
}

# ── Profile directory helpers ─────────────────────────────────────────────────

# init_profile_dirs <path> — create standard upper/ and work/ subdirectories
init_profile_dirs() {
    local path="$1"
    mkdir -p "$path/upper/etc" "$path/upper/usr" "$path/upper/var"
    mkdir -p "$path/work/etc" "$path/work/usr" "$path/work/var"
}

# write_profile_json <path> <type> <template> — write .profile.json
write_profile_json() {
    local path="$1" type="$2" template="$3"
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    cat > "$path/.profile.json" <<EOF
{
    "type": "$type",
    "template": "$template",
    "created": "$now",
    "last_boot": "",
    "boot_count": 0,
    "size_bytes": 0
}
EOF
}
