# Core.Effects.ps1 -- the only file in lib/ that opens a terminal.
#
# Loaded by the scripts that open a terminal tab and by nothing else. The reboot
# path never dot-sources it: reboot-plan.ps1 renders and records (its one process
# is Core.State's read-only `claude agents --json`), and the two
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
    # Process scope only: this script's environment is what wt and Start-Process pass on.
    # Remove-Item, not SetEnvironmentVariable($name, $null): under pwsh 7.6 that still
    # hands a child the name with an empty value.
    foreach ($name in $script:InheritedSessionVariables) { Remove-Item -LiteralPath "Env:$name" -ErrorAction Ignore }
    $wt = Resolve-WindowsTerminal
    if ($wt) {
        $wtArgs = New-WtArgumentList -WorkDir $WorkDir -Exe $ClaudeExe -Arguments $ClaudeArgs -Window '0'
        & $wt @wtArgs
        Show-TerminalWindow
        return 'wt'
    }
    # No Windows Terminal: a plain console window. -WorkingDirectory instead of an
    # interpolated `Set-Location "<path>"`, which a quote or '$' in the path breaks;
    # escaped, because -WorkingDirectory reads [ ] as wildcards.
    Start-Process -FilePath $ClaudeExe -ArgumentList @($ClaudeArgs | ForEach-Object { ConvertTo-QuotedArgument $_ }) -WorkingDirectory ([WildcardPattern]::Escape($WorkDir))
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
        [string]$Name,
        [string]$PermissionMode,
        [switch]$Fork,
        [switch]$AllowUntrusted,
        # Get-RunningSessions rows the caller already has: each query starts a process
        [object[]]$RunningSessions
    )

    $refusal = Get-NameRefusal $Name
    if ($refusal) { return $refusal }

    $trusted = Test-WorkspaceTrusted -Path $WorkDir
    if (-not $trusted -and -not $AllowUntrusted) {
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

    # Two tabs on one conversation interleave their writes into the same transcript.
    # A fork is a new conversation, and a picker chooses in the tab, so neither is refused.
    if ($Mode -eq 'resume' -and -not $Fork) {
        $rows = if ($PSBoundParameters.ContainsKey('RunningSessions')) { @($RunningSessions) } else { @(Get-RunningSessions) }
        $running = $rows | Where-Object { $_.SessionId -eq $SessionId } | Select-Object -First 1
        if ($running) {
            # A background session has no tab to switch to; `claude attach` takes its job id, not the session id.
            $jobId = if ($running.PSObject.Properties['JobId'] -and $running.JobId) { [string]$running.JobId } else { $null }
            $message = if ($running.Kind -ne 'background') {
                'That session is already open in another terminal. Nothing was opened; switch to that tab, or resume with -Fork to work on a copy.'
            } elseif ($jobId) {
                "That session is running in the background, not in a tab. Nothing was opened; ``claude attach $jobId`` opens it in a terminal."
            } else {
                'That session is running in the background, not in a tab. Nothing was opened; `claude agents` lists it and can open it.'
            }
            return [ordered]@{
                ok = $false; code = 'ALREADY_RUNNING'; sessionId = $SessionId; path = $WorkDir
                pid = $running.Pid; kind = $running.Kind; name = $running.Name; jobId = $jobId; message = $message
            }
        }
    }

    if ($Mode -eq 'new' -and -not $SessionId) { $SessionId = [guid]::NewGuid().ToString() }
    # A fork is created under an id minted here, so it can be recorded like any launch.
    $forkedFrom = $null
    $forkId = $null
    if ($Fork -and $Mode -eq 'resume') { $forkedFrom = $SessionId; $forkId = [guid]::NewGuid().ToString() }
    $claudeArgs = Get-ClaudeArgs -Mode $Mode -SessionId $SessionId -Name $Name -PermissionMode $PermissionMode -Fork:$Fork -ForkSessionId $forkId
    if ($forkId) { $SessionId = $forkId }

    $launcher = Start-ClaudeTerminal -WorkDir $WorkDir -ClaudeExe $claude -ClaudeArgs $claudeArgs

    # A picker has no id at all: it cannot be recorded truthfully, so it is not.
    $registered = $false
    if ($SessionId -and $Mode -ne 'picker') {
        try { Register-LaunchedSession -SessionId $SessionId -Cwd $WorkDir -Alias $Alias -Source $Source -Name $Name; $registered = $true } catch {}
    }
    Write-KitLog ("launch mode={0} source={1} launcher={2} session={3} forkedFrom={4} cwd={5}" -f $Mode, $Source, $launcher, $SessionId, $forkedFrom, $WorkDir)

    # <CODE>_UNTRUSTED: the tab was opened on the user's say-so (-AllowUntrusted) in a
    # folder that really is untrusted, so it is sitting on the trust prompt.
    $code = switch ($Mode) { 'new' { 'LAUNCHED' } 'resume' { 'RESUMED' } 'picker' { 'PICKER_OPENED' } }
    if (-not $trusted) { $code += '_UNTRUSTED' }
    $message = switch ($Mode) {
        'new' { 'A new session was opened in a terminal tab.' }
        'resume' { 'The session was reopened in a terminal tab.' }
        'picker' { "No session could be chosen automatically; the CLI's own session picker was opened in that folder." }
    }
    if (-not $trusted) { $message += ' The trust prompt is showing in that tab and has to be answered there, by the user.' }

    $result = [ordered]@{
        ok = $true; code = $code; path = $WorkDir; alias = $(if ($Alias) { $Alias } else { $null }); mode = $Mode; trusted = $trusted
        sessionId = $SessionId; registered = $registered; launcher = $launcher; message = $message
    }
    if ($forkedFrom) { $result['forkedFrom'] = $forkedFrom }
    return $result
}
