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
    3. Newest *.jsonl transcript in ~\.claude\projects\<munged-workdir>\ that was
       written by an INTERACTIVE session (entrypoint "cli") and whose recorded cwd
       matches -WorkDir. Scheduled/SDK transcripts (entrypoint "sdk-cli") live in
       the same folder and are often the newest file there; they are never chosen.
    4. None -> the resume script starts a FRESH session carrying the prompt
       (`claude --continue` is not used: it would reopen whatever conversation was
       most recent, including an automation's.)

.PARAMETER PromptFile
  Path to a UTF-8 text file containing the continuation prompt. Preferred over
  -Prompt for non-ASCII (e.g. Korean) text to avoid console codepage issues.

.PARAMETER Cancel
  Aborts a pending reboot, removes the RunOnce entry and the state file.

.PARAMETER NoReboot
  Register everything but do not reboot; resume fires at the next logon
  after the user reboots manually.

.PARAMETER DryRun
  Resolve the working directory, prompt, session id and the exact RunOnce command
  line, print them, and exit. Nothing is written to disk or the registry and no
  reboot is scheduled. Use this to inspect what WOULD be registered.

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
  [switch]$Status,
  [switch]$DryRun
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

# --- Transcript inspection ---------------------------------------------------
# Only an interactive CLI session may be resumed. Scheduled/SDK runs write their
# transcripts into the SAME project folder with entrypoint "sdk-cli", and they are
# frequently the most recently written file there -- so "newest transcript wins"
# silently resumes an automation's conversation and appends this session to it.
#
# This is an allowlist, not a denylist: a transcript whose entrypoint cannot be
# read is skipped rather than assumed safe. The recorded cwd must also match the
# working directory, because the project folder name is a lossy munge and two
# different paths can land in the same folder.
function Get-TranscriptKind {
  param(
    [Parameter(Mandatory)][string]$Path,
    [int]$HeadLines = 200
  )

  $entrypoint = $null
  $cwd        = $null
  $sessionId  = $null
  try {
    foreach ($line in (Get-Content -LiteralPath $Path -TotalCount $HeadLines -ErrorAction Stop)) {
      if (-not $entrypoint -and $line -match '"entrypoint"\s*:\s*"([^"]+)"') { $entrypoint = $Matches[1] }
      if (-not $cwd        -and $line -match '"cwd"\s*:\s*"([^"]+)"')        { $cwd        = $Matches[1] -replace '\\\\', '\' }
      if (-not $sessionId  -and $line -match '"sessionId"\s*:\s*"([^"]+)"')  { $sessionId  = $Matches[1] }
      if ($entrypoint -and $cwd) { break }
    }
  } catch {
    return [pscustomobject]@{ Kind = 'unreadable'; Cwd = $null }
  }

  # Known-good: an interactive CLI conversation.
  if ($entrypoint -eq 'cli') { return [pscustomobject]@{ Kind = 'interactive'; Cwd = $cwd } }

  # Any OTHER entrypoint ("sdk-cli" today, whatever ships tomorrow) is automation.
  # Treated as a positive rejection rather than an unknown, so a new entrypoint
  # value can never quietly become a resume candidate.
  if ($entrypoint) { return [pscustomobject]@{ Kind = 'automated'; Cwd = $cwd } }

  # A live session writes a small metadata sidecar (last-prompt / ai-title / mode /
  # permission-mode ...) keyed by sessionId, while its conversation is still being
  # buffered -- so no entrypoint and no cwd have been recorded yet. This is the
  # normal shape of the session that is asking for the reboot, and rejecting it
  # would break the skill's main path. Identified positively, not by absence.
  if ($sessionId -and -not $cwd -and -not $entrypoint) {
    return [pscustomobject]@{ Kind = 'sidecar'; Cwd = $null }
  }

  return [pscustomobject]@{ Kind = 'unknown'; Cwd = $cwd }
}

function Test-CwdMatches {
  param([string]$Recorded, [Parameter(Mandatory)][string]$Expected)
  if (-not $Recorded) { return $true }   # nothing recorded yet: fall back to the project folder
  try {
    return ([IO.Path]::GetFullPath($Recorded).TrimEnd('\') -ieq [IO.Path]::GetFullPath($Expected).TrimEnd('\'))
  } catch { return $false }
}

# --- Resolve session id -----------------------------------------------------
if (-not $SessionId -and $env:CLAUDE_SESSION_ID) { $SessionId = $env:CLAUDE_SESSION_ID }
if (-not $SessionId) {
  $munged  = ($WorkDir -replace '[^A-Za-z0-9]', '-')
  $projDir = Join-Path $env:USERPROFILE (Join-Path '.claude\projects' $munged)
  if (Test-Path -LiteralPath $projDir) {
    $candidates = Get-ChildItem -LiteralPath $projDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending
    foreach ($candidate in $candidates) {
      $info = Get-TranscriptKind -Path $candidate.FullName
      if ($info.Kind -ne 'interactive' -and $info.Kind -ne 'sidecar') { continue }
      if (-not (Test-CwdMatches -Recorded $info.Cwd -Expected $WorkDir)) { continue }
      $SessionId     = [IO.Path]::GetFileNameWithoutExtension($candidate.Name)
      $SessionSource = $info.Kind
      break
    }
  }
}

# --- Build the RunOnce command line ------------------------------------------
$resumeScript = Join-Path $PSScriptRoot 'resume-after-reboot.ps1'
if (-not (Test-Path $resumeScript)) { throw "resume-after-reboot.ps1 not found next to this script." }
# Pick the PowerShell host for the RunOnce entry. This path is written into the
# registry now and executed at the NEXT logon, so it must stay valid across
# updates: `Get-Command pwsh.exe` resolves to the versioned MSIX location
# (…\WindowsApps\Microsoft.PowerShell_7.6.6.0_x64__…\pwsh.exe), which moves on
# every PowerShell update and would leave a dead RunOnce entry that fails at
# logon with nothing to show for it. Prefer the version-free execution alias.
function Resolve-PowerShellHost {
  $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
  if (Test-Path -LiteralPath $alias) { return $alias }

  $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
  if ($pwsh -and $pwsh.Source -notmatch '\\WindowsApps\\Microsoft\.PowerShell_') { return $pwsh.Source }
  if ($pwsh) { return 'pwsh.exe' }   # versioned MSIX only: rely on PATH at logon

  return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

$psExe = Resolve-PowerShellHost
$inner = "`"$psExe`" -NoProfile -ExecutionPolicy Bypass -File `"$resumeScript`""

$wt = Get-Command wt.exe -ErrorAction SilentlyContinue
if ($wt) {
  # Windows Terminal treats ';' as a command separator, so a semicolon anywhere in
  # the path would silently truncate the command line. Verified on wt: child
  # arguments are NOT swallowed by wt's own parser, so `$inner` passes through
  # intact; `nt` targets a new tab rather than relying on default behaviour.
  $wtDir  = $WorkDir -replace ';', '\;'
  $runCmd = "`"$($wt.Source)`" nt -d `"$wtDir`" $inner"
} else {
  $runCmd = $inner
}

# --- Dry run: report what WOULD happen, touch nothing -------------------------
if ($DryRun) {
  Write-Host "[reboot-continue] DRY RUN - nothing written, no reboot scheduled."
  Write-Host "[reboot-continue] WorkDir      : $WorkDir"
  if ($SessionId) {
    Write-Host "[reboot-continue] Session      : $SessionId (claude --resume)"
  } else {
    Write-Host "[reboot-continue] Session      : no resumable CLI transcript found -> a fresh session would be started"
  }
  Write-Host "[reboot-continue] Prompt       : $($Prompt.Length) chars"
  Write-Host "[reboot-continue] Would write  : $stateFile"
  Write-Host "[reboot-continue] RunOnce would be:"
  Write-Host "  $runCmd"
  exit 0
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
Set-ItemProperty -Path $runOnceKey -Name $valueName -Value $runCmd -Type String

Write-Host "[reboot-continue] State saved  : $stateFile"
if ($SessionId) {
  Write-Host "[reboot-continue] Session      : $SessionId (claude --resume)"
} else {
  Write-Host "[reboot-continue] Session      : no resumable CLI transcript found -> a fresh session will be started"
  Write-Host "[reboot-continue]                (scheduled/SDK transcripts are never resumed)"
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
