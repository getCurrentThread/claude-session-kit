#requires -Version 7.0
<#
.SYNOPSIS
  Lists sessions that resume-session.ps1 could reopen. Read-only.

.DESCRIPTION
  Registry entries first (sessions this kit opened), then interactive transcripts
  from the last -Days days, de-duplicated, newest first. Scheduled and SDK
  transcripts never appear. Titles are whatever the CLI recorded; message bodies
  are never read out.

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
        $rows.Add([pscustomobject]@{ sessionId = $r.SessionId; cwd = $r.Cwd; alias = $r.Alias; title = $rec.Title; lastWrite = $rec.LastWrite; source = 'registry' })
    }
    foreach ($s in @(Get-ClaudeSessions -Path $scope -Days $Days)) {
        if ($seen.ContainsKey($s.SessionId) -or -not $s.Cwd) { continue }
        $seen[$s.SessionId] = $true
        $rows.Add([pscustomobject]@{ sessionId = $s.SessionId; cwd = $s.Cwd; alias = $null; title = $s.Title; lastWrite = $s.LastWrite; source = 'scan' })
    }

    $sorted = @($rows | Sort-Object lastWrite -Descending | Select-Object -First $Top | ForEach-Object {
            [ordered]@{
                sessionId = $_.sessionId; cwd = $_.cwd; alias = $_.alias; title = $_.title
                lastWrite = $_.lastWrite.ToString('yyyy-MM-dd HH:mm'); source = $_.source
                cwdExists = [bool](Test-Path -LiteralPath $_.cwd -PathType Container)
            }
        })
    Exit-WithResult ([ordered]@{ ok = $true; code = 'SESSIONS'; scope = $scope; days = $Days; total = $rows.Count; sessions = $sorted })
} catch {
    Write-KitResult -Ok $false -Code 'INTERNAL_ERROR' -Message $_.Exception.Message
    exit 2
}
