# Game guard: with_cpu.sh starts one per GPU-lane job (game/engine runs, Blender, emulators, AI tools) on Windows, so
# background jobs never steal the user's mouse, keyboard or focus, and never leave windows open.
#  - Every 150 ms: if the foreground window belongs to the job's process tree, minimize it without activating
#    anything (SW_SHOWMINNOACTIVE) and release any cursor clip, so the user keeps their mouse and keyboard. The job's
#    top-level windows are also kept at the bottom of the Z order. On the 3rd strike the job's tree is closed.
#  - When the job ends: every process it started that is still running (game, editor, dialogs, helpers) is closed.
# Only processes in the job's own tree (descendants of -JobPid) are ever touched, matched by PID AND creation time:
# Windows reuses PIDs fast, and a cleanup matched by PID alone can close an unrelated, live game whose processes
# inherited PIDs of the job's exited helpers. Log: -Log (default %USERPROFILE%\.claude\game-guard.log).
# Never closed: Claude and MCP servers, plus anything matching $env:GAME_GUARD_SPARE (a regex on "name commandline").
param([Parameter(Mandatory=$true)][int]$JobPid, [string]$Owner = "job", [string]$Marker = "", [string]$RunFile = "", [int]$HolderPid = 0, [string]$Log = "")
$ErrorActionPreference = "SilentlyContinue"
Add-Type -Namespace GG -Name U -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool ClipCursor(IntPtr r);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
public delegate bool EnumProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
'@
$log = if ($Log) { $Log } else { Join-Path $env:USERPROFILE ".claude\game-guard.log" }
$spare = '(?i)^claude\.exe|^bridge-mcp|\bmcp\b|mcp[-_]server|modelcontextprotocol'
if ($env:GAME_GUARD_SPARE) { $spare += "|" + $env:GAME_GUARD_SPARE }
function Log($m) { Add-Content -Path $log -Value ("{0} {1} {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Owner, $m) }
$start = Get-Date
# pid -> creation time of the process that held that pid when it joined the job (a reused pid is a different process)
$tree = @{}
$root = Get-CimInstance Win32_Process -Filter "ProcessId=$JobPid" -Property CreationDate
$tree[$JobPid] = $(if ($root) { $root.CreationDate } else { $start.AddSeconds(-30) })
$seen = @{}   # pid -> @{ Name; Created } for every descendant, the only processes ever closed
# WMI launches (Win32_Process.Create, used to start games detached) are children of WmiPrvSE.exe, not of the job.
# Processes WMI starts while this job runs, and their children, are watched too: minimized and
# cursor released if they take the foreground. They are never closed by this guard, since another job may own them.
$wmi = @{}
function Refresh {
  $all = Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,Name,CreationDate
  $names = @{}; $live = @{}
  foreach ($p in $all) { $names[[int]$p.ProcessId] = $p.Name; $live[[int]$p.ProcessId] = $p.CreationDate }
  foreach ($p in $all) {
    $id = [int]$p.ProcessId; $pp = [int]$p.ParentProcessId
    if ($wmi.ContainsKey($id) -or $tree.ContainsKey($id) -or $p.CreationDate -lt $start.AddSeconds(-30)) { continue }
    if ($names[$pp] -eq 'WmiPrvSE.exe' -or $wmi.ContainsKey($pp)) {
      $wmi[$id] = $true; Log ("watching WMI-launched {0} (pid {1})" -f $p.Name, $id)
    }
  }
  $changed = $true
  while ($changed) {
    $changed = $false
    foreach ($p in $all) {
      $id = [int]$p.ProcessId; $pp = [int]$p.ParentProcessId
      if ($tree.ContainsKey($id) -or -not $tree.ContainsKey($pp) -or $p.CreationDate -lt $start.AddSeconds(-30)) { continue }
      # The parent must be the same process that joined the tree: born before the child, and its pid not since
      # taken by a newer process that this child belongs to.
      $pc = $tree[$pp]
      if ($p.CreationDate -lt $pc) { continue }
      if ($live.ContainsKey($pp) -and $live[$pp] -ne $pc -and $p.CreationDate -ge $live[$pp]) { continue }
      $tree[$id] = $p.CreationDate; $seen[$id] = @{ Name = $p.Name; Created = $p.CreationDate }; $changed = $true
    }
  }
}
# Close the job's own processes that are still running: a pid now held by a different (reused) process is skipped.
function StopOwn {
  $now = @{}; $cmd = @{}
  foreach ($p in (Get-CimInstance Win32_Process -Property ProcessId,CreationDate,Name,CommandLine)) {
    $now[[int]$p.ProcessId] = $p.CreationDate; $cmd[[int]$p.ProcessId] = "$($p.Name) $($p.CommandLine)"
  }
  $closed = @(); $reused = 0; $spared = @()
  foreach ($id in @($seen.Keys)) {
    if (-not $now.ContainsKey($id)) { continue }
    if ($now[$id] -ne $seen[$id].Created) { $reused++; continue }
    # Safety net: never close Claude, an MCP server (they can be launched from inside a job) or a spared process.
    if ($cmd[$id] -match $spare) { $spared += $seen[$id].Name; continue }
    Stop-Process -Id $id -Force; $closed += $id
  }
  if ($reused -gt 0) { Log "left $reused reused pid(s) alone (now other processes)" }
  if ($spared.Count -gt 0) { Log ("spared {0} Claude/MCP process(es): {1}" -f $spared.Count, ($spared -join ", ")) }
  return ,$closed
}
function KillTree($why) {
  [void](StopOwn)
  Stop-Process -Id $JobPid -Force
  Log "closed the job's processes: $why"
  if ($Marker) { Set-Content -Path $Marker -Value $why }
}
# The job runs while its first process lives, or (Git Bash exec gives the job a new Windows PID) while with_cpu.sh, the
# -HolderPid, still keeps -RunFile: it deletes the file only when its own wait for the job returns.
function JobAlive {
  if (Get-Process -Id $JobPid) { return $true }
  return [bool]($RunFile -and $HolderPid -gt 0 -and (Test-Path -LiteralPath $RunFile) -and (Get-Process -Id $HolderPid))
}
$strikes = 0; $tick = 0
$bottom = [IntPtr]1; $flags = [uint32]0x0013   # HWND_BOTTOM; SWP_NOSIZE|SWP_NOMOVE|SWP_NOACTIVATE
Refresh
while (JobAlive) {
  if ($tick % 13 -eq 0) { Refresh }   # about every 2 s
  $fg = [GG.U]::GetForegroundWindow(); $fp = [uint32]0
  [void][GG.U]::GetWindowThreadProcessId($fg, [ref]$fp)
  if ($fg -ne [IntPtr]::Zero -and $wmi.ContainsKey([int]$fp)) {
    [void][GG.U]::ShowWindowAsync($fg, 7); [void][GG.U]::ClipCursor([IntPtr]::Zero)
    Log ("WMI-launched pid {0} took the foreground: minimized, cursor released" -f $fp)
    Start-Sleep -Milliseconds 400
  }
  if ($fg -ne [IntPtr]::Zero -and $tree.ContainsKey([int]$fp)) {
    [void][GG.U]::ShowWindowAsync($fg, 7)      # SW_SHOWMINNOACTIVE
    [void][GG.U]::ClipCursor([IntPtr]::Zero)   # give the mouse back
    $strikes++
    Log ("took the foreground (pid {0}, strike {1}): minimized, cursor released" -f $fp, $strikes)
    if ($strikes -ge 3) { KillTree "its window took the foreground 3 times"; break }
    Start-Sleep -Milliseconds 400
  }
  if ($tick % 7 -eq 0) {
    $cb = [GG.U+EnumProc]{ param($h, $l)
      $wp = [uint32]0; [void][GG.U]::GetWindowThreadProcessId($h, [ref]$wp)
      if (($tree.ContainsKey([int]$wp) -or $wmi.ContainsKey([int]$wp)) -and [GG.U]::IsWindowVisible($h)) { [void][GG.U]::SetWindowPos($h, $bottom, 0, 0, 0, 0, $flags) }
      return $true }
    [void][GG.U]::EnumWindows($cb, [IntPtr]::Zero)
  }
  $tick++
  Start-Sleep -Milliseconds 150
}
# Job finished: close everything it started that is still open.
Refresh
$left = StopOwn
if ($left.Count -gt 0) {
  $names = ($left | ForEach-Object { $seen[$_].Name }) -join ", "
  Log "job ended; closed $($left.Count) leftover process(es): $names"
}
