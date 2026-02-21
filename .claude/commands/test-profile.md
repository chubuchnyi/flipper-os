Test a Flipper OS profile using QEMU aarch64.

Profile: $ARGUMENTS

1. Build minimal rootfs with OSTree deployment
2. Apply profile overlay
3. Boot in QEMU with: qemu-system-aarch64 -M virt -cpu cortex-a72 -m 4G
4. Verify systemd boots successfully
5. Check profile-specific services are running
6. Report boot time and memory usage
