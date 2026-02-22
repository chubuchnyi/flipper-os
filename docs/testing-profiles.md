# Testing the Profile System (Phase 2)

This guide covers how to test the Flipper OS profile system — from unit-level
shell script validation to full QEMU integration tests.

## Prerequisites

```bash
# Host packages (Ubuntu/Debian)
sudo apt install shellcheck qemu-system-arm mmdebstrap qemu-user-static \
    binfmt-support e2fsprogs ostree

# Load environment
source ~/flipper-one-dev/.env
```

## 1. Static Analysis (shellcheck)

Run shellcheck on all profile system scripts:

```bash
# Bash scripts
shellcheck profiles/lib/profile-common.sh
shellcheck profiles/cli/flipper-profile
shellcheck profiles/profiled/flipper-profiled

# POSIX sh / dash (initramfs)
shellcheck -s dash initramfs/hooks/flipper-profile
shellcheck -s dash initramfs/scripts/local-bottom/flipper-profile

# Or use the Makefile target (covers everything)
make lint
```

Expected: only SC2034 (unused vars exported for sourcing), SC1091 (external
sources), and SC3043/SC3045 (busybox ash extensions in initramfs scripts).

## 2. Unit Testing the Shared Library

Test `profiles/lib/profile-common.sh` functions in isolation on the host:

```bash
# Source the library
source profiles/lib/profile-common.sh

# --- Name validation ---
# Should succeed (no output, exit 0):
profile_validate_name "my-profile"
profile_validate_name "default"
profile_validate_name "a"
profile_validate_name "profile-with-32-chars-abcdefghij"

# Should fail (prints error, exits):
(profile_validate_name "" 2>&1)              # empty
(profile_validate_name "UPPER" 2>&1)         # uppercase
(profile_validate_name ".hidden" 2>&1)       # starts with dot
(profile_validate_name "tmp-foo" 2>&1)       # starts with tmp-
(profile_validate_name "lost+found" 2>&1)    # reserved
(profile_validate_name "a b" 2>&1)           # space
(profile_validate_name "aaaaaaaaaa-bbbbbbbbbbb-cccccccccc-x" 2>&1)  # >32 chars

# --- Random name ---
generate_random_name   # → "profile-a7f3" (varies)
generate_random_name   # → different each time

# --- JSON parsing ---
echo '{"type": "built-in", "boot_count": 42}' > /tmp/test.json
json_get /tmp/test.json "type"          # → "built-in"
json_get_int /tmp/test.json "boot_count"  # → "42"
rm /tmp/test.json

# --- Human-readable sizes ---
human_size 512        # → "512B"
human_size 10240      # → "10KB"
human_size 5242880    # → "5MB"
human_size 2147483648 # → "2GB"
```

## 3. Unit Testing the CLI (on host with mock /data)

Create a temporary `/data` structure and test CLI commands without a full
image build. Requires root because the CLI reads `/data/profiles/`.

```bash
# Setup mock environment
export TEST_DIR=$(mktemp -d)
sudo mkdir -p $TEST_DIR/data/profiles

# Copy templates as "installed" built-in profiles
for t in profiles/templates/*/; do
    name=$(basename "$t")
    sudo cp -a "$t" "$TEST_DIR/data/profiles/$name"
    sudo mkdir -p "$TEST_DIR/data/profiles/$name/work/"{etc,usr,var}
    sudo mkdir -p "$TEST_DIR/data/profiles/$name/upper/"{etc,usr,var}
done

# Simulate runtime state
sudo mkdir -p /run
echo "default" | sudo tee /run/flipper-profile > /dev/null

# Symlink /data for CLI access (or modify DATA_DIR in profile-common.sh)
# WARNING: only do this on a test VM or container, NOT on a production host.
# Alternative: run in a chroot or namespace.
```

If you don't want to touch the host `/data`, the safest approach is to test
inside QEMU (see section 5).

### CLI commands to test

