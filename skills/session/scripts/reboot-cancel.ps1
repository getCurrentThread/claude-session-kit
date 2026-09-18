<#
.SYNOPSIS
  Cancels a scheduled reboot-and-resume, or (-Status) reports what is pending. Cannot restart anything.

.DESCRIPTION
  Loads none of lib/: cancelling has to keep working even when the shared code
  does not parse. It can abort a shutdown and delete this kit's own RunOnce value,
  plan and state -- nothing else.

  Also sweeps the state file of the older standalone "reboot-continue" skill, which
  used the same RunOnce value name.

  Prints one JSON object. code: CANCELLED | NOTHING_PENDING | STATUS

.PARAMETER Status
  Report only. The prompt body is never printed -- only its length.
#>
[CmdletBinding()]
param(
    [switch]$Status
)

$ErrorActionPreference = 'Stop'

$kitRoot     = if ($env:CLAUDE_SESSION_KIT_HOME) { $env:CLAUDE_SESSION_KIT_HOME } else { Join-Path $env:USERPROFILE '.claude\claude-session-kit' }
$planFile    = Join-Path $kitRoot 'plan.json'
$stateFile   = Join-Path $kitRoot 'state.json'
$legacyState = Join-Path $env:USERPROFILE '.claude\reboot-continue\state.json'
$runOnceKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
$valueName   = 'ClaudeRebootContinue'

function Out-Result([System.Collections.IDictionary]$r, [int]$code) {
    Write-Output ($r | ConvertTo-Json -Compress -Depth 5)
    exit $code
}

try {
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}

    $entry = $null
    try { $entry = (Get-ItemProperty -Path $runOnceKey -Name $valueName -ErrorAction Stop).$valueName } catch { $entry = $null }

    if ($Status) {
        $summary = $null
        foreach ($f in @($stateFile, $legacyState)) {
            if (-not (Test-Path -LiteralPath $f)) { continue }
            try {
                $s = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
                $summary = [ordered]@{ file = $f; workdir = [string]$s.workdir; sessionId = [string]$s.session_id; promptLength = ([string]$s.prompt).Length; createdAt = [string]$s.created_at }
            } catch { $summary = [ordered]@{ file = $f; unreadable = $true } }
            break
        }
        Out-Result ([ordered]@{
                ok = $true; code = 'STATUS'
                runOnce = $entry; resumeRegistered = [bool]$entry
                state = $summary; planPending = [bool](Test-Path -LiteralPath $planFile)
            }) 0
    }

    # shutdown /a: 0 = a pending shutdown was aborted, 1116 = none was in progress.
    # Through cmd so that shutdown's stderr never becomes a PowerShell error record.
    & cmd.exe /c 'shutdown.exe /a >nul 2>&1'
    $aborted = ($LASTEXITCODE -eq 0)

    $removedRunOnce = $false
    $runOnceError = $null
    if ($entry) {
        try { Remove-ItemProperty -Path $runOnceKey -Name $valueName -ErrorAction Stop; $removedRunOnce = $true }
        catch { $runOnceError = $_.Exception.Message }
    }

    $removedFiles = @()
    foreach ($f in @($stateFile, $planFile, $legacyState)) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force; $removedFiles += $f }
    }

    if ($runOnceError) {
        Out-Result ([ordered]@{ ok = $false; code = 'RUNONCE_NOT_REMOVED'; rebootAborted = $aborted; error = $runOnceError; message = 'The RunOnce value could not be removed; the resume may still fire at the next logon.' }) 1
    }
    $anything = $aborted -or $removedRunOnce -or ($removedFiles.Count -gt 0)
    Out-Result ([ordered]@{
            ok = $true; code = $(if ($anything) { 'CANCELLED' } else { 'NOTHING_PENDING' })
            rebootAborted = $aborted; runOnceRemoved = $removedRunOnce; filesRemoved = $removedFiles
            message = $(if ($anything) { 'Cancelled.' } else { 'Nothing was pending: no scheduled reboot, no RunOnce value, no saved state.' })
        }) 0
} catch {
    Write-Output (([ordered]@{ ok = $false; code = 'INTERNAL_ERROR'; message = $_.Exception.Message }) | ConvertTo-Json -Compress)
    exit 2
}
