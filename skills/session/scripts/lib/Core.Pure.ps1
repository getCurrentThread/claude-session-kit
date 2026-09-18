# Core.Pure.ps1 -- string in, string out.
#
# Nothing in this file touches the disk, the registry, a process or the console.
# That is the point of the split: every command line this kit will ever hand to
# Windows Terminal, to `claude`, or to the RunOnce key is rendered here, so
# tests/run-tests.ps1 can assert the exact text without opening a tab or
# scheduling a reboot.

Set-StrictMode -Version Latest

# \A and \z, not ^ and $: in .NET `$` also matches before a final line feed.
$script:SessionIdPattern = '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z'

# The documented ceiling for a Run/RunOnce value. A longer value is not rejected
# when written -- it just never runs at logon, with nothing logged anywhere.
$script:RunOnceMaxLength = 260

function Test-SessionIdFormat {
    param([string]$SessionId)
    return [bool]($SessionId -and $SessionId -match $script:SessionIdPattern)
}

function ConvertTo-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    # "C:\" must keep its separator; "C:\work\" must lose it, or the project slug
    # gains a trailing dash and points at a folder that does not exist.
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\', '/') }
    return $full
}

# Claude Code files transcripts under ~/.claude/projects/<slug>. The slug is ONE
# WAY: every character outside [A-Za-z0-9] -- each Hangul syllable included --
# collapses to a single dash, so different paths can share a slug. Never try to
# turn a slug back into a path; read the "cwd" field of a transcript instead.
function ConvertTo-ProjectSlug {
    param([Parameter(Mandatory)][string]$Path)
    return ((ConvertTo-NormalizedPath $Path) -replace '[^A-Za-z0-9]', '-')
}

# ~/.claude.json keys its per-folder entries with FORWARD slashes and no trailing
# separator. A backslash key is one Claude Code will never look up.
function ConvertTo-TrustPath {
    param([Parameter(Mandatory)][string]$Path)
    return (($Path -replace '\\', '/').TrimEnd('/'))
}

function Test-PathEqual {
    param([string]$Left, [string]$Right)
    if (-not $Left -or -not $Right) { return $false }
    try {
        return ((ConvertTo-NormalizedPath $Left) -ieq (ConvertTo-NormalizedPath $Right))
    } catch { return $false }
}

