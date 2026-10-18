#requires -Version 7.0
<#
.SYNOPSIS
  Reopens the sessions that were open before a crash, a closed window or a power cut.

.DESCRIPTION
  The candidates are the records track-session.ps1 (the plugin's SessionStart /
  SessionEnd hook) left behind: interactive sessions that started and were never ended
  on purpose. A candidate is not running now, and its transcript exists and is an
  interactive one. Newest first, numbered 1..n.

    (default) / -List   list the candidates; opens nothing
    -All / -Ids 1,3     reopen each in its own tab, in the folder recorded for it
    -Forget 2,4         drop those records without opening anything
    -ForgetAll          drop every candidate's record

  -Ids and -Forget take row numbers or the rows' sessionId values. An id always means
  the same session; a number only means the row it had in the list it came from.

  Every mode prunes records that can never be reopened: the transcript is gone, or it
  is not an interactive conversation. A reopened session gets back the permission mode
  it was started with when that mode is replayable; bypassPermissions never is, and
  is reported as droppedPermissionMode.

  Prints one JSON object.
  code: OPEN_SESSIONS | NOTHING_TO_RESTORE | RESTORED | NOT_RESTORED | FORGOTTEN |
        NOT_IN_LIST | CONFLICTING_OPTIONS
  RESTORED / NOT_RESTORED carry `results`, one per session, each with its own code:
        RESUMED (RESUMED_UNTRUSTED after -AllowUntrusted) | UNTRUSTED_WORKSPACE |
        PATH_NOT_FOUND | ALREADY_RUNNING | CLAUDE_NOT_FOUND | INTERNAL_ERROR
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$List,
    [switch]$All,
    # Text, not [int[]]: pwsh -File hands "-Ids 1,3" over as the one string '1,3',
    # which an [int[]] parameter reads as 13.
    [string[]]$Ids,
    [string[]]$Forget,
    [switch]$ForgetAll,
    [switch]$AllowUntrusted
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\Core.Effects.ps1"

