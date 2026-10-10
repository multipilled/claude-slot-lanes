#!/usr/bin/env bash
# Who holds which slot and lock, as a table: CPU and GPU slot holders, ranked waiters, pauses and project locks.
#   slot_status.sh            table for people
#   slot_status.sh --json     the same as `with_cpu.sh --status` (one line of JSON)
exec bash "$(dirname "${BASH_SOURCE[0]}")/with_cpu.sh" "$([ "$1" = --json ] && echo --status || echo --table)"
