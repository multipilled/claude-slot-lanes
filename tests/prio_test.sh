#!/usr/bin/env bash
# Ranked priority, in an isolated state folder with 1 CPU slot. A holder keeps the slot 6 s; then an unranked waiter (z),
# a rank-3 waiter (gamma), a rank-2 waiter (beta) and a rank-1 waiter (alpha) queue in that order.
# Expected run order after the holder: alpha beta gamma z.
BIN="${SLOT_BIN:-$(cd "$(dirname "$0")/.." && { [ -d bin ] && cd bin; pwd; })}"   # repo layout bin/, or flat
T=$(mktemp -d)
mkdir -p "$T/state" "$T/alpha-proj" "$T/beta-proj" "$T/gamma-proj" "$T/other"
printf 'alpha-proj\nbeta-proj   # second\ngamma-proj\n' > "$T/state/slot-priority"
export SLOT_LANES_HOME="$T/state" CPU_SLOTS=1 CPU_POLL_SEC=1 WITH_LANE=cpu
run() { (cd "$T/$1" && bash "$BIN/with_cpu.sh" "$2" bash -c "echo $2 >> '$T/order'; sleep 1") & }
(cd "$T/other" && bash "$BIN/with_cpu.sh" holder bash -c "sleep 6") &
sleep 2; run other z; sleep 0.5; run gamma-proj gamma; sleep 0.5; run beta-proj beta; sleep 0.5; run alpha-proj alpha
wait
got=$(tr '\n' ' ' < "$T/order"); rm -rf "$T"
[ "$got" = "alpha beta gamma z " ] && echo "PASS prio ($got)" || { echo "FAIL prio: order was '$got'"; exit 1; }
