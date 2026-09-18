# Core.Effects.ps1 -- the only file in lib/ that starts a process.
#
# Loaded by the scripts that open a terminal tab and by nothing else. The reboot
# path never dot-sources it: reboot-plan.ps1 renders and records, and the two
# things that actually change the machine (the RunOnce value and `shutdown`) live
# in reboot-commit.ps1 alone. tests/run-tests.ps1 enforces both halves.

Set-StrictMode -Version Latest

. "$PSScriptRoot\Core.State.ps1"

# Bring the terminal forward. A tab opened with `wt -w 0 nt` joins an existing
# window without raising it, so a session waiting on a prompt can sit unnoticed
# behind other windows. Best effort: Windows may refuse the focus change, and a
# failure here must never take the launch down with it.
function Show-TerminalWindow {
    try {
        $wt = Get-Process -Name 'WindowsTerminal' -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 } |
            Sort-Object StartTime -Descending |
            Select-Object -First 1
        if (-not $wt) { return }
        (New-Object -ComObject WScript.Shell).AppActivate($wt.Id) | Out-Null
    } catch {
        # focus is a convenience, never a precondition
    }
}

function Start-ClaudeTerminal {
    param(
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)][string]$ClaudeExe,
        [string[]]$ClaudeArgs = @()
    )
    $wt = Resolve-WindowsTerminal
    if ($wt) {
        $wtArgs = New-WtArgumentList -WorkDir $WorkDir -Exe $ClaudeExe -Arguments $ClaudeArgs -Window '0'
        & $wt @wtArgs
        Show-TerminalWindow
        return 'wt'
    }
    # No Windows Terminal: a plain console window. -WorkingDirectory instead of an
    # interpolated `Set-Location "<path>"`, which a quote or '$' in the path breaks.
    Start-Process -FilePath $ClaudeExe -ArgumentList @($ClaudeArgs | ForEach-Object { ConvertTo-QuotedArgument $_ }) -WorkingDirectory $WorkDir
    return 'console'
}

# The one entry point behind new-temp-task / open-workspace / resume-session.
# Checks trust, mints or reuses a session id, opens the tab, records the session.
# Returns the hashtable to print; never throws for an expected refusal.
function Invoke-SessionLaunch {
    param(
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)][ValidateSet('new', 'resume', 'picker')][string]$Mode,
        [string]$SessionId,
        [string]$Alias,
        [ValidateSet('new', 'open', 'resume')][string]$Source = 'open',
        [switch]$Fork,
        [switch]$AllowUntrusted
    )

    if (-not $AllowUntrusted -and -not (Test-WorkspaceTrusted -Path $WorkDir)) {
        return [ordered]@{
            ok = $false; code = 'UNTRUSTED_WORKSPACE'; path = $WorkDir
            trustKey = (Get-TrustKey -Path $WorkDir)
            isRepo = [bool](Get-GitRootOrNull -Path $WorkDir)
            message = 'This folder is not trusted in Claude Code yet. No session was started.'
        }
    }

    $claude = Resolve-ClaudeBinary
    if (-not $claude) {
        return [ordered]@{ ok = $false; code = 'CLAUDE_NOT_FOUND'; message = 'The claude executable was not found on PATH or in the usual install locations.' }
    }

    if ($Mode -eq 'new' -and -not $SessionId) { $SessionId = [guid]::NewGuid().ToString() }
    $claudeArgs = Get-ClaudeArgs -Mode $Mode -SessionId $SessionId -Fork:$Fork

    $launcher = Start-ClaudeTerminal -WorkDir $WorkDir -ClaudeExe $claude -ClaudeArgs $claudeArgs

    # A forked resume gets an id only the CLI knows, and a picker has none at all:
    # neither can be recorded truthfully, so neither is.
    $registered = $false
    if ($SessionId -and -not $Fork -and $Mode -ne 'picker') {
        try { Register-LaunchedSession -SessionId $SessionId -Cwd $WorkDir -Alias $Alias -Source $Source; $registered = $true } catch {}
    }
    Write-KitLog ("launch mode={0} source={1} launcher={2} session={3} cwd={4}" -f $Mode, $Source, $launcher, $SessionId, $WorkDir)

    $code = switch ($Mode) { 'new' { 'LAUNCHED' } 'resume' { 'RESUMED' } 'picker' { 'PICKER_OPENED' } }
    if ($AllowUntrusted) { $code += '_UNTRUSTED' }
    $message = switch ($Mode) {
        'new' { 'A new session was opened in a terminal tab.' }
        'resume' { 'The session was reopened in a terminal tab.' }
        'picker' { "No session could be chosen automatically; the CLI's own session picker was opened in that folder." }
    }
    if ($AllowUntrusted) { $message += ' The trust prompt is showing in that tab and has to be answered there, by the user.' }

    return [ordered]@{
        ok = $true; code = $code; path = $WorkDir; alias = $(if ($Alias) { $Alias } else { $null }); mode = $Mode
        sessionId = $SessionId; registered = $registered; launcher = $launcher; message = $message
    }
}