# --- transcript head parsing ---------------------------------------------------
# Only an interactive CLI conversation may be resumed. Scheduled and SDK runs write
# their transcripts into the SAME project folder with entrypoint "sdk-cli", and
# they are frequently the newest file there -- "newest transcript wins" quietly
# appends a person's work to an automation's conversation.
#
# This is an allowlist: any entrypoint other than "cli" is automation, including
# values that do not exist yet, and a transcript that records none is not
# assumed safe.
function Get-TranscriptHeadInfo {
    param([string[]]$Lines)

    $entrypoint = $null; $cwd = $null; $sessionId = $null; $title = $null
    foreach ($line in @($Lines)) {
        if (-not $line) { continue }
        if (-not $entrypoint -and $line -match '"entrypoint"\s*:\s*"([^"]+)"') { $entrypoint = $Matches[1] }
        if (-not $cwd -and $line -match '"cwd"\s*:\s*"((?:[^"\\]|\\.)*)"') {
            $raw = $Matches[1]
            try { $cwd = ('"' + $raw + '"') | ConvertFrom-Json } catch { $cwd = $raw -replace '\\\\', '\' }
        }
        if (-not $sessionId -and $line -match '"sessionId"\s*:\s*"([^"]+)"') { $sessionId = $Matches[1] }
        if ($line -match '"type"\s*:\s*"(?:ai-title|custom-title)"' -and
            $line -match '"(?:aiTitle|customTitle)"\s*:\s*"((?:[^"\\]|\\.)*)"') {
            # later titles supersede earlier ones
            try { $title = ('"' + $Matches[1] + '"') | ConvertFrom-Json } catch { $title = $Matches[1] }
        }
    }

    $kind =
        if ($entrypoint -eq 'cli') { 'interactive' }
        elseif ($entrypoint) { 'automated' }
        # A live session writes a small metadata sidecar (last-prompt / mode / ...)
        # keyed by sessionId while its conversation is still buffered, so neither
        # entrypoint nor cwd exists yet. Recognised by what it has, not by absence.
        elseif ($sessionId -and -not $cwd) { 'sidecar' }
        else { 'unknown' }

    return [pscustomobject]@{
        Kind = $kind; Entrypoint = $entrypoint; Cwd = $cwd; SessionId = $sessionId; Title = $title
    }
}

# --- claude argv -----------------------------------------------------------------
# `--continue` cannot be expressed here, on purpose: it reopens whatever
# conversation is newest in the folder, which may be a scheduled run's.
function Get-ClaudeArgs {
    param(
        [Parameter(Mandatory)][ValidateSet('new', 'resume', 'picker')][string]$Mode,
        [string]$SessionId,
        [string]$Prompt,
        [switch]$Fork
    )

    $argv = [System.Collections.Generic.List[string]]::new()
    switch ($Mode) {
        'new' {
            if ($SessionId) {
                if (-not (Test-SessionIdFormat $SessionId)) { throw "Not a session id: $SessionId" }
                $argv.Add('--session-id'); $argv.Add($SessionId)
            }
        }
        'resume' {
            if (-not (Test-SessionIdFormat $SessionId)) { throw "Mode 'resume' needs a session id, got: '$SessionId'" }
            $argv.Add('--resume'); $argv.Add($SessionId)
            if ($Fork) { $argv.Add('--fork-session') }
        }
        'picker' {
            if ($Prompt) { throw "Mode 'picker' cannot carry a prompt." }
            $argv.Add('--resume')
        }
    }
    if ($Prompt) {
        # `--resume` takes an OPTIONAL value, so a bare prompt is liable to be
        # consumed as the resume target. '--' ends option parsing.
        $argv.Add('--'); $argv.Add($Prompt)
    }
    return , $argv.ToArray()
}

# True when `claude` is a batch shim (an npm install puts claude.cmd on PATH).
# cmd.exe re-parses whatever is handed to a shim -- &, |, <, >, %VAR% and line
# feeds are all live there -- so a prompt must never travel on its command line.
function Test-ClaudeShim {
    param([string]$Path)
    return [bool]($Path -and $Path -match '\.(cmd|bat)\z')
}

# --- command lines -----------------------------------------------------------------
# Standard Win32 argv quoting (what CommandLineToArgvW undoes).
function ConvertTo-QuotedArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value -ne '' -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'   # backslashes before a quote double up
    $escaped = $escaped -replace '(\\+)\z', '$1$1'  # ...and so do trailing ones
    return '"' + $escaped + '"'
}

# Windows Terminal splits its own command line on ';'. Unescaped, a semicolon
# anywhere in a path silently truncates everything after it.
function ConvertTo-WtArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return ($Value -replace ';', '\;')
}

# Argument list for `& wt.exe @list`. Window '0' joins the most recent window (a
# person is at the keyboard); 'new' never attaches to one, which is what logon
# needs, where '0' would race whatever the user's own startup opens.
function New-WtArgumentList {
    param(
        [string]$WorkDir,
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @(),
        [ValidateSet('0', 'new')][string]$Window = '0'
    )
    $list = [System.Collections.Generic.List[string]]::new()
    $list.Add('-w'); $list.Add($Window); $list.Add('nt')
    if ($WorkDir) { $list.Add('-d'); $list.Add((ConvertTo-WtArgument $WorkDir)) }
    # '--' ends wt's own option parsing; everything after it is the child's.
    $list.Add('--')
    $list.Add((ConvertTo-WtArgument $Exe))
    foreach ($a in @($Arguments)) { $list.Add((ConvertTo-WtArgument $a)) }
    return , $list.ToArray()
}

