#requires -Version 7.0
<#
.SYNOPSIS
  Prints the alias table (aliases.json) for the model to read. Read-only.

.DESCRIPTION
  The table is personal -- folder paths, the phrases that mean each folder, and
  notes on what an ambiguous mention should do -- so it lives in
  ~/.claude/claude-session-kit/aliases.json and never in SKILL.md.

  Per alias: name, path, exists, triggers[], note, confirm.
    triggers  phrases that select this alias
    note      free text: how to treat an ambiguous or bare mention
    confirm   true = ask the user before opening, even on a match

  Prints one JSON object. code: ALIASES | NO_ALIASES | ALIASES_UNREADABLE
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\Core.State.ps1"

try {
    Initialize-KitState | Out-Null
    $file = Get-KitPath aliases
    if (-not (Test-Path -LiteralPath $file)) {
        Exit-WithResult ([ordered]@{
                ok = $true; code = 'NO_ALIASES'; file = $file; aliases = @()
                message = 'No alias file yet. Create it from examples/aliases.example.json, or add the first alias.'
            })
    }
    try { $table = @(Get-AliasTable) } catch {
        Exit-WithResult ([ordered]@{ ok = $false; code = 'ALIASES_UNREADABLE'; file = $file; message = $_.Exception.Message })
    }
    $settings = Get-TempTaskSettings
    $rows = @($table | ForEach-Object {
            [ordered]@{
                name = $_.name; path = $_.path
                exists = [bool](Test-Path -LiteralPath $_.path -PathType Container)
                triggers = @($_.triggers); note = $_.note; confirm = $_.confirm
            }
        })
    Exit-WithResult ([ordered]@{
            ok = $true; code = 'ALIASES'; file = $file; count = $rows.Count; aliases = $rows
            tempTask = [ordered]@{ root = $settings.Root; prefix = $settings.Prefix }
        })
} catch {
    Write-KitResult -Ok $false -Code 'INTERNAL_ERROR' -Message $_.Exception.Message
    exit 2
}
