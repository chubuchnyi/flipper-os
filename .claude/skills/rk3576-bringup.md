# RK3576 Board Bring-Up

## When to use
When working with U-Boot, kernel, DTB, or hardware-specific configuration for RK3576.

## Boot chain
```
RK3576 BootROM → SPL (idbloader.img) → U-Boot proper → Kernel → initramfs → systemd
```

## Key facts
- Upstream U-Boot: only Firefly ROC-RK3576-PC supported as of Aug 2025
- kwiboo's fork adds: Sige5, Omni3576, NanoPi M5, Rock 4D
- Flipper has their own U-Boot fork: ~/flipper-one-dev/repos/flipper-u-boot/
- No UFS boot support in upstream U-Boot yet (eMMC + SD only)
- Kernel: Flipper's fork at ~/flipper-one-dev/repos/flipper-linux-kernel/
- Collabora rockchip-devel branch has best upstream RK3576 support

## Cross-compilation
```bash
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
make defconfig  # or flipper_one_defconfig when available
make -j$(nproc) Image dtbs modules
```

## Flashing via Maskrom
```bash
# Device must be in Maskrom mode (hold button + power)
sudo rockusb list
sudo rockusb download-boot out/u-boot/rock-4d/rk3576_spl_loader_*.bin
sudo rockusb write-bmap out/images/debian-rock-4d-*.img.gz
sudo rockusb reset-device
```

## Dev board: Radxa Rock 4D
- Same RK3576 SoC as Flipper One
- Top USB 3.0 port for Maskrom connection
- eMMC and SPI flash share pins — cannot use both
