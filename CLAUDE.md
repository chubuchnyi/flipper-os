# Flipper OS — Custom Linux Distribution for Flipper One

## Project Overview
Building a profile-based immutable Linux OS for the Flipper One (RK3576 ARM64).
Core concept: OSTree immutable rootfs + OverlayFS profiles + Flatpak apps + RAUC firmware updates.

See @docs/architecture.md for full architecture.
See @docs/concept.md for the original Flipper OS concept.

## Repository Map
```
flipper-os/                        ← THIS REPO
├── build/                         ← Build scripts (kernel, rootfs, image generation)
│   ├── build-kernel.sh            ← Kernel build with fragment injection
│   ├── build-rootfs.sh            ← OSTree-ready rootfs via mmdebstrap
│   ├── build-image.sh             ← GPT disk image from OSTree commit
│   ├── ostree-commit.sh           ← OSTree commit from rootfs
│   └── lib/common.sh              ← Shared helpers (logging, env, cleanup)
├── configs/                       ← Board DTS, kernel config, U-Boot env
│   └── kernel/fragments/          ← Kernel config fragments (ostree, qemu-virt)
├── ostree/                        ← OSTree repo management, commit tooling
├── profiles/                      ← Profile system (profiled daemon, CLI, templates)
│   ├── profiled/                  ← systemd service managing profile lifecycle
│   ├── cli/                       ← flipper-profile command-line tool
│   └── templates/                 ← Built-in profile configs (wifi-router, desktop, etc.)
├── initramfs/                     ← Custom initramfs with profile selector
├── updater/                       ← flipper-updater OTA service
├── rauc/                          ← RAUC bundle configs and integration
├── tests/                         ← Integration tests, QEMU-based smoke tests
│   └── qemu-boot-test.sh         ← QEMU virt boot smoke test
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
make kernel                             # Build kernel with Flipper OS fragments
make rootfs                             # Build OSTree-ready rootfs (sudo)
make ostree-commit                      # Generate OSTree commit from rootfs
make image                              # Build full disk image (sudo)
make qemu-test BOARD=rock-4d            # QEMU boot smoke test (sudo)
make profile-test PROFILE=wifi-router   # Test a profile in QEMU
make rauc-bundle                        # Create firmware update bundle
make flash BOARD=rock-4d                # Flash to dev board via Maskrom
shellcheck build/*.sh                   # Lint shell scripts
```

## Kernel Build
`build/build-kernel.sh` wraps upstream `flipperone-linux-build-scripts/build-kernel-mainline.sh`:
- Merges upstream config fragments with ours from `configs/kernel/fragments/`
- Kernel source cloned to `$FLIPPER_DEV/kernel-build/linux` (not inside upstream repo)
- Output goes to `$REPOS/rk3576-linux-build/out/linux/` (where `build-rootfs.sh` searches)
- Use `--clean` for fresh build, default is `KEEP_SRC=update` (incremental)

## Code Style
- Shell: POSIX sh preferred, bash when needed. shellcheck clean. No bashisms in portable scripts.
- C (initramfs, profiled): C11, kernel coding style, -Wall -Werror.
- Python (tooling): 3.10+, type hints, ruff lint.
- Commits: Conventional Commits (feat/fix/build/docs/refactor).

## Critical Rules
- NEVER hardcode paths. Use $FLIPPER_DEV, $OSTREE_REPO, $BOARD env vars.
- NEVER modify upstream repos in ~/flipper-one-dev/repos/. Patches go in configs/patches/, kernel fragments in configs/kernel/fragments/.
- Always test with 4GB RAM constraint in mind (QEMU test uses -m 4096).
- Partition layout changes require updating docs/partition-layout.md AND build scripts.
- Profile operations (reset/clone/delete) must be atomic — no partial states on power loss.
