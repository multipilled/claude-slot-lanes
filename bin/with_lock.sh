#!/usr/bin/env bash
# Shared project lock. Serializes everything that runs a project's game or writes a shared build artifact, across
# every session and every git worktree of that project. Each project's tools/with_lock.sh is a thin wrapper that sets
# WITH_LOCK_ROOT (the main checkout, shared by all its worktrees) and execs this file (see examples/).
#   tools/with_lock.sh <session-name> <command...>      LOCK_NAME=<name> picks a different lock (default game)
# Stale locks: the holder writes its PID first, with builtins only. A lock with a PID is stale only when that PID is
# gone, never by age: a holder may wait hours for a CPU slot inside the lock. A lock with no PID is either a holder
# that died while taking it (no owner file: stale after 2 minutes) or one from an old age-based copy (owner file:
# stale after 40 minutes); there is no PID to check, so age is all there is.
# A stale lock is renamed away before it is deleted, so two waiters can never delete each other's new lock.
# Each lock root is listed once in $SLOT_LANES_HOME/lock-roots, so `with_cpu.sh --status` can show every lock.
# Edit this file only by writing a new copy and mv-ing it over: bash reads running scripts lazily.
: "${WITH_LOCK_ROOT:?with_lock.sh: set WITH_LOCK_ROOT (use the project wrapper tools/with_lock.sh)}"
LOCK="$WITH_LOCK_ROOT/.locks/${LOCK_NAME:-game}"
mkdir -p "$WITH_LOCK_ROOT/.locks"
owner="$1"; shift
# Re-entrant: a job holding a lock gets WITH_LOCK_HELD lines "<pid><TAB><lock path>", and a call inside it
# for the same lock runs straight through instead of waiting on itself. A line counts only while that pid lives and the
# lock's pid file still names it. LOCK_MAX_WAIT_SEC (used by with_gpu.sh escalation) bounds the wait: exit 75.
inside=""
if [ -n "$WITH_LOCK_HELD" ]; then
  while IFS=$'\t' read -r hp hl; do
    lp=""; [ "$hl" = "$LOCK" ] && kill -0 "$hp" 2>/dev/null && [ -f "$LOCK/pid" ] && read -r lp < "$LOCK/pid"
    [ -n "$lp" ] && [ "$lp" = "$hp" ] && inside=1
  done <<< "$WITH_LOCK_HELD"
fi
if [ -n "$inside" ]; then "$@"; exit $?; fi
max_wait=$LOCK_MAX_WAIT_SEC; unset LOCK_MAX_WAIT_SEC

SLOT_HOME=${SLOT_LANES_HOME:-$HOME/.claude}
reg="$SLOT_HOME/lock-roots" known=""
if [ -f "$reg" ]; then while IFS= read -r l; do [ "$l" = "$WITH_LOCK_ROOT" ] && known=1; done < "$reg"; fi
[ -n "$known" ] || { mkdir -p "$SLOT_HOME"; echo "$WITH_LOCK_ROOT" >> "$reg"; } 2>/dev/null

older_than() { [ -n "$(find "$LOCK" -maxdepth 0 -mmin +"$1" 2>/dev/null)" ]; }
first_owner() { local l=""; [ -f "$LOCK/owner" ] && IFS= read -r l < "$LOCK/owner"; echo "$l"; }

announced=0 polls=0
until mkdir "$LOCK" 2>/dev/null; do
  # A PID check is a builtin and runs every poll. A lock with no PID needs an age check, which forks: about once a minute.
  stale=0 p=""
  [ -f "$LOCK/pid" ] && read -r p < "$LOCK/pid"
  if [ -n "$p" ]; then kill -0 "$p" 2>/dev/null || stale=1
  elif [ $((polls % 20)) -eq 0 ]; then
    if [ -f "$LOCK/owner" ]; then older_than 40 && stale=1; else older_than 2 && stale=1; fi
  fi
  if [ $stale -eq 1 ]; then
    gone="$LOCK.stale.$$"
    if mv "$LOCK" "$gone" 2>/dev/null; then
      echo "with_lock: removed stale lock held by $(LOCK=$gone first_owner)"; rm -rf "$gone"
    else
      polls=$((polls + 1)); sleep 1   # another waiter took it over first, or Windows held the folder
    fi
    continue
  fi
  if [ $announced -eq 0 ]; then echo "with_lock: waiting for lock held by $(first_owner)"; announced=1; fi
  if [ -n "$max_wait" ] && [ $SECONDS -ge "$max_wait" ]; then
    echo "with_lock: gave up after ${SECONDS}s waiting for ${LOCK_NAME:-game}; nothing ran: $*" >&2; exit 75
  fi
  polls=$((polls + 1))
  sleep 3
done
trap 'rm -rf "$LOCK"' EXIT
export WITH_LOCK_HELD="${WITH_LOCK_HELD:+$WITH_LOCK_HELD$'\n'}$$"$'\t'"$LOCK"
echo $$ > "$LOCK/pid"
printf '%s %(%T)T %s %s\nstart %(%s)T\n' "$owner" -1 "$PWD" "$*" -1 > "$LOCK/owner"
"$@"
