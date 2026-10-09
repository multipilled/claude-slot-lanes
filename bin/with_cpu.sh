#!/usr/bin/env bash
# Machine-wide CPU budget shared by every agent session of every project (one copy; a project's tools/with_cpu.sh
# can just exec this). Heavy jobs (builds, engine runs, headless decompilers, exporters, big scans) take one of
# $CPU_SLOTS slots and run at below-normal priority (re-applied to late children), so the desktop stays responsive.
#   with_cpu.sh <session-name> <command...>
#   with_cpu.sh --status                     one line of JSON: caps, holders, ages, waiters, pauses (both lanes)
#   with_cpu.sh --cap cpu|gpu <n>|default    change a lane's cap live (waiters pick it up on their next check)
#   with_cpu.sh --pause <lane|all|fragment> [reason]  /  --resume <same>     hold matching waiters
# Combine with with_lock.sh for anything that touches a shared build artifact or runs a game.
#
# State lives in $SLOT_LANES_HOME (default $HOME/.claude): slot folders, slot-priority, slot-caps, slot-pause/,
# cpu-patterns and gpu-patterns (also read from next to this script), and the logs.
# Slots: $CPU_SLOT_DIR/<n>/ (default $SLOT_LANES_HOME/cpu-slots, n = 1..cap, default 4).
#   owner  "<session> <HH:MM:SS> <cwd> <command>"
#          "pid <n>"                                (this wrapper's PID, held for the job's life)
#          "start <epoch>"                          (for --status ages)
# Reclaiming: a slot whose pid is dead is freed at once. A slot folder with no owner file older than a
#   minute is a leftover (its holder died between mkdir and the owner write, or Windows refused the rmdir
#   on release) and is taken over. A slot without a pid line (written by an old copy) is freed when its
#   folder is older than 40 minutes, as before. Never an age-only check on a slot with a live pid.
# Waiting: a job gives up after $CPU_MAX_WAIT_MIN minutes (default 90) without a slot, exit 75 (time spent
# paused does not count).
# Waiters are fork-free (compared with pueue's daemon and GPU task-spooler; ~50 polling waiters once made Git Bash
# forks fail). Each loop reads the slot folders once with builtins (no mkdir on a held slot, no $(...)),
# then sleeps in `read -t` on its own FIFO ($DIR/.wait/<rank>.<pid>.<epoch>.<session>) with exponential backoff
# from $CPU_POLL_SEC (default 2) up to $CPU_POLL_MAX_SEC (default 30). A holder that releases its slot writes a byte
# to every waiter FIFO of its lane, so a freed slot is taken at once, like a daemon handing it over, without one.
# Measured (tests/forkrate.sh), one waiter on full slots: 152 processes/min before, 0/min after startup.
# Caps (like pueue groups): $SLOT_LANES_HOME/slot-caps ("cpu 4" / "gpu 3" lines) is re-read on every
# loop, so caps change without restarting waiters. CPU_SLOTS / GPU_SLOTS in the environment still win for that job.
# Lowering a cap never stops a running job; new jobs wait until fewer than the cap are running.
# Pause: a file $SLOT_LANES_HOME/slot-pause/<name> holds every waiter it matches (running jobs continue):
#   "all", a lane ("cpu" / "gpu"), or a fragment of the job's folder or session name (e.g. a project, matched like
#   slot-priority). Its first line is the reason shown by --status. A paused waiter never holds back other waiters.
# Never pass the script on stdin (`with_cpu.sh me python - <<EOF`): the job runs in the background, the
# heredoc never arrives and the interpreter hangs. A `-` argument is refused (exit 2); write a file.
# Editing THIS file: write a temp copy and `mv` it over (bash reads running scripts incrementally, so an
# in-place write garbles every waiter and holder already running it).
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLOT_HOME=${SLOT_LANES_HOME:-$HOME/.claude}
CAPS_FILE="$SLOT_HOME/slot-caps"
PAUSE_DIR="$SLOT_HOME/slot-pause"

