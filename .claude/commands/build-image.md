Build a Flipper OS disk image for the specified board.

Steps:
1. Source ~/flipper-one-dev/.env
2. Run the build pipeline in build/ to generate a Debian rootfs
3. Commit the rootfs to OSTree
4. Generate partition layout and assemble disk image
5. Report image path, size, and sha256

Target board: $ARGUMENTS (default: rock-4d)
