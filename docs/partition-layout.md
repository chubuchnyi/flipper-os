# Flipper OS eMMC/SD Card Partition Layout

## Disk Layout (GPT, 8GB minimum)

| Region | Start | End | Size | Filesystem | Label | Mount | Purpose |
|--------|-------|-----|------|------------|-------|-------|---------|
| GPT header | 0 | 32KB | 32KB | - | - | - | GPT protective MBR + header |
| U-Boot raw | 32KB | 16MB | ~16MB | raw | - | - | u-boot-rockchip.bin (sector 64) |
| boot (p1) | 16MB | 272MB | 256MB | ext4 | boot | /boot | Kernel, DTB, initramfs, extlinux.conf |
| sysroot (p2) | 272MB | 3.27GB | 3GB | ext4 | sysroot | /sysroot | OSTree repo + deployments |
| data (p3) | 3.27GB | end | remainder | ext4 | data | /data | Profiles, Flatpak, user data |

Note: SPL and U-Boot are NOT separate GPT partitions. The combined `u-boot-rockchip.bin`
(TPL+SPL+U-Boot proper) is written at raw sector 64 (32KB offset), before the first partition.
This matches the Rockchip BootROM convention.

## SD Card (optional)

| Partition | Size | Filesystem | Mount | Purpose |
|-----------|------|------------|-------|---------|
| profiles | all | ext4 | /mnt/sdcard | External profiles |

## OSTree Sysroot Structure

After `ostree admin deploy`, the sysroot partition contains:

```
/ostree/
    repo/                           # bare repo with committed content
    deploy/
        flipper-os/                 # stateroot
            deploy/
                <checksum>.0/       # immutable rootfs checkout
                    usr/
                    usr/etc/        # config base (3-way merge)
                    ...
            var/                    # persistent writable state
/boot/
    loader/
        entries/
            ostree-1-flipper-os.conf  # BLS boot entry
    ostree/
        flipper-os-<checksum>/
            vmlinuz
            initramfs.img
    extlinux/
        extlinux.conf               # generated for U-Boot
    dtbs/                           # device tree blobs
```

## Rules

- sysroot partition MUST NOT be modified by running system (OSTree manages it)
- data partition is the ONLY writable persistent storage during normal operation
- boot partition updated only during OS upgrade (via OSTree + RAUC)
- Filesystem labels (LABEL=sysroot, LABEL=boot, LABEL=data) used for deterministic mounting
- boot partition formatted with `-O ^metadata_csum` for U-Boot ext4 driver compatibility
