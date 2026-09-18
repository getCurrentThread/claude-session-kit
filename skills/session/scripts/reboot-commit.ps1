<#
.SYNOPSIS
  Step 2 of 2: registers the resume and REBOOTS THE MACHINE, from a plan made by reboot-plan.ps1.

.DESCRIPTION
  THIS IS THE ONLY SCRIPT IN THE KIT THAT CAN RESTART WINDOWS. Run it only after the
  user has said, in their own words and in the turn just before, to reboot.
  Do not add it to a permission allowlist.

  It decides nothing. Everything -- folder, session, prompt, the RunOnce command --
  was resolved and shown by reboot-plan.ps1; this script replays that plan, and
  only when -Token matches and the plan is under ten minutes old. It loads none of
  lib/ on purpose, so a fault in the shared code cannot change what gets registered
  after the plan was shown.

  In order: freeze a copy of the resume script under the kit's state folder, write
  state.json, set HKCU RunOnce\ClaudeRebootContinue, then `shutdown /r`.

  Prints one JSON object.
  code: REBOOT_SCHEDULED | RESUME_REGISTERED | SIMULATED | NO_PLAN | TOKEN_MISMATCH |
        PLAN_EXPIRED | PLAN_INVALID | SHUTDOWN_FAILED

.PARAMETER Simulate
  Do everything except the registry write and the shutdown. Used by the tests.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Token,
    [switch]$Simulate
)

$ErrorActionPreference = 'Stop'

$kitRoot    = if ($env:CLAUDE_SESSION_KIT_HOME) { $env:CLAUDE_SESSION_KIT_HOME } else { Join-Path $env:USERPROFILE '.claude\claude-session-kit' }
$planFile   = Join-Path $kitRoot 'plan.json'
$stateFile  = Join-Path $kitRoot 'state.json'
$logFile    = Join-Path $kitRoot 'kit.log'
$runOnceKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
$valueName  = 'ClaudeRebootContinue'
$utf8       = New-Object System.Text.UTF8Encoding($false)

function Out-Result([System.Collections.IDictionary]$r, [int]$code) {
    Write-Output ($r | ConvertTo-Json -Compress -Depth 5)
    exit $code
}
function Write-Log([string]$msg) {
    try { Add-Content -LiteralPath $logFile -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding utf8 } catch {}
}

try {
    try { [Console]::OutputEncoding = $utf8 } catch {}

    if (-not (Test-Path -LiteralPath $planFile)) {
        Out-Result ([ordered]@{ ok = $false; code = 'NO_PLAN'; message = 'There is no plan. Run reboot-plan.ps1 first.' }) 1
    }
    $plan = Get-Content -LiteralPath $planFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$plan.token -cne $Token) {
        Out-Result ([ordered]@{ ok = $false; code = 'TOKEN_MISMATCH'; message = 'The token does not match the current plan. Nothing was registered.' }) 1
    }
    $created = if ($plan.created_at -is [datetime]) { $plan.created_at } else { [datetime]::Parse([string]$plan.created_at) }
    if (((Get-Date) - $created).TotalSeconds -gt 600) {
        Remove-Item -LiteralPath $planFile -Force
        Out-Result ([ordered]@{ ok = $false; code = 'PLAN_EXPIRED'; message = 'The plan is more than ten minutes old. Run reboot-plan.ps1 again.' }) 1
    }
    foreach ($field in 'workdir', 'prompt', 'runonce', 'resume_source', 'runtime_script') {
        if (-not $plan.$field) { Out-Result ([ordered]@{ ok = $false; code = 'PLAN_INVALID'; message = "The plan has no '$field'. Run reboot-plan.ps1 again." }) 1 }
    }
    if (-not (Test-Path -LiteralPath $plan.resume_source -PathType Leaf)) {
        Out-Result ([ordered]@{ ok = $false; code = 'PLAN_INVALID'; message = 'The resume script named by the plan no longer exists. Run reboot-plan.ps1 again.' }) 1
    }
    # The command that gets registered must point at the frozen copy made below --
    # never anywhere else, whatever plan.json says.
    $ro = [string]$plan.runonce
    $rs = [string]$plan.runtime_script
    $pointsAtCopy = $ro.EndsWith(' ' + $rs) -or $ro.EndsWith(' "' + $rs + '"')
    $copyIsOurs = $rs.StartsWith($kitRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
    if (-not $pointsAtCopy -or -not $copyIsOurs) {
        Out-Result ([ordered]@{ ok = $false; code = 'PLAN_INVALID'; message = 'The RunOnce command does not reference the frozen resume script. Run reboot-plan.ps1 again.' }) 1
    }
    $delay = [int]$plan.delay_seconds
    if ($delay -lt 30) { $delay = 30 }

    # 1. frozen, version-independent copy of the resume script
    $runtimeDir = Split-Path -Parent $plan.runtime_script
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
    Copy-Item -LiteralPath $plan.resume_source -Destination $plan.runtime_script -Force

    # 2. state for the resume script (the prompt lives here, never in the registry or a log)
    $state = [ordered]@{
        session_id = [string]$plan.session_id
        workdir    = [string]$plan.workdir
        prompt     = [string]$plan.prompt
        created_at = (Get-Date).ToString('o')
    }
    [IO.File]::WriteAllText($stateFile, ($state | ConvertTo-Json -Depth 4), $utf8)

    # The plan is single-use from here on, whatever happens next.
    Remove-Item -LiteralPath $planFile -Force

    if ($Simulate) {
        Out-Result ([ordered]@{ ok = $true; code = 'SIMULATED'; stateFile = $stateFile; runtimeScript = [string]$plan.runtime_script; runOnce = [string]$plan.runonce; delaySeconds = $delay; message = 'Simulated: state and frozen script written; registry and shutdown skipped.' }) 0
    }

    # 3. RunOnce -- fires once at the next logon, then Windows deletes it
    Set-ItemProperty -Path $runOnceKey -Name $valueName -Value ([string]$plan.runonce) -Type String
    Write-Log ("reboot-commit registered session={0} cwd={1}" -f $plan.session_id, $plan.workdir)

    if ($plan.no_reboot) {
        Out-Result ([ordered]@{ ok = $true; code = 'RESUME_REGISTERED'; workdir = [string]$plan.workdir; sessionId = [string]$plan.session_id; message = 'Registered. No reboot was scheduled; the session resumes at the next logon after a manual restart.' }) 0
    }

    # 4. the reboot
    & shutdown.exe /r /t $delay /c "Claude Code session kit: restarting in $delay seconds. Run 'shutdown /a' to abort."
    if ($LASTEXITCODE -ne 0) {
        Write-Log "reboot-commit shutdown.exe failed exit=$LASTEXITCODE"
        Out-Result ([ordered]@{ ok = $false; code = 'SHUTDOWN_FAILED'; exitCode = $LASTEXITCODE; message = 'shutdown.exe refused. The resume is still registered for the next logon; run reboot-cancel.ps1 to remove it.' }) 1
    }
    Out-Result ([ordered]@{ ok = $true; code = 'REBOOT_SCHEDULED'; delaySeconds = $delay; workdir = [string]$plan.workdir; sessionId = [string]$plan.session_id; message = "Restarting in $delay seconds. Abort with 'shutdown /a' or reboot-cancel.ps1." }) 0
} catch {
    Write-Output (([ordered]@{ ok = $false; code = 'INTERNAL_ERROR'; message = $_.Exception.Message }) | ConvertTo-Json -Compress)
    exit 2
}