```bash
flipper-profile list
# Expected: 4 profiles (default, wifi-router, desktop, sniffer), all type=built-in

flipper-profile info default
# Expected: type=built-in, template=default

flipper-profile current
# Expected: "default"

flipper-profile create test-one
# Expected: success, profile-common creates /data/profiles/test-one/

flipper-profile create --from wifi-router my-router
# Expected: success, copied from wifi-router template, type=user

flipper-profile clone default clone-of-default
# Expected: success, upper/ copied, type=user

flipper-profile list
# Expected: 7 profiles now

flipper-profile info test-one
# Expected: type=user, template=""

flipper-profile rename test-one renamed-profile
# Expected: success

flipper-profile delete renamed-profile
# Expected: success

flipper-profile delete default
# Expected: ERROR — cannot delete built-in profile

flipper-profile reset wifi-router
# Expected: success — upper/ reset to template

flipper-profile switch desktop
# Expected: writes /data/.next-profile, prints reboot message

cat /data/.next-profile
# Expected: "desktop"
```

## 4. Full Image Build

Build a complete image with the profile system included:

```bash
# Step 1: Build rootfs (includes profile system install)
sudo ./build/build-rootfs.sh

# Verify profile system files are installed
ls -la $FLIPPER_DEV/ostree-work/rootfs/usr/lib/flipper-os/
# Expected: profile-common.sh, flipper-profiled

ls -la $FLIPPER_DEV/ostree-work/rootfs/usr/local/bin/flipper-profile
# Expected: executable

ls -la $FLIPPER_DEV/ostree-work/rootfs/usr/share/flipper-os/templates/
# Expected: default/, wifi-router/, desktop/, sniffer/

ls -la $FLIPPER_DEV/ostree-work/rootfs/usr/share/initramfs-tools/hooks/flipper-profile
# Expected: executable

ls -la $FLIPPER_DEV/ostree-work/rootfs/usr/share/initramfs-tools/scripts/local-bottom/flipper-profile
# Expected: executable

ls -la $FLIPPER_DEV/ostree-work/rootfs/usr/lib/systemd/system/flipper-profiled.service
# Expected: present

ls -la $FLIPPER_DEV/ostree-work/rootfs/usr/lib/systemd/system/data.mount
# Expected: present

# Step 2: OSTree commit
./build/ostree-commit.sh

# Step 3: Build disk image
sudo ./build/build-image.sh rock-4d

# Verify data partition was seeded
WORK=$(mktemp -d)
LOOP=$(sudo losetup -fP --show $FLIPPER_DEV/images/flipper-os-rock-4d.img)
sudo mount ${LOOP}p3 $WORK
ls $WORK/profiles/
# Expected: default/ wifi-router/ desktop/ sniffer/
cat $WORK/.last-profile
# Expected: "default"
sudo umount $WORK
sudo losetup -d $LOOP
rm -rf $WORK
```

## 5. QEMU Boot Test (Basic)

The existing boot test verifies the system reaches a login prompt:

```bash
sudo make qemu-test BOARD=rock-4d
```

This confirms the initramfs (including the flipper-profile script) doesn't
break the boot process.

## 6. QEMU Profile Integration Test

The dedicated profile test checks overlay mounts and profile system messages:

```bash
sudo ./tests/qemu-profile-test.sh rock-4d
# Or:
sudo make profile-test BOARD=rock-4d
```

This test:
1. Extracts boot files from the image
2. Boots QEMU with serial logging
3. Checks serial log for `flipper-profile:` messages
4. Verifies 3 overlay mounts were reported (etc, var, usr)
5. Verifies data partition was mounted

Expected output:
```
[INFO]  === Flipper OS Profile System Test ===
[INFO]    PASS: System booted to login prompt
[INFO]    PASS: Profile system activated during boot
[INFO]    PASS: Three overlay mounts reported (etc, var, usr)
[INFO]    PASS: Data partition and profiles initialized
[INFO]  =========================================
[INFO]    ALL 4 TESTS PASSED
[INFO]  =========================================
```

