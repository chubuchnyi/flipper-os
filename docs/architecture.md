# Flipper OS Architecture

## Overview

Flipper OS is a profile-based immutable Linux distribution for Flipper One (RK3576 ARM64).
The system combines several technologies to achieve safe, isolated, switchable system
configurations:

- **OSTree** — immutable, versioned rootfs with atomic upgrades and rollback
- **OverlayFS** — per-profile writable layers on top of the immutable base
- **initramfs profile selector** — profile choice before systemd starts
- **RAUC** — firmware update framework (U-Boot, MCU) (planned)
- **Flatpak** — sandboxed application delivery per profile (planned)

## Boot Flow

```
Power On
  │
  ▼
U-Boot (sector 64, raw on eMMC/SD)
  │  Reads extlinux.conf from boot partition
  │  Loads vmlinuz + initramfs.img
  ▼
Kernel (arm64, aarch64)
  │
  ▼
initramfs-tools
  │
  ├─ local-top: (standard) mount root device (LABEL=sysroot)
  │
  ├─ local-premount: (standard)
  │
  ├─ local-bottom/ostree:
  │     ostree-prepare-root sets up OSTree deployment as ${rootmnt}
  │     Bind-mounts /usr (read-only), /etc (3-way merge), /var
  │
  ├─ local-bottom/flipper-profile:    ◄── Profile system entry point
  │     1. Mount data partition (LABEL=data) → /run/flipper-data
  │     2. Seed built-in templates on first boot
  │     3. Select profile (cmdline / .next-profile / auto / menu)
  │     4. Mount OverlayFS for /etc, /usr, /var
  │     5. Write runtime state to /run/flipper-profile
  │     6. Bind-mount /data into rootfs
  │
  ▼
switch_root → systemd (PID 1)
  │
  ├─ data.mount (safety net — skipped if already mounted)
  ├─ flipper-profiled.service (updates profile metadata)
  └─ normal systemd boot...
  │
  ▼
Login prompt / desktop environment
```

## Partition Layout

```
┌──────────┬────────────┬────────────────┬──────────────────────┐
│  U-Boot  │  boot (p1) │  sysroot (p2)  │  data (p3)           │
│  raw     │  256 MB    │  3 GB          │  remainder           │
│  sector  │  ext4      │  ext4          │  ext4                │
│  64      │  LABEL=    │  LABEL=        │  LABEL=data          │
│          │  boot      │  sysroot       │                      │
└──────────┴────────────┴────────────────┴──────────────────────┘
```

See [partition-layout.md](partition-layout.md) for full details.

## Profile System

### Concept

Each profile is a named directory on the data partition containing OverlayFS upper
and work directories. The immutable OSTree deployment serves as the lower layer.
This means:

- The base OS is shared and read-only
- Each profile sees its own modifications to `/etc`, `/usr`, `/var`
- Switching profiles changes which overlay is mounted — zero-cost, instant
- Deleting a profile removes only its overlay data
- OS updates change the base layer; profile overlays persist

### Profile Types

| Type | Can Delete | Can Reset | Can Clone | Created By |
|------|-----------|-----------|-----------|------------|
| built-in | No | Yes (to template) | Yes | Shipped with OS |
| user | Yes | No | Yes | User via CLI |

### Directory Structure

```
/data/
├── .last-profile              Last booted profile name
├── .next-profile              Profile to boot next (consumed on boot)
└── profiles/
    ├── default/
    │   ├── .profile.json      {"type":"built-in","template":"default",...}
    │   ├── upper/
    │   │   ├── etc/           Overlay upper for /etc
    │   │   ├── usr/           Overlay upper for /usr
    │   │   └── var/           Overlay upper for /var
    │   └── work/
    │       ├── etc/           Overlay workdir for /etc
    │       ├── usr/           Overlay workdir for /usr
    │       └── var/           Overlay workdir for /var
    ├── wifi-router/
    ├── desktop/
    └── sniffer/
```

