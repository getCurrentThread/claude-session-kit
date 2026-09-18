#requires -Version 7.0
<#
.SYNOPSIS
  Step 1 of 2: works out exactly what a reboot-and-resume would do, and records it. Changes nothing else.

.DESCRIPTION
  Runs every check that can fail while a person is still looking at the terminal
  -- the folder, its trust, the claude executable, which session would be resumed,
  the exact RunOnce command and its length -- then writes the result to plan.json
  with a one-time token. No registry value is written and no reboot is scheduled;
  reboot-commit.ps1 -Token <token> does that, and only from an unexpired plan.

  Which session is resumed:
    1. -SessionId -- refused (SESSION_REJECTED) unless its transcript exists, is an
       interactive CLI conversation and was recorded in this folder
    2. CLAUDE_CODE_SESSION_ID, the running session, under the same three conditions
    3. the newest INTERACTIVE transcript in this folder (never a scheduled/SDK one),
       or this session's own sidecar while it is under ten minutes old
    4. none -> a FRESH session carrying the prompt. `claude --continue` is never
       used: it would reopen whatever conversation is newest, an automation's included.

  Prints one JSON object.
  code: REBOOT_PLANNED | PATH_NOT_FOUND | PROMPT_NOT_FOUND | UNTRUSTED_WORKSPACE |
        CLAUDE_NOT_FOUND | SESSION_REJECTED | RUNONCE_TOO_LONG

.PARAMETER PromptFile
  UTF-8 text file with the continuation prompt. Preferred over -Prompt for any
  non-ASCII text, which a console codepage can mangle on the command line.

.PARAMETER NoReboot
  Plan a registration only; the user reboots by hand and the resume fires at the next logon.
#>
[CmdletBinding()]
param(
    [string]$Prompt = '',
    [string]$PromptFile = '',
    [string]$SessionId = '',
    [string]$WorkDir = '',
    [int]$DelaySeconds = 30,
    [switch]$NoReboot,
    [switch]$AllowUntrusted
)

$ErrorActionPreference = 'Stop'
# State only. This script must stay unable to open a terminal, write the registry
# or shut the machine down -- tests/run-tests.ps1 checks that it still is.
. "$PSScriptRoot\lib\Core.State.ps1"