## 7. Manual QEMU Testing (Interactive)

For hands-on testing inside a running system:

```bash
# Boot image interactively (not as a test)
IMAGE=$FLIPPER_DEV/images/flipper-os-rock-4d.img

# Extract kernel and initrd first (reuse test infrastructure)
WORK=$(mktemp -d)
LOOP=$(sudo losetup -fP --show $IMAGE)
sudo mount -o ro ${LOOP}p1 $WORK
VMLINUZ=$(find $WORK -name 'vmlinuz*' | head -1)
INITRD=$(find $WORK -name 'initramfs*' | head -1)
APPEND=$(sed -n 's/^[[:space:]]*append[[:space:]]\+//p' $WORK/extlinux/extlinux.conf)
# Adjust console for QEMU virt
APPEND=$(echo "$APPEND" | sed 's/console=ttyS[^ ]*/console=ttyAMA0/g; s/console=tty1//g')

sudo qemu-system-aarch64 \
    -M virt -cpu cortex-a72 -m 4096 -nographic \
    -kernel $VMLINUZ \
    -initrd $INITRD \
    -drive file=$IMAGE,format=raw,if=virtio,snapshot=on \
    -append "$APPEND console=ttyAMA0"
```

Once logged in (`user` / `user`), run:

```bash
# 1. Verify profile is active
cat /run/flipper-profile
# → "default"

cat /run/flipper-profile-status
# → "ok"

# 2. Check overlay mounts
mount | grep overlay
# → overlay on /etc type overlay (lowerdir=/etc,upperdir=...,workdir=...)
# → overlay on /var type overlay (...)
# → overlay on /usr type overlay (...)

# 3. Check data partition
df -h /data
# → mounted ext4 partition
ls /data/profiles/
# → default/  wifi-router/  desktop/  sniffer/

# 4. List profiles
flipper-profile list
# NAME                 TYPE       SIZE         STATUS
# ----                 ----       ----         ------
# default              built-in   0KB          active
# desktop              built-in   0KB
# sniffer              built-in   0KB
# wifi-router          built-in   0KB

# 5. Create a user profile
flipper-profile create my-test
flipper-profile list
# → my-test should appear with type=user

# 6. Create from template
flipper-profile create --from wifi-router my-router
flipper-profile info my-router
# → type=user, template=wifi-router

# 7. Clone
flipper-profile clone default clone-1
flipper-profile info clone-1

# 8. Switch profile (sets .next-profile for next reboot)
flipper-profile switch my-test
cat /data/.next-profile
# → "my-test"

# 9. Test constraints
flipper-profile delete default
# → ERROR: cannot delete built-in

flipper-profile delete my-test
# → ERROR: cannot delete active profile (if current)

flipper-profile reset default
# → success: resets to template

# 10. Check profiled daemon
systemctl status flipper-profiled
# → active (running)
cat /data/profiles/default/.profile.json
# → last_boot should be set, boot_count >= 1

# 11. Write a file to verify overlay persistence
echo "test" > /etc/flipper-test-file
ls -la /data/profiles/default/upper/etc/flipper-test-file
# → file exists in the overlay upper dir
```

### Testing profile switch across reboot

