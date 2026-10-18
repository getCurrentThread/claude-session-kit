#requires -Version 7.0
<#
.SYNOPSIS
  Reopens an earlier Claude Code session in a new terminal tab.

.DESCRIPTION
  Picks the session in this order and stops at the first hit:
    1. -SessionId, when given (it must exist; an id is never guessed)
    2. the launcher registry -- sessions this kit opened, newest first
    3. a scan of interactive transcripts from the last -Days days
    4. the CLI's own picker, opened in the folder (needs -Alias or -Path)

  With -Alias or -Path the search is limited to that folder; without either it
  spans every folder, and step 4 is unavailable. Steps 2 and 3 skip sessions that
  are open right now, the asking one included (not with -Fork); an explicit
  -SessionId that is open is refused with ALREADY_RUNNING.

  The tab always opens in the folder RECORDED for the session. Scheduled and SDK
  transcripts are never candidates, and `claude --continue` is never used.

  While the plugin's hook still holds a record for the session (one that was not
  ended on purpose), the permission mode it was started with is replayed
  (`permissionMode`); bypassPermissions never is (`droppedPermissionMode`).

  Prints one JSON object.
  code: RESUMED | PICKER_OPENED (each with an _UNTRUSTED suffix after -AllowUntrusted, when the
        tab is on the trust prompt) | NO_RESUMABLE_SESSION | UNTRUSTED_WORKSPACE |
        ALREADY_RUNNING | ALIAS_NOT_FOUND | PATH_NOT_FOUND | CLAUDE_NOT_FOUND

.PARAMETER Fork
  Resume into a copy (--fork-session) and leave the original untouched. Not the
  default: a silent fork makes "the latest session" point at the copy next time.
  The copy gets a new id (sessionId; forkedFrom names the original) and is recorded
  like any launch -- except a fork from the CLI's picker, whose id only the CLI knows.
#>
[CmdletBinding()]
param(
    [string]$Alias,
    [string]$Path,
    [string]$SessionId,
    [int]$Days = 30,
    [switch]$Fork,
    [switch]$NoPicker,
    [switch]$AllowUntrusted
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\Core.Effects.ps1"

try {
    Initialize-KitState | Out-Null

    $aliasName = $null
    if ($Alias) {
        $entry = Find-Alias -Name $Alias
        if (-not $entry) {
            Exit-WithResult ([ordered]@{ ok = $false; code = 'ALIAS_NOT_FOUND'; alias = $Alias; known = @(Get-AliasTable | ForEach-Object name); message = "Alias '$Alias' is not registered. Nothing was opened." })
        }
        $aliasName = $entry.name
        $Path = $entry.path
    }

    $scope = $null
    if ($Path) {
        $scope = Resolve-WorkspacePath $Path
        if (-not $scope) {
            Exit-WithResult ([ordered]@{ ok = $false; code = 'PATH_NOT_FOUND'; path = $Path; alias = $aliasName; message = 'That folder does not exist. Nothing was opened.' })
        }
    }

    # Asked once: the ladder skips open sessions, and the launch refuses one. A fork
    # skips nothing: forking an open session is what -Fork is for.
    $running = @(Get-RunningSessions)
    $target = Resolve-ResumeTarget -Path $scope -SessionId $SessionId -Days $Days -AllowPicker:(-not $NoPicker) -RunningSessions $running -IncludeOpen:$Fork
    if ($target.Mode -eq 'none') {
        Exit-WithResult ([ordered]@{ ok = $false; code = 'NO_RESUMABLE_SESSION'; path = $scope; alias = $aliasName; retentionDays = (Get-TranscriptRetention).Days; message = $target.Reason })
    }

    $workDir = Resolve-WorkspacePath $target.Cwd
    if (-not $workDir) {
        Exit-WithResult ([ordered]@{ ok = $false; code = 'PATH_NOT_FOUND'; path = $target.Cwd; sessionId = $target.SessionId; message = 'The folder recorded for that session no longer exists. Nothing was opened.' })
    }

    $mode = if ($target.Mode -eq 'picker') { 'picker' } else { 'resume' }
    # The mode the session was started with, as track-session.ps1 recorded it -- replayed
    # only when replayable. The kit never picks a mode of its own.
    $recorded = if ($target.SessionId) { @(Get-OpenSessionRecords) | Where-Object { $_.SessionId -eq $target.SessionId } | Select-Object -First 1 }
    $startMode = if ($recorded -and $recorded.PermissionMode) { $recorded.PermissionMode } else { $null }
    $replay = if ($startMode -cin $script:ReplayablePermissionModes) { $startMode } else { $null }
    $result = Invoke-SessionLaunch -WorkDir $workDir -Mode $mode -SessionId $target.SessionId -Alias $aliasName -Source resume -PermissionMode $replay -Fork:$Fork -AllowUntrusted:$AllowUntrusted -RunningSessions $running
    $result['chosenFrom'] = $target.Source
    if ($target.Title) { $result['title'] = $target.Title }
    if ($replay) { $result['permissionMode'] = $replay }
    if ($startMode -and -not $replay) { $result['droppedPermissionMode'] = $startMode }
    Exit-WithResult $result
} catch {
    Write-KitResult -Ok $false -Code 'INTERNAL_ERROR' -Message $_.Exception.Message
    exit 2
}
