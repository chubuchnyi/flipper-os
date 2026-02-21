# Flipper OS eMMC Partition Layout

| Partition | Offset   | Size     | Filesystem | Mount Point | Purpose                    |
|-----------|----------|----------|------------|-------------|----------------------------|
| SPL       | 32KB     | ~8MB     | raw        | -           | idbloader (SPL)            |
| U-Boot    | 8MB      | 8MB      | raw        | -           | U-Boot proper              |
| boot      | 16MB     | 512MB    | ext4       | /boot       | Kernel, DTB, initramfs     |
| sysroot   | 528MB    | 4GB      | ext4       | /sysroot    | OSTree repo + deployments  |
| data      | 4.5GB    | remainder| ext4       | /data       | Profiles, Flatpak, shared  |

SD card (optional):
| Partition | Size     | Filesystem | Mount Point        | Purpose              |
|-----------|----------|------------|--------------------|----------------------|
| profiles  | all      | ext4       | /mnt/sdcard        | External profiles    |

## Rules
- sysroot partition MUST NOT be modified by running system (OSTree manages it)
- data partition is the ONLY writable persistent storage during normal operation
- boot partition updated only during OS upgrade (via OSTree + RAUC)
