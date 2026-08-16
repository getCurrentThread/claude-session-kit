<#
.SYNOPSIS
  Registers an automatic Claude Code session resume for the next logon, then reboots Windows.

.DESCRIPTION
  Part of the "reboot-continue" Claude Code skill.

  Saves resume state (working directory, session id, continuation prompt) to
  %USERPROFILE%\.claude\reboot-continue\state.json, registers a one-shot RunOnce
  entry that relaunches Claude Code at the next logon, and (unless -NoReboot)
  schedules a reboot.

  Session id resolution order:
    1. -SessionId parameter
    2. CLAUDE_SESSION_ID environment variable
    3. Newest *.jsonl transcript in ~\.claude\projects\<munged-workdir>\
       (while a session is live, its transcript is the most recently written file)
    4. None -> the resume script falls back to `claude --continue`

.PARAMETER PromptFile
  Path to a UTF-8 text file containing the continuation prompt. Preferred over
  -Prompt for non-ASCII (e.g. Korean) text to avoid console codepage issues.

.PARAMETER Cancel
  Aborts a pending reboot, removes the RunOnce entry and the state file.

.PARAMETER NoReboot
  Register everything but do not reboot; resume fires at the next logon
  after the user reboots manually.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File request-reboot.ps1 -PromptFile next-prompt.txt -WorkDir C:\work\proj -DelaySeconds 30
#>
[CmdletBinding()]
param(
  [string]$Prompt = "",
  [string]$PromptFile = "",
  [string]$SessionId = "",
  [string]$WorkDir = "",
  [int]$DelaySeconds = 30,
  [switch]$NoReboot,
  [switch]$Cancel,
  [switch]$Status
)

$ErrorActionPreference = 'Stop'

$stateDir   = Join-Path $env:USERPROFILE '.claude\reboot-continue'
$stateFile  = Join-Path $stateDir 'state.json'
$runOnceKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
$valueName  = 'ClaudeRebootContinue'

if ($Status) {
  $entry = (Get-ItemProperty -Path $runOnceKey -ErrorAction SilentlyContinue).$valueName
  if ($entry) { Write-Host "RunOnce : $entry" } else { Write-Host "RunOnce : (not registered)" }
  if (Test-Path $stateFile) {
    Write-Host "State   : $stateFile"
    Get-Content $stateFile -Raw | Write-Host
  } else {
    Write-Host "State   : (none)"
  }
  exit 0
}

if ($Cancel) {
  cmd /c "shutdown /a >nul 2>&1"
  try { Remove-ItemProperty -Path $runOnceKey -Name $valueName -ErrorAction Stop } catch {}
  if (Test-Path $stateFile) { Remove-Item $stateFile -Force }
  Write-Host "[reboot-continue] Cancelled: pending reboot aborted (if any), RunOnce entry and state removed."
  exit 0
}

# --- Resolve working directory ---------------------------------------------
if (-not $WorkDir) { $WorkDir = (Get-Location).Path }
$WorkDir = (Resolve-Path -Path $WorkDir).Path

# --- Resolve continuation prompt -------------------------------------------
if ($PromptFile) {
  $Prompt = (Get-Content -Path $PromptFile -Raw -Encoding UTF8).Trim()
}
if (-not $Prompt) {
  $Prompt = "The machine has been rebooted as planned. Read the notes left before the reboot and continue the task from where we left off."
}

# --- Resolve session id -----------------------------------------------------
if (-not $SessionId -and $env:CLAUDE_SESSION_ID) { $SessionId = $env:CLAUDE_SESSION_ID }
if (-not $SessionId) {
  $munged  = ($WorkDir -replace '[^A-Za-z0-9]', '-')
  $projDir = Join-Path $env:USERPROFILE (Join-Path '.claude\projects' $munged)
  if (Test-Path $projDir) {
    $newest = Get-ChildItem -Path $projDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($newest) { $SessionId = [IO.Path]::GetFileNameWithoutExtension($newest.Name) }
  }
}

# --- Save state --------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
[ordered]@{
  session_id = $SessionId
  workdir    = $WorkDir
  prompt     = $Prompt
  created_at = (Get-Date).ToString('o')
} | ConvertTo-Json | Out-File -FilePath $stateFile -Encoding utf8

# --- Register RunOnce --------------------------------------------------------
$resumeScript = Join-Path $PSScriptRoot 'resume-after-reboot.ps1'
if (-not (Test-Path $resumeScript)) { throw "resume-after-reboot.ps1 not found next to this script." }
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$inner = "`"$psExe`" -NoProfile -ExecutionPolicy Bypass -File `"$resumeScript`""

$wt = Get-Command wt.exe -ErrorAction SilentlyContinue
if ($wt) {
  $runCmd = "`"$($wt.Source)`" -d `"$WorkDir`" $inner"
} else {
  $runCmd = $inner
}
Set-ItemProperty -Path $runOnceKey -Name $valueName -Value $runCmd -Type String

Write-Host "[reboot-continue] State saved  : $stateFile"
if ($SessionId) {
  Write-Host "[reboot-continue] Session      : $SessionId (claude --resume)"
} else {
  Write-Host "[reboot-continue] Session      : unknown -> will use claude --continue"
}
Write-Host "[reboot-continue] RunOnce      : $runCmd"

# --- Reboot ------------------------------------------------------------------
if ($NoReboot) {
  Write-Host "[reboot-continue] -NoReboot given: reboot NOT scheduled."
  Write-Host "[reboot-continue] Resume will fire at the next logon after you reboot manually."
} else {
  shutdown.exe /r /t $DelaySeconds /c "Claude Code reboot-continue: rebooting in $DelaySeconds seconds. Run 'shutdown /a' to abort."
  Write-Host "[reboot-continue] Reboot in $DelaySeconds seconds. Abort: shutdown /a  (or rerun with -Cancel)"
}
