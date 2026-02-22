# Flipper OS Architecture

> Full architecture document: see FlipperOS_Architecture.docx in project root.

## Implementation Phases

### Phase 1: OSTree Foundation 
Transform Debian build scripts into OSTree-managed immutable rootfs.
- [x] Modified build scripts producing OSTree commits
- [x] Partition layout tool (boot, sysroot, data)
- [x] U-Boot integration with OSTree kernel params
- [x] Smoke test: boot from OSTree on Radxa Rock 4D

### Phase 2: Profile System Core 
Profile creation, switching, reset, clone.
- [x] flipper-profiled daemon
- [x] Custom initramfs with profile selector (text UI)
- [x] flipper-profile CLI tool
- [x] Built-in profile templates (wifi-router, desktop, sniffer)

### Phase 3: Update System 
OTA updates for OS and firmware.
- [ ] OSTree remote + CI/CD for publishing commits
- [ ] flipper-updater service
- [ ] RAUC integration for U-Boot/MCU firmware
- [ ] Boot counter + auto-rollback

### Phase 4: User Experience 
Graphical boot menu, Flatpak, SD card.
- [ ] LVGL graphical profile selector
- [ ] Flatpak per-profile setup
- [ ] SD card profile management
- [ ] In-profile management UI

### Phase 5: Hardening 
Security, reliability, manufacturing.
- [ ] OSTree commit signing
- [ ] Secure Boot chain (eFuse)
- [ ] Factory provisioning tool
- [ ] Recovery system
- [ ] CI/CD pipeline
