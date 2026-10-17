#requires -Version 7.0
<#
.SYNOPSIS
  SessionStart / SessionEnd hook: remembers which interactive sessions are open.

.DESCRIPTION
  Registered by hooks/hooks.json at the plugin root; Claude Code hands it the hook
  input as JSON on stdin.
    SessionStart  writes <kit>\open-sessions\<sessionId>.json
    SessionEnd    deletes it when the session was ended on purpose
  Any other end -- a closed window, a crash, a power cut, a reason this script does
  not know -- leaves the record behind, and restore-open.ps1 offers to reopen it.

  Only interactive CLI sessions are recorded. Scheduled, SDK (-p) and background
  sessions never are.

  SessionEnd runs within Claude Code's 1.5 s budget for plugin hooks, which a plugin
  cannot raise. A pwsh too slow to start in time leaves the record, and the session
  is offered by restore-open.ps1 until it is forgotten there.

  The one script here that prints NOTHING: it runs inside somebody's session, and
  SessionStart stdout is added to the model's context. It always exits 0, and an error
  goes to kit.log, never to the session.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# SessionEnd reasons that mean the person ended the session on purpose (Claude Code
# hooks reference): /clear, switching with /resume, logout, and /exit or Ctrl+C/Ctrl+D
# at the prompt. 'other' -- a closed window among them -- keeps the record, as does
# any reason added later.
$deliberateEnds = @('clear', 'resume', 'logout', 'prompt_input_exit')

try {
    . "$PSScriptRoot\lib\Core.State.ps1"

    # Run by hand, there is no hook input, only a keyboard to wait on.
    if (-not [Console]::IsInputRedirected) { exit 0 }
    $hook = [Console]::In.ReadToEnd() | ConvertFrom-Json -AsHashtable
    if ($hook -isnot [System.Collections.IDictionary]) { exit 0 }

    # stdin is the trust boundary: the id is checked before it names a file, and
    # nothing else from the input ever becomes part of a path.
    $id = [string]$hook['session_id']
    if (-not (Test-SessionIdFormat $id)) { exit 0 }

    switch -CaseSensitive ([string]$hook['hook_event_name']) {
        'SessionStart' {
            # claude sets this for itself: 'cli' at a terminal, 'sdk-cli' under -p or
            # the SDK -- even when started from inside an interactive session.
            if ($env:CLAUDE_CODE_ENTRYPOINT -cne 'cli') { exit 0 }
            $mode = $null
            $claudePid = 0
            if ([int]::TryParse([string]$env:CLAUDE_PID, [ref]$claudePid) -and $claudePid -gt 0) {
                # A background session runs the same CLI; its process record says what it is.
                $pidFile = Join-Path (Join-Path (Get-ClaudeHome) 'sessions') ($claudePid.ToString() + '.json')
                $kind = $null
                try { $kind = [string](Get-Content -LiteralPath $pidFile -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable)['kind'] } catch {}
                if ($kind -and $kind -cne 'interactive') { exit 0 }
                # An async hook has no timeout of its own: a stuck WMI must not leave this running.
                $proc = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$claudePid" -Property CommandLine -OperationTimeoutSec 5 -ErrorAction SilentlyContinue
                if ($proc) { $mode = Get-StartPermissionMode $proc.CommandLine }
            }
            Set-OpenSessionRecord -SessionId $id -Cwd ([string]$hook['cwd']) -TranscriptPath ([string]$hook['transcript_path']) -PermissionMode $mode -Source ([string]$hook['source'])
        }
        'SessionEnd' {
            if ([string]$hook['reason'] -cin $deliberateEnds) { Remove-OpenSessionRecord -SessionId $id }
        }
    }
} catch {
    try { Write-KitLog ('track-session: ' + $_.Exception.Message) } catch {}
}
exit 0
