#requires -Version 7.0
<#
.SYNOPSIS
  Reopens an earlier Claude Code session in a new terminal tab.

.DESCRIPTION
  -SessionId reopens that session (it must exist; an id is never guessed). Without
  it, the newest interactive session of the last -Days days is reopened: in the
  -Alias or -Path folder when one is given, anywhere otherwise. Sessions that are
  open right now, the asking one included, are skipped by that choice; an explicit
  -SessionId that is open is refused with ALREADY_RUNNING.

  The tab always opens in the folder RECORDED for the session. Scheduled and SDK
  transcripts are never candidates, and `claude --continue` is never used.

  Prints one JSON object.
  code: RESUMED | NO_RESUMABLE_SESSION | UNTRUSTED_WORKSPACE | TRUST_REFUSED | TRUST_WRITE_FAILED |
        ALREADY_RUNNING | ALIAS_NOT_FOUND | PATH_NOT_FOUND | CLAUDE_NOT_FOUND

.PARAMETER TrustFolder
  Marks the session's folder trusted in ~/.claude.json before opening, so no trust prompt
  appears and the folder's hooks, MCP servers and settings apply. Only when the user said so.
#>
[CmdletBinding()]
param(
    [string]$Alias,
    [string]$Path,
    [string]$SessionId,
    [int]$Days = 30,
    [switch]$TrustFolder
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\Core.Effects.ps1"

try {
    Initialize-KitState | Out-Null

    $where = Resolve-AliasOrPath -Alias $Alias -Path $Path -Suffix ' Nothing was opened.'
    if ($where.Refusal) { Exit-WithResult $where.Refusal }

    # Asked once: the choice skips open sessions, and the launch refuses one.
    $running = @(Get-RunningSessions)
    $target = Resolve-ResumeTarget -Path $where.Scope -SessionId $SessionId -Days $Days -RunningSessions $running
    if (-not $target.SessionId) {
        Exit-WithResult ([ordered]@{ ok = $false; code = 'NO_RESUMABLE_SESSION'; path = $where.Scope; alias = $where.Alias; message = $target.Reason })
    }

    $workDir = Resolve-WorkspacePath $target.Cwd
    if (-not $workDir) {
        Exit-WithResult ([ordered]@{ ok = $false; code = 'PATH_NOT_FOUND'; path = $target.Cwd; sessionId = $target.SessionId; message = 'The folder recorded for that session no longer exists. Nothing was opened.' })
    }

    $result = Invoke-SessionLaunch -WorkDir $workDir -Mode resume -SessionId $target.SessionId -Alias $where.Alias -TrustFolder:$TrustFolder -RunningSessions $running
    if ($target.Title) { $result['title'] = $target.Title }
    Exit-WithResult $result
} catch {
    Write-KitResult -Ok $false -Code 'INTERNAL_ERROR' -Message $_.Exception.Message
    exit 2
}