# Cap of lane $1 (cpu|gpu) into $cap: $2 (an explicit env setting) wins, then slot-caps, then the default.
lane_cap() {
  local k v
  cap=$2
  if [ -z "$cap" ] && [ -f "$CAPS_FILE" ]; then
    while IFS=' =:' read -r k v _; do
      k=${k,,}; k=${k%_slots}
      [ "$k" = "$1" ] && [[ "$v" =~ ^[0-9]+$ ]] && cap=$v
    done < "$CAPS_FILE"
  fi
  [ -n "$cap" ] || { [ "$1" = gpu ] && cap=3 || cap=4; }
}
# Pause file that holds a job of lane $1 with folder/session text $2 (lower case), into $pause ("" = none).
paused_by() {
  local f n
  pause=""
  for f in "$PAUSE_DIR"/*; do
    [ -f "$f" ] || continue
    n=${f##*/}; n=${n,,}
    case "$n" in
      all|"$1") pause=$n; return ;;
      cpu|gpu) continue ;;
    esac
    [[ "$2" == *"$n"* ]] && { pause=$n; return; }
  done
}
# JSON string of $1 into the variable named $2.
json_str() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/ }; s=${s//$'\r'/}; s=${s//$'\n'/ }
  printf -v "$2" '"%s"' "$s"
}

