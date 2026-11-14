#requires -Version 7.0
<#
.SYNOPSIS
  Lists sessions that resume-session.ps1 could reopen. Read-only.

.DESCRIPTION
  Interactive transcripts from the last -Days days, newest first, in the -Alias or
  -Path folder when one is given. Scheduled and SDK transcripts never appear.
  Message bodies are never read out, with one exception: a session with no name
  (/rename, --name) and no summary of the CLI's own is titled by the start of its
  first prompt.

  Per row: sessionId, cwd, alias (when the folder is a registered one), title,
  lastWrite, source (registry: this kit opened it, so resume-session.ps1 prefers it;
  scan: any other), cwdExists, running (open right now).

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

    $where = Resolve-AliasOrPath -Alias $Alias -Path $Path
    if ($where.Refusal) { Exit-WithResult $where.Refusal }

    $aliased = @{}
    # decoration only: a broken aliases.json still fails -Alias above, but not a plain list
    foreach ($a in @(try { Get-AliasTable } catch { @() })) {
        try { $aliased[(ConvertTo-NormalizedPath $a.path).ToLowerInvariant()] = $a.name } catch {}
    }
    $running = @{}
    foreach ($r in @(Get-RunningSessions)) { $running[$r.SessionId] = $true }
    $kit = @{}
    foreach ($r in @(Get-RegisteredSessions -Days $Days)) { $kit[$r.SessionId] = $true }

    # no recorded folder: nowhere to reopen it
    $all = @(Get-ClaudeSessions -Path $where.Scope -Days $Days | Where-Object Cwd)
    $rows = @($all | Select-Object -First $Top | ForEach-Object {
            [ordered]@{
                sessionId = $_.SessionId; cwd = $_.Cwd; alias = $aliased[(ConvertTo-NormalizedPath $_.Cwd).ToLowerInvariant()]
                title = $_.Title; lastWrite = $_.LastWrite.ToString('yyyy-MM-dd HH:mm')
                source = $(if ($kit.ContainsKey($_.SessionId)) { 'registry' } else { 'scan' })
                cwdExists = [bool](Test-Path -LiteralPath $_.Cwd -PathType Container)
                running = $running.ContainsKey($_.SessionId)
            }
        })
    Exit-WithResult ([ordered]@{ ok = $true; code = 'SESSIONS'; scope = $where.Scope; days = $Days; total = $all.Count; sessions = $rows })
} catch {
    Write-KitResult -Ok $false -Code 'INTERNAL_ERROR' -Message $_.Exception.Message
    exit 2
}
