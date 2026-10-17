#requires -Version 7.0
<#
.SYNOPSIS
  Finds earlier sessions by what was said in them. Read-only.

.DESCRIPTION
  -Query is split on whitespace; a session matches when EVERY term occurs, ignoring
  case, in its title, its folder (cwd) or the words of its messages. Rows rank by
  where the terms were found -- title over folder over message text -- then newest
  first. Only interactive transcripts from the last -Days days are searched:
  scheduled and SDK runs, sidecars and subagent files never are.

  Message text is what the user typed and the assistant wrote back, not tool
  output and not JSON keys. `rg` narrows the candidates first when it is on PATH,
  Select-String otherwise; both feed the same matcher (`prefilter` says which ran).
  The session running the search is left out: it holds the query itself.

  `snippet` (one line around the first message hit) and a title whose titleSource
  is "prompt" are message content: they are there to help the user pick a session.

  Prints one JSON object.
  code: SEARCH_RESULTS (an empty list when nothing matched) | EMPTY_QUERY | ALIAS_NOT_FOUND | PATH_NOT_FOUND
#>
[CmdletBinding()]
param(
    [string]$Query,
    [string]$Alias,
    [string]$Path,
    [int]$Days = 30,
    [int]$Top = 10
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\Core.State.ps1"

try {
    Initialize-KitState | Out-Null

    $terms = [System.Collections.Generic.List[string]]::new()
    foreach ($t in ($Query -split '\s+')) { if ($t -and -not ($terms -contains $t)) { $terms.Add($t) } }
    if ($terms.Count -eq 0) { Exit-WithResult ([ordered]@{ ok = $false; code = 'EMPTY_QUERY'; message = 'Give at least one search term.' }) }

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

    $candidates = @(Get-ClaudeSessions -Path $scope -Days $Days)

    # Prefilter: keep the transcripts whose raw text holds every term. On disk a term's
    # quotes and backslashes are JSON-escaped, so it is searched for in that form.
    $pool = [System.Collections.Generic.HashSet[string]]::new([string[]]@($candidates | ForEach-Object TranscriptPath), [StringComparer]::OrdinalIgnoreCase)
    # rg.exe only: an rg.cmd shim runs through cmd.exe, which re-parses the terms (see Test-ClaudeShim)
    $rg = Get-Command rg.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    foreach ($t in $terms) {
        if ($pool.Count -eq 0) { break }
        # pwsh 7.0-7.2 hand a native exe \" as a bare quote; the matcher still checks this term
        if ($rg -and $t.Contains('"')) { continue }
        $needle = $t.Replace('\', '\\').Replace('"', '\"')
        $hits = if ($rg) {
            # By folder, not by file list: a few hundred paths overflow a command line.
            # Depth 1 below a project folder is where transcripts live; subagents/ is deeper.
            # No user rg config, no ignore files, no binary skipping (a crash can leave NULs), junctions followed.
            $root, $depth = if ($scope) { (Get-ProjectTranscriptDir $scope), 1 } else { (Get-ClaudeProjectsDir), 2 }
            if (Test-Path -LiteralPath $root) {
                & $rg.Source --no-config --files-with-matches --fixed-strings --ignore-case --no-ignore --hidden --text --follow --max-depth $depth --glob '*.jsonl' -e $needle -- $root
            }
        } else {
            Select-String -LiteralPath @($pool) -SimpleMatch -Pattern $needle -List -ErrorAction SilentlyContinue | ForEach-Object Path
        }
        $pool.IntersectWith([string[]]@($hits | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_) }))
    }

    $aliased = @{}
    # decoration only: a broken aliases.json still fails -Alias above, but not a plain search
    foreach ($a in @(try { Get-AliasTable } catch { @() })) {
        try { $aliased[(ConvertTo-NormalizedPath $a.path).ToLowerInvariant()] = $a.name } catch {}
    }

    $ic = [StringComparison]::OrdinalIgnoreCase
    # the session running the search holds the query itself
    $self = if ($env:CLAUDE_CODE_SESSION_ID) { $env:CLAUDE_CODE_SESSION_ID } else { $env:CLAUDE_SESSION_ID }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $candidates) {
        # no recorded folder: nowhere to reopen it, so list-sessions leaves it out too
        if (-not $s.Cwd -or $s.SessionId -eq $self -or -not $pool.Contains($s.TranscriptPath)) { continue }
        $body = Search-TranscriptMessages -TranscriptPath $s.TranscriptPath -Terms $terms.ToArray()
        $in = [ordered]@{ title = @{}; cwd = @{}; body = @{} }   # field -> the terms found in it
        foreach ($t in $terms) {
            if ($s.Title -and $s.Title.IndexOf($t, $ic) -ge 0) { $in.title[$t] = $true }
            if ($s.Cwd -and $s.Cwd.IndexOf($t, $ic) -ge 0) { $in.cwd[$t] = $true }
        }
        foreach ($t in $body.Found) { $in.body[$t] = $true }

        # Each term counts once, by the best field it was found in: title 3, folder 2, body 1.
        $score = 0
        foreach ($t in $terms) {
            $w = if ($in.title[$t]) { 3 } elseif ($in.cwd[$t]) { 2 } elseif ($in.body[$t]) { 1 } else { 0 }
            if ($w -eq 0) { $score = 0; break }   # every term has to match somewhere
            $score += $w
        }
        if ($score -eq 0) { continue }
        $rows.Add([pscustomobject]@{
                sessionId = $s.SessionId; cwd = $s.Cwd; alias = $aliased[(ConvertTo-NormalizedPath $s.Cwd).ToLowerInvariant()]
                title = $s.Title; titleSource = $s.TitleSource; lastWrite = $s.LastWrite; score = $score
                matchedIn = @($in.Keys | Where-Object { $in[$_].Count -gt 0 }); snippet = $body.Snippet
            })
    }

    $sorted = @($rows | Sort-Object @{ Expression = 'score'; Descending = $true }, @{ Expression = 'lastWrite'; Descending = $true } |
            Select-Object -First $Top | ForEach-Object {
                [ordered]@{
                    sessionId = $_.sessionId; cwd = $_.cwd; alias = $_.alias; title = $_.title; titleSource = $_.titleSource
                    lastWrite = $_.lastWrite.ToString('yyyy-MM-dd HH:mm'); score = $_.score; matchedIn = $_.matchedIn; snippet = $_.snippet
                }
            })
    Exit-WithResult ([ordered]@{
            ok = $true; code = 'SEARCH_RESULTS'; terms = $terms.ToArray(); scope = $scope; days = $Days
            prefilter = $(if ($rg) { 'rg' } else { 'select-string' }); total = $rows.Count; sessions = $sorted
        })
} catch {
    Write-KitResult -Ok $false -Code 'INTERNAL_ERROR' -Message $_.Exception.Message
    exit 2
}
