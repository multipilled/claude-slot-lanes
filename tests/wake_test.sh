#!/usr/bin/env bash
# Fork-free waiting, in an isolated state folder. (1) Wake: a waiter deep in its backoff (8 s, then 16 s naps) starts
# within ~2 s of the holder releasing, not at its next poll. (2) Stress: 30 jobs on 2 slots all run, never more than 2
# at once, and no slot or waiter file is left behind.
BIN="${SLOT_BIN:-$(cd "$(dirname "$0")/.." && { [ -d bin ] && cd bin; pwd; })}"   # repo layout bin/, or flat
T=$(mktemp -d)
export SLOT_LANES_HOME="$T/state" WITH_LANE=cpu GAME_GUARD=off
fail=""
CPU_SLOTS=1 bash "$BIN/with_cpu.sh" holder bash -c "sleep 10" >/dev/null &
sleep 1
SECONDS=0; CPU_SLOTS=1 CPU_POLL_SEC=8 bash "$BIN/with_cpu.sh" late true >/dev/null; secs=$SECONDS
wait
[ $secs -le 11 ] || fail="wake took ${secs}s (no wake: ~23 s)"
mkdir -p "$T/run"
for i in $(seq 1 30); do
  CPU_SLOTS=2 CPU_POLL_SEC=1 bash "$BIN/with_cpu.sh" "s$i" bash -c "n=\$(ls '$T/state/cpu-slots' | grep -c '^[0-9]'); echo \$n >> '$T/run/conc'; sleep 0.3" >/dev/null 2>&1 &
done
wait
ran=$(wc -l < "$T/run/conc"); most=$(sort -n "$T/run/conc" | tail -1)
left=$(ls -A "$T/state/cpu-slots" "$T/state/cpu-slots/.wait" 2>/dev/null | grep -cE '^[0-9p]')
rm -rf "$T"
[ "$ran" = 30 ] && [ "$most" -le 2 ] && [ "$left" = 0 ] || fail="$fail stress: ran=$ran max-concurrent=$most left=$left"
[ -z "$fail" ] && echo "PASS wake (released-slot start ${secs}s after waiting; 30 jobs on 2 slots)" || { echo "FAIL wake:$fail"; exit 1; }
