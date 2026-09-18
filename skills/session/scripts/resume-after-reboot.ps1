<#
.SYNOPSIS
  Relaunches Claude Code after a reboot and resumes the saved session.

.DESCRIPTION
  Runs once at logon from HKCU RunOnce -- not from the plugin folder but from a
  frozen copy, <kit state>\runtime\resume.ps1, made by reboot-commit.ps1. The
  plugin may be updated or moved between the reboot request and the next logon;
  the copy cannot be.

  For that reason this file is SELF-CONTAINED: it loads nothing from lib/, and it
  stays parseable by Windows PowerShell 5.1 (ASCII only, no PS7 syntax), which is
  the fallback host when pwsh is not installed.

  Reads state.json, changes to the saved folder and runs
      claude --resume <id> -- "<prompt>"
  or, when no session id was recorded, a fresh `claude -- "<prompt>"`. It never
  uses `claude --continue`, which reopens whatever conversation is newest in the
  folder -- possibly a scheduled run's. It never re-decides which session to
  resume either: that was settled, and shown to the user, before the reboot.

.PARAMETER DryRun
  Log the resolved command without launching Claude; the state file is kept.
#>
[CmdletBinding()]
param(
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if ($env:CLAUDE_SESSION_KIT_HOME) {
    $kitRoot = $env:CLAUDE_SESSION_KIT_HOME
} elseif ((Split-Path -Leaf $PSScriptRoot) -eq 'runtime') {
    $kitRoot = Split-Path -Parent $PSScriptRoot
} else {
    $kitRoot = Join-Path $env:USERPROFILE '.claude\claude-session-kit'
}
$stateFile = Join-Path $kitRoot 'state.json'
$logFile   = Join-Path $kitRoot 'kit.log'

function Write-Log([string]$msg) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Host $line
    try { Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 } catch {}
}

# Keeps the window open so a failure can be read. Skipped when there is nobody to
# press Enter -- a blocked Read-Host with no console would hang forever, unseen.
function Wait-BeforeClose {
    if ($DryRun -or -not [Environment]::UserInteractive) { return }
    try { Read-Host 'Press Enter to close' | Out-Null } catch {}
}

Write-Log "resume-after-reboot started (DryRun=$([bool]$DryRun))"

if (-not (Test-Path -LiteralPath $stateFile)) {
    # One release of grace for a reboot scheduled by the older standalone skill.
    $legacy = Join-Path $env:USERPROFILE '.claude\reboot-continue\state.json'
    if (Test-Path -LiteralPath $legacy) { $stateFile = $legacy }
}
if (-not (Test-Path -LiteralPath $stateFile)) {
    Write-Log "No state file at $stateFile - nothing to resume."
    Wait-BeforeClose
    exit 1
}

$state     = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
$workdir   = [string]$state.workdir
$sessionId = [string]$state.session_id
$prompt    = [string]$state.prompt

if ($workdir -and (Test-Path -LiteralPath $workdir -PathType Container)) {
    Set-Location -LiteralPath $workdir
} else {
    Write-Log "WARN: saved workdir '$workdir' not found; staying in $((Get-Location).Path)"
}

# --- resolve the claude binary -------------------------------------------------
# -CommandType Application: under a profile, a function or alias named `claude`
# must not win. RunOnce sees a thinner PATH than a terminal, so the list matters.
$claude = $null
$cmdInfo = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($cmdInfo) { $claude = $cmdInfo.Source }
if (-not $claude) {
    $candidates = @(
        $env:CLAUDE_CODE_BIN,
        (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\claude\claude.exe'),
        (Join-Path $env:APPDATA 'npm\claude.cmd'),
        (Join-Path $env:USERPROFILE '.bun\bin\claude.exe')
    )
    foreach ($cand in $candidates) {
        if ($cand -and (Test-Path -LiteralPath $cand)) { $claude = $cand; break }
    }
}
if (-not $claude) {
    Write-Log 'ERROR: claude binary not found (PATH and known install locations).'
    Wait-BeforeClose
    exit 1
}

# Windows PowerShell 5.1 does not escape embedded quotes when it builds a native
# command line; PowerShell 7.3+ does.
$promptArg = $prompt
if ($PSVersionTable.PSVersion.Major -lt 7) { $promptArg = $prompt -replace '"', '\"' }

$uuid = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
if ($sessionId -and $sessionId -match $uuid) {
    # '--' ends option parsing. `--resume` takes an OPTIONAL value, so without the
    # separator the prompt is liable to be consumed as the resume target.
    $claudeArgs  = @('--resume', $sessionId, '--', $promptArg)
    $sessionDesc = $sessionId
} else {
    $claudeArgs  = @('--', $promptArg)
    $sessionDesc = '(no resumable session was identified -- starting a fresh one)'
}

# The prompt body is never logged: it holds paths, branch names and plans, and
# this log is what people attach to bug reports.
Write-Log "workdir : $((Get-Location).Path)"
Write-Log "session : $sessionDesc"
Write-Log "claude  : $claude"
Write-Log "prompt  : $($prompt.Length) chars"

if ($DryRun) {
    Write-Log 'DryRun: not launching. State file left in place.'
    exit 0
}

# Archive the state FIRST, so a relaunch that crashes can never loop.
Move-Item -LiteralPath $stateFile -Destination (Join-Path (Split-Path -Parent $stateFile) 'state.last.json') -Force

Start-Sleep -Seconds 3
& $claude @claudeArgs
$code = $LASTEXITCODE
Write-Log "claude exited with code $code"
Wait-BeforeClose