try {
    Initialize-KitState | Out-Null

    $actions = @('List', 'All', 'Ids', 'Forget', 'ForgetAll' | Where-Object { $PSBoundParameters.ContainsKey($_) })
    if ($actions.Count -gt 1) {
        Exit-WithResult ([ordered]@{ ok = $false; code = 'CONFLICTING_OPTIONS'; options = $actions; message = 'Use one of -List, -All, -Ids, -Forget or -ForgetAll. Nothing was opened or forgotten.' })
    }

    $runningRows = @(Get-RunningSessions)
    $running = @{}
    foreach ($r in $runningRows) { $running[$r.SessionId] = $true }
    # The asking session is open whatever the CLI could tell us.
    if ($env:CLAUDE_CODE_SESSION_ID) { $running[$env:CLAUDE_CODE_SESSION_ID] = $true }

    $pruned = 0
    $found = [System.Collections.Generic.List[object]]::new()
    foreach ($rec in @(Get-OpenSessionRecords)) {
        if ($running.ContainsKey($rec.SessionId)) { continue }
        # The transcript is the one the hook was told about, and its name must be the id.
        # /cd and worktree moves fire no SessionStart, so a moved one is looked up by id.
        $t = $rec.TranscriptPath
        if (-not ($t -and [IO.Path]::GetFileName($t) -eq ($rec.SessionId + '.jsonl') -and (Test-Path -LiteralPath $t -PathType Leaf))) {
            $t = Find-SessionTranscript -SessionId $rec.SessionId
        }
        $info = if ($t) { Get-ClaudeSessionRecord -TranscriptPath $t }
        if ($info -and $info.Kind -eq 'unreadable') { continue }   # locked for now; ask again later
        if (-not $info -or $info.Kind -ne 'interactive') {
            Remove-OpenSessionRecord -SessionId $rec.SessionId
            $pruned++; continue
        }
        $found.Add([pscustomobject]@{
                # The transcript's own folder, as resume-session and reboot-plan use: the hook
                # rewrites cwd on every compact, after a `cd` or a move into a worktree.
                SessionId = $rec.SessionId; Cwd = $(if ($info.Cwd) { $info.Cwd } else { $rec.Cwd }); Title = $info.Title; LastWrite = $info.LastWrite
                PermissionMode = $(if ($rec.PermissionMode) { $rec.PermissionMode } else { $null })
            })
    }
    $candidates = @($found | Sort-Object LastWrite -Descending)
    $rows = @(for ($i = 0; $i -lt $candidates.Count; $i++) {
            $c = $candidates[$i]
            [ordered]@{
                n = $i + 1; sessionId = $c.SessionId; title = $c.Title; cwd = $c.Cwd
                cwdExists = [bool]($c.Cwd -and (Test-Path -LiteralPath $c.Cwd -PathType Container))
                lastWrite = $c.LastWrite.ToString('yyyy-MM-dd HH:mm'); permissionMode = $c.PermissionMode
            }
        })

    if ($candidates.Count -eq 0) {
        Exit-WithResult ([ordered]@{ ok = $true; code = 'NOTHING_TO_RESTORE'; pruned = $pruned; message = 'No session was left open by a crash or a closed window. Nothing was opened.' })
    }
    if (-not ($All -or $ForgetAll -or $PSBoundParameters.ContainsKey('Ids') -or $PSBoundParameters.ContainsKey('Forget'))) {
        Exit-WithResult ([ordered]@{ ok = $true; code = 'OPEN_SESSIONS'; count = $rows.Count; pruned = $pruned; sessions = $rows })
    }

    # Chosen rows, first mention first, by number or by sessionId; anything that is not in
    # the current list stops everything.
    $pick = 1..$candidates.Count
    if (-not ($All -or $ForgetAll)) {
        $row = @{}
        for ($i = 0; $i -lt $candidates.Count; $i++) { $row[[string]($i + 1)] = $i + 1; $row[$candidates[$i].SessionId] = $i + 1 }
        $asked = @(@($Ids) + @($Forget) | ForEach-Object { "$_" -split '[,\s]+' } | Where-Object { $_ })
        $bad = @($asked | Where-Object { -not $row.ContainsKey($_) })
        if ($bad.Count -or -not $asked) {
            Exit-WithResult ([ordered]@{ ok = $false; code = 'NOT_IN_LIST'; notInList = $bad; count = $candidates.Count; sessions = $rows; message = 'Those rows are not in the current list. Nothing was opened or forgotten; pick again from this list.' })
        }
        $pick = @($asked | ForEach-Object { $row[$_] } | Select-Object -Unique)
    }

    if ($ForgetAll -or $PSBoundParameters.ContainsKey('Forget')) {
        $gone = @(foreach ($n in $pick) {
                $c = $candidates[$n - 1]
                Remove-OpenSessionRecord -SessionId $c.SessionId
                [ordered]@{ n = $n; sessionId = $c.SessionId; title = $c.Title }
            })
        Exit-WithResult ([ordered]@{ ok = $true; code = 'FORGOTTEN'; forgotten = $gone; remaining = $candidates.Count - $gone.Count; message = 'Those sessions will no longer be offered for restore. Nothing was opened.' })
    }

    $results = @(foreach ($n in $pick) {
            $c = $candidates[$n - 1]
            # Only a mode the person started that session with, and only a replayable one.
            $replay = if ($c.PermissionMode -cin $script:ReplayablePermissionModes) { $c.PermissionMode } else { $null }
            $r = [ordered]@{ n = $n; sessionId = $c.SessionId; title = $c.Title }
            try {
                $workDir = Resolve-WorkspacePath $c.Cwd
                $launch = if ($workDir) {
                    Invoke-SessionLaunch -WorkDir $workDir -Mode resume -SessionId $c.SessionId -Source resume -PermissionMode $replay -AllowUntrusted:$AllowUntrusted -RunningSessions $runningRows
                } else {
                    [ordered]@{ ok = $false; code = 'PATH_NOT_FOUND'; path = $c.Cwd; message = 'The folder recorded for that session no longer exists. Nothing was opened.' }
                }
            } catch {
                $launch = [ordered]@{ ok = $false; code = 'INTERNAL_ERROR'; message = $_.Exception.Message }
            }
            foreach ($k in $launch.Keys) { $r[$k] = $launch[$k] }
            $r['permissionMode'] = $replay
            if ($c.PermissionMode -and -not $replay) { $r['droppedPermissionMode'] = $c.PermissionMode }
            $r
        })
    $opened = @($results | Where-Object { $_['ok'] }).Count
    Exit-WithResult ([ordered]@{
            ok = ($opened -gt 0); code = $(if ($opened) { 'RESTORED' } else { 'NOT_RESTORED' })
            opened = $opened; requested = $results.Count; results = $results
            message = "$opened of $($results.Count) sessions were reopened; each result says what happened to that one."
        })
} catch {
    Write-KitResult -Ok $false -Code 'INTERNAL_ERROR' -Message $_.Exception.Message
    exit 2
}
