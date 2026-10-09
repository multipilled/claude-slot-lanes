#!/usr/bin/env bash
# A project's tools/with_lock.sh: one lock folder for the main checkout and every git worktree of it.
#   tools/with_lock.sh <session-name> <command...>
# The first worktree in `git worktree list` is the main checkout.
export WITH_LOCK_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" worktree list --porcelain | sed -n '1s/^worktree //p')"
exec bash "${SLOT_LANES_BIN:-$HOME/.claude/bin}/with_lock.sh" "$@"
