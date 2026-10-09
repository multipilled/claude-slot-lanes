#!/usr/bin/env bash
# Runs every test in isolated temp folders (never touches your live slots). About a minute.
cd "$(dirname "$0")"; rc=0
for t in route_test.sh lock_test.sh prio_test.sh excl_test.sh; do bash "$t" || rc=1; done
if command -v powershell.exe >/dev/null; then powershell.exe -NoProfile -ExecutionPolicy Bypass -File guard_test.ps1 || rc=1; fi
exit $rc
