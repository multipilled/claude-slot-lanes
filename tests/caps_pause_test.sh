#!/usr/bin/env bash
# Live caps and pause, in an isolated state folder (1-slot CPU lane set through slot-caps, not the environment).
# (1) Raising the cap with --cap lets a waiter start while the holder still runs. (2) Lowering it stops nothing, and
# a new job waits until fewer than the cap are running. (3) A paused project's waiter holds while the slot is free,
# does not hold back an unranked waiter even though it is ranked first, and a running job under "--pause all"
# finishes; --resume lets the paused job run.
BIN="${SLOT_BIN:-$(cd "$(dirname "$0")/.." && { [ -d bin ] && cd bin; pwd; })}"   # repo layout bin/, or flat
T=$(mktemp -d)
mkdir -p "$T/state" "$T/alpha-proj" "$T/other"
unset CPU_SLOTS GPU_SLOTS
export SLOT_LANES_HOME="$T/state" WITH_LANE=cpu GAME_GUARD=off CPU_POLL_SEC=1 CPU_POLL_MAX_SEC=2
W="$BIN/with_cpu.sh"; fail=""
ev() { echo "$1" >> "$T/ev"; }
bash "$W" --cap cpu 1 >/dev/null
# (1)
(cd "$T/other" && bash "$W" a bash -c "sleep 6; echo a-end >> '$T/ev'") >/dev/null &
sleep 1; (cd "$T/other" && bash "$W" b bash -c "echo b-start >> '$T/ev'") >/dev/null &
sleep 2; bash "$W" --cap cpu 2 >/dev/null; wait
[ "$(head -1 "$T/ev")" = b-start ] || fail="$fail raise($(tr '\n' ' ' < "$T/ev"))"
: > "$T/ev"
# (2)
(cd "$T/other" && bash "$W" c bash -c "sleep 4; echo c-end >> '$T/ev'") >/dev/null &
(cd "$T/other" && bash "$W" d bash -c "sleep 5; echo d-end >> '$T/ev'") >/dev/null &
sleep 1; bash "$W" --cap cpu 1 >/dev/null
(cd "$T/other" && bash "$W" e bash -c "echo e-start >> '$T/ev'") >/dev/null &
wait
[ "$(tr '\n' ' ' < "$T/ev")" = "c-end d-end e-start " ] || fail="$fail lower($(tr '\n' ' ' < "$T/ev"))"
: > "$T/ev"
# (3)
printf 'alpha-proj\n' > "$T/state/slot-priority"
bash "$W" --pause alpha-proj "test hold" >/dev/null
(cd "$T/other" && bash "$W" h bash -c "sleep 3; echo h-end >> '$T/ev'") >/dev/null &
sleep 1; (cd "$T/alpha-proj" && bash "$W" al bash -c "echo al-start >> '$T/ev'") >/dev/null &
sleep 0.5; (cd "$T/other" && bash "$W" z bash -c "echo z-start >> '$T/ev'; sleep 2") >/dev/null &
sleep 0.5; bash "$W" --pause all >/dev/null
sleep 4; bash "$W" --resume all >/dev/null
sleep 3; ev check; bash "$W" --resume alpha-proj >/dev/null
wait
got=$(tr '\n' ' ' < "$T/ev")
rm -rf "$T"
[ "$got" = "h-end z-start check al-start " ] || fail="$fail pause($got)"
[ -z "$fail" ] && echo "PASS caps+pause" || { echo "FAIL caps+pause:$fail"; exit 1; }
