Show the current state of the local OSTree repository.

1. Check if $OSTREE_REPO exists and is initialized
2. List all branches with `ostree refs`
3. Show the latest commit on each branch with `ostree log --max=1`
4. Report repo size with `du -sh`
