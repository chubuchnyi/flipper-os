# Flipper OS Profile System

## When to use
When implementing profile creation, switching, reset, clone, or delete operations.

## Architecture
Profiles are OverlayFS upper layers stored in /data/profiles/<name>/.

Each profile directory contains:
```
<profile-name>/
├── .profile.json          ← Metadata (type, created, last_boot, size_bytes)
├── etc/                   ← Modified /etc files (OverlayFS upper)
├── var/                   ← Modified /var files
├── home/                  ← User home directories
├── packages.installed     ← apt packages installed in this profile
└── flatpak/               ← Per-profile Flatpak user installation
```

## Profile types
- **built-in**: Ships with OS. Can reset (rm overlay), cannot delete. E.g., wifi-router.
- **user**: Created by user. Can delete. Cannot reset (no "default" to go back to).

## Operations
- **Reset** (built-in only): `rm -rf /data/profiles/<name>/*` — next boot starts clean
- **Clone**: `cp -a /data/profiles/<src>/ /data/profiles/<dst>/` + update .profile.json
- **Delete** (user only): `rm -rf /data/profiles/<name>/`
- **New**: `mkdir` + skeleton .profile.json + random name generation

## Critical: Atomicity
All operations must be atomic. Use rename() for the final step:
1. Create/modify in a temp directory: /data/profiles/.tmp-<operation>/
2. When complete, `mv` to final location
3. On power loss, cleanup .tmp-* dirs on next boot
