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
        $wtArgs = New-WtArgumentList -WorkDir $WorkDir -Exe $ClaudeExe -Arguments $ClaudeArgs
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
# Checks trust, mints a session id for a new session, opens the tab.
# Returns the hashtable to print; never throws for an expected refusal.
function Invoke-SessionLaunch {
    param(
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)][ValidateSet('new', 'resume')][string]$Mode,
        [string]$SessionId,
        [string]$Alias,
        [string]$Name,
        # model, effort and first prompt: only what the person asked for, as they said it
        [string]$Model,
        [string]$Effort,
        [string]$Prompt,
        # Marks the folder trusted in ~/.claude.json first, so no prompt appears. Only on the person's say-so.
        [switch]$TrustFolder,
        # Get-RunningSessions rows the caller already has: each query starts a process
        [object[]]$RunningSessions
    )

    foreach ($refusal in (Get-NameRefusal $Name), (Get-ModelRefusal $Model), (Get-EffortRefusal $Effort), (Get-PromptRefusal $Prompt)) {
        if ($refusal) { return $refusal }
    }

    $trusted = Test-WorkspaceTrusted -Path $WorkDir
    if (-not $trusted -and -not $TrustFolder) {
        return (New-UntrustedRefusal -Path $WorkDir -Message 'This folder is not trusted in Claude Code yet. No session was started.')
    }

    $claude = Resolve-ClaudeBinary
    if (-not $claude) {
        return [ordered]@{ ok = $false; code = 'CLAUDE_NOT_FOUND'; message = 'The claude executable was not found on PATH or in the usual install locations.' }
    }
    if ($Prompt -and (Test-ClaudeShim $claude)) {
        return [ordered]@{
            ok = $false; code = 'CLAUDE_IS_SHIM'; claude = $claude
            message = 'claude is a .cmd/.bat shim here (an npm install), and cmd.exe would re-read a prompt on its command line. Nothing was opened. Open the session without -Prompt and type the prompt in the tab, or install the native claude.exe.'
        }
    }

    # Two tabs on one conversation interleave their writes into the same transcript.
    if ($Mode -eq 'resume') {
        $rows = if ($PSBoundParameters.ContainsKey('RunningSessions')) { @($RunningSessions) } else { @(Get-RunningSessions) }
        $running = $rows | Where-Object { $_.SessionId -eq $SessionId } | Select-Object -First 1
        if ($running) {
            # A background session has no tab to switch to; `claude attach` takes its job id, not the session id.
            $jobId = if ($running.PSObject.Properties['JobId'] -and $running.JobId) { [string]$running.JobId } else { $null }
            $message = if ($running.Kind -ne 'background') {
                'That session is already open in another terminal. Nothing was opened; switch to that tab.'
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

    if ($Mode -eq 'new') { $SessionId = [guid]::NewGuid().ToString() }
    $claudeArgs = Get-ClaudeArgs -Mode $Mode -SessionId $SessionId -Name $Name -Model $Model -Effort $Effort -Prompt $Prompt

    # Written only after every refusal above, so a refused launch never leaves trust behind.
    $trustWritten = $false
    if (-not $trusted -and $TrustFolder) {
        $t = Set-WorkspaceTrusted -Path $WorkDir
        if (-not $t.ok) { $t['path'] = $WorkDir; return $t }
        $trustWritten = [bool]$t.written
    }

    $launcher = Start-ClaudeTerminal -WorkDir $WorkDir -ClaudeExe $claude -ClaudeArgs $claudeArgs
    # Resume looks at these first. The tab is open by now, so a failed write is only logged.
    try { Register-LaunchedSession -SessionId $SessionId -Cwd $WorkDir } catch { Write-KitLog "registry write failed: $($_.Exception.Message)" }
    # the prompt's length only, never its text
    Write-KitLog ("launch mode={0} launcher={1} session={2} model={3} effort={4} promptChars={5} cwd={6}" -f $Mode, $launcher, $SessionId, $Model, $Effort, $Prompt.Length, $WorkDir)

    $new = $Mode -eq 'new'
    $message = if ($new) { 'A new session was opened in a terminal tab.' } else { 'The session was reopened in a terminal tab.' }
    if ($trustWritten) { $message += ' The folder was marked trusted in Claude Code first (-TrustFolder), so no trust prompt was shown.' }

    $result = [ordered]@{
        ok = $true; code = $(if ($new) { 'LAUNCHED' } else { 'RESUMED' }); path = $WorkDir; alias = $(if ($Alias) { $Alias } else { $null })
        sessionId = $SessionId; launcher = $launcher; message = $message
    }
    if ($trustWritten) { $result['trustWritten'] = $true; $result['trustKey'] = Get-TrustKey -Path $WorkDir }
    # the name is also the session's SendMessage address in ListAgents
    if ($Name) { $result['name'] = $Name }
    if ($Model) { $result['model'] = $Model }
    if ($Effort) { $result['effort'] = $Effort }
    if ($Prompt) { $result['promptChars'] = $Prompt.Length }
    return $result
}
