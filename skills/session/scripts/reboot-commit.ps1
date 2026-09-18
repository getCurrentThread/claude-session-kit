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

  It does not trust plan.json with anything executable either: the resume script
  it freezes is the one next to this file, the frozen copy's location is fixed,
  and the RunOnce command is accepted only in the exact shape reboot-plan.ps1
  renders, with an installed pwsh/powershell (and wt), and is re-rendered before
  it is registered. An edited plan yields PLAN_INVALID, not a different command.

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

# Canonical form (no '..', no 8.3 names), like Get-KitRoot in lib/: plan and commit must agree on the string.
$kitRoot    = [IO.Path]::GetFullPath($(if ($env:CLAUDE_SESSION_KIT_HOME) { $env:CLAUDE_SESSION_KIT_HOME } else { Join-Path $env:USERPROFILE '.claude\claude-session-kit' }))
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
    $age = ((Get-Date) - $created).TotalSeconds
    if ($age -gt 600 -or $age -lt -60) {   # a timestamp from the future never expires, so it is refused too
        Remove-Item -LiteralPath $planFile -Force
        Out-Result ([ordered]@{ ok = $false; code = 'PLAN_EXPIRED'; message = 'The plan is more than ten minutes old (or not dated now). Run reboot-plan.ps1 again.' }) 1
    }
    foreach ($field in 'workdir', 'prompt', 'runonce', 'runtime_script') {
        if (-not $plan.$field) { Out-Result ([ordered]@{ ok = $false; code = 'PLAN_INVALID'; message = "The plan has no '$field'. Run reboot-plan.ps1 again." }) 1 }
    }
    if (-not (Test-Path -LiteralPath ([string]$plan.workdir) -PathType Container)) {
        Out-Result ([ordered]@{ ok = $false; code = 'PLAN_INVALID'; message = 'The working directory named by the plan does not exist. Run reboot-plan.ps1 again.' }) 1
    }
    if ($plan.session_id -and ([string]$plan.session_id) -notmatch '\A[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\z') {
        Out-Result ([ordered]@{ ok = $false; code = 'PLAN_INVALID'; message = 'The session id in the plan is not a session id. Run reboot-plan.ps1 again.' }) 1
    }

    # plan.json is a file anyone with write access to the state folder can edit, and
    # the permission prompt for this script shows only the token. So NOTHING that
    # will be executed is taken from it:
    #   * the script that gets frozen is the one sitting next to this file;
    #   * the place it is frozen to is fixed;
    #   * the RunOnce command must be, token for token, one of the two shapes
    #     reboot-plan.ps1 renders, naming hosts that exist and that a system folder
    #     or PATH vouches for -- and what is registered is re-rendered from those
    #     tokens, never the string as found.
    $resumeSource  = Join-Path $PSScriptRoot 'resume-after-reboot.ps1'
    $runtimeScript = [IO.Path]::GetFullPath((Join-Path $kitRoot 'runtime\resume.ps1'))
    $invalid = { param($why) Out-Result ([ordered]@{ ok = $false; code = 'PLAN_INVALID'; message = "$why Nothing was registered. Run reboot-plan.ps1 again." }) 1 }
    if (-not (Test-Path -LiteralPath $resumeSource -PathType Leaf)) { & $invalid 'resume-after-reboot.ps1 is missing next to reboot-commit.ps1.' }
    if ([IO.Path]::GetFullPath([string]$plan.runtime_script) -ine $runtimeScript) { & $invalid 'The plan does not point at the frozen resume script in the state folder.' }

    function Test-VouchedHost([string]$Exe, [string[]]$Names) {
        if ([IO.Path]::GetFileName($Exe) -notin $Names) { return $false }
        if ($Exe -notmatch '\A[A-Za-z]:[\\/]' -or -not (Test-Path -LiteralPath $Exe -PathType Leaf)) { return $false }
        $full = [IO.Path]::GetFullPath($Exe)
        $roots = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')) | Where-Object { $_ }
        foreach ($r in $roots) { if ($full.StartsWith($r.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true } }
        $onPath = @(Get-Command ([IO.Path]::GetFileName($Exe)) -CommandType Application -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
        return [bool]($onPath | Where-Object { [IO.Path]::GetFullPath($_) -ieq $full })   # a PATH entry may be spelled with '..' or an 8.3 name
    }

    $ro = [string]$plan.runonce
    $tokens = @([regex]::Matches($ro, '"([^"]*)"|(\S+)') | ForEach-Object { if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value } })
    $hostShape = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File')
    $wtExe = $null
    if ($tokens.Count -eq 11 -and (($tokens[1..4] -join ' ') -ceq '-w new nt --')) { $wtExe = $tokens[0]; $tokens = @($tokens[5..10]) }
    if ($tokens.Count -ne 6 -or (($tokens[1..4] -join ' ') -cne ($hostShape -join ' '))) { & $invalid 'The RunOnce command in the plan is not one this kit renders.' }
    $psExe = $tokens[0]
    if ($tokens[5] -notmatch '\A[A-Za-z]:[\\/]' -or [IO.Path]::GetFullPath($tokens[5]) -ine $runtimeScript) { & $invalid 'The RunOnce command does not run the frozen resume script.' }
    if (-not (Test-VouchedHost $psExe @('pwsh.exe', 'powershell.exe'))) { & $invalid 'The PowerShell host named by the plan is not an installed pwsh.exe or powershell.exe.' }
    if ($wtExe -and -not (Test-VouchedHost $wtExe @('wt.exe'))) { & $invalid 'The Windows Terminal named by the plan is not an installed wt.exe.' }

    $quote = { param($s) if ($s -match '\s') { '"' + $s + '"' } else { $s } }
    $runOnce = (@((& $quote $psExe)) + $hostShape + @((& $quote $runtimeScript))) -join ' '
    if ($wtExe) { $runOnce = (& $quote $wtExe) + ' -w new nt -- ' + $runOnce }
    if ($runOnce.Length -gt 260) { & $invalid 'The RunOnce command would exceed 260 characters.' }

    $delay = [int]$plan.delay_seconds
    if ($delay -lt 30) { $delay = 30 }

    # 1. frozen, version-independent copy of the resume script
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $runtimeScript) | Out-Null
    Copy-Item -LiteralPath $resumeSource -Destination $runtimeScript -Force

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
        Out-Result ([ordered]@{ ok = $true; code = 'SIMULATED'; stateFile = $stateFile; runtimeScript = $runtimeScript; runOnce = $runOnce; delaySeconds = $delay; message = 'Simulated: state and frozen script written; registry and shutdown skipped.' }) 0
    }

    # 3. RunOnce -- fires once at the next logon, then Windows deletes it
    Set-ItemProperty -Path $runOnceKey -Name $valueName -Value $runOnce -Type String
    Write-Log ("reboot-commit registered session={0} cwd={1}" -f $plan.session_id, $plan.workdir)

    if ($plan.no_reboot) {
        Out-Result ([ordered]@{ ok = $true; code = 'RESUME_REGISTERED'; workdir = [string]$plan.workdir; sessionId = [string]$plan.session_id; runOnce = $runOnce; message = 'Registered. No reboot was scheduled; the session resumes at the next logon after a manual restart.' }) 0
    }

    # 4. the reboot
    & shutdown.exe /r /t $delay /c "Claude Code session kit: restarting in $delay seconds. Run 'shutdown /a' to abort."
    if ($LASTEXITCODE -ne 0) {
        Write-Log "reboot-commit shutdown.exe failed exit=$LASTEXITCODE"
        Out-Result ([ordered]@{ ok = $false; code = 'SHUTDOWN_FAILED'; exitCode = $LASTEXITCODE; message = 'shutdown.exe refused. The resume is still registered for the next logon; run reboot-cancel.ps1 to remove it.' }) 1
    }
    Out-Result ([ordered]@{ ok = $true; code = 'REBOOT_SCHEDULED'; delaySeconds = $delay; workdir = [string]$plan.workdir; sessionId = [string]$plan.session_id; runOnce = $runOnce; message = "Restarting in $delay seconds. Abort with 'shutdown /a' or reboot-cancel.ps1." }) 0
} catch {
    Write-Output (([ordered]@{ ok = $false; code = 'INTERNAL_ERROR'; message = $_.Exception.Message }) | ConvertTo-Json -Compress)
    exit 2
}
