#!/usr/bin/env bash
# Machine-wide CPU budget shared by every agent session of every project (one copy; a project's tools/with_cpu.sh
# can just exec this). Heavy jobs (builds, engine runs, headless decompilers, exporters, big scans) take one of
# $CPU_SLOTS slots and run at below-normal priority (re-applied to late children), so the desktop stays responsive.
#   with_cpu.sh <session-name> <command...>
# Combine with with_lock.sh for anything that touches a shared build artifact or runs a game.
#
# State lives in $SLOT_LANES_HOME (default $HOME/.claude): slot folders, the priority file, pattern files and logs.
# Slots: $CPU_SLOT_DIR/<n>/ (default $SLOT_LANES_HOME/cpu-slots, n = 1..$CPU_SLOTS, default 4).
#   owner  "<session> <HH:MM:SS> <cwd> <command>"
#          "pid <n>"   (second line: this wrapper's PID, held for the job's life)
# Reclaiming: a slot whose pid is dead is freed at once. A slot folder with no owner file older than a minute is a
#   leftover (its holder died between mkdir and the owner write, or Windows refused the rmdir on release) and is
#   taken over. A slot without a pid line is freed when its folder is older than 40 minutes.
# Waiting: a job gives up after $CPU_MAX_WAIT_MIN minutes (default 90) without a slot, exit 75.
# Waiters are kept nearly fork-free (Git Bash forks fail under load, and dozens of waiters poll at once).
# Never pass the script on stdin (`with_cpu.sh me python - <<EOF`): the job runs in the background, the heredoc never
# arrives and the interpreter hangs. A `-` argument is refused (exit 2); write a file.
# Editing THIS file: write a temp copy and `mv` it over (bash reads running scripts incrementally, so an in-place
# write garbles every waiter and holder already running it).
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLOT_HOME=${SLOT_LANES_HOME:-$HOME/.claude}
# Lock before slot: `with_cpu.sh me with_lock.sh me <cmd>` would take a slot and then wait for the project lock
# inside it, idling a scarce slot. Take the project lock first, then the slot.
if [ $# -ge 3 ] && [ "${2##*/}" = with_lock.sh ]; then
  self="${BASH_SOURCE[0]}" o="$1" l="$2"; shift 2
  exec bash "$l" "$1" bash "$self" "$o" "${@:2}"
fi
# Read a pattern file (one extended regex per line, # comments) into one alternation, without forking.
patterns() {
  local line out=""
  [ -f "$1" ] || return
  while IFS= read -r line; do
    line=${line%%#*}; line=${line%"${line##*[![:space:]]}"}; line=${line#"${line%%[![:space:]]*}"}
    [ -n "$line" ] && out+="${out:+|}${line,,}"
  done < "$1"
  printf '%s' "$out"
}
# Auto-routing: a job sent here that mostly loads the GPU (game/engine runs, Blender, emulators, AI upscalers or 3D
# models, GPU texture compression) runs in the GPU lane instead. Explicit compiles stay CPU. The command line and the
# text of any script it runs (first 400 lines) are matched; mixed scripts (build then run) go GPU.
# Add your own patterns in $SLOT_LANES_HOME/gpu-patterns and cpu-patterns (see examples/). Override per job:
# WITH_LANE=cpu|gpu. Every decision is logged to $SLOT_LANES_HOME/slot-lanes.log so the patterns can be refined.
CPU_RE='cargo (build|test|check|clippy)|cmake|msbuild|dotnet (build|test)|ninja|pytest|gradle|analyzeheadless'
GPU_RE='godot|blender|esrgan|comfyui|stable.diffusion|texconv.*-gpu|unrealeditor|renderdoc|optix|citra|azahar|melonds|desmume|shadps4|emuhawk|bizhawk|ryujinx|rpcs3|pcsx2|dolphin\.exe'
if [ -z "$SLOT_LANE" ] && [ $# -ge 2 ] && [ "${WITH_LANE:-auto}" != cpu ]; then
  cmdline="${*:2}"; cmdline="${cmdline,,}"; gpu=""
  extra=$(patterns "$SLOT_HOME/cpu-patterns"); [ -n "$extra" ] && CPU_RE+="|$extra"
  extra=$(patterns "$SLOT_HOME/gpu-patterns"); [ -n "$extra" ] && GPU_RE+="|$extra"
  if [ "$WITH_LANE" = gpu ]; then
    gpu=1
  elif ! [[ "$cmdline" =~ ($CPU_RE) ]]; then
    hay="$cmdline"
    for a in "${@:2}"; do
      case "${a,,}" in
        *.sh|*.ps1|*.bat|*.cmd|*.py)
          if [ -f "$a" ]; then n=0; while [ $n -lt 400 ] && IFS= read -r l; do hay+=" ${l,,}"; n=$((n + 1)); done < "$a"; fi ;;
      esac
    done
    if [[ "$hay" =~ ($GPU_RE) ]]; then gpu=1; fi
  fi
  if [ -n "$gpu" ] && [ -n "$IN_GPU_SLOT" ]; then
    shift; "$@"; exit $?   # a step of a job that already holds a GPU slot shares that slot (a child, not exec: see with_gpu.sh)
  fi
  if [ -n "$gpu" ]; then
    SLOT_LANE=gpu LANE_SLOTS=${GPU_SLOTS:-3} LANE_DIR=${GPU_SLOT_DIR:-$SLOT_HOME/gpu-slots} LANE_MAX_WAIT_MIN=${GPU_MAX_WAIT_MIN:-90}
  fi
  unset cmdline gpu hay a n l extra
fi
unset WITH_LANE
mkdir -p "$SLOT_HOME" 2>/dev/null
LANE_LOG="$SLOT_HOME/slot-lanes.log"
lane_log="${SLOT_LANE:-cpu} $1 ${*:2}"
printf '%(%F %T)T %s\n' -1 "${lane_log:0:220}" >> "$LANE_LOG" 2>/dev/null
unset lane_log
# Lanes: with_gpu.sh runs this same script with SLOT_LANE=gpu (its own slot folder and count). The lane settings are
# unset before the job starts, so a with_cpu call inside a GPU job still takes a CPU slot.
if [ "$SLOT_LANE" = gpu ]; then
  TOOL=with_gpu KIND=GPU SLOTS=${LANE_SLOTS:-3} DIR=${LANE_DIR:-$SLOT_HOME/gpu-slots}
  MAX_WAIT=$(( ${LANE_MAX_WAIT_MIN:-90} * 60 ))
else
  TOOL=with_cpu KIND=CPU SLOTS=${CPU_SLOTS:-4} DIR=${CPU_SLOT_DIR:-$SLOT_HOME/cpu-slots}
  MAX_WAIT=$(( ${CPU_MAX_WAIT_SEC:-$(( ${CPU_MAX_WAIT_MIN:-90} * 60 ))} ))
fi
unset SLOT_LANE LANE_SLOTS LANE_DIR LANE_MAX_WAIT_MIN
POLL=${CPU_POLL_SEC:-5}
AGE_EVERY=${CPU_AGE_CHECK_SEC:-60}   # folder-age checks fork find, so they run at most this often
[ $# -ge 2 ] || { echo "usage: $TOOL.sh <session-name> <command...>" >&2; exit 2; }
owner="$1"; shift
for a in "$@"; do
  if [ "$a" = "-" ]; then
    echo "$TOOL: refusing '$*': a script on stdin never reaches the backgrounded job; write it to a file" >&2
    exit 2
  fi
done
# Disk guard: a heavy job on a drive with less than $SLOT_MIN_FREE_GB (default 2) GB free does not start, so builds
# and imports fail cleanly up front instead of corrupting halfway. Exit 77.
jobline="$*"
free_kb=$(df -Pk "$PWD" 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "$free_kb" ] && [ "$free_kb" -lt $(( ${SLOT_MIN_FREE_GB:-2} * 1048576 )) ]; then
  echo "$TOOL: refusing '$*': only $(( free_kb / 1048576 )) GB free on this drive (need ${SLOT_MIN_FREE_GB:-2} GB); free space first" >&2
  printf '%(%F %T)T refused-disk %s %s\n' -1 "$owner" "${jobline:0:120}" >> "$LANE_LOG" 2>/dev/null
  exit 77
fi
mkdir -p "$DIR"

# Owner file text, built with builtins only (no fork between taking a slot and writing its owner).
owner_text() { local now; printf -v now '%(%T)T' -1; printf '%s %s %s %s\npid %s\n' "$owner" "$now" "$PWD" "$*" "$$"; }
# pid line of an owner file, without forking.
slot_pid() { local k v; while read -r k v; do [ "$k" = pid ] && { echo "$v"; return; }; done < "$1/owner" 2>/dev/null; }
older_than() { [ -n "$(find "$1" -maxdepth 0 -mmin +"$2" 2>/dev/null)" ]; }

# Take over slot $1 when it is an owner-less leftover older than a minute. The owner write is O_EXCL (noclobber), so
# only one waiter wins.
adopt() {
  local d="$DIR/$1"
  [ -d "$d" ] && [ ! -e "$d/owner" ] && older_than "$d" 1 || return 1
  ( set -C; owner_text "$@" > "$d/owner" ) 2>/dev/null || return 1
  echo "$TOOL: took over leftover slot $1" >&2
}

# Free slot $1 if its holder is gone. The folder is renamed first (atomic, so only one waiter wins), then put back if
# it turns out to belong to someone else (a new holder took it in between).
reclaim() {
  local d="$DIR/$1" p stale
  [ -e "$d/owner" ] || return
  p=$(slot_pid "$d")
  if [ -n "$p" ]; then
    kill -0 "$p" 2>/dev/null && return
  else
    [ "$2" = age ] && older_than "$d" 40 || return
  fi
  stale="$DIR/.stale.$1.$$"
  mv "$d" "$stale" 2>/dev/null || return
  if [ "$(slot_pid "$stale")" != "$p" ]; then
    mv -T "$stale" "$d" 2>/dev/null || rm -rf "$stale"
    return
  fi
  echo "$TOOL: reclaimed slot $1 ($(head -1 "$stale/owner" 2>/dev/null | cut -c1-80))" >&2
  rm -rf "$stale"
}

# Release: retry, because Windows refuses to remove a folder while another process has it open. A folder still left
# behind has no owner file and is taken over by the next waiter after a minute (adopt).
cleanup() {
  local t
  [ -n "$slot" ] || return
  for t in 1 2 3 4 5; do
    rm -rf "$DIR/$slot" 2>/dev/null
    [ -e "$DIR/$slot" ] || return
    sleep 1
  done
}

# GPU slots 3+ open only while the card has room: at least $GPU_EXTRA_MIN_FREE_MB (default 4096) MB of VRAM free
# (NVIDIA only; without nvidia-smi only slots 1-2 are used).
vram_room() {
  local f
  f=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null) || return 1
  f=${f%%[!0-9]*}
  [ -n "$f" ] && [ "$f" -ge "${GPU_EXTRA_MIN_FREE_MB:-4096}" ]
}
# Priority: $SLOT_LANES_HOME/slot-priority lists folder or session-name fragments, best first. A job whose working
# folder or session name contains line N has rank N (unlisted: no rank). While a ranked job waits it keeps
# $DIR/.wait/<rank>.<pid>, and any waiter holds back while a better-ranked waiter is still waiting.
# Empty or missing file: first come, first served.
prio=0
if [ -f "$SLOT_HOME/slot-priority" ]; then
  n=0
  while IFS= read -r pl; do
    pl=${pl%%#*}; pl=${pl//[[:space:]]/}
    [ -n "$pl" ] || continue
    n=$((n + 1))
    [ $prio -eq 0 ] && [[ "${PWD,,} ${owner,,}" == *"${pl,,}"* ]] && prio=$n
  done < "$SLOT_HOME/slot-priority"
fi
wdir="$DIR/.wait"; wf=""
better_waiting() {   # is a live waiter ranked above this job waiting?
  local f b r
  for f in "$wdir"/*.*; do
    [ -f "$f" ] || continue
    b=${f##*/}; r=${b%%.*}
    if kill -0 "${b#*.}" 2>/dev/null; then
      [ $prio -eq 0 ] || [ "$r" -lt $prio ] && return 0
    else
      rm -f "$f" 2>/dev/null   # that waiter is gone
    fi
  done
  return 1
}
slot=""
announced=0
start=$SECONDS
last_age=-$AGE_EVERY
while [ -z "$slot" ]; do
  age=""
  if [ $(( SECONDS - last_age )) -ge "$AGE_EVERY" ]; then age=age; last_age=$SECONDS; fi
  better_waiting && held=1 || held=0
  for (( i = 1; i <= SLOTS && held == 0; i++ )); do
    if [ "$KIND" = GPU ] && [ $i -gt 2 ] && [ ! -d "$DIR/$i" ] && ! vram_room; then continue; fi
    if mkdir "$DIR/$i" 2>/dev/null; then slot=$i; trap cleanup EXIT; break; fi
    if [ -n "$age" ] && adopt "$i" "$@"; then slot=$i; trap cleanup EXIT; break; fi
    reclaim "$i" "$age"
    if mkdir "$DIR/$i" 2>/dev/null; then slot=$i; trap cleanup EXIT; break; fi
  done
  if [ -z "$slot" ] && [ $prio -gt 0 ] && [ -z "$wf" ]; then
    mkdir -p "$wdir" 2>/dev/null; wf="$wdir/$prio.$$"; : > "$wf"; trap 'rm -f "$wf"' EXIT
  fi
  if [ -z "$slot" ]; then
    if [ $(( SECONDS - start )) -ge "$MAX_WAIT" ]; then
      echo "$TOOL: gave up after $(( (SECONDS - start) / 60 )) min without a $KIND slot; nothing ran: $*" >&2
      echo "$TOOL: holders: $(head -qn1 "$DIR"/*/owner 2>/dev/null | cut -c1-60 | tr '\n' ';')" >&2
      exit 75
    fi
    [ $announced -eq 0 ] && echo "$TOOL: waiting for a $KIND slot ($(head -qn1 "$DIR"/*/owner 2>/dev/null | tr '\n' ';'))" && announced=1
    sleep "$POLL"
  fi
done
owner_text "$@" > "$DIR/$slot/owner"
[ -n "$wf" ] && rm -f "$wf"
printf '%(%F %T)T start %s %s waited=%ss\n' -1 "${KIND,,}" "$owner" "$(( SECONDS - start ))" >> "$LANE_LOG" 2>/dev/null   # wait times, for tuning slot counts

[ "$KIND" = GPU ] && export IN_GPU_SLOT=1   # nested GPU steps of this job share its slot
pid=""; watcher=""
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; [ -n "$watcher" ] && kill "$watcher" 2>/dev/null; exit 143' TERM INT HUP
"$@" &
pid=$!
winpid=$(cat /proc/$pid/winpid 2>/dev/null)   # Git Bash / Cygwin only; empty elsewhere (guard and priority lowering skipped)
# Game guard for GPU-lane jobs (Windows): keeps the job's windows from taking the foreground or the cursor, and closes
# whatever the job left open when it ends. GAME_GUARD=off skips it (for a run you want to play yourself).
guard=""; gmark=""; grun=""
if [ "$KIND" = GPU ] && [ "${GAME_GUARD:-on}" != off ] && [ -n "$winpid" ] && [ -f "$BIN/game_guard.ps1" ]; then
  gmark="$DIR/$slot/guard"
  # The guard treats the job as running while this file exists and this script lives: an exec inside the job (Git
  # Bash gives it a new Windows PID) must not look like the job ending.
  grun="$DIR/$slot/running"; : > "$grun"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$BIN/game_guard.ps1")" \
    -JobPid "$winpid" -Owner "$owner" -Marker "$(cygpath -w "$gmark")" -Log "$(cygpath -w "$SLOT_HOME/game-guard.log")" \
    -RunFile "$(cygpath -w "$grun")" -HolderPid "$(cat /proc/$$/winpid 2>/dev/null || echo 0)" >/dev/null 2>&1 &
  guard=$!
fi
lower() {
  [ "$KIND" = GPU ] && return   # the GPU lane is favored: its jobs keep normal priority
  [ -n "$winpid" ] && powershell.exe -NoProfile -Command "
    function Low(\$id) { try { (Get-Process -Id \$id -ErrorAction Stop).PriorityClass = 'BelowNormal' } catch {}
      Get-CimInstance Win32_Process -Filter \"ParentProcessId=\$id\" | ForEach-Object { Low \$_.ProcessId } }
    Low $winpid" >/dev/null 2>&1
}
( for t in 1 5 20 60; do sleep $t; kill -0 $pid 2>/dev/null || exit 0; lower; done ) &
watcher=$!
lower
wait $pid
code=$?
[ -n "$grun" ] && rm -f "$grun"   # the job really ended: the guard may now close its leftovers
if [ -n "$guard" ]; then
  for t in 1 2 3 4 5 6 7 8 9 10 11 12; do kill -0 "$guard" 2>/dev/null || break; sleep 1; done   # leftover cleanup
  if [ -f "$gmark" ]; then
    echo "$TOOL: game guard closed this job: $(cat "$gmark") (log: $SLOT_HOME/game-guard.log)" >&2
    code=76
  fi
fi
kill $watcher 2>/dev/null
exit $code
