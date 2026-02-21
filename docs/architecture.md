# Flipper OS Architecture

> Full architecture document: see FlipperOS_Architecture.docx in project root.

## Implementation Phases

### Phase 1: OSTree Foundation (4-6 weeks)
Transform Debian build scripts into OSTree-managed immutable rootfs.
- [ ] Modified build scripts producing OSTree commits
- [ ] Partition layout tool (boot, sysroot, data)
- [ ] U-Boot integration with OSTree kernel params
- [ ] Smoke test: boot from OSTree on Radxa Rock 4D

### Phase 2: Profile System Core (4-6 weeks)
Profile creation, switching, reset, clone.
- [ ] flipper-profiled daemon
- [ ] Custom initramfs with profile selector (text UI)
- [ ] flipper-profile CLI tool
- [ ] Built-in profile templates (wifi-router, desktop, sniffer)

### Phase 3: Update System (3-4 weeks)
OTA updates for OS and firmware.
- [ ] OSTree remote + CI/CD for publishing commits
- [ ] flipper-updater service
- [ ] RAUC integration for U-Boot/MCU firmware
- [ ] Boot counter + auto-rollback

### Phase 4: User Experience (3-4 weeks)
Graphical boot menu, Flatpak, SD card.
- [ ] LVGL graphical profile selector
- [ ] Flatpak per-profile setup
- [ ] SD card profile management
- [ ] In-profile management UI

### Phase 5: Hardening (3-4 weeks)
Security, reliability, manufacturing.
- [ ] OSTree commit signing
- [ ] Secure Boot chain (eFuse)
- [ ] Factory provisioning tool
- [ ] Recovery system
- [ ] CI/CD pipeline
