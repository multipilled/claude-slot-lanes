# game_guard.ps1 (Windows): a job's leftover child is closed when the job ends; an unrelated process started during the
# job survives.   powershell -ExecutionPolicy Bypass -File tests\guard_test.ps1
$bin = if ($env:SLOT_BIN) { $env:SLOT_BIN } elseif (Test-Path (Join-Path $PSScriptRoot "..\bin")) { Join-Path $PSScriptRoot "..\bin" } else { Join-Path $PSScriptRoot ".." }
$guard = Join-Path $bin "game_guard.ps1"
$log = Join-Path $env:TEMP ("guard_test_{0}.log" -f $PID)
$errs = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($guard, [ref]$null, [ref]$errs)
$victim = Start-Process ping -ArgumentList '-n','40','127.0.0.1' -WindowStyle Hidden -PassThru
$job = Start-Process powershell -ArgumentList '-NoProfile','-Command',"Start-Process ping -ArgumentList '-n','40','127.0.0.1' -WindowStyle Hidden; Start-Sleep 5" -WindowStyle Hidden -PassThru
$g = Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$guard,'-JobPid',$job.Id,'-Owner','guardtest','-Log',$log -WindowStyle Hidden -PassThru
[void]$g.WaitForExit(40000)
$alive = [bool](Get-Process -Id $victim.Id -ErrorAction SilentlyContinue)
$closed = [bool](Select-String -Path $log -Pattern 'job ended; closed .*PING' -Quiet -ErrorAction SilentlyContinue)
Stop-Process -Id $victim.Id -Force -ErrorAction SilentlyContinue
if (-not $g.HasExited) { Stop-Process -Id $g.Id -Force -ErrorAction SilentlyContinue }
Remove-Item $log -ErrorAction SilentlyContinue
if ($errs.Count -eq 0 -and $g.HasExited -and $alive -and $closed) { "PASS guard" } else {
  "FAIL guard: parse errors $($errs.Count), guard exited $($g.HasExited), unrelated alive $alive, leftover closed $closed"; exit 1 }
