#requires -Version 7.0
<#
.SYNOPSIS
  Opens a NEW Claude Code session in a registered alias folder or an explicit path.

.DESCRIPTION
  An alias that is not in aliases.json is an error -- no other folder is ever
  guessed. Prints one JSON object.
  code: LAUNCHED | UNTRUSTED_WORKSPACE | ALIAS_NOT_FOUND | NO_ALIASES | PATH_NOT_FOUND | CLAUDE_NOT_FOUND

.PARAMETER AllowUntrusted
  Only after the user has been told the folder is untrusted and said to go ahead.
#>
[CmdletBinding(DefaultParameterSetName = 'Alias')]
param(
    [Parameter(ParameterSetName = 'Alias', Mandatory)][string]$Alias,
    [Parameter(ParameterSetName = 'Path', Mandatory)][string]$Path,
    [switch]$AllowUntrusted
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

    Exit-WithResult (Invoke-SessionLaunch -WorkDir $workDir -Mode new -Alias $aliasName -Source open -AllowUntrusted:$AllowUntrusted)
} catch {
    Write-KitResult -Ok $false -Code 'INTERNAL_ERROR' -Message $_.Exception.Message
    exit 2
}
