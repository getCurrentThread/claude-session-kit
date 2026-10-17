#requires -Version 7.0
<#
.SYNOPSIS
  Lists sessions that resume-session.ps1 could reopen. Read-only.

.DESCRIPTION
  Registry entries first (sessions this kit opened), then interactive transcripts
  from the last -Days days, de-duplicated, newest first. Scheduled and SDK
  transcripts never appear. Message bodies are never read out, with one exception:
  a session the CLI recorded no title for is titled by the start of its first
  prompt (titleSource "prompt"; the others are "custom" for /rename or --name, and
  "ai"). A registered name stands in until the transcript records a title.

  retentionDays is how long Claude Code keeps transcripts (cleanupPeriodDays); at 30
  or less, `warning` says how to keep older ones.

  Prints one JSON object. code: SESSIONS | ALIAS_NOT_FOUND | PATH_NOT_FOUND
#>
[CmdletBinding()]
param(
    [string]$Alias,
    [string]$Path,
    [int]$Days = 30,
    [int]$Top = 15
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\Core.State.ps1"

try {
    Initialize-KitState | Out-Null

    if ($Alias) {
        $entry = Find-Alias -Name $Alias
        if (-not $entry) {
            Exit-WithResult ([ordered]@{ ok = $false; code = 'ALIAS_NOT_FOUND'; alias = $Alias; known = @(Get-AliasTable | ForEach-Object name); message = "Alias '$Alias' is not registered." })
        }
        $Path = $entry.path
    }
    $scope = $null
    if ($Path) {
        $scope = Resolve-WorkspacePath $Path
        if (-not $scope) { Exit-WithResult ([ordered]@{ ok = $false; code = 'PATH_NOT_FOUND'; path = $Path; message = 'That folder does not exist.' }) }
    }

    $seen = @{}
    $rows = [System.Collections.Generic.List[object]]::new()

    foreach ($r in @(Get-RegisteredSessions -Days $Days)) {
        if ($scope -and -not (Test-PathEqual $r.Cwd $scope)) { continue }
        if ($seen.ContainsKey($r.SessionId)) { continue }
        $t = Join-Path (Get-ProjectTranscriptDir $r.Cwd) ($r.SessionId + '.jsonl')
        if (-not (Test-Path -LiteralPath $t)) { continue }
        $rec = Get-ClaudeSessionRecord -TranscriptPath $t
        if ($rec.Kind -ne 'interactive') { continue }
        $seen[$r.SessionId] = $true
        # a custom title in the transcript (a later /rename) beats the name given at launch
        $title, $titleSource = if ($r.Name -and $rec.TitleSource -ne 'custom') { $r.Name, 'custom' } else { $rec.Title, $rec.TitleSource }
        $rows.Add([pscustomobject]@{ sessionId = $r.SessionId; cwd = $r.Cwd; alias = $r.Alias; title = $title; titleSource = $titleSource; lastWrite = $rec.LastWrite; source = 'registry' })
    }
    foreach ($s in @(Get-ClaudeSessions -Path $scope -Days $Days)) {
        if ($seen.ContainsKey($s.SessionId) -or -not $s.Cwd) { continue }
        $seen[$s.SessionId] = $true
        $rows.Add([pscustomobject]@{ sessionId = $s.SessionId; cwd = $s.Cwd; alias = $null; title = $s.Title; titleSource = $s.TitleSource; lastWrite = $s.LastWrite; source = 'scan' })
    }

    $running = @{}
    foreach ($r in @(Get-RunningSessions)) { $running[$r.SessionId] = $true }
    $sorted = @($rows | Sort-Object lastWrite -Descending | Select-Object -First $Top | ForEach-Object {
            [ordered]@{
                sessionId = $_.sessionId; cwd = $_.cwd; alias = $_.alias; title = $_.title; titleSource = $_.titleSource
                lastWrite = $_.lastWrite.ToString('yyyy-MM-dd HH:mm'); source = $_.source
                cwdExists = [bool](Test-Path -LiteralPath $_.cwd -PathType Container)
                running = $running.ContainsKey($_.sessionId)
            }
        })
    $result = [ordered]@{ ok = $true; code = 'SESSIONS'; scope = $scope; days = $Days; total = $rows.Count; sessions = $sorted }
    $retention = Get-TranscriptRetention
    $result.retentionDays = $retention.Days
    if ($retention.Days -le 30) {
        $result.warning = ("Claude Code deletes transcripts older than {0} days, and a deleted session can no longer be listed, searched or resumed. " +
            "To keep them, raise cleanupPeriodDays in {1} to a large value such as 3650 (never 0: rejected since v2.1.89, and older versions took it as 'save no transcripts'), " +
            'or back them up with archive-sessions.ps1.') -f $retention.Days, (Join-Path (Get-ClaudeHome) 'settings.json')
    }
    Exit-WithResult $result
} catch {
    Write-KitResult -Ok $false -Code 'INTERNAL_ERROR' -Message $_.Exception.Message
    exit 2
}
