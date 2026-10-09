#!/usr/bin/env bash
# with_lock.sh: two jobs on one lock never overlap, and a lock left by a dead PID is taken over at once.
BIN="${SLOT_BIN:-$(cd "$(dirname "$0")/.." && { [ -d bin ] && cd bin; pwd; })}"   # repo layout bin/, or flat
T=$(mktemp -d)
export WITH_LOCK_ROOT="$T"
job() { bash "$BIN/with_lock.sh" "$1" bash -c "echo start-$1 >> '$T/log'; sleep 2; echo end-$1 >> '$T/log'" >/dev/null; }
job a & sleep 0.5; job b & wait
got=$(tr '\n' ' ' < "$T/log")
mkdir -p "$T/.locks/game"; echo 999999 > "$T/.locks/game/pid"; echo "ghost" > "$T/.locks/game/owner"
SECONDS=0; timeout 30 bash "$BIN/with_lock.sh" c true >/dev/null; rc=$?; secs=$SECONDS
rm -rf "$T"
fail=""
[ "$got" = "start-a end-a start-b end-b " ] || fail="overlap: $got"
[ $rc -eq 0 ] && [ $secs -lt 10 ] || fail="$fail stale lock not taken (rc=$rc, ${secs}s)"
[ -z "$fail" ] && echo "PASS lock" || { echo "FAIL lock: $fail"; exit 1; }