Inside QEMU (with `snapshot=on`, changes don't persist to the image file):

```bash
flipper-profile create reboot-test
flipper-profile switch reboot-test
reboot
```

After reboot, log in and check:
```bash
cat /run/flipper-profile
# → "reboot-test"
```

**Note**: With QEMU `snapshot=on`, the disk state is lost on QEMU restart. To
test reboot persistence, remove `snapshot=on` from the QEMU command and work on
a copy of the image.

## 8. Testing Edge Cases

### Power loss during profile operations

Simulate by killing QEMU mid-operation:

```bash
# In guest: start a create operation on a large clone
flipper-profile clone desktop big-clone &

# From host: kill QEMU immediately
kill -9 <qemu-pid>

# Restart QEMU — the initramfs should clean up .tmp-* dirs
# Check serial log for: "flipper-profile: removing stale temp dir: ..."
```

### Boot without data partition

Test graceful degradation by removing the data partition label:

```bash
# Modify QEMU append line to use a non-existent partition label
# The system should boot without profiles and log an error
```

Check serial output for:
```
flipper-profile: ERROR: data partition (LABEL=data) not found
flipper-profile: ERROR: cannot mount data partition — booting without profile
```

### Force profile via kernel cmdline

```bash
sudo qemu-system-aarch64 ... \
    -append "... flipper.profile=wifi-router"
```

After boot: `cat /run/flipper-profile` should show `wifi-router`.

### Skip selector

```bash
sudo qemu-system-aarch64 ... \
    -append "... flipper.noselector"
```

Should auto-select the last booted profile without showing a menu.

## 9. Troubleshooting

### Common initramfs issues

The initramfs uses busybox `ash`, which is more limited than full bash. If you
modify `initramfs/scripts/local-bottom/flipper-profile`, keep these constraints
in mind:

| Pitfall | Symptom | Fix |
|---------|---------|-----|
| `basename` used | `basename: not found` | Use `${var%/}; ${var##*/}` |
| `dirname` used | `dirname: not found` | Use `${var%/*}` or hardcode path |
| `grep` used | `grep: not found` | Use `case` statements instead |
| `mount --bind` | `mount: invalid option --` | Use `mount -o bind` |
| Multi-line `mount -t overlay` | `Usage: mount [...]` | Put entire command on one line |
| `read -t` not working | No timeout on menu | busybox ash supports `read -t` but suppress SC3045 |

### No serial output from QEMU

Ensure the kernel config includes:
```
CONFIG_SERIAL_AMBA_PL011=y
CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
```

And the boot args include `console=ttyAMA0` (not `ttyS2` or `tty1`).

### QEMU disk not found ("LABEL=sysroot does not exist")

Ensure the kernel config includes:
```
CONFIG_PCI_HOST_GENERIC=y
```

QEMU virt uses a generic PCI host bridge. Without this, virtio-pci devices
(including the disk) are invisible to the kernel.

### Overlay mount fails

Check the serial log for the exact error. Common causes:
- Overlay module not loaded: the initramfs script runs `modprobe overlay`
- Workdir on different filesystem than upperdir: both must be on the data partition
- Stale workdir from crash: the script clears `work/<dir>/work` and `work/<dir>/index`

### Stale rootfs from failed build

If `build-rootfs.sh` fails mid-build, `/proc` or `/dev` may remain mounted inside
the rootfs directory. Clean up with:

```bash
sudo umount $FLIPPER_DEV/ostree-work/rootfs/proc 2>/dev/null
sudo umount $FLIPPER_DEV/ostree-work/rootfs/sys 2>/dev/null
sudo umount $FLIPPER_DEV/ostree-work/rootfs/dev/pts 2>/dev/null
sudo umount $FLIPPER_DEV/ostree-work/rootfs/dev 2>/dev/null
sudo rm -rf $FLIPPER_DEV/ostree-work/rootfs
```

## 10. Checklist

Use this checklist to track test coverage:

- [ ] `make lint` passes (shellcheck clean)
- [ ] Shared library functions work in isolation
- [ ] `make rootfs` installs profile system files
- [ ] `make ostree-commit` succeeds
- [ ] `make image` seeds templates on data partition
- [ ] `make qemu-test` boots to login (no regressions)
- [ ] `make profile-test` passes all 4 checks
- [ ] `flipper-profile list` shows 4 built-in profiles
- [ ] `flipper-profile create` / `clone` / `delete` / `reset` work
- [ ] `flipper-profile switch` + reboot switches profile
- [ ] `flipper-profiled` daemon updates `.profile.json` on boot
- [ ] Overlay writes land in `upper/` directory
- [ ] Graceful degradation without data partition
- [ ] `flipper.profile=` cmdline override works
- [ ] Stale `.tmp-*` directories are cleaned on boot
