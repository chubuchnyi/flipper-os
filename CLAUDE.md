# Flipper OS — Custom Linux Distribution for Flipper One

## Project Overview
Building a profile-based immutable Linux OS for the Flipper One (RK3576 ARM64).
Core concept: OSTree immutable rootfs + OverlayFS profiles + Flatpak apps + RAUC firmware updates.

See @docs/architecture.md for full architecture.
See @docs/concept.md for the original Flipper OS concept.

## Repository Map
```
flipper-os/                        ← THIS REPO
├── build/                         ← Build scripts (image generation, OSTree commits)
├── ostree/                        ← OSTree repo management, commit tooling
├── profiles/                      ← Profile system (profiled daemon, CLI, templates)
│   ├── profiled/                  ← systemd service managing profile lifecycle
│   ├── cli/                       ← flipper-profile command-line tool
│   └── templates/                 ← Built-in profile configs (wifi-router, desktop, etc.)
├── initramfs/                     ← Custom initramfs with profile selector
├── updater/                       ← flipper-updater OTA service
├── rauc/                          ← RAUC bundle configs and integration
├── configs/                       ← Board DTS, kernel config, U-Boot env
├── tests/                         ← Integration tests, QEMU-based smoke tests
└── docs/                          ← Architecture, specs, decision records
```

Upstream repos are in `~/flipper-one-dev/repos/` — READ ONLY, never modify directly.

## Target Hardware
- SoC: Rockchip RK3576 (ARM64, 4xA72 + 4xA53)
- RAM: 4-16GB LPDDR4x (MUST work with 4GB)
- Dev board: Radxa Rock 4D (same SoC)
- Storage: eMMC + SD card slot

## Key Commands
```bash
source ~/flipper-one-dev/.env           # Load environment
make image                              # Build full disk image
make ostree-commit                      # Generate OSTree commit from rootfs
make profile-test PROFILE=wifi-router   # Test a profile in QEMU
make rauc-bundle                        # Create firmware update bundle
make flash BOARD=rock-4d                # Flash to dev board via Maskrom
shellcheck build/*.sh                   # Lint shell scripts
```

## Code Style
- Shell: POSIX sh preferred, bash when needed. shellcheck clean. No bashisms in portable scripts.
- C (initramfs, profiled): C11, kernel coding style, -Wall -Werror.
- Python (tooling): 3.10+, type hints, ruff lint.
- Commits: Conventional Commits (feat/fix/build/docs/refactor).

## Critical Rules
- NEVER hardcode paths. Use $FLIPPER_DEV, $OSTREE_REPO, $BOARD env vars.
- NEVER modify upstream repos in ~/flipper-one-dev/repos/. Patches go in configs/patches/.
- Always test with 4GB RAM constraint in mind.
- Partition layout changes require updating docs/partition-layout.md AND build scripts.
- Profile operations (reset/clone/delete) must be atomic — no partial states on power loss.
