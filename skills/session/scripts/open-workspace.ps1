#requires -Version 7.0
<#
.SYNOPSIS
  Opens a NEW Claude Code session in a registered alias folder or an explicit path.

.DESCRIPTION
  An alias that is not in aliases.json is an error -- no other folder is ever
  guessed. Prints one JSON object.
  code: LAUNCHED | UNTRUSTED_WORKSPACE | TRUST_REFUSED | TRUST_WRITE_FAILED | ALIAS_NOT_FOUND | NO_ALIASES |
        PATH_NOT_FOUND | CLAUDE_NOT_FOUND | INVALID_NAME

.PARAMETER Name
  A display name for the session (`claude --name`): the tab title, the CLI's /resume
  picker and list-sessions.ps1 all show it. Only when the user named the session.

.PARAMETER TrustFolder
  Marks the folder trusted in ~/.claude.json before opening, so no trust prompt appears
  and the folder's hooks, MCP servers and settings apply. Only when the user said so.
#>
[CmdletBinding(DefaultParameterSetName = 'Alias')]
param(
    [Parameter(ParameterSetName = 'Alias', Mandatory)][string]$Alias,
    [Parameter(ParameterSetName = 'Path', Mandatory)][string]$Path,
    [string]$Name,
    [switch]$TrustFolder
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\Core.Effects.ps1"

try {
    Initialize-KitState | Out-Null

    if ($Alias -and @(Get-AliasTable).Count -eq 0) {
        Exit-WithResult ([ordered]@{ ok = $false; code = 'NO_ALIASES'; file = (Get-KitPath aliases); message = 'No aliases are registered yet.' })
    }
    $where = Resolve-AliasOrPath -Alias $Alias -Path $Path -Suffix ' Nothing was opened.'
    if ($where.Refusal) { Exit-WithResult $where.Refusal }

    Exit-WithResult (Invoke-SessionLaunch -WorkDir $where.Scope -Mode new -Alias $where.Alias -Source open -Name $Name -TrustFolder:$TrustFolder)
} catch {
    Write-KitResult -Ok $false -Code 'INTERNAL_ERROR' -Message $_.Exception.Message
    exit 2
}