### Profile Selection Priority

During boot, the initramfs script selects a profile using this priority:

1. **Kernel command line**: `flipper.profile=<name>` — always wins
2. **`.next-profile` file**: set by `flipper-profile switch`, deleted after use
3. **Single profile**: if only one profile exists, auto-select it
4. **`flipper.noselector` + `.last-profile`**: skip menu, use previous profile
5. **Interactive menu**: text-mode menu with configurable timeout (default: 5s)

### Built-in Templates

| Template | Description | Key Configs |
|----------|-------------|-------------|
| `default` | Minimal system, network + SSH | Empty overlay |
| `wifi-router` | WiFi AP + NAT routing | dnsmasq, nftables NAT, hostapd |
| `desktop` | Wayland desktop environment | SDDM, Plasma Desktop |
| `sniffer` | Network analysis | tshark, tcpdump, nmap |

Templates are stored in the rootfs at `/usr/share/flipper-os/templates/` and seeded
to the data partition on first boot.

### Profile CLI (`flipper-profile`)

Installed at `/usr/local/bin/flipper-profile`. All mutation operations are atomic
(write to `.tmp-*`, then `mv` to final location).

```
flipper-profile list                       List all profiles
flipper-profile info [name]                Show profile details (default: current)
flipper-profile current                    Print active profile name
flipper-profile create <name>              Create empty user profile
flipper-profile create --from <tmpl> <n>   Create from template
flipper-profile clone <src> [dst]          Clone profile (random name if dst omitted)
flipper-profile delete <name>              Delete user profile (not built-in, not active)
flipper-profile reset <name>               Reset built-in profile to template defaults
flipper-profile switch <name>              Set profile for next boot
flipper-profile rename <old> <new>         Rename profile (not active profile)
```

### Profile Daemon (`flipper-profiled`)

A lightweight bash daemon (`flipper-profiled.service`) that runs after boot:

- Updates `.profile.json` metadata: `last_boot`, `boot_count`, `size_bytes`
- Cleans stale `.tmp-*` directories older than 1 hour
- Periodically recalculates profile disk usage (every 5 minutes)

### Crash Safety

- All profile operations use atomic rename: create in `.tmp-*`, then `mv`
- Stale `.tmp-*` directories are cleaned on boot by both initramfs and daemon
- OverlayFS workdirs are cleared before mount (handles unclean shutdown)
- If the data partition is missing, the system boots without profiles (graceful degradation)

## Build Pipeline

```
build-kernel.sh                  build-rootfs.sh
      │                                │
      │  linux-image-*.deb             │  rootfs directory
      ▼                                ▼
  ┌────────────────────────────────────────┐
  │           ostree-commit.sh             │
  │  Creates OSTree commit from rootfs     │
  └───────────────────┬────────────────────┘
                      │  OSTree repo
                      ▼
  ┌────────────────────────────────────────┐
  │           build-image.sh               │
  │  Creates GPT image:                    │
  │    - boot partition (kernel, initrd)   │
  │    - sysroot (ostree admin deploy)     │
  │    - data (seed profile templates)     │
  │    - U-Boot at sector 64              │
  └────────────────────────────────────────┘
                      │
                      ▼
              flipper-os-<board>.img
```

### Build Scripts

| Script | Purpose | Input | Output |
|--------|---------|-------|--------|
| `build/build-kernel.sh` | Cross-compile kernel with config fragments | Upstream kernel source | `linux-image-*.deb` |
| `build/build-rootfs.sh` | Build rootfs via mmdebstrap, install profile system | kernel .deb, templates | rootfs directory |
| `build/ostree-commit.sh` | Create OSTree commit from rootfs | rootfs directory | OSTree repo commit |
| `build/build-image.sh` | Assemble GPT disk image | OSTree repo | `.img` file |

### What `build-rootfs.sh` Installs

The rootfs build installs the complete profile system:

1. **Profile library** → `/usr/lib/flipper-os/profile-common.sh`
2. **CLI tool** → `/usr/local/bin/flipper-profile`
3. **Daemon** → `/usr/lib/flipper-os/flipper-profiled`
4. **systemd units** → `/usr/lib/systemd/system/{flipper-profiled.service,data.mount}`
5. **Templates** → `/usr/share/flipper-os/templates/{default,wifi-router,desktop,sniffer}/`
6. **initramfs hook** → `/usr/share/initramfs-tools/hooks/flipper-profile`
7. **initramfs script** → `/usr/share/initramfs-tools/scripts/local-bottom/flipper-profile`

Then `update-initramfs` runs, embedding the hook and script into the initramfs image.

## QEMU Testing

The project includes QEMU aarch64 virt-based testing:

- **`qemu-boot-test.sh`** — verifies the system boots to a login prompt
- **`qemu-profile-test.sh`** — verifies profile selection, overlay mounts, data partition

Both tests extract kernel + initramfs from the built image, boot QEMU with
`snapshot=on` (non-destructive), and parse serial console output.

Kernel config fragments in `configs/kernel/fragments/qemu-virt.config` enable:
- PL011 UART console (`ttyAMA0` for QEMU virt serial)
- Generic PCI host controller (ECAM, required for virtio-pci disk)
- virtio-mmio command line devices

## Implementation Phases

### Phase 1: OSTree Foundation — Done

- [x] Modified build scripts producing OSTree commits
- [x] GPT partition layout (boot, sysroot, data)
- [x] U-Boot integration with OSTree kernel params
- [x] QEMU boot smoke test

### Phase 2: Profile System Core — Done

- [x] Custom initramfs with profile selector (text UI)
- [x] OverlayFS per-directory overlays (etc, usr, var)
- [x] `flipper-profile` CLI tool (list, create, clone, delete, reset, switch, rename)
- [x] `flipper-profiled` daemon (metadata updates, cleanup)
- [x] Built-in profile templates (default, wifi-router, desktop, sniffer)
- [x] QEMU integration test (4/4 tests passing)

### Phase 3: Update System — Planned

- [ ] OSTree remote + CI/CD for publishing commits
- [ ] `flipper-updater` OTA service
- [ ] RAUC integration for U-Boot/MCU firmware
- [ ] Boot counter + auto-rollback

### Phase 4: User Experience — Planned

- [ ] LVGL graphical profile selector (replaces text menu)
- [ ] Flatpak per-profile setup
- [ ] SD card profile management
- [ ] In-profile management UI

### Phase 5: Hardening — Planned

- [ ] OSTree commit signing
- [ ] Secure Boot chain (eFuse)
- [ ] Factory provisioning tool
- [ ] Recovery system
- [ ] CI/CD pipeline

## Design Decisions

### Why per-directory overlays instead of full-root overlay?

OSTree's `ostree-prepare-root` sets up bind mounts and a specific mount topology.
A full-root overlay would conflict with these mounts. Per-directory overlays for
`/etc`, `/usr`, `/var` stack cleanly on top of the existing OSTree layout and
preserve bind-mount semantics.

### Why initramfs for profile selection?

The profile must be selected before `switch_root` because OverlayFS mounts need
to be in place before systemd starts. Moving this to a systemd service would
require remounting filesystems that are already in use, which is fragile and
may cause service failures.

### Why POSIX sh in initramfs?

The initramfs uses busybox, which provides `ash` (a minimal POSIX shell). Bash
is not available. All initramfs scripts must avoid bashisms and work with busybox
utilities (no standalone `grep`, `basename`, `dirname`; use shell builtins and
`case` statements instead).

### Why `mount -o bind` instead of `mount --bind`?

Busybox `mount` does not support long options. `mount -o bind` is the busybox-
compatible equivalent.

### Why seed templates at build time?

Templates are seeded onto the data partition during `build-image.sh` so the first
boot doesn't need to copy files (faster first boot). The initramfs also seeds
templates if the profiles directory is empty (factory reset recovery).
