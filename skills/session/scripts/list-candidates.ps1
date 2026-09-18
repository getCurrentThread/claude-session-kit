#requires -Version 7.0
<#
.SYNOPSIS
  Shows the folders Claude Code is used in most, to help pick new aliases. Read-only.

.DESCRIPTION
  Folders come from the "cwd" recorded inside interactive transcripts -- never
  from decoding project folder names, which is not reversible. Temp and system
  folders are left out.

  Prints one JSON object. code: CANDIDATES
#>
[CmdletBinding()]
param(
    [int]$Days = 90,
    [int]$Top = 20,
    # Temp folders are left out by default; the test suite lives in one.
    [switch]$IncludeTemp
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\Core.State.ps1"

try {
    Initialize-KitState | Out-Null

    $exclude = @(
        [regex]'(?i)\\AppData\\Local\\Temp(\\|$)',
        [regex]'(?i)^[A-Z]:\\Windows(\\|$)',
        [regex]'(?i)^[A-Z]:\\Program Files( \(x86\))?(\\|$)'
    )
    $aliased = @{}
    foreach ($a in @(Get-AliasTable)) {
        try { $aliased[(ConvertTo-NormalizedPath $a.path).ToLowerInvariant()] = $a.name } catch {}
    }

    $groups = @{}
    foreach ($s in @(Get-ClaudeSessions -Days $Days)) {
        if (-not $s.Cwd) { continue }
        $skip = $false
        foreach ($rx in $exclude) { if ($rx.IsMatch($s.Cwd)) { $skip = $true; break } }
        if ($IncludeTemp -and $exclude[0].IsMatch($s.Cwd)) { $skip = $false }
        if ($skip) { continue }
        $key = (ConvertTo-NormalizedPath $s.Cwd).ToLowerInvariant()
        if (-not $groups.ContainsKey($key)) { $groups[$key] = [pscustomobject]@{ Path = $s.Cwd; Count = 0; Last = [datetime]::MinValue } }
        $groups[$key].Count++
        if ($s.LastWrite -gt $groups[$key].Last) { $groups[$key].Last = $s.LastWrite }
    }

    $rows = @($groups.GetEnumerator() | Sort-Object { $_.Value.Count } -Descending | Select-Object -First $Top | ForEach-Object {
            [ordered]@{
                path = $_.Value.Path; sessions = $_.Value.Count; last = $_.Value.Last.ToString('yyyy-MM-dd')
                alias = $aliased[$_.Key]
                exists = [bool](Test-Path -LiteralPath $_.Value.Path -PathType Container)
            }
        })
    Exit-WithResult ([ordered]@{ ok = $true; code = 'CANDIDATES'; days = $Days; candidates = $rows })
} catch {
    Write-KitResult -Ok $false -Code 'INTERNAL_ERROR' -Message $_.Exception.Message
    exit 2
}