# --status (a cheap stand-in for a job daemon's API): one line of JSON for a dashboard, a scheduler or any session.
#   {"time":<epoch>,"lanes":{"cpu":{"cap":4,"running":1,"holders":[{"slot":1,"session":..,"pid":..,"alive":true,
#    "age_s":..,"cwd":..,"cmd":..}],"waiters":[{"rank":1,"pid":..,"session":..,"age_s":..,"paused":false}],
#    "paused_by":null},"gpu":{...}},"pauses":[{"name":..,"reason":..}]}
# rank 0 = unranked. Ages come from the owner's start line (or its HH:MM:SS for jobs started by an older copy).
status() {
  local now lane dir cap d n first k v sp st t sess cwd cmd out hs ws f b r rest p e alive age pf lr sep=""
  printf -v now '%(%s)T' -1
  printf -v t '%(%H:%M:%S)T' -1
  local today=$(( now - (10#${t:0:2} * 3600 + 10#${t:3:2} * 60 + 10#${t:6:2}) ))
  out="{\"time\":$now,\"lanes\":{"
  for lane in cpu gpu; do
    if [ $lane = cpu ]; then dir=${CPU_SLOT_DIR:-$SLOT_HOME/cpu-slots}; lane_cap cpu "$CPU_SLOTS"
    else dir=${GPU_SLOT_DIR:-$SLOT_HOME/gpu-slots}; lane_cap gpu "$GPU_SLOTS"; fi
    hs=""; ws=""; n=0
    for d in "$dir"/[0-9]*; do
      [ -d "$d" ] || continue
      sp=""; st=""; first=""
      if [ -f "$d/owner" ]; then
        { IFS= read -r first; while read -r k v; do [ "$k" = pid ] && sp=$v; [ "$k" = start ] && st=$v; done; } < "$d/owner"
      fi
      alive=false; [ -n "$sp" ] && kill -0 "$sp" 2>/dev/null && { alive=true; n=$((n + 1)); }
      sess=${first%% *}; rest=${first#* }; t=${rest%% *}; rest=${rest#* }; cwd=${rest%% *}; cmd=${rest#* }
      if [ -n "$st" ]; then age=$(( now - st ))
      elif [[ "$t" =~ ^([0-9]{2}):([0-9]{2}):([0-9]{2})$ ]]; then
        age=$(( now - today - (10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]}) ))
        [ $age -lt 0 ] && age=$(( age + 86400 ))
      else age=null; fi
      [ -n "$first" ] || { sess=""; cwd=""; cmd=""; }
      json_str "$sess" sess; json_str "$cwd" cwd; json_str "${cmd:0:200}" cmd
      hs+="${hs:+,}{\"slot\":${d##*/},\"session\":$sess,\"pid\":${sp:-null},\"alive\":$alive,\"age_s\":$age,\"cwd\":$cwd,\"cmd\":$cmd}"
    done
    for f in "$dir/.wait"/*; do
      [ -e "$f" ] || continue
      b=${f##*/}; r=${b%%.*}; rest=${b#*.}; p=${rest%%.*}; rest=${rest#"$p"}; rest=${rest#.}
      e=${rest%%.*}; sess=${rest#"$e"}; sess=${sess#.}
      kill -0 "$p" 2>/dev/null || continue
      pf=false; [ "${r:0:1}" = p ] && { pf=true; r=${r#p}; }
      [[ "$r" =~ ^[0-9]+$ ]] || continue
      [ "$r" -ge 9999 ] && r=0
      [[ "$e" =~ ^[0-9]+$ ]] && age=$(( now - e )) || age=null
      json_str "$sess" sess
      ws+="${ws:+,}{\"rank\":$r,\"pid\":$p,\"session\":$sess,\"age_s\":$age,\"paused\":$pf}"
    done
    paused_by $lane ""
    lr=null; [ -n "$pause" ] && json_str "$pause" lr
    out+="$sep\"$lane\":{\"cap\":$cap,\"running\":$n,\"holders\":[$hs],\"waiters\":[$ws],\"paused_by\":$lr}"; sep=,
  done
  out+="},\"pauses\":["
  ws=""
  for f in "$PAUSE_DIR"/*; do
    [ -f "$f" ] || continue
    v=""; IFS= read -r v < "$f"
    json_str "${f##*/}" b; json_str "$v" v
    ws+="${ws:+,}{\"name\":$b,\"reason\":$v}"
  done
  echo "$out$ws]}"
}

case "$1" in
  --status) status; exit 0 ;;
  --cap)
    [[ "$2" =~ ^(cpu|gpu)$ ]] && [[ "$3" =~ ^([0-9]+|default)$ ]] || { echo "usage: with_cpu.sh --cap cpu|gpu <n>|default" >&2; exit 2; }
    mkdir -p "$SLOT_HOME"; tmp="$CAPS_FILE.$$"; : > "$tmp"
    if [ -f "$CAPS_FILE" ]; then
      while IFS= read -r l; do k=${l%%[ =:]*}; k=${k,,}; k=${k%_slots}; [ "$k" = "$2" ] || echo "$l"; done < "$CAPS_FILE" > "$tmp"
    fi
    [ "$3" = default ] || echo "$2 $3" >> "$tmp"
    mv -f "$tmp" "$CAPS_FILE"; echo "with_cpu: $2 cap = $3"; exit 0 ;;
  --pause)
    [ -n "$2" ] && [[ "$2" != */* ]] || { echo "usage: with_cpu.sh --pause <cpu|gpu|all|folder-or-session fragment> [reason]" >&2; exit 2; }
    mkdir -p "$PAUSE_DIR"; echo "${*:3}" > "$PAUSE_DIR/${2,,}"; echo "with_cpu: paused ${2,,}"; exit 0 ;;
  --resume)
    [ -n "$2" ] && [[ "$2" != */* ]] || { echo "usage: with_cpu.sh --resume <name>" >&2; exit 2; }
    rm -f "$PAUSE_DIR/${2,,}"; echo "with_cpu: resumed ${2,,}"; exit 0 ;;
esac

# A job whose command is itself a slot wrapper (`with_cpu.sh me bash with_gpu.sh me <cmd>`) takes no slot here: the
# inner call picks the lane (otherwise the outer call would scan the wrapper's own text and hold a slot idle).
if [ -z "$SLOT_LANE" ] && [ $# -ge 2 ]; then
  j=$2; case "${j##*/}" in bash|bash.exe|sh) j=$3 ;; esac
  case "${j##*/}" in with_cpu.sh|with_gpu.sh) shift; "$@"; exit $? ;; esac
  unset j
