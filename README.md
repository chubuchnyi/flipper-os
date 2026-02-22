# Flipper OS

Custom Linux distribution for [Flipper One](https://flipperzero.one/) (Rockchip RK3576 ARM64).

Flipper OS combines an **immutable OSTree rootfs** with **OverlayFS-based profiles**,
allowing users to switch between pre-configured system personalities (WiFi router,
desktop environment, network sniffer, etc.) at boot time — without reflashing.

## Key Features

- **Immutable base system** — OSTree-managed rootfs prevents accidental breakage
- **Profile isolation** — each profile gets its own `/etc`, `/usr`, `/var` via OverlayFS
- **Boot-time profile selector** — choose or switch profiles before systemd starts
- **Built-in profiles** — WiFi Router, Wayland Desktop, Network Sniffer, plus a minimal Default
- **User profiles** — create, clone, rename, delete custom profiles
- **Atomic operations** — all profile mutations are crash-safe (tmp dir + rename)
- **OTA updates** — system updates apply to the immutable base; profiles are preserved (planned)

## Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│                    Running System                        │
│                                                          │
│  /etc ──► overlay(profile/upper/etc, ostree/etc)         │
│  /usr ──► overlay(profile/upper/usr, ostree/usr)         │
│  /var ──► overlay(profile/upper/var, ostree/var)         │
│  /data ─► bind mount from data partition                 │
│                                                          │
├──────────────────────────────────────────────────────────┤
│  initramfs: ostree-prepare-root → flipper-profile        │
├──────────────────────────────────────────────────────────┤
│  OSTree deployment (immutable rootfs)                    │
├──────────────────────────────────────────────────────────┤
│  GPT: boot (256M) │ sysroot (3G) │ data (remainder)     │
└──────────────────────────────────────────────────────────┘
```

See [docs/architecture.md](docs/architecture.md) for the full architecture and implementation phases.

## Target Hardware

| Component | Specification |
|-----------|---------------|
| SoC | Rockchip RK3576 (4x Cortex-A72 + 4x Cortex-A53) |
| RAM | 4-16 GB LPDDR4x |
| Storage | eMMC + SD card slot |
| Dev board | Radxa Rock 4D (same SoC) |

## Repository Structure

```
flipper-os/
├── build/                         Build scripts
│   ├── build-kernel.sh            Kernel build with config fragment injection
│   ├── build-rootfs.sh            OSTree-ready rootfs via mmdebstrap
│   ├── build-image.sh             GPT disk image from OSTree commit
│   ├── ostree-commit.sh           OSTree commit from rootfs
│   └── lib/common.sh              Shared helpers (logging, env, cleanup)
├── configs/                       Board and kernel configuration
│   ├── kernel/fragments/          Kernel config fragments (ostree, qemu-virt)
│   └── systemd/                   systemd units (data.mount)
├── profiles/                      Profile system
│   ├── lib/profile-common.sh      Shared bash library
│   ├── cli/flipper-profile        CLI tool (/usr/local/bin/flipper-profile)
│   ├── profiled/                  flipper-profiled daemon + systemd service
│   └── templates/                 Built-in profile templates
├── initramfs/                     Custom initramfs hooks and scripts
│   ├── hooks/flipper-profile      Initramfs build hook
│   └── scripts/local-bottom/      Boot-time scripts (profile selector + overlay)
├── ostree/                        OSTree repo management
├── tests/                         Integration tests
│   ├── qemu-boot-test.sh          QEMU boot smoke test
│   └── qemu-profile-test.sh       Profile system integration test
└── docs/                          Documentation
```

## Prerequisites

Ubuntu/Debian host with:

```bash
sudo apt install \
    qemu-system-arm qemu-user-static binfmt-support \
    mmdebstrap e2fsprogs ostree shellcheck \
    gcc-aarch64-linux-gnu make bc flex bison libssl-dev
```

## Quick Start

```bash
# 1. Load environment
source ~/flipper-one-dev/.env

# 2. Build kernel (cross-compile for arm64)
make kernel

# 3. Build rootfs (installs profile system, generates initramfs)
make rootfs

# 4. Create OSTree commit
make ostree-commit

# 5. Build bootable disk image
make image BOARD=rock-4d

# 6. Run tests
make qemu-test BOARD=rock-4d       # Basic boot test
make profile-test BOARD=rock-4d    # Profile system test
```

The output image is at `$FLIPPER_DEV/images/flipper-os-rock-4d.img`.

### Docker (Zero-Setup)

Build and try Flipper OS without installing any dependencies on your host:

```bash
# Build the Docker image (installs deps + clones repos; ~20 min, cached)
docker build -t flipper-os .

# Full pipeline: build kernel → rootfs → image → run tests → interactive QEMU
docker run --privileged -it flipper-os

# Or just launch QEMU (after a previous full run)
docker run --privileged -it flipper-os qemu

# Drop into a shell for manual exploration
docker run --privileged -it flipper-os shell
```

> **Note:** `--privileged` is required for `losetup`, `mount`, `chroot`, and `binfmt_misc`
> (cross-architecture ARM64 emulation on x86_64 host).
>
> If the build fails at `mmdebstrap` with binfmt errors, register ARM64 handlers on the host:
> ```bash
> docker run --privileged --rm tonistiigi/binfmt --install all
> ```
>
> First run takes **30-60 minutes** (kernel compilation + rootfs build). Subsequent
> `docker run` commands detect the existing image and skip directly to QEMU.

### Flash to Hardware

```bash
# Flash to SD card or eMMC via USB Maskrom
sudo dd if=$FLIPPER_DEV/images/flipper-os-rock-4d.img of=/dev/sdX bs=4M status=progress
```

### Test in QEMU

```bash
make qemu-test BOARD=rock-4d
```

This extracts the kernel and initramfs from the image, boots QEMU virt (aarch64,
cortex-a72, 4GB RAM), and verifies the system reaches a login prompt.

### Interactive QEMU Session

To boot the image interactively and explore the system hands-on:

```bash
source ~/flipper-one-dev/.env
IMAGE="$FLIPPER_DEV/images/flipper-os-rock-4d.img"

# Extract kernel and initramfs from the boot partition
WORK=$(mktemp -d /tmp/flipper-qemu.XXXXXX)
LOOP=$(sudo losetup -fP --show "$IMAGE")
sudo mkdir -p "$WORK/boot"
sudo mount -o ro "${LOOP}p1" "$WORK/boot"

EXTLINUX="$WORK/boot/extlinux/extlinux.conf"
VMLINUZ=$(sudo sed -n 's/^[[:space:]]*linux[[:space:]]\+//p' "$EXTLINUX" | head -1)
INITRD=$(sudo sed -n 's/^[[:space:]]*initrd[[:space:]]\+//p' "$EXTLINUX" | head -1)
APPEND=$(sudo sed -n 's/^[[:space:]]*append[[:space:]]\+//p' "$EXTLINUX" | head -1)

sudo cp "$WORK/boot${VMLINUZ}" "$WORK/vmlinuz"
sudo cp "$WORK/boot${INITRD}" "$WORK/initramfs.img"
sudo umount "$WORK/boot"
sudo losetup -d "$LOOP"

# Fix console for QEMU virt (ttyAMA0 instead of ttyS2/tty1)
BOOT_ARGS=$(echo "$APPEND" | sed 's/console=ttyS[^ ]*/console=ttyAMA0/g; s/console=tty1//g')
echo "$BOOT_ARGS" | grep -q console=ttyAMA0 || BOOT_ARGS="$BOOT_ARGS console=ttyAMA0"

# Boot (snapshot=on keeps the image file unmodified)
sudo qemu-system-aarch64 \
    -M virt -cpu cortex-a72 -m 4096 -nographic \
    -kernel "$WORK/vmlinuz" \
    -initrd "$WORK/initramfs.img" \
    -drive "file=$IMAGE,format=raw,if=virtio,snapshot=on" \
    -append "$BOOT_ARGS"
```

Login credentials: `root` / `root` (or `user` / `user`).

> **Tip**: `snapshot=on` means all disk writes go to RAM — the image file is never
> modified. You can freely experiment and just restart QEMU to get a fresh system.
>
> To exit QEMU: press `Ctrl+A`, then `X`.

### Exploring Profiles Inside QEMU

Once logged in, try these commands:

```bash
# Check which profile is active
cat /run/flipper-profile           # → "default"
flipper-profile current            # → "default"

# List all profiles
flipper-profile list
# NAME                 TYPE       SIZE         STATUS
# ----                 ----       ----         ------
# default              built-in   ...          active
# desktop              built-in   ...
# sniffer              built-in   ...
# wifi-router          built-in   ...

# Show detailed info
flipper-profile info default

# Verify overlay mounts are active
mount | grep overlay
# overlay on /etc type overlay (lowerdir=...,upperdir=...,workdir=...)
# overlay on /var type overlay (...)
# overlay on /usr type overlay (...)

# Check the data partition
df -h /data
ls /data/profiles/

# ── Create and manage user profiles ──

# Create an empty profile
flipper-profile create my-test

# Create from a template
flipper-profile create --from wifi-router my-router

# Clone an existing profile
flipper-profile clone default clone-of-default

# See all profiles now
flipper-profile list

# Rename a profile
flipper-profile rename clone-of-default my-clone

# Delete a user profile
flipper-profile delete my-clone

# ── Profile switching ──

# Schedule a profile for next boot
flipper-profile switch my-test
cat /data/.next-profile            # → "my-test"

# Reboot to activate it
reboot
# After reboot:
cat /run/flipper-profile           # → "my-test"

# ── Verify overlay isolation ──

# Write a file — it goes to the profile's overlay, not the base OS
echo "hello from default" > /etc/test-file
ls /data/profiles/my-test/upper/etc/test-file   # → exists

# ── Built-in profile operations ──

# Reset a built-in profile to its template defaults
flipper-profile reset wifi-router

# Cannot delete built-in profiles
flipper-profile delete default     # → ERROR

# Cannot delete the currently active profile
flipper-profile delete my-test     # → ERROR (if active)

# ── Kernel command line overrides ──
# Force a specific profile (add to QEMU -append):
#   flipper.profile=wifi-router
# Skip the selector menu:
#   flipper.noselector
# Change menu timeout (seconds):
#   flipper.timeout=10
```

## Profile System

Flipper OS ships four built-in profiles:

| Profile | Description |
|---------|-------------|
| `default` | Minimal system with network and SSH |
| `wifi-router` | WiFi access point with NAT routing (dnsmasq, nftables) |
| `desktop` | Wayland desktop environment (SDDM, Plasma) |
| `sniffer` | Network analysis tools (tshark, tcpdump, nmap) |

### How Profiles Work

Each profile has its own `upper/` directory for OverlayFS, layered on top of the
immutable OSTree base. Changes made within a profile (installed packages, config
edits, user data) are isolated to that profile's overlay.

```
/data/profiles/<name>/
├── .profile.json      Metadata (type, template, boot count, timestamps)
├── upper/
│   ├── etc/           OverlayFS upper for /etc
│   ├── usr/           OverlayFS upper for /usr
│   └── var/           OverlayFS upper for /var
└── work/
    ├── etc/           OverlayFS workdir
    ├── usr/
    └── var/
```

### Profile CLI

```bash
flipper-profile list                       # List all profiles
flipper-profile info <name>                # Show profile details
flipper-profile current                    # Show active profile
flipper-profile create <name>              # Create empty profile
flipper-profile create --from <tmpl> <n>   # Create from template
flipper-profile clone <src> [dst]          # Clone a profile
flipper-profile delete <name>              # Delete user profile
flipper-profile reset <name>               # Reset built-in to defaults
flipper-profile switch <name>              # Switch on next reboot
flipper-profile rename <old> <new>         # Rename a profile
```

### Boot-time Selection

The profile is selected during initramfs, before systemd starts:

1. **Kernel cmdline** `flipper.profile=<name>` — forced selection
2. **`.next-profile`** — set by `flipper-profile switch`, consumed on boot
3. **Single profile** — auto-selected if only one exists
4. **`flipper.noselector`** — use last booted profile
5. **Interactive menu** — text menu with configurable timeout

## Disk Layout

GPT partition table (8 GB minimum):

| Partition | Size | Label | Filesystem | Purpose |
|-----------|------|-------|------------|---------|
| (raw) | ~16 MB | — | — | U-Boot at sector 64 |
| p1 | 256 MB | boot | ext4 | Kernel, initramfs, extlinux.conf |
| p2 | 3 GB | sysroot | ext4 | OSTree repo + deployments |
| p3 | remainder | data | ext4 | Profiles, user data |

See [docs/partition-layout.md](docs/partition-layout.md) for details.

## Build Targets

| Target | Description | Requires |
|--------|-------------|----------|
| `make kernel` | Build kernel with Flipper OS config fragments | — |
| `make rootfs` | Build OSTree-ready rootfs | sudo |
| `make ostree-commit` | Create OSTree commit from rootfs | — |
| `make image` | Build bootable GPT disk image | sudo |
| `make qemu-test` | Boot smoke test in QEMU | sudo |
| `make profile-test` | Profile system integration test | sudo |
| `make lint` | Run shellcheck on all scripts | — |
| `make flash` | Flash image to dev board | sudo |

## Testing

See [docs/testing-profiles.md](docs/testing-profiles.md) for the full testing guide.

```bash
# Static analysis
make lint

# Boot test — verifies systemd reaches login prompt
make qemu-test BOARD=rock-4d

# Profile test — verifies overlay mounts and profile selection
make profile-test BOARD=rock-4d
```

## Implementation Status

| Phase | Description | Status |
|-------|-------------|--------|
| Phase 1 | OSTree Foundation | Done |
| Phase 2 | Profile System Core | Done |
| Phase 3 | Update System (OTA) | Planned |
| Phase 4 | User Experience (GUI, Flatpak) | Planned |
| Phase 5 | Hardening (Secure Boot, CI/CD) | Planned |

See [docs/architecture.md](docs/architecture.md) for detailed phase breakdown.

## Documentation

- [Architecture & Phases](docs/architecture.md)
- [Partition Layout](docs/partition-layout.md)
- [Profile System Testing](docs/testing-profiles.md)
- [Original Concept](docs/concept.md)

## License

Proprietary. Copyright (c) Flipper Devices Inc.
