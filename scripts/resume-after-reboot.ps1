<#
.SYNOPSIS
  Relaunches Claude Code after a reboot and resumes the saved session.

.DESCRIPTION
  Part of the "reboot-continue" Claude Code skill.

  Executed once at logon via the RunOnce entry registered by request-reboot.ps1
  (inside a Windows Terminal window when available). Reads
  %USERPROFILE%\.claude\reboot-continue\state.json, changes to the saved working
  directory and runs `claude --resume <id> "<prompt>"` (or `claude --continue`
  when no session id was recorded).

.PARAMETER DryRun
  Print the resolved command without launching Claude and keep the state file.
#>
[CmdletBinding()]
param(
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$stateDir  = Join-Path $env:USERPROFILE '.claude\reboot-continue'
$stateFile = Join-Path $stateDir 'state.json'
$logFile   = Join-Path $stateDir 'resume.log'

function Write-Log([string]$msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  Write-Host $line
  try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch {}
}

Write-Log "resume-after-reboot started (DryRun=$([bool]$DryRun))"

if (-not (Test-Path $stateFile)) {
  Write-Log "No state file at $stateFile - nothing to resume."
  if (-not $DryRun) { Read-Host "Press Enter to close" | Out-Null }
  exit 1
}

$state     = Get-Content -Path $stateFile -Raw | ConvertFrom-Json
$workdir   = $state.workdir
$sessionId = $state.session_id
$prompt    = $state.prompt

if ($workdir -and (Test-Path $workdir)) {
  Set-Location -Path $workdir
} else {
  Write-Log "WARN: saved workdir '$workdir' not found; staying in $((Get-Location).Path)"
}

# --- Resolve claude binary ---------------------------------------------------
$claude = $null
$cmdInfo = Get-Command claude -ErrorAction SilentlyContinue
if ($cmdInfo) { $claude = $cmdInfo.Source }
if (-not $claude) {
  $candidates = @(
    (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
    (Join-Path $env:APPDATA 'npm\claude.cmd')
  )
  foreach ($cand in $candidates) {
    if (Test-Path $cand) { $claude = $cand; break }
  }
}
if (-not $claude) {
  Write-Log "ERROR: claude binary not found (PATH and known install locations)."
  if (-not $DryRun) { Read-Host "Press Enter to close" | Out-Null }
  exit 1
}

if ($sessionId) {
  $claudeArgs = @('--resume', $sessionId, $prompt)
  $sessionDesc = $sessionId
} else {
  $claudeArgs = @('--continue', $prompt)
  $sessionDesc = '(latest session in workdir via --continue)'
}

Write-Log "workdir : $((Get-Location).Path)"
Write-Log "session : $sessionDesc"
Write-Log "command : `"$claude`" $($claudeArgs -join ' ')"

if ($DryRun) {
  Write-Log "DryRun: not launching. State file left in place."
  exit 0
}

# Archive state first so a crashing relaunch can never loop.
Move-Item -Path $stateFile -Destination (Join-Path $stateDir 'state.last.json') -Force

Start-Sleep -Seconds 3
& $claude @claudeArgs
$code = $LASTEXITCODE
Write-Log "claude exited with code $code"
Read-Host "Press Enter to close" | Out-Null
