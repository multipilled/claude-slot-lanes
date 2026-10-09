#!/usr/bin/env bash
# Machine-wide GPU lane. Jobs that mostly load the GPU go here instead of taking a CPU slot: game and engine runs,
# Blender renders, AI tools (upscalers, image-to-3D, any CUDA/Vulkan model), GPU texture compression. Compiles, tests,
# decompilers and exporters stay on with_cpu.sh.
#   with_gpu.sh <session-name> <command...>               one of $GPU_SLOTS slots (default 3; the 3rd only with 4 GB VRAM free)
#   with_gpu.sh --exclusive <session-name> <command...>   the whole card (two slots; big AI models)
# Same machinery as with_cpu.sh (dead-holder reclaim, fork-free owner writes, 90-minute give-up, exit 75), with its own
# slots in $SLOT_LANES_HOME/gpu-slots. GPU jobs keep normal priority; CPU-lane jobs run below normal.
# Combine with with_lock.sh for anything that runs a game:  with_gpu.sh me tools/with_lock.sh me <cmd>
# Edit this file only by writing a new copy and mv-ing it over (bash reads running scripts lazily).
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GDIR=${GPU_SLOT_DIR:-${SLOT_LANES_HOME:-$HOME/.claude}/gpu-slots}

if [ -n "$GPU_EXCL_INNER" ]; then
  # Inside an exclusive job: give the job back the caller's own lock settings.
  if [ -n "$GPU_SAVED_LOCK_NAME" ]; then export LOCK_NAME="$GPU_SAVED_LOCK_NAME"; else unset LOCK_NAME; fi
  if [ -n "$GPU_SAVED_LOCK_ROOT" ]; then export WITH_LOCK_ROOT="$GPU_SAVED_LOCK_ROOT"; else unset WITH_LOCK_ROOT; fi
  unset GPU_EXCL_INNER GPU_SAVED_LOCK_NAME GPU_SAVED_LOCK_ROOT
  export GPU_EXCL_NEST=1   # the job's own with_gpu call below takes the second slot
fi

if [ -n "$IN_GPU_SLOT" ]; then
  if [ -n "$GPU_EXCL_NEST" ]; then
    unset GPU_EXCL_NEST    # second slot of an exclusive job
  else
    [ "$1" = "--exclusive" ] && shift
    # Already inside a GPU-slot job: share its slot. Run as a child, never exec: under Git Bash exec gives the process
    # a new Windows PID, so the game guard watching the old one would think the job ended and close the rest of it.
    shift; "$@"; exit $?
  fi
fi

if [ "$1" = "--exclusive" ]; then
  shift
  [ $# -ge 2 ] || { echo "usage: with_gpu.sh --exclusive <session-name> <command...>" >&2; exit 2; }
  # One exclusive job at a time (so two can never each hold one slot and wait for the other), then both slots.
  mkdir -p "$GDIR"
  GPU_SAVED_LOCK_NAME="$LOCK_NAME" GPU_SAVED_LOCK_ROOT="$WITH_LOCK_ROOT" GPU_EXCL_INNER=1 \
  WITH_LOCK_ROOT="$GDIR" LOCK_NAME=exclusive \
    exec bash "$BIN/with_lock.sh" "$1" bash "$BIN/with_gpu.sh" "$1" bash "$BIN/with_gpu.sh" "$@"
fi

if [ -n "$IN_GPU_SLOT" ]; then   # second slot of an exclusive job: this process IS the first slot's job, so stay alive
  SLOT_LANE=gpu LANE_SLOTS="$GPU_SLOTS" LANE_DIR="$GDIR" LANE_MAX_WAIT_MIN="${GPU_MAX_WAIT_MIN:-90}" \
    bash "$BIN/with_cpu.sh" "$@"
  exit $?
fi
SLOT_LANE=gpu LANE_SLOTS="$GPU_SLOTS" LANE_DIR="$GDIR" LANE_MAX_WAIT_MIN="${GPU_MAX_WAIT_MIN:-90}" \
  exec bash "$BIN/with_cpu.sh" "$@"
