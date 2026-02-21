Create a new built-in profile template for Flipper OS.

Profile name: $ARGUMENTS

1. Create directory profiles/templates/$ARGUMENTS/
2. Generate profile.json with metadata (name, type: "built-in", description)
3. Create etc/ overlay directory with profile-specific configs
4. Create packages.list with required apt packages
5. Create flatpak.list with required Flatpak apps (if any)
6. Update profiles/templates/README.md with the new profile