fi
# Lock before slot: `with_cpu.sh me with_lock.sh me <cmd>` would take a slot and then wait for the project lock
# inside it, idling a scarce slot. Take the project lock first, then the slot.
if [ $# -ge 3 ] && [ "${2##*/}" = with_lock.sh ]; then
  self="${BASH_SOURCE[0]}" o="$1" l="$2"; shift 2
  exec bash "$l" "$1" bash "$self" "$o" "${@:2}"
fi
# Read pattern file $1 (one extended regex per line, # comments) from next to this script and from $SLOT_LANES_HOME
# into one alternation in the variable named $2. Builtins only.
patterns() {
  local f line out=""
  for f in "$BIN/$1" "$SLOT_HOME/$1"; do
    [ -f "$f" ] || continue
    while IFS= read -r line; do
      line=${line%%#*}; line=${line%"${line##*[![:space:]]}"}; line=${line#"${line%%[![:space:]]*}"}
      [ -n "$line" ] && out+="${out:+|}${line,,}"
    done < "$f"
  done
  printf -v "$2" '%s' "$out"
}
# Auto-routing: a job sent here that mostly loads the GPU (game/engine runs, Blender, emulators, AI upscalers or 3D
# models, GPU texture compression) runs in the GPU lane instead. Explicit compiles stay CPU. The command line and the
# text of any script it runs (first 400 lines) are matched; mixed scripts (build then run) go GPU.
# Add your own patterns in gpu-patterns and cpu-patterns, next to this script or in $SLOT_LANES_HOME (see examples/).
# Override per job: WITH_LANE=cpu|gpu. Every decision is logged to $SLOT_LANES_HOME/slot-lanes.log.
CPU_RE='cargo (build|test|check|clippy)|cmake|msbuild|dotnet (build|test)|ninja|pytest|gradle|ghidra|analyzeheadless'
GPU_RE='godot|blender|esrgan|hunyuan|comfyui|stable.diffusion|texconv.*-gpu|unrealeditor|renderdoc|optix|citra|azahar|melonds|desmume|shadps4|emuhawk|bizhawk|ryujinx|yuzu|rpcs3|pcsx2|dolphin\.exe'
if [ -z "$SLOT_LANE" ] && [ $# -ge 2 ] && [ "${WITH_LANE:-auto}" != cpu ]; then
  cmdline="${*:2}"; cmdline="${cmdline,,}"; gpu=""
  patterns cpu-patterns extra; [ -n "$extra" ] && CPU_RE+="|$extra"
  patterns gpu-patterns extra; [ -n "$extra" ] && GPU_RE+="|$extra"
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
  if [ -n "$gpu" ]; then
    SLOT_LANE=gpu LANE_SLOTS=$GPU_SLOTS LANE_DIR=${GPU_SLOT_DIR:-$SLOT_HOME/gpu-slots} LANE_MAX_WAIT_MIN=${GPU_MAX_WAIT_MIN:-90}
  fi
  unset cmdline gpu hay a n l extra
fi
unset WITH_LANE CPU_RE GPU_RE
mkdir -p "$SLOT_HOME" 2>/dev/null
LANE_LOG="$SLOT_HOME/slot-lanes.log"
lane_log="${SLOT_LANE:-cpu} $1 ${*:2}"
printf '%(%F %T)T %s\n' -1 "${lane_log:0:220}" >> "$LANE_LOG" 2>/dev/null
unset lane_log
# Lanes: with_gpu.sh runs this same script with SLOT_LANE=gpu (its own slot folder and count). The lane
# settings are unset before the job starts, so a with_cpu call inside a GPU job still takes a CPU slot.
if [ "$SLOT_LANE" = gpu ]; then
  TOOL=with_gpu KIND=GPU LANE=gpu SLOTS_ENV=$LANE_SLOTS DIR=${LANE_DIR:-$SLOT_HOME/gpu-slots}
  MAX_WAIT=$(( ${LANE_MAX_WAIT_MIN:-90} * 60 ))
else
  TOOL=with_cpu KIND=CPU LANE=cpu SLOTS_ENV=$CPU_SLOTS DIR=${CPU_SLOT_DIR:-$SLOT_HOME/cpu-slots}
  MAX_WAIT=$(( ${CPU_MAX_WAIT_SEC:-$(( ${CPU_MAX_WAIT_MIN:-90} * 60 ))} ))
fi
unset SLOT_LANE LANE_SLOTS LANE_DIR LANE_MAX_WAIT_MIN
POLL0=${CPU_POLL_SEC:-2}
POLL_MAX=${CPU_POLL_MAX_SEC:-30}
AGE_EVERY=${CPU_AGE_CHECK_SEC:-60}   # folder-age checks fork find, so they run at most this often (and only on leftovers)
[ $# -ge 2 ] || { echo "usage: $TOOL.sh <session-name> <command...>   (or --status)" >&2; exit 2; }
owner="$1"; shift
# Nested calls (with_cpu.sh inside a CPU job would take a second CPU slot, and could deadlock): the job gets
# SLOT_LANES_HELD="<lane>:<slot>:<pid> ..." and a call inside it for a lane it already holds runs straight through, as a
# child (never exec: see with_gpu.sh). An entry counts only while that pid lives and still owns that slot. A call for
# the other lane still takes a slot there. SLOT_TAKE_EXTRA (set by with_gpu.sh --exclusive) asks for a second slot.
held_lane() {
  local e r s p k v
  for e in $SLOT_LANES_HELD; do
    [ "${e%%:*}" = "$LANE" ] || continue
    r=${e#*:}; s=${r%%:*}; p=${r#*:}
    kill -0 "$p" 2>/dev/null || continue
    while read -r k v; do [ "$k" = pid ] && [ "$v" = "$p" ] && return 0; done < "$DIR/$s/owner" 2>/dev/null
  done
  [ "$LANE" = gpu ] && [ -n "$IN_GPU_SLOT" ] && [ -z "$SLOT_LANES_HELD" ]   # job started by an older copy
}
if [ -z "$SLOT_TAKE_EXTRA" ] && held_lane; then "$@"; exit $?; fi
unset SLOT_TAKE_EXTRA
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
[ -d "$DIR" ] || mkdir -p "$DIR"

# Owner file text, built with builtins only (no fork between taking a slot and writing its owner).
owner_text() { local now ep; printf -v now '%(%T)T' -1; printf -v ep '%(%s)T' -1; printf '%s %s %s %s\npid %s\nstart %s\n' "$owner" "$now" "$PWD" "$*" "$$" "$ep"; }
# pid line of slot $1's owner file into $sp, without forking.
slot_pid() { local k v; sp=""; while read -r k v; do [ "$k" = pid ] && { sp=$v; return; }; done < "$1/owner" 2>/dev/null; }
older_than() { [ -n "$(find "$1" -maxdepth 0 -mmin +"$2" 2>/dev/null)" ]; }

# Take over slot $1 when it is an owner-less leftover older than a minute. The owner write is O_EXCL
# (noclobber), so only one waiter wins.
adopt() {
  local d="$DIR/$1"
  [ -d "$d" ] && [ ! -e "$d/owner" ] && older_than "$d" 1 || return 1
  ( set -C; owner_text "${@:2}" > "$d/owner" ) 2>/dev/null || return 1
  echo "$TOOL: took over leftover slot $1" >&2
}

# Free slot $1 if its holder is gone. The folder is renamed first (atomic, so only one waiter wins),
# then put back if it turns out to belong to someone else (a new holder took it in between).
reclaim() {
  local d="$DIR/$1" p stale
  [ -e "$d/owner" ] || return
  slot_pid "$d"; p=$sp
  if [ -n "$p" ]; then
    kill -0 "$p" 2>/dev/null && return
  else
    [ "$2" = age ] && older_than "$d" 40 || return
  fi
  stale="$DIR/.stale.$1.$$"
  mv "$d" "$stale" 2>/dev/null || return
  slot_pid "$stale"
  if [ "$sp" != "$p" ]; then
    mv -T "$stale" "$d" 2>/dev/null || rm -rf "$stale"
    return
  fi
  echo "$TOOL: reclaimed slot $1 ($(head -1 "$stale/owner" 2>/dev/null | cut -c1-80))" >&2
  rm -rf "$stale"
}

# Wake every waiter of this lane: one byte into each FIFO. Opening read-write never blocks, even when the waiter is
# gone (its FIFO is removed by the next live waiter's scan). Builtins only.
wake() {
  local f
  for f in "$DIR/.wait"/*; do [ -p "$f" ] && { printf x 1<>"$f"; } 2>/dev/null; done
}
# Release: retry, because Windows refuses to remove a folder while another process has it open. A folder
# still left behind has no owner file and is taken over by the next waiter after a minute (adopt).
cleanup() {
  local t
  [ -n "$slot" ] || return
  for t in 1 2 3 4 5; do
    rm -rf "$DIR/$slot" 2>/dev/null
    [ -e "$DIR/$slot" ] || break
    sleep 1
  done
  wake
}
on_exit() { [ -n "$wf" ] && rm -f "$wf" 2>/dev/null; cleanup; }

# GPU slots 3+ open only while the card has room: at least $GPU_EXTRA_MIN_FREE_MB (default 4096) MB of VRAM free
# (NVIDIA only; without nvidia-smi only slots 1-2 are used). nvidia-smi costs two forks, so its answer is kept for 30 s.
vram_at=-999 vram_ok=1
vram_room() {
  local f
  if [ $(( SECONDS - vram_at )) -ge 30 ]; then
    vram_at=$SECONDS vram_ok=1
    f=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null) || vram_ok=0
    f=${f%%[!0-9]*}
    [ -n "$f" ] && [ "$f" -ge "${GPU_EXTRA_MIN_FREE_MB:-4096}" ] || vram_ok=0
  fi
  [ $vram_ok = 1 ]
}
# Priority: $SLOT_LANES_HOME/slot-priority lists folder or session-name fragments, best first. A job matching line N
# has rank N (unlisted: 9999). Every waiter keeps a FIFO $DIR/.wait/<rank>.<pid>.<epoch>.<session> (p<rank>... while
# paused), and holds back while a live waiter with a better rank is waiting and not paused.
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
rank=$prio; [ $rank -eq 0 ] && rank=9999
match="${PWD,,} ${owner,,}"
wdir="$DIR/.wait"; wf=""; wfd=""
better_waiting() {   # is a live, unpaused waiter ranked above this job waiting?
  local f b r p
  for f in "$wdir"/*; do
    [ -e "$f" ] || continue
    b=${f##*/}; r=${b%%.*}; p=${b#*.}; p=${p%%.*}
    [[ "$r" =~ ^[0-9]+$ ]] || continue   # paused (p<rank>) or not a waiter file
    if kill -0 "$p" 2>/dev/null; then
      [ "$r" -lt $rank ] && return 0
    else
      rm -f "$f" 2>/dev/null   # that waiter is gone
    fi
  done
  return 1
}
# Sleep up to $1 s without forking; a releasing holder's byte ends it early.
nap() {
  if [ -n "$wfd" ]; then read -r -t "$1" -n 1 -u "$wfd" wk 2>/dev/null; else sleep "$1"; fi
}
slot=""
announced=0
start=$SECONDS
paused_secs=0 pause_since="" pause_shown=""
last_age=-$AGE_EVERY
poll=$POLL0
while [ -z "$slot" ]; do
  lane_cap $LANE "$SLOTS_ENV"
  paused_by $LANE "$match"
  if [ -n "$pause" ]; then
    [ -n "$pause_since" ] || pause_since=$SECONDS
    if [ "$pause_shown" != "$pause" ]; then echo "$TOOL: paused by $PAUSE_DIR/$pause; waiting (running jobs continue)"; pause_shown=$pause; fi
  elif [ -n "$pause_since" ]; then
    paused_secs=$(( paused_secs + SECONDS - pause_since )); pause_since=""; pause_shown=""
  fi
  # Waiter FIFO name follows the pause state (renames are rare: only when a pause starts or ends).
  if [ -n "$wf" ]; then
    want="$wdir/${pause:+p}$rank.$wbase"
    [ "$want" = "$wf" ] || { mv -f "$wf" "$want" 2>/dev/null && wf=$want; }
  fi
  if [ -z "$pause" ] && ! better_waiting; then
    age=""
    if [ $(( SECONDS - last_age )) -ge "$AGE_EVERY" ]; then age=age; last_age=$SECONDS; fi
    # One pass over the lane: live holders, dead holders (freed now), leftovers. Builtins only on the common path.
    running=0
    for d in "$DIR"/[0-9]*; do
      [ -d "$d" ] || continue
      i=${d##*/}; [[ "$i" =~ ^[0-9]+$ ]] || continue
      if [ -e "$d/owner" ]; then
        slot_pid "$d"
        if [ -n "$sp" ] && kill -0 "$sp" 2>/dev/null; then running=$((running + 1)); continue; fi
        [ -n "$sp" ] || [ -n "$age" ] && reclaim "$i" "$age"
        [ -d "$d" ] && running=$((running + 1))
      elif [ -n "$age" ] && [ $i -le $cap ] && [ $running -lt $cap ] && adopt "$i" "$@"; then
        slot=$i; trap on_exit EXIT; break
      elif [ $i -le $cap ]; then
        running=$((running + 1))   # just taken (owner not yet written) or a leftover younger than a minute
      fi
    done
    if [ -z "$slot" ] && [ $running -lt $cap ]; then
      for (( i = 1; i <= cap; i++ )); do
        [ -d "$DIR/$i" ] && continue
        if [ "$KIND" = GPU ] && [ $i -gt 2 ] && ! vram_room; then continue; fi
        if mkdir "$DIR/$i" 2>/dev/null; then slot=$i; trap on_exit EXIT; break; fi
      done
    fi
  fi
  [ -n "$slot" ] && break
  if [ -z "$wf" ]; then
    [ -d "$wdir" ] || mkdir -p "$wdir" 2>/dev/null
    printf -v wbase '%s.%(%s)T.%s' "$$" -1 "${owner//[^A-Za-z0-9_-]/_}"
    wf="$wdir/${pause:+p}$rank.$wbase"
    if mkfifo "$wf" 2>/dev/null; then exec {wfd}<>"$wf"; else : > "$wf"; fi
    trap on_exit EXIT
  fi
  waited=$(( SECONDS - start - paused_secs ))
  [ -n "$pause_since" ] && waited=$(( waited - (SECONDS - pause_since) ))
  if [ $waited -ge "$MAX_WAIT" ]; then
    echo "$TOOL: gave up after $(( waited / 60 )) min without a $KIND slot; nothing ran: $*" >&2
    echo "$TOOL: holders: $(head -qn1 "$DIR"/*/owner 2>/dev/null | cut -c1-60 | tr '\n' ';')" >&2
    exit 75
  fi
  [ $announced -eq 0 ] && [ -z "$pause" ] && echo "$TOOL: waiting for a $KIND slot ($(head -qn1 "$DIR"/*/owner 2>/dev/null | tr '\n' ';'))" && announced=1
  nap "$poll"
  poll=$(( poll * 2 )); [ $poll -gt "$POLL_MAX" ] && poll=$POLL_MAX
done
owner_text "$@" > "$DIR/$slot/owner"
if [ -n "$wf" ]; then
  [ -n "$wfd" ] && exec {wfd}>&-
  rm -f "$wf" 2>/dev/null; wf=""
fi
printf '%(%F %T)T start %s %s waited=%ss\n' -1 "${KIND,,}" "$owner" "$(( SECONDS - start ))" >> "$LANE_LOG" 2>/dev/null   # wait times, for tuning slot counts

[ "$KIND" = GPU ] && export IN_GPU_SLOT=1   # for copies older than SLOT_LANES_HELD
export SLOT_LANES_HELD="${SLOT_LANES_HELD:+$SLOT_LANES_HELD }$LANE:$slot:$$"   # nested calls of this lane share the slot
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
# Below-normal priority for CPU-lane jobs, re-applied to late children after 1, 6, 26 and 86 s. One PowerShell does all
# five passes (instead of five PowerShell starts per job).
if [ "$KIND" = CPU ] && [ -n "$winpid" ]; then
  powershell.exe -NoProfile -Command "
    function Low(\$id) { try { (Get-Process -Id \$id -ErrorAction Stop).PriorityClass = 'BelowNormal' } catch {}
      Get-CimInstance Win32_Process -Filter \"ParentProcessId=\$id\" | ForEach-Object { Low \$_.ProcessId } }
    foreach (\$t in 0, 1, 5, 20, 60) { Start-Sleep -Seconds \$t; if (-not (Get-Process -Id $winpid -ErrorAction SilentlyContinue)) { break }; Low $winpid }" >/dev/null 2>&1 &
  watcher=$!
fi
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
[ -n "$watcher" ] && kill $watcher 2>/dev/null
exit $code
