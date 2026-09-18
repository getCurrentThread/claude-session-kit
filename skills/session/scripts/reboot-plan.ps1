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
    1. -SessionId
    2. CLAUDE_SESSION_ID, if its transcript really is in this folder's project
    3. the newest INTERACTIVE transcript in this folder (never a scheduled/SDK one)
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
        $Prompt = (Get-Content -LiteralPath $PromptFile -Raw -Encoding UTF8).Trim()
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

    # --- which session ---------------------------------------------------------
    $sessionSource = $null
    $projectDir = Get-ProjectTranscriptDir $WorkDir
    if ($SessionId) {
        if (-not (Test-SessionIdFormat $SessionId)) {
            Exit-WithResult ([ordered]@{ ok = $false; code = 'SESSION_REJECTED'; sessionId = $SessionId; message = 'That is not a session id.' })
        }
        $t = Join-Path $projectDir ($SessionId + '.jsonl')
        if (Test-Path -LiteralPath $t) {
            $rec = Get-ClaudeSessionRecord -TranscriptPath $t
            if ($rec.Kind -eq 'automated') {
                Exit-WithResult ([ordered]@{ ok = $false; code = 'SESSION_REJECTED'; sessionId = $SessionId; message = 'That session belongs to a scheduled or SDK run and is never resumed.' })
            }
        }
        $sessionSource = 'explicit'
    } elseif ($env:CLAUDE_SESSION_ID -and (Test-SessionIdFormat $env:CLAUDE_SESSION_ID) -and
        (Test-Path -LiteralPath (Join-Path $projectDir ($env:CLAUDE_SESSION_ID + '.jsonl')))) {
        $SessionId = $env:CLAUDE_SESSION_ID
        $sessionSource = 'env'
    } else {
        # A sidecar is the session asking for this reboot, still buffering its first
        # lines -- but only while it is fresh. An old one is a conversation that was
        # never written out, and `--resume` on it finds nothing.
        $live = (Get-Date).AddMinutes(-10)
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
        resume_source  = $resumeSource
        runtime_script = $runtimeScript
    }
    [IO.File]::WriteAllText((Get-KitPath plan), ($plan | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Write-KitLog ("reboot-plan token={0} mode={1} session={2} prompt={3} cwd={4}" -f $token, $sessionMode, $SessionId, (Get-TextDigest $Prompt), $WorkDir)

    Exit-WithResult ([ordered]@{
            ok = $true; code = 'REBOOT_PLANNED'; token = $token; expiresInSeconds = 600
            workdir = $WorkDir; sessionMode = $sessionMode; sessionId = $SessionId; sessionSource = $sessionSource
            prompt = (Get-TextDigest $Prompt); delaySeconds = $DelaySeconds; willReboot = (-not $NoReboot)
            runOnce = $runOnce
            message = if ($sessionMode -eq 'fresh') {
                'Planned. No resumable interactive session was identified, so a FRESH session carrying the prompt will start after logon. Nothing has been registered or scheduled yet.'
            } else {
                'Planned. Nothing has been registered or scheduled yet.'
            }
        })
} catch {
    Write-KitResult -Ok $false -Code 'INTERNAL_ERROR' -Message $_.Exception.Message
    exit 2
}
