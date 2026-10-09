#!/usr/bin/env bash
# Machine-wide GPU lane. Jobs that mostly load the GPU go here instead of taking a CPU slot: game and engine runs,
# Blender renders, AI tools (upscalers, image-to-3D, any CUDA/Vulkan model), GPU texture compression. Compiles, tests,
# decompilers and exporters stay on with_cpu.sh.
#   with_gpu.sh <session-name> <command...>               one of $GPU_SLOTS slots (default 3; the 3rd only with 4 GB VRAM free)
#   with_gpu.sh --exclusive <session-name> <command...>   the whole card (two slots; big AI models)
# Same machinery as with_cpu.sh (dead-holder reclaim, fork-free owner writes, 90-minute give-up, exit 75), with its own
# slots in $SLOT_LANES_HOME/gpu-slots. GPU jobs keep normal priority; CPU-lane jobs run below normal.
# Combine with with_lock.sh for anything that runs a game:  with_gpu.sh me tools/with_lock.sh me <cmd>
# Nested calls: a job holding a GPU slot gets SLOT_LANES_HELD="... gpu:<slot>:<pid>" from with_cpu.sh, checked against
# that slot's owner pid, and every with_gpu.sh call inside it shares the slot. --exclusive asked from inside a normal
# slot escalates: it takes the exclusive lock (waiting at most $GPU_ESCALATE_WAIT_SEC, default 600, so two escalating
# jobs can never wait on each other forever; exit 75) and then one more slot. A job whose command is itself
# with_cpu.sh / with_gpu.sh takes no slot here; the inner call decides.
# Edit this file only by writing a new copy and mv-ing it over (bash reads running scripts lazily).
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GDIR=${GPU_SLOT_DIR:-${SLOT_LANES_HOME:-$HOME/.claude}/gpu-slots}

# Does an ancestor of this process hold a GPU slot? Builtins only. IN_GPU_SLOT alone counts only for jobs started by an
# older copy (no SLOT_LANES_HELD).
held() {
  local e r s p k v
  for e in $SLOT_LANES_HELD; do
    [ "${e%%:*}" = gpu ] || continue
    r=${e#*:}; s=${r%%:*}; p=${r#*:}
    kill -0 "$p" 2>/dev/null || continue
    while read -r k v; do [ "$k" = pid ] && [ "$v" = "$p" ] && return 0; done < "$GDIR/$s/owner" 2>/dev/null
  done
  [ -n "$IN_GPU_SLOT" ] && [ -z "$SLOT_LANES_HELD" ]
}

if [ -n "$GPU_EXCL_INNER" ]; then
  # Inside an exclusive job: give the job back the caller's own lock settings.
  if [ -n "$GPU_SAVED_LOCK_NAME" ]; then export LOCK_NAME="$GPU_SAVED_LOCK_NAME"; else unset LOCK_NAME; fi
  if [ -n "$GPU_SAVED_LOCK_ROOT" ]; then export WITH_LOCK_ROOT="$GPU_SAVED_LOCK_ROOT"; else unset WITH_LOCK_ROOT; fi
  unset GPU_EXCL_INNER GPU_SAVED_LOCK_NAME GPU_SAVED_LOCK_ROOT LOCK_MAX_WAIT_SEC
  export GPU_EXCL_NEST=1   # the job's own with_gpu call below takes the second slot
fi

second=""
if held; then
  if [ -n "$GPU_EXCL_NEST" ]; then
    unset GPU_EXCL_NEST; second=1   # second slot of an exclusive (or escalated) job
  elif [ "$1" = "--exclusive" ] && [ -z "$GPU_EXCLUSIVE_HELD" ]; then
    shift
    [ $# -ge 2 ] || { echo "usage: with_gpu.sh --exclusive <session-name> <command...>" >&2; exit 2; }
    # Escalate (a child, never exec: see below).
    GPU_SAVED_LOCK_NAME="$LOCK_NAME" GPU_SAVED_LOCK_ROOT="$WITH_LOCK_ROOT" GPU_EXCL_INNER=1 \
    WITH_LOCK_ROOT="$GDIR" LOCK_NAME=exclusive LOCK_MAX_WAIT_SEC="${GPU_ESCALATE_WAIT_SEC:-600}" \
      bash "$BIN/with_lock.sh" "$1" bash "$BIN/with_gpu.sh" "$@"
    exit $?
  else
    [ "$1" = "--exclusive" ] && shift
    # Already inside a GPU-slot job: share its slot. Run as a child, never exec: under Git Bash exec gives the process
    # a new Windows PID, so the game guard watching the old one would think the job ended and close the rest of it.
    shift; "$@"; exit $?
  fi
fi

if [ -n "$second" ]; then   # this process IS the first slot's job, so stay alive
  GPU_EXCLUSIVE_HELD=1 SLOT_TAKE_EXTRA=1 SLOT_LANE=gpu LANE_SLOTS="$GPU_SLOTS" LANE_DIR="$GDIR" \
  LANE_MAX_WAIT_MIN="${GPU_MAX_WAIT_MIN:-90}" bash "$BIN/with_cpu.sh" "$@"
  exit $?
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

if [ -z "$GPU_EXCL_NEST" ] && [ $# -ge 2 ]; then   # the job is itself a slot wrapper: let it decide
  j=$2; case "${j##*/}" in bash|bash.exe|sh) j=$3 ;; esac
  case "${j##*/}" in with_cpu.sh|with_gpu.sh) shift; "$@"; exit $? ;; esac
fi
SLOT_LANE=gpu LANE_SLOTS="$GPU_SLOTS" LANE_DIR="$GDIR" LANE_MAX_WAIT_MIN="${GPU_MAX_WAIT_MIN:-90}" \
  exec bash "$BIN/with_cpu.sh" "$@"