try {
    Initialize-KitState | Out-Null

    if (-not $WorkDir) { $WorkDir = (Get-Location).Path }
    $resolved = Resolve-WorkspacePath $WorkDir
    if (-not $resolved) {
        Exit-WithResult ([ordered]@{ ok = $false; code = 'PATH_NOT_FOUND'; path = $WorkDir; message = 'The working directory does not exist. Nothing was planned.' })
    }
    $WorkDir = $resolved

    if ($PromptFile) {
        if (-not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) {
            Exit-WithResult ([ordered]@{ ok = $false; code = 'PROMPT_NOT_FOUND'; path = $PromptFile; message = 'The prompt file does not exist. Nothing was planned.' })
        }
        # -Raw yields nothing at all for a zero-byte file; interpolation turns that into ''.
        $Prompt = "$(Get-Content -LiteralPath $PromptFile -Raw -Encoding UTF8)".Trim()
    }
    if (-not $Prompt) {
        $Prompt = 'The machine has been rebooted as planned. Read the notes left before the reboot and continue the task from where we left off.'
    }

    if (-not $AllowUntrusted -and -not (Test-WorkspaceTrusted -Path $WorkDir)) {
        Exit-WithResult ([ordered]@{
                ok = $false; code = 'UNTRUSTED_WORKSPACE'; path = $WorkDir
                trustKey = (Get-TrustKey -Path $WorkDir); isRepo = [bool](Get-GitRootOrNull -Path $WorkDir)
                message = 'This folder is not trusted in Claude Code, so a resumed session would stop on the trust prompt. Nothing was planned.'
            })
    }

    $claude = Resolve-ClaudeBinary
    if (-not $claude) {
        Exit-WithResult ([ordered]@{ ok = $false; code = 'CLAUDE_NOT_FOUND'; message = 'The claude executable was not found, so nothing could be resumed after the reboot. Nothing was planned.' })
    }
    $shim = Test-ClaudeShim $claude

    # --- which session ---------------------------------------------------------
    # A sidecar is the session asking for this reboot, still buffering its first
    # lines -- but only while it is fresh. An old one is a conversation that was
    # never written out, and `--resume` on it finds nothing.
    $live = (Get-Date).AddMinutes(-10)
    $sessionSource = $null
    $projectDir = Get-ProjectTranscriptDir $WorkDir

    # Why a given id cannot be planned, or $null when it can. An ALLOWLIST, like the
    # rest of the kit: the transcript has to exist, be an interactive CLI conversation
    # (or the asking session's own fresh sidecar), and belong to this folder. Anything
    # less would only fail after the machine is already down.
    function Get-SessionProblem([string]$Id) {
        $t = Join-Path $projectDir ($Id + '.jsonl')
        if (-not (Test-Path -LiteralPath $t)) {
            $t = $null
            foreach ($d in @(Get-ChildItem -LiteralPath (Get-ClaudeProjectsDir) -Directory -ErrorAction SilentlyContinue)) {
                $c = Join-Path $d.FullName ($Id + '.jsonl')
                if (Test-Path -LiteralPath $c) { $t = $c; break }
            }
        }
        if (-not $t) { return @{ message = 'No transcript exists for that session id, so there would be nothing to resume after the reboot.' } }
        $rec = Get-ClaudeSessionRecord -TranscriptPath $t
        $ok = $rec.Kind -eq 'interactive' -or ($rec.Kind -eq 'sidecar' -and $rec.LastWrite -ge $live)
        if (-not $ok) { return @{ kind = $rec.Kind; message = 'That session is not an interactive CLI session. Scheduled and SDK runs are never resumed.' } }
        $here = if ($rec.Cwd) { Test-PathEqual $rec.Cwd $WorkDir } else { (Split-Path -Parent $t) -ieq $projectDir }
        if (-not $here) { return @{ recordedCwd = $rec.Cwd; message = 'That session was recorded in another folder. Plan again with -WorkDir set to the folder it belongs to.' } }
        return $null
    }

    # Claude Code exports the id of the running session; the older name is kept for
    # one release.
    $envSid = if ($env:CLAUDE_CODE_SESSION_ID) { $env:CLAUDE_CODE_SESSION_ID } else { $env:CLAUDE_SESSION_ID }

    if ($SessionId) {
        if (-not (Test-SessionIdFormat $SessionId)) {
            Exit-WithResult ([ordered]@{ ok = $false; code = 'SESSION_REJECTED'; sessionId = $SessionId; message = 'That is not a session id.' })
        }
        $problem = Get-SessionProblem $SessionId
        if ($problem) {
            $r = [ordered]@{ ok = $false; code = 'SESSION_REJECTED'; sessionId = $SessionId }
            foreach ($k in $problem.Keys) { $r[$k] = $problem[$k] }
            $r.message = $r.message + ' Nothing was planned.'
            Exit-WithResult $r
        }
        $sessionSource = 'explicit'
    } elseif ((Test-SessionIdFormat $envSid) -and -not (Get-SessionProblem $envSid)) {
        $SessionId = $envSid
        $sessionSource = 'env'
    } else {
        $newest = @(Get-ClaudeSessions -Path $WorkDir -Days 30 -Kinds @('interactive', 'sidecar')) |
            Where-Object { $_.Kind -eq 'interactive' -or $_.LastWrite -ge $live } | Select-Object -First 1
        if ($newest) { $SessionId = $newest.SessionId; $sessionSource = 'scan:' + $newest.Kind }
    }
    $sessionMode = if ($SessionId) { 'resume' } else { 'fresh' }

    # --- the RunOnce value -------------------------------------------------------
    # It points at a FROZEN COPY of the resume script under the kit's own state
    # folder, never into the plugin: an installed plugin lives in a versioned cache
    # directory, and an update between now and the next logon would leave RunOnce
    # pointing at a path that no longer exists -- a failure that logs nothing.
    $resumeSource = Join-Path $PSScriptRoot 'resume-after-reboot.ps1'
    if (-not (Test-Path -LiteralPath $resumeSource)) { throw 'resume-after-reboot.ps1 is missing next to this script.' }
    $runtimeScript = Join-Path (Get-KitPath runtime) 'resume.ps1'

    $psHost = Resolve-PowerShellHost
    $wt = Resolve-WindowsTerminal
    $runOnce = $null
    try { $runOnce = New-RunOnceCommand -PowerShellExe $psHost -ResumeScript $runtimeScript -WtExe $wt } catch { $runOnce = $null }
    if (-not $runOnce -or -not (Test-RunOnceCommandLength $runOnce)) {
        # Without the Windows Terminal wrapper the entry is shorter and still opens a console.
        $runOnce = New-RunOnceCommand -PowerShellExe $psHost -ResumeScript $runtimeScript
    }
    if (-not (Test-RunOnceCommandLength $runOnce)) {
        Exit-WithResult ([ordered]@{ ok = $false; code = 'RUNONCE_TOO_LONG'; length = $runOnce.Length; message = 'The RunOnce command would exceed 260 characters and Windows would silently skip it. Nothing was planned.' })
    }

    if ($DelaySeconds -lt 30) { $DelaySeconds = 30 }   # other apps may hold unsaved work

    $token = -join ((1..8) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
    $plan = [ordered]@{
        token          = $token
        created_at     = (Get-Date).ToString('o')
        workdir        = $WorkDir
        session_id     = $SessionId
        session_mode   = $sessionMode
        prompt         = $Prompt
        delay_seconds  = $DelaySeconds
        no_reboot      = [bool]$NoReboot
        runonce        = $runOnce
        runtime_script = $runtimeScript
    }
    [IO.File]::WriteAllText((Get-KitPath plan), ($plan | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Write-KitLog ("reboot-plan token={0} mode={1} session={2} prompt={3} cwd={4}" -f $token, $sessionMode, $SessionId, (Get-TextDigest $Prompt), $WorkDir)

    Exit-WithResult ([ordered]@{
            ok = $true; code = 'REBOOT_PLANNED'; token = $token; expiresInSeconds = 600
            workdir = $WorkDir; sessionMode = $sessionMode; sessionId = $SessionId; sessionSource = $sessionSource
            prompt = (Get-TextDigest $Prompt); delaySeconds = $DelaySeconds; willReboot = (-not $NoReboot)
            runOnce = $runOnce; promptDelivery = $(if ($shim) { 'file' } else { 'argv' })
            message = $(if ($sessionMode -eq 'fresh') {
                    'Planned. No resumable interactive session was identified, so a FRESH session carrying the prompt will start after logon. Nothing has been registered or scheduled yet.'
                } else {
                    'Planned. Nothing has been registered or scheduled yet.'
                }) + $(if ($shim) { ' Note: claude is a .cmd shim here, so after logon the prompt is handed over in resume-prompt.txt (state folder) and the command line only points at it.' } else { '' })
        })
} catch {
    Write-KitResult -Ok $false -Code 'INTERNAL_ERROR' -Message $_.Exception.Message
    exit 2
}
