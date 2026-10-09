# claude-slot-lanes

Keep one PC usable while many AI coding agent sessions (Claude Code or any other) build, test and run games on it at
the same time.

**Status: stable, 1.0.** In daily use on a machine running a dozen agent sessions at once; all tests pass.

## The problem

Run five or ten agent sessions on one machine and they all decide to compile, render or launch a game at once. The
desktop freezes, builds time out, two sessions launch the same game and fight over its save folder, a game window
grabs your mouse in the middle of your own work, and when a session dies its lock or its game window stays behind.

These four small scripts fix that with plain folders and PIDs. No daemon and no service: every job just goes through a
wrapper.

| Script | What it does |
|---|---|
| `with_cpu.sh` | CPU lane. A machine-wide pool of slots (default 4). Heavy jobs wait for a slot and run at below-normal priority, so the desktop stays responsive. |
| `with_gpu.sh` | GPU lane. Its own pool (default 3; the 3rd opens only with 4 GB of VRAM free) for game and engine runs, Blender, emulators and AI models. `--exclusive` takes the whole card. |
| `with_lock.sh` | Per-project lock shared by every session and git worktree of the project, so only one job at a time runs the game or writes a shared build output. |
| `game_guard.ps1` | Windows game guard for GPU-lane jobs: the job's windows can never take your foreground, keyboard or cursor (minimized without activating; the 3rd strike closes the job), and whatever the job left open is closed when it ends. |

What makes it robust on a busy machine:
- **Auto-routing.** Send everything to `with_cpu.sh`; jobs that run a GPU tool (Godot, Blender, emulators, upscalers,
  ...) move to the GPU lane by themselves. The wrapper also reads the first 400 lines of a script the job runs. Compiles
  always stay CPU. Add your own patterns in `gpu-patterns` / `cpu-patterns`, or force a lane with `WITH_LANE=cpu|gpu`.
- **PID-safe slots and locks.** A slot or lock remembers its holder's PID: a dead holder's slot is freed at once, a live
  one is never stolen however long it runs. Stale locks are renamed away before they are deleted, so two waiters can
  never delete each other's fresh lock. The game guard matches processes by PID *and* creation time, so a reused PID
  never gets an unrelated program closed.
- **Ranked priority.** List folder or session-name fragments in `slot-priority`, best first: ranked jobs take free slots
  before lower-ranked and unlisted ones. No file: first come, first served.
- **Lock before slot.** `with_cpu.sh me tools/with_lock.sh me <cmd>` takes the project lock first, so no job sits on a
  scarce slot while it waits for a lock.
- **Clean failures.** Exit 75: no slot within 90 minutes, nothing ran. 76: the game guard closed the job. 77: less than
  2 GB free on the drive, nothing ran. 2: bad usage (including a script piped on stdin, which would hang).
- **Fork-light waiting.** Waiters poll with shell builtins, because Git Bash's `fork` fails under heavy load when dozens
  of waiters poll at once.

## Install

Requirements: bash 4.2+ (Git Bash on Windows, or Linux). The game guard and the priority lowering need Windows
(PowerShell 5.1); elsewhere they are skipped and the lanes and locks work the same. VRAM checks use `nvidia-smi` if it
is there.

```bash
git clone https://github.com/multipilled/claude-slot-lanes
mkdir -p ~/.claude/bin && cp claude-slot-lanes/bin/* ~/.claude/bin/
cp claude-slot-lanes/examples/slot-priority ~/.claude/slot-priority   # optional
```

In each project, add `tools/with_lock.sh` from `examples/project-with_lock.sh`, and tell the agents to use the lanes:
paste `examples/CLAUDE.md.snippet` into the project's `CLAUDE.md` (or your agent's instructions file).

## Use

```bash
~/.claude/bin/with_cpu.sh my-session cargo build --release
~/.claude/bin/with_gpu.sh my-session tools/with_lock.sh my-session ./run_game_test.sh
~/.claude/bin/with_gpu.sh --exclusive my-session python big_model.py
```

The session name shows up in every slot's owner file and in the logs, so you can see who holds what:
`head -n1 ~/.claude/cpu-slots/*/owner ~/.claude/gpu-slots/*/owner`.

## Settings

| Variable | Default | Meaning |
|---|---|---|
| `SLOT_LANES_HOME` | `~/.claude` | State folder: slots, `slot-priority`, `gpu-patterns`, `cpu-patterns`, `slot-lanes.log`, `game-guard.log` |
| `CPU_SLOTS` / `GPU_SLOTS` | 4 / 3 | Slots per lane |
| `CPU_MAX_WAIT_MIN` / `GPU_MAX_WAIT_MIN` | 90 | Minutes to wait before giving up (exit 75) |
| `GPU_EXTRA_MIN_FREE_MB` | 4096 | Free VRAM needed before GPU slot 3+ opens |
| `SLOT_MIN_FREE_GB` | 2 | Free disk needed to start a job (exit 77) |
| `WITH_LANE` | auto | `cpu` or `gpu` forces the lane for one job |
| `GAME_GUARD` | on | `off` skips the guard (for a run you want to play yourself) |
| `GAME_GUARD_SPARE` | | Extra regex of processes the guard must never close |
| `WITH_LOCK_ROOT`, `LOCK_NAME` | | Lock folder (set by the project wrapper) and lock name (default `game`) |

`slot-lanes.log` records every routing decision and every wait time, which is how you tune slot counts and patterns.

## Tests

`bash tests/run_all.sh` runs everything in temp folders, never touching your live slots: routing, locks (no overlap,
stale lock takeover), priority order, `--exclusive`, and on Windows the game guard.

## Editing the scripts

Bash reads a running script lazily, so editing one in place garbles every waiter already running it. Write a new copy
and `mv` it over.

## License

MIT, see `LICENSE`. Not affiliated with Anthropic.
