#!/usr/bin/env bash
# Nested calls take no second slot, in an isolated state folder: GPU in GPU, CPU in CPU, a wrapper given as the job,
# a nested lock on the same lock, a stale SLOT_LANES_HELD that must be ignored, and --exclusive from inside a normal
# GPU slot, which escalates to two slots and finishes (no deadlock).
BIN="${SLOT_BIN:-$(cd "$(dirname "$0")/.." && { [ -d bin ] && cd bin; pwd; })}"   # repo layout bin/, or flat
T=$(mktemp -d)
mkdir -p "$T/state"
export SLOT_LANES_HOME="$T/state" GAME_GUARD=off CPU_POLL_SEC=1 GPU_EXTRA_MIN_FREE_MB=999999 WITH_LOCK_ROOT="$T"
unset SLOT_LANES_HELD IN_GPU_SLOT WITH_LOCK_HELD GPU_EXCLUSIVE_HELD
G="$BIN/with_gpu.sh" C="$BIN/with_cpu.sh" L="$BIN/with_lock.sh"
n() { ls "$T/state/$1-slots" 2>/dev/null | grep -c '^[0-9]'; }
export -f n; export T
r() { timeout 60 "$@" 2>/dev/null | tail -1; }
fail=""
got=$(r bash "$G" t bash "$G" t bash -c 'echo $(n gpu)'); [ "$got" = 1 ] || fail="$fail gpu-in-gpu=$got"
got=$(WITH_LANE=cpu r bash "$C" t bash "$C" t bash -c 'echo $(n cpu)'); [ "$got" = 1 ] || fail="$fail cpu-in-cpu=$got"
got=$(r bash "$C" t bash "$G" t bash -c 'echo $(n gpu)/$(n cpu)'); [ "$got" = 1/0 ] || fail="$fail wrapper-job=$got"
got=$(r bash "$L" t bash "$L" t echo ok); [ "$got" = ok ] || fail="$fail lock-in-lock=$got"
got=$(SLOT_LANES_HELD="gpu:1:999999" r bash "$G" t bash -c 'echo $(n gpu)'); [ "$got" = 1 ] || fail="$fail stale-marker=$got"
got=$(r bash "$G" t bash -c "bash '$G' --exclusive t bash -c 'echo \$(n gpu)'"); [ "$got" = 2 ] || fail="$fail escalate=$got"
left=$(n gpu)$(n cpu)
rm -rf "$T"
[ "$left" = 00 ] || fail="$fail left=$left"
[ -z "$fail" ] && echo "PASS nested" || { echo "FAIL nested:$fail"; exit 1; }
