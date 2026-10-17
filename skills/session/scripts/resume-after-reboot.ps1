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
  or, when no session id was recorded, a fresh `claude -- "<prompt>"`. When claude
  is a .cmd/.bat shim, the prompt is written to <kit state>\resume-prompt.txt and
  the command line only points at that file (cmd.exe would re-parse it). It never
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

if (-not (Test-Path -LiteralPath $stateFile) -and -not $env:CLAUDE_SESSION_KIT_HOME) {
    # One release of grace for a reboot scheduled by the older standalone skill, which
    # never knew CLAUDE_SESSION_KIT_HOME (set, it is a test sandbox).
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

# The session is resumed in the folder RECORDED for it or not at all -- the same
# rule every other script in the kit follows. A mapped or removable drive can lag
# behind the logon, so wait a little before giving up.
$found = $false
if ($workdir) {
    foreach ($try in 1..10) {
        if (Test-Path -LiteralPath $workdir -PathType Container) { $found = $true; break }
        if ($DryRun) { break }
        Start-Sleep -Seconds 3
    }
}
if (-not $found) {
    Write-Log "ERROR: saved workdir '$workdir' not found. Not launching; the state file is kept."
    Write-Log "When the folder is back, run this script again: $PSCommandPath  (reboot-cancel.ps1 discards the pending resume instead)."
    Wait-BeforeClose
    exit 1
}
Set-Location -LiteralPath $workdir

# --- resolve the claude binary -------------------------------------------------
# An explicit override wins (same order as Resolve-ClaudeBinary in lib/). Then
# PATH, with -CommandType Application so that a profile function or alias named
# `claude` cannot win, and a real .exe ahead of an npm-style .cmd shim. RunOnce
# sees a thinner PATH than a terminal, so the list of usual places matters.
$claude = $null
if ($env:CLAUDE_CODE_BIN -and (Test-Path -LiteralPath $env:CLAUDE_CODE_BIN -PathType Leaf)) { $claude = $env:CLAUDE_CODE_BIN }
if (-not $claude) {
    $cmds = @(Get-Command claude -CommandType Application -All -ErrorAction SilentlyContinue)
    $exe = $cmds | Where-Object { $_.Source -match '\.exe\z' } | Select-Object -First 1
    if ($exe) { $claude = $exe.Source } elseif ($cmds.Count -gt 0) { $claude = $cmds[0].Source }
}
if (-not $claude) {
    $candidates = @(
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

# --- how the prompt travels ------------------------------------------------------
# To a real executable: as one argument. To a .cmd/.bat shim (an npm install):
# NEVER -- cmd.exe re-parses the shim's command line, so quotes, & | < > and %VAR%
# in the prompt would be live, and everything after the first line feed is dropped.
# The prompt goes into a file instead and the command line carries a fixed
# sentence, made of nothing cmd.exe cares about, that points at it.
$delivery = 'argv'
$promptArg = $prompt
if ($claude -match '\.(cmd|bat)\z') {
    $delivery = 'file'
    $promptFile = Join-Path $kitRoot 'resume-prompt.txt'
    if ($promptFile -match '\A[A-Za-z0-9 _.:\\-]+\z') { $where = "the file $promptFile" }
    else { $where = 'the file resume-prompt.txt in the claude-session-kit folder under .claude in your home folder' }
    $promptArg = "The machine has been rebooted as planned. Read $where and continue from the instructions in it."
}

# PowerShell 7.3+ builds a correct native command line from an argument array.
# Windows PowerShell 5.1 and pwsh 7.0-7.2 (and 7.3+ in 'Legacy' mode) do not: they
# neither escape embedded quotes nor wrap an argument reliably, and no amount of
# pre-escaping fixes both (a prompt that STARTS with a quote is never wrapped). On
# those hosts the command line is rendered here and the process started directly.
$ownCommandLine = ($delivery -eq 'argv') -and
    (($PSVersionTable.PSVersion -lt [version]'7.3') -or ("$PSNativeCommandArgumentPassing" -eq 'Legacy'))

$uuid = '\A[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\z'
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
Write-Log "prompt  : $($prompt.Length) chars, delivered by $delivery"

# Use the same Win32 quoting on every host; wt also treats semicolons as separators.
function ConvertTo-NativeArgument([string]$Value) {
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    return '"' + ($escaped -replace '(\\+)\z', '$1$1') + '"'
}
# A rerun by hand (the folder came back later, see above) must not open a session a
# second time. The CLI keeps <config>\sessions\<pid>.json for each live one: the same
# rule as Get-RunningSessions in lib/, without asking `claude agents`.
function Test-SessionRunning([string]$Id) {
    $cfg = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $cfg 'sessions') -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $r = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$r.sessionId -ne $Id -or -not $r.pid) { continue }
            $proc = Get-Process -Id ([int]$r.pid) -ErrorAction Stop
            $started = $null
            try { $started = $proc.StartTime.ToUniversalTime().ToFileTimeUtc() } catch {}
            if ($r.procStart -and $null -ne $started) { if ($started -eq [long]$r.procStart) { return $true } }
            elseif ($proc.ProcessName -in 'claude', 'node') { return $true }
        } catch {}
    }
    return $false
}
function Open-OtherSessions {
    $wt = $null
    # Narrow executable override for hermetic resume tests, like CLAUDE_CODE_BIN.
    if ($env:CLAUDE_SESSION_KIT_WT_BIN) {
        if (Test-Path -LiteralPath $env:CLAUDE_SESSION_KIT_WT_BIN -PathType Leaf) { $wt = $env:CLAUDE_SESSION_KIT_WT_BIN }
    } else {
        $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
        if (Test-Path -LiteralPath $alias -PathType Leaf) { $wt = $alias }
        else {
            $cmd = Get-Command wt.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cmd) { $wt = $cmd.Source }
        }
    }
    $seen = @{}; $count = 0
    foreach ($other in @($state.others)) {
        if (-not $other) { continue }
        $id = [string]$other.session_id; $dir = [string]$other.workdir
        if ($id -notmatch $uuid -or $id -ieq $sessionId -or $seen.ContainsKey($id) -or $count -ge 8 -or $dir -notmatch '\A[A-Za-z]:[\\/]') {
            Write-Log 'Skipping invalid other session target.'; continue
        }
        $seen[$id] = $true; $count++
        $exists = $false
        foreach ($attempt in 1..10) {
            if (Test-Path -LiteralPath $dir -PathType Container) { $exists = $true; break }
            if ($DryRun) { break }
            Start-Sleep -Seconds 3
        }
        if (-not $exists) { Write-Log "Skipping session $id : saved workdir '$dir' not found."; continue }
        if (Test-SessionRunning $id) { Write-Log "Skipping session $id : already open in another terminal."; continue }
        $launcher = if ($wt) { 'wt tab' } else { 'console' }
        Write-Log "Other session $id : $launcher in $dir (no prompt)."
        if ($DryRun) { continue }
        try {
            if ($wt) {
                $wtArgs = @('-w', '0', 'nt', '-d', ($dir -replace ';', '\;'), '--', ($claude -replace ';', '\;'), '--resume', $id)
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $wt
                $psi.Arguments = (@($wtArgs | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
                $psi.UseShellExecute = $false
                $psi.WorkingDirectory = $dir
                $proc = [System.Diagnostics.Process]::Start($psi)
                $proc.WaitForExit()
                $proc.Dispose()
            } else {
                # Escaped: -WorkingDirectory reads [ ] as wildcards and would not find the folder.
                Start-Process -FilePath $claude -ArgumentList @('--resume', $id) -WorkingDirectory ([WildcardPattern]::Escape($dir))
            }
        } catch { Write-Log "Could not reopen other session $id : $($_.Exception.Message)" }
    }
}

# Only a rerun by hand can find it open: right after the reboot nothing is.
$primaryOpen = ($sessionId -match $uuid) -and (Test-SessionRunning $sessionId)
if ($primaryOpen) { Write-Log "Session $sessionId is already open in another terminal; it is not opened a second time." }

if ($DryRun) {
    Open-OtherSessions
    Write-Log 'DryRun: not launching. State file left in place.'
    exit 0
}

if ($delivery -eq 'file') {
    [IO.File]::WriteAllText($promptFile, $prompt, (New-Object System.Text.UTF8Encoding($false)))
}

# Archive the state FIRST, so a relaunch that crashes can never loop.
Move-Item -LiteralPath $stateFile -Destination (Join-Path (Split-Path -Parent $stateFile) 'state.last.json') -Force

Open-OtherSessions
if ($primaryOpen) { Wait-BeforeClose; exit 0 }

Start-Sleep -Seconds 3
if ($ownCommandLine) {
    # CommandLineToArgvW rules: backslashes before a quote double up and the quote
    # gets one more; trailing backslashes double up before the closing quote. Every
    # other argument here is a flag or a validated UUID and needs no quoting.
    $quoted = $promptArg -replace '(\\*)"', '$1$1\"'
    $quoted = '"' + ($quoted -replace '(\\+)\z', '$1$1') + '"'
    $flags = @($claudeArgs | Select-Object -First ($claudeArgs.Count - 1))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $claude
    $psi.Arguments = (($flags -join ' ') + ' ' + $quoted)
    $psi.UseShellExecute = $false          # same console, no shell in between
    $psi.WorkingDirectory = (Get-Location).Path
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.WaitForExit()
    $code = $proc.ExitCode
} else {
    & $claude @claudeArgs
    $code = $LASTEXITCODE
}
Write-Log "claude exited with code $code"
Wait-BeforeClose
