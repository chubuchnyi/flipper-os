# OSTree Operations for Flipper OS

## When to use
When working with OSTree repositories, commits, deployments, or rootfs management.

## Key concepts
- **Repository** ($OSTREE_REPO): archive-mode repo storing all rootfs commits
- **Branch naming**: `flipper-os:base/latest`, `flipper-os:profiles/<name>`
- **Commits are content-addressed**: identical files are deduplicated via hardlinks
- **Deployments**: checked-out commits in /ostree/deploy/flipper-os/

## Common operations
```bash
# Init repo
ostree init --repo=$OSTREE_REPO --mode=archive

# Commit a rootfs directory
ostree commit --repo=$OSTREE_REPO \
  --branch=flipper-os:base/latest \
  --subject="Flipper OS $(date +%Y%m%d)" \
  --add-metadata-string=version=0.1.0 \
  $ROOTFS_DIR

# Generate static delta for OTA
ostree static-delta generate --repo=$OSTREE_REPO \
  --from=<old-commit> --to=<new-commit>

# Deploy to sysroot
ostree admin deploy --os=flipper-os --sysroot=$SYSROOT flipper-os:base/latest
```

## Rules
- Always use archive mode for repos that will serve updates
- Never modify a committed tree — create a new commit instead
- Static deltas should be generated for every release pair
