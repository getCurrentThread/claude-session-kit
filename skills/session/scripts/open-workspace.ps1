#requires -Version 7.0
<#
.SYNOPSIS
  Opens a NEW Claude Code session in a registered alias folder or an explicit path.

.DESCRIPTION
  An alias that is not in aliases.json is an error -- no other folder is ever
  guessed. Prints one JSON object.
  code: LAUNCHED | LAUNCHED_UNTRUSTED (-AllowUntrusted, the tab is on the trust prompt) |
        UNTRUSTED_WORKSPACE | TRUST_REFUSED | TRUST_WRITE_FAILED | ALIAS_NOT_FOUND | NO_ALIASES |
        PATH_NOT_FOUND | CLAUDE_NOT_FOUND | INVALID_NAME

.PARAMETER Name
  A display name for the session (`claude --name`): the tab title, the CLI's /resume
  picker and list-sessions.ps1 all show it. Only when the user named the session.

.PARAMETER AllowUntrusted
  Only after the user has been told the folder is untrusted and said to go ahead.

.PARAMETER TrustFolder
  Marks the folder trusted in ~/.claude.json before opening, so no trust prompt appears
  and the folder's hooks, MCP servers and settings apply. Only when the user said so.
#>
[CmdletBinding(DefaultParameterSetName = 'Alias')]
param(
    [Parameter(ParameterSetName = 'Alias', Mandatory)][string]$Alias,
    [Parameter(ParameterSetName = 'Path', Mandatory)][string]$Path,
    [string]$Name,
    [switch]$AllowUntrusted,
    [switch]$TrustFolder
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\Core.Effects.ps1"

try {
    Initialize-KitState | Out-Null

    $aliasName = $null
    if ($PSCmdlet.ParameterSetName -eq 'Alias') {
        $table = @(Get-AliasTable)
        if ($table.Count -eq 0) {
            Exit-WithResult ([ordered]@{ ok = $false; code = 'NO_ALIASES'; file = (Get-KitPath aliases); message = 'No aliases are registered yet.' })
        }
        $entry = $table | Where-Object { $_.name -eq $Alias } | Select-Object -First 1
        if (-not $entry) {
            Exit-WithResult ([ordered]@{ ok = $false; code = 'ALIAS_NOT_FOUND'; alias = $Alias; known = @($table | ForEach-Object name); message = "Alias '$Alias' is not registered. Nothing was opened." })
        }
        $aliasName = $entry.name
        $Path = $entry.path
    }

    $workDir = Resolve-WorkspacePath $Path
    if (-not $workDir) {
        Exit-WithResult ([ordered]@{ ok = $false; code = 'PATH_NOT_FOUND'; path = $Path; alias = $aliasName; message = 'That folder does not exist. Nothing was opened.' })
    }

    Exit-WithResult (Invoke-SessionLaunch -WorkDir $workDir -Mode new -Alias $aliasName -Source open -Name $Name -AllowUntrusted:$AllowUntrusted -TrustFolder:$TrustFolder)
} catch {
    Write-KitResult -Ok $false -Code 'INTERNAL_ERROR' -Message $_.Exception.Message
    exit 2
}
