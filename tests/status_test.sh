#!/usr/bin/env bash
# --status in an isolated state folder: one holder, one waiter and a pause show up in one line of valid JSON.
BIN="${SLOT_BIN:-$(cd "$(dirname "$0")/.." && { [ -d bin ] && cd bin; pwd; })}"   # repo layout bin/, or flat
T=$(mktemp -d)
export SLOT_LANES_HOME="$T/state" WITH_LANE=cpu GAME_GUARD=off CPU_SLOTS=1 CPU_POLL_SEC=1
W="$BIN/with_cpu.sh"
bash "$W" --pause zzz-nothing 'hold "P3" work' >/dev/null
bash "$W" holder bash -c "sleep 5" >/dev/null &
sleep 1; bash "$W" waiter true >/dev/null &
sleep 2; out=$(bash "$W" --status); wait
rm -rf "$T"
py=$(command -v python3 || command -v python)
lines=$(printf '%s\n' "$out" | wc -l)
if [ -n "$py" ]; then
  chk=$(printf '%s' "$out" | "$py" -c 'import json,sys; d=json.load(sys.stdin); c=d["lanes"]["cpu"]
print(c["cap"], c["running"], c["holders"][0]["session"], c["holders"][0]["alive"], c["waiters"][0]["session"], d["pauses"][0]["reason"])' 2>&1)
else
  chk="1 1 holder True waiter hold \"P3\" work"   # no python: shape checks below only
fi
[ "$lines" = 1 ] && [ "$chk" = '1 1 holder True waiter hold "P3" work' ] && [[ "$out" == '{"time":'*']}' ]] \
  && echo "PASS status" || { echo "FAIL status: lines=$lines check=$chk out=${out:0:300}"; exit 1; }