# The RunOnce value. It deliberately carries NO working directory and NO prompt:
# the resume script reads both from state.json, which keeps this string short and
# free of anything that needs escaping.
function New-RunOnceCommand {
    param(
        [Parameter(Mandatory)][string]$PowerShellExe,
        [Parameter(Mandatory)][string]$ResumeScript,
        [string]$WtExe
    )
    $inner = @(
        (ConvertTo-QuotedArgument $PowerShellExe), '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', (ConvertTo-QuotedArgument $ResumeScript)
    ) -join ' '
    if ($WtExe) {
        if (($PowerShellExe + $ResumeScript) -match ';') {
            throw "A ';' in a path cannot be passed through Windows Terminal from RunOnce."
        }
        return ((ConvertTo-QuotedArgument $WtExe) + ' -w new nt -- ' + $inner)
    }
    return $inner
}

function Test-RunOnceCommandLength {
    param([Parameter(Mandatory)][string]$Command)
    return ($Command.Length -le $script:RunOnceMaxLength)
}

# --- temp task numbering ---------------------------------------------------------
# Next free index for <prefix><N>. Counts folders on disk AND folders that only
# survive as transcript history: reusing the number of a deleted folder would
# drop the new session into the old folder's project history.
function Get-NextTempIndex {
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [string[]]$DiskNames = @(),
        [string[]]$HistorySlugs = @(),
        [string]$RootSlug
    )
    $max = 0
    # At most nine digits: that always fits an Int32, and a folder such as
    # "<prefix>20240101120000" is somebody's timestamp, not one of our indexes.
    $leaf = '^' + [regex]::Escape($Prefix) + '(\d{0,9})$'
    foreach ($n in @($DiskNames)) {
        if ($n -match $leaf) {
            $i = if ($Matches[1]) { [int]$Matches[1] } else { 0 }   # bare "<prefix>" is 0, not 1
            if ($i -gt $max) { $max = $i }
        }
    }
    if ($RootSlug) {
        $slugRx = '^' + [regex]::Escape($RootSlug + '-' + ($Prefix -replace '[^A-Za-z0-9]', '-')) + '(\d{0,9})$'
        foreach ($s in @($HistorySlugs)) {
            if ($s -cmatch $slugRx) {
                $i = if ($Matches[1]) { [int]$Matches[1] } else { 0 }
                if ($i -gt $max) { $max = $i }
            }
        }
    }
    return ($max + 1)
}

# --- alias documents -----------------------------------------------------------------
# Accepts both shapes of aliases.json:
#   v1  { "<name>": "<path>", ... }
#   v2  { "version": 2, "aliases": { "<name>": { "path", "triggers", "note", "confirm" } } }
# Members are read through PSObject.Properties, never `$doc.$name`, so an alias
# called Count or Length resolves to the alias and not to a built-in member.
function ConvertFrom-AliasDocument {
    param([Parameter(Mandatory)]$Document)

    $source = $Document
    $isV2 = $false
    $aliasesProp = $Document.PSObject.Properties | Where-Object { $_.Name -eq 'aliases' } | Select-Object -First 1
    if ($aliasesProp -and $aliasesProp.Value -is [pscustomobject]) { $source = $aliasesProp.Value; $isV2 = $true }

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $source.PSObject.Properties) {
        if (-not $isV2 -and $p.Name -in @('version', 'tempTask')) { continue }
        $path = $null; $triggers = @(); $note = $null; $confirm = $false
        if ($p.Value -is [string]) {
            $path = $p.Value
        } elseif ($p.Value -is [pscustomobject]) {
            foreach ($f in $p.Value.PSObject.Properties) {
                switch ($f.Name) {
                    'path' { $path = [string]$f.Value }
                    'triggers' { $triggers = @($f.Value | ForEach-Object { [string]$_ }) }
                    'note' { $note = [string]$f.Value }
                    'confirm' { $confirm = [bool]$f.Value }
                }
            }
        }
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $out.Add([pscustomobject]@{
                name = $p.Name; path = $path; triggers = $triggers; note = $note; confirm = $confirm
            })
    }
    # Streams the rows (no `, ` wrapper): callers collect them with @( ).
    return $out.ToArray()
}
