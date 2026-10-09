#!/usr/bin/env bash
# Shared project lock. Serializes everything that runs a project's game or writes a shared build artifact, across
# every session and every git worktree of that project. Each project's tools/with_lock.sh is a thin wrapper that sets
# WITH_LOCK_ROOT (the main checkout, shared by all its worktrees) and execs this file (see examples/).
#   tools/with_lock.sh <session-name> <command...>      LOCK_NAME=<name> picks a different lock (default game)
# Stale locks: the holder writes its PID first, with builtins only. A lock is stale only when that PID is gone, or when
# it is older than 3 hours. A holder may wait a long time for a CPU slot inside the lock, so age alone means nothing.
# A lock with no PID is either a holder that died while taking it (no owner file: stale after 2 minutes) or one from
# an old age-based copy (owner file: stale after 40 minutes).
# A stale lock is renamed away before it is deleted, so two waiters can never delete each other's new lock.
# Edit this file only by writing a new copy and mv-ing it over: bash reads running scripts lazily.
: "${WITH_LOCK_ROOT:?with_lock.sh: set WITH_LOCK_ROOT (use the project wrapper tools/with_lock.sh)}"
LOCK="$WITH_LOCK_ROOT/.locks/${LOCK_NAME:-game}"
mkdir -p "$WITH_LOCK_ROOT/.locks"
owner="$1"; shift

older_than() { [ -n "$(find "$LOCK" -maxdepth 0 -mmin +"$1" 2>/dev/null)" ]; }
stale() {
  local pid=""
  [ -f "$LOCK/pid" ] && read -r pid < "$LOCK/pid"
  if [ -n "$pid" ]; then
    kill -0 "$pid" 2>/dev/null || return 0
    older_than 180
  elif [ -f "$LOCK/owner" ]; then
    older_than 40
  else
    older_than 2
  fi
}

announced=0 polls=0
until mkdir "$LOCK" 2>/dev/null; do
  # PID checks are builtins; age checks fork, so run the full check only about once a minute.
  dead=0
  if [ -f "$LOCK/pid" ]; then read -r p < "$LOCK/pid"; [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null && dead=1; fi
  if { [ $dead -eq 1 ] || [ $((polls % 20)) -eq 0 ]; } && stale; then
    gone="$LOCK.stale.$$"
    if mv "$LOCK" "$gone" 2>/dev/null; then
      echo "with_lock: removed stale lock held by $(cat "$gone/owner" 2>/dev/null)"; rm -rf "$gone"
    else
      polls=$((polls + 1)); sleep 1   # another waiter took it over first, or Windows held the folder
    fi
    continue
  fi
  if [ $announced -eq 0 ]; then echo "with_lock: waiting for lock held by $(cat "$LOCK/owner" 2>/dev/null)"; announced=1; fi
  polls=$((polls + 1))
  sleep 3
done
trap 'rm -rf "$LOCK"' EXIT
echo $$ > "$LOCK/pid"
printf '%s %(%T)T %s %s\n' "$owner" -1 "$PWD" "$*" > "$LOCK/owner"
"$@"
