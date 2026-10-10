#!/usr/bin/env bash
# with_lock.sh: two jobs on one lock never overlap, a lock left by a dead PID is taken over at once, a lock whose
# holder PID lives is never taken over by age alone, and --status / slot_status.sh list the held lock.
BIN="${SLOT_BIN:-$(cd "$(dirname "$0")/.." && { [ -d bin ] && cd bin; pwd; })}"   # repo layout bin/, or flat
T=$(mktemp -d)
export WITH_LOCK_ROOT="$T" SLOT_LANES_HOME="$T/state"
job() { bash "$BIN/with_lock.sh" "$1" bash -c "echo start-$1 >> '$T/log'; sleep 2; echo end-$1 >> '$T/log'" >/dev/null; }
job a & sleep 0.5; job b & wait
got=$(tr '\n' ' ' < "$T/log")
mkdir -p "$T/.locks/game"; echo 999999 > "$T/.locks/game/pid"; echo "ghost" > "$T/.locks/game/owner"
SECONDS=0; timeout 30 bash "$BIN/with_lock.sh" c true >/dev/null; rc=$?; secs=$SECONDS
# A live holder (this shell) whose lock folder is 5 hours old: the waiter must give up (75), not take it over.
mkdir -p "$T/.locks/old"; echo $$ > "$T/.locks/old/pid"; printf 'oldie 01:00:00 /x sleep\n' > "$T/.locks/old/owner"
touch -d '5 hours ago' "$T/.locks/old"
LOCK_NAME=old LOCK_MAX_WAIT_SEC=4 bash "$BIN/with_lock.sh" d true >/dev/null 2>&1; rc_old=$?
held=$( [ -f "$T/.locks/old/pid" ] && cat "$T/.locks/old/pid")
st=$(bash "$BIN/with_cpu.sh" --status); tb=$(bash "$BIN/slot_status.sh")
rm -rf "$T"
fail=""
[ "$got" = "start-a end-a start-b end-b " ] || fail="overlap: $got"
[ $rc -eq 0 ] && [ $secs -lt 10 ] || fail="$fail stale lock not taken (rc=$rc, ${secs}s)"
[ $rc_old -eq 75 ] && [ "$held" = "$$" ] || fail="$fail live lock taken by age (rc=$rc_old, pid now '$held')"
[[ "$st" == *'"locks":[{"root":'*'"name":"old","session":"oldie","pid":'$$',"alive":true'* ]] || fail="$fail status: ${st:0:300}"
[[ "$tb" == *lock*old*oldie*held* ]] || fail="$fail table: $tb"
[ -z "$fail" ] && echo "PASS lock" || { echo "FAIL lock: $fail"; exit 1; }
