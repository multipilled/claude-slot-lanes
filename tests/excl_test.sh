#!/usr/bin/env bash
# with_gpu.sh --exclusive in an isolated state folder: the job runs to the end and both GPU slots are released.
BIN="$(cd "$(dirname "$0")/../bin" && pwd)"
T=$(mktemp -d)
export SLOT_LANES_HOME="$T/state" GAME_GUARD=off
timeout 90 bash "$BIN/with_gpu.sh" --exclusive excltest bash -c "sleep 2 && echo RAN > '$T/ran.txt'"
rc=$?
ran=$(cat "$T/ran.txt" 2>/dev/null); left=$(ls "$T/state/gpu-slots" 2>/dev/null | grep -c '^[0-9]')
rm -rf "$T"
[ $rc -eq 0 ] && [ "$ran" = RAN ] && [ "$left" = 0 ] && echo "PASS exclusive" || { echo "FAIL exclusive: rc=$rc ran=$ran slots left=$left"; exit 1; }
