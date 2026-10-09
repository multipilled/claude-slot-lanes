#!/usr/bin/env bash
# forkrate.sh <with_cpu.sh> <seconds> [lane]: runs one waiter against full slots in an isolated HOME and counts the
# processes it creates: subshells (new $BASHPID in the xtrace) + external commands (each forks a child).
# strace -f segfaults under Git Bash, so the count comes from bash's own trace.
W="$1"; S="${2:-60}"; L="${3:-cpu}"; T=$(mktemp -d)
mkdir -p "$T/.claude"
sleep 900 & holder=$!
for i in 1 2 3 4; do mkdir -p "$T/.claude/cpu-slots/$i"; printf 'holder 00:00:00 / sleep\npid %s\n' "$holder" > "$T/.claude/cpu-slots/$i/owner"; done
for i in 1 2 3; do mkdir -p "$T/.claude/gpu-slots/$i"; printf 'holder 00:00:00 / sleep\npid %s\n' "$holder" > "$T/.claude/gpu-slots/$i/owner"; done
cd "$T"
HOME="$T" SLOT_LANES_HOME="$T/.claude" WITH_LANE=$L GAME_GUARD=off PS4='+${BASHPID}| ' timeout "$S" bash -x "$W" probe true >/dev/null 2>"$T/tr.log"
main=$(grep -m1 -oE '^\++[0-9]+' "$T/tr.log" | tr -d +)
sub=$(grep -oE '^\++[0-9]+' "$T/tr.log" | tr -d + | sort -u | grep -vc "^$main\$")
ext=0; declare -A seen
while IFS= read -r c; do
  [ -n "${seen[$c]}" ] || { [ "$(type -t "$c")" = file ] && seen[$c]=1 || seen[$c]=0; }
  [ "${seen[$c]}" = 1 ] && ext=$((ext + 1))
done < <(sed -nE 's/^\++[0-9]+\| ([^ =]+)( .*)?$/\1/p' "$T/tr.log")
n=$((sub + ext))
kill $holder
echo "lane=$L ${S}s subshells=$sub externals=$ext total=$n per_min=$(( n * 60 / S ))"
sed -nE 's/^\++[0-9]+\| ([^ =]+)( .*)?$/\1/p' "$T/tr.log" | sort | uniq -c | sort -rn | head -8 | tr '\n' ' '; echo
[ -n "$KEEP" ] && cp "$T/tr.log" "$KEEP"; rm -rf "$T"
