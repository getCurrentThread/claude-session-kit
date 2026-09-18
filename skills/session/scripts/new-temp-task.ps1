#requires -Version 7.0
<#
.SYNOPSIS
  Creates the next scratch folder (<root>\<prefix><N>) and opens a new Claude Code session in it.

.DESCRIPTION
  Root and prefix default to %USERPROFILE%\Downloads and "test"; override them with a
  "tempTask": { "root": "...", "prefix": "..." } block in aliases.json.

  N is one more than the highest number seen ON DISK OR IN TRANSCRIPT HISTORY. A
  folder that was deleted still owns its project history under ~/.claude/projects,
  and reusing its number would drop the new session into that old history.

  Prints one JSON object. code: LAUNCHED | LAUNCHED_UNTRUSTED (-AllowUntrusted, the tab is on the
  trust prompt) | UNTRUSTED_WORKSPACE | PATH_NOT_FOUND | CLAUDE_NOT_FOUND

.PARAMETER AllowUntrusted
  Only after the user has been told the folder is untrusted and said to go ahead.
#>
[CmdletBinding()]
param(
    [switch]$AllowUntrusted
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\Core.Effects.ps1"

try {
    Initialize-KitState | Out-Null
    $settings = Get-TempTaskSettings
    $root = Resolve-WorkspacePath $settings.Root
    if (-not $root) {
        Exit-WithResult ([ordered]@{ ok = $false; code = 'PATH_NOT_FOUND'; path = $settings.Root; message = 'The scratch root folder does not exist.' })
    }

    # Checked BEFORE the folder is created: a fresh folder is never a repository, so
    # its trust is whatever it inherits from the root -- and refusing afterwards
    # would leave an empty folder behind on every refusal.
    if (-not $AllowUntrusted -and -not (Test-WorkspaceTrusted -Path $root)) {
        Exit-WithResult ([ordered]@{
                ok = $false; code = 'UNTRUSTED_WORKSPACE'; path = $root
                trustKey = (Get-TrustKey -Path $root); isRepo = [bool](Get-GitRootOrNull -Path $root)
                message = 'The scratch root is not trusted in Claude Code. No folder was created and no session was started.'
            })
    }

    $disk = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
    $history = @(Get-ChildItem -LiteralPath (Get-ClaudeProjectsDir) -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
    $next = Get-NextTempIndex -Prefix $settings.Prefix -DiskNames $disk -HistorySlugs $history -RootSlug (ConvertTo-ProjectSlug $root)

    # New-Item is the atomic step: if another launch took the name first, move on.
    $newDir = $null
    for ($try = 0; $try -lt 50 -and -not $newDir; $try++) {
        $candidate = Join-Path $root ($settings.Prefix + $next)
        try {
            if (Test-Path -LiteralPath $candidate) { throw [IO.IOException]::new('exists') }
            New-Item -ItemType Directory -Path $candidate -ErrorAction Stop | Out-Null
            $newDir = $candidate
        } catch [IO.IOException] { $next++ }
    }
    if (-not $newDir) { throw "Could not create a scratch folder under $root." }

    Exit-WithResult (Invoke-SessionLaunch -WorkDir $newDir -Mode new -Source new -AllowUntrusted:$AllowUntrusted)
} catch {
    Write-KitResult -Ok $false -Code 'INTERNAL_ERROR' -Message $_.Exception.Message
    exit 2
}
