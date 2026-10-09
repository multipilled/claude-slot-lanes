#!/usr/bin/env bash
# Auto-routing: GPU tools go to the GPU lane, compiles stay CPU, user patterns and WITH_LANE override work.
BIN="$(cd "$(dirname "$0")/../bin" && pwd)"
T=$(mktemp -d)
export SLOT_LANES_HOME="$T/state" GAME_GUARD=off CPU_POLL_SEC=1
mkdir -p "$T/state"; echo 'mygame\.exe' > "$T/state/gpu-patterns"
printf 'echo blender --background scene.blend\n' > "$T/render.sh"
lane() { bash "$BIN/with_cpu.sh" rt "$@" >/dev/null 2>&1; tail -n 2 "$T/state/slot-lanes.log" | grep -oE ' start (cpu|gpu) ' | tr -d ' ' | sed 's/start//'; }
fail=""
[ "$(lane echo cmake --build x)" = cpu ] || fail="$fail compile"
[ "$(lane bash "$T/render.sh")" = gpu ] || fail="$fail script-scan"
[ "$(lane echo godot --headless)" = gpu ] || fail="$fail godot"
[ "$(lane echo mygame.exe)" = gpu ] || fail="$fail user-pattern"
[ "$(WITH_LANE=cpu lane echo blender)" = cpu ] || fail="$fail override"
rm -rf "$T"
[ -z "$fail" ] && echo "PASS route" || { echo "FAIL route:$fail"; exit 1; }
