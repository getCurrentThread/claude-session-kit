# Core.State.ps1 -- reads and writes files; starts nothing, registers nothing.
#
# Everything the kit remembers lives OUTSIDE the plugin folder, under
# ~/.claude/claude-session-kit/. An installed plugin sits in a versioned cache
# directory that is replaced on every update, and a cloned one is a git work
# tree -- neither is a place for a person's paths, sessions or prompts.

Set-StrictMode -Version Latest

. "$PSScriptRoot\Core.Pure.ps1"

$script:KitName = 'claude-session-kit'

function Get-ClaudeHome {
    if ($env:CLAUDE_CONFIG_DIR) { return $env:CLAUDE_CONFIG_DIR }
    return (Join-Path $env:USERPROFILE '.claude')
}

function Get-ClaudeConfigFile {
    if ($env:CLAUDE_CONFIG_DIR) { return (Join-Path $env:CLAUDE_CONFIG_DIR '.claude.json') }
    return (Join-Path $env:USERPROFILE '.claude.json')
}

function Get-ClaudeProjectsDir { return (Join-Path (Get-ClaudeHome) 'projects') }

# CLAUDE_SESSION_KIT_HOME exists so the test suite can run against a scratch
# directory instead of a person's real aliases and session registry.
#
# Returned in canonical form (no '..', no 8.3 short names): reboot-plan.ps1 renders
# the RunOnce command from it and reboot-commit.ps1 compares that command with its
# own idea of the path, so both have to arrive at the same string.
function Get-KitRoot {
    $root = if ($env:CLAUDE_SESSION_KIT_HOME) { $env:CLAUDE_SESSION_KIT_HOME } else { Join-Path (Join-Path $env:USERPROFILE '.claude') $script:KitName }
    return [IO.Path]::GetFullPath($root)
}

function Get-KitPath {
    param([Parameter(Mandatory)][ValidateSet('aliases', 'registry', 'state', 'stateLast', 'plan', 'prompt', 'log', 'runtime')][string]$Name)
    $root = Get-KitRoot
    switch ($Name) {
        'aliases' { Join-Path $root 'aliases.json' }
        'registry' { Join-Path $root 'sessions.jsonl' }
        'state' { Join-Path $root 'state.json' }
        'stateLast' { Join-Path $root 'state.last.json' }
        'plan' { Join-Path $root 'plan.json' }
        'prompt' { Join-Path $root 'next-prompt.txt' }
        'log' { Join-Path $root 'kit.log' }
        'runtime' { Join-Path $root 'runtime' }
    }
}

function Initialize-KitState {
    $root = Get-KitRoot
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
    try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch {}
    return $root
}

# --- results and logging ----------------------------------------------------------
# Contract with the model: stdout carries exactly ONE JSON object per run.
# `ok` and `code` are for branching, `message` is for people.
function Write-KitResult {
    param(
        [Parameter(Mandatory)][bool]$Ok,
        [Parameter(Mandatory)][string]$Code,
        [string]$Message,
        [System.Collections.IDictionary]$Data
    )
    $o = [ordered]@{ ok = $Ok; code = $Code }
    if ($Message) { $o.message = $Message }
    if ($Data) { foreach ($k in $Data.Keys) { $o[$k] = $Data[$k] } }
    Write-Output ($o | ConvertTo-Json -Compress -Depth 6)
}

# Prints a result table and ends the script: 0 = done, 1 = refused or failed in an
# expected way (the JSON says which), 2 is reserved for the catch-all in each script.
function Exit-WithResult {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Result)
    Write-Output ($Result | ConvertTo-Json -Compress -Depth 6)
    if ($Result['ok']) { exit 0 } else { exit 1 }
}

# A prompt is never logged or echoed: it routinely holds absolute paths, branch
# names and plans, and logs are what people paste into bug reports.
function Get-TextDigest {
    param([AllowEmptyString()][string]$Text)
    if (-not $Text) { return 'empty' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
    } finally { $sha.Dispose() }
    $hex = -join ($hash[0..5] | ForEach-Object { $_.ToString('x2') })
    return ("sha256:{0} len:{1}" -f $hex, $Text.Length)
}

function Write-KitLog {
    param([Parameter(Mandatory)][string]$Message)
    try {
        $log = Get-KitPath log
        if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 1MB) {
            Move-Item -LiteralPath $log -Destination ($log + '.1') -Force
        }
        $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $log -Value $line -Encoding utf8
    } catch {
        # logging is never a reason to fail
    }
}

# --- paths --------------------------------------------------------------------------
# Returns the existing directory with its on-disk casing, or $null. Casing matters
# because the project slug preserves it while NTFS does not.
function Resolve-WorkspacePath {
    param([Parameter(Mandatory)][string]$Path)
    # UNC slugs are unverified: refuse rather than guess. Windows accepts forward
    # slashes too, and a relative or PSDrive path can still resolve to a share.
    if ($Path -match '^[\\/]{2}') { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $null }
    $item = Get-Item -LiteralPath $Path -Force
    $full = $item.FullName
    if ($full.StartsWith('\\')) { return $null }
    try {
        # Get-Item echoes the caller's casing; walking GetFileSystemInfos recovers the real one.
        $di = [IO.DirectoryInfo]::new($full)
        $parts = [System.Collections.Generic.List[string]]::new()
        while ($di.Parent) {
            $real = $di.Parent.GetFileSystemInfos($di.Name) | Select-Object -First 1
            $parts.Insert(0, $(if ($real) { $real.Name } else { $di.Name }))
            $di = $di.Parent
        }
        $full = $di.FullName.ToUpperInvariant()
        foreach ($p in $parts) { $full = Join-Path $full $p }
    } catch {}
    return (ConvertTo-NormalizedPath $full)
}

function Get-ProjectTranscriptDir {
    param([Parameter(Mandatory)][string]$Path)
    return (Join-Path (Get-ClaudeProjectsDir) (ConvertTo-ProjectSlug $Path))
}

# --- folder trust (READ ONLY) -------------------------------------------------------
# Claude Code decides whether to show "do you trust this folder?" by looking the
# folder up in ~/.claude.json. Repeating that lookup lets the launcher refuse up
# front instead of opening a tab that parks on a prompt nobody sees.
#
#   * The key is the git root when the path is inside a repository, otherwise the
#     path itself -- forward slashes, no trailing separator.
#   * Only `hasTrustDialogAccepted: true` counts. An entry merely existing, or
#     holding false, is not trust.
#   * Trust is inherited from ancestors, but the walk stops at the git root: a
#     repository does NOT inherit trust from a trusted parent folder.
#
# Nothing here writes that file, and nothing in this kit may. Accepting trust on
# a person's behalf removes the one gate between opening a folder and running the
# hooks, MCP servers and settings that folder ships with. When the answer is
# unclear the answer is "untrusted": the worst case is one refused launch.
function Get-GitRootOrNull {
    param([Parameter(Mandatory)][string]$Path)
    # Looks for `.git` as a directory OR a file (worktrees, submodules), the way the
    # CLI does, instead of asking git -- which may be absent or configured differently.
    $dir = $null
    try { $dir = [IO.DirectoryInfo]::new((ConvertTo-NormalizedPath $Path)) } catch { return $null }
    while ($dir) {
        $marker = Join-Path $dir.FullName '.git'
        if ((Test-Path -LiteralPath $marker)) { return (ConvertTo-TrustPath $dir.FullName) }
        $dir = $dir.Parent
    }
    return $null
}

function Get-TrustKey {
    param([Parameter(Mandatory)][string]$Path)
    $root = Get-GitRootOrNull -Path $Path
    if ($root) { return $root }
    return (ConvertTo-TrustPath (ConvertTo-NormalizedPath $Path))
}

function Test-WorkspaceTrusted {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ConfigFile = (Get-ClaudeConfigFile)
    )
    if (-not (Test-Path -LiteralPath $ConfigFile)) { return $false }

    # -AsHashtable is required, not stylistic: the file legitimately holds keys that
    # differ only by case, and ConvertFrom-Json throws on those without it.
    try {
        $config = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    } catch { return $false }
    if (-not $config -or -not $config.ContainsKey('projects') -or -not $config.projects) { return $false }
    $projects = $config.projects

    $ceiling = Get-GitRootOrNull -Path $Path
    $current = ConvertTo-TrustPath (ConvertTo-NormalizedPath $Path)

    while ($true) {
        if ($null -ne $ceiling -and $current -ine $ceiling -and
            -not $current.StartsWith($ceiling + '/', [StringComparison]::OrdinalIgnoreCase)) {
            return $false   # walked above the repository root
        }
        foreach ($key in @($projects.Keys)) {
            # a drive root may be keyed "C:/" -- the one key that keeps its slash
            if ($key -ine $current -and $key -ine ($current + '/')) { continue }
            $entry = $projects[$key]
            if ($entry -is [System.Collections.IDictionary] -and $entry.Contains('hasTrustDialogAccepted') -and
                $entry['hasTrustDialogAccepted'] -eq $true) { return $true }
        }
        if ($null -ne $ceiling -and $current -ieq $ceiling) { return $false }

        $slash = $current.LastIndexOf('/')
        if ($slash -lt 0) { return $false }   # "C:" -- nothing above
        $current = $current.Substring(0, $slash)
    }
}

# --- aliases ----------------------------------------------------------------------------
function Read-AliasDocument {
    $file = Get-KitPath aliases
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try {
        return (Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        # Reaches the model as INTERNAL_ERROR from whichever script needed an alias,
        # so the message has to say which file to fix.
        throw "aliases.json is not valid JSON ($file): $($_.Exception.Message)"
    }
}

function Get-AliasTable {
    $doc = Read-AliasDocument
    if (-not $doc) { return }
    # %USERPROFILE% and friends are expanded here, like tempTask.root, so a shared
    # aliases.json need not spell out anybody's home folder.
    foreach ($a in @(ConvertFrom-AliasDocument -Document $doc)) {
        $a.path = [Environment]::ExpandEnvironmentVariables([string]$a.path)
        $a
    }
}

function Find-Alias {
    param([Parameter(Mandatory)][string]$Name)
    foreach ($a in @(Get-AliasTable)) { if ($a.name -eq $Name) { return $a } }
    return $null
}

function Get-TempTaskSettings {
    $root = Join-Path $env:USERPROFILE 'Downloads'
    $prefix = 'test'
    try {
        $doc = Read-AliasDocument
        if ($doc) {
            $tt = $doc.PSObject.Properties | Where-Object { $_.Name -eq 'tempTask' } | Select-Object -First 1
            if ($tt -and $tt.Value -is [pscustomobject]) {
                foreach ($f in $tt.Value.PSObject.Properties) {
                    if ($f.Name -eq 'root' -and $f.Value) { $root = [Environment]::ExpandEnvironmentVariables([string]$f.Value) }
                    if ($f.Name -eq 'prefix' -and $f.Value) { $prefix = [string]$f.Value }
                }
            }
        }
    } catch {}
    return [pscustomobject]@{ Root = $root; Prefix = $prefix }
}

# List-returning functions below stream their rows; collect them with @( ).

# --- session registry -----------------------------------------------------------------
# sessions.jsonl is append-only: one JSON object per line, one line per session
# this kit opened. It is the FIRST place resume looks, because it holds only
# sessions a person started on purpose, with the folder recorded at launch rather
# than reverse-engineered later. It is never rewritten in place, and a damaged
# line costs that line, not the file.
function Register-LaunchedSession {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Cwd,
        [string]$Alias,
        [ValidateSet('new', 'open', 'resume')][string]$Source = 'open'
    )
    $record = [ordered]@{
        sessionId = $SessionId
        cwd       = $Cwd
        alias     = $(if ($Alias) { $Alias } else { $null })
        source    = $Source
        startedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Compress

    $file = Get-KitPath registry
    $mutex = [Threading.Mutex]::new($false, 'Local\ClaudeSessionKitRegistry')
    $held = $false
    try {
        try { $held = $mutex.WaitOne(3000) } catch [Threading.AbandonedMutexException] { $held = $true }
        [IO.File]::AppendAllText($file, $record + "`n", [Text.UTF8Encoding]::new($false))
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-RegisteredSessions {
    param([int]$Days = 30)
    $file = Get-KitPath registry
    if (-not (Test-Path -LiteralPath $file)) { return }
    $cutoff = (Get-Date).AddDays(-$Days)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($line in [IO.File]::ReadAllLines($file)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $r = $line | ConvertFrom-Json
            if (-not (Test-SessionIdFormat $r.sessionId) -or -not $r.cwd) { continue }
            # "o"-format timestamps are auto-converted to DateTime by ConvertFrom-Json on PS7.
            $started = if ($r.startedAt -is [datetime]) { $r.startedAt } else { [datetime]::Parse([string]$r.startedAt) }
            if ($started -lt $cutoff) { continue }
            $out.Add([pscustomobject]@{
                    SessionId = [string]$r.sessionId; Cwd = [string]$r.cwd; Alias = [string]$r.alias
                    Source = [string]$r.source; StartedAt = $started
                })
        } catch { continue }
    }
    return $out.ToArray()
}

# --- transcripts ---------------------------------------------------------------------------
function Get-ClaudeSessionRecord {
    param([Parameter(Mandatory)][string]$TranscriptPath, [int]$HeadLines = 120)

    $lines = [System.Collections.Generic.List[string]]::new()
    try {
        $fs = [IO.File]::Open($TranscriptPath, 'Open', 'Read', 'ReadWrite, Delete')   # a live session holds it open
        try {
            $reader = [IO.StreamReader]::new($fs, [Text.Encoding]::UTF8)
            while ($lines.Count -lt $HeadLines -and -not $reader.EndOfStream) { $lines.Add($reader.ReadLine()) }
        } finally { $fs.Dispose() }
    } catch {
        return [pscustomobject]@{
            SessionId = $null; Kind = 'unreadable'; Cwd = $null; Title = $null
            LastWrite = [datetime]::MinValue; TranscriptPath = $TranscriptPath
        }
    }
    $info = Get-TranscriptHeadInfo -Lines $lines.ToArray()
    $file = Get-Item -LiteralPath $TranscriptPath
    return [pscustomobject]@{
        # The file name IS the session id; the sessionId fields inside agree with it.
        SessionId      = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        Kind           = $info.Kind
        Cwd            = $info.Cwd
        Title          = $info.Title
        LastWrite      = $file.LastWriteTime
        TranscriptPath = $file.FullName
    }
}

# Lists transcripts, newest first. NOT recursive, and that is load-bearing: project
# folders also hold subagents/, workflows/, tool-results/ and per-session
# directories full of *.jsonl that are not conversations anyone can resume.
function Get-ClaudeSessions {
    param(
        [string]$Path,
        [int]$Days = 30,
        [string[]]$Kinds = @('interactive'),
        [string]$ProjectsDir = (Get-ClaudeProjectsDir)
    )
    if (-not (Test-Path -LiteralPath $ProjectsDir)) { return }

    $dirs = if ($Path) {
        $one = Join-Path $ProjectsDir (ConvertTo-ProjectSlug $Path)
        if (Test-Path -LiteralPath $one) { @(Get-Item -LiteralPath $one) } else { @() }
    } else {
        @(Get-ChildItem -LiteralPath $ProjectsDir -Directory -ErrorAction SilentlyContinue)
    }

    $cutoff = (Get-Date).AddDays(-$Days)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($d in $dirs) {
        $files = Get-ChildItem -LiteralPath $d.FullName -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $cutoff -and (Test-SessionIdFormat $_.BaseName) }
        foreach ($f in @($files)) {
            $rec = Get-ClaudeSessionRecord -TranscriptPath $f.FullName
            if ($rec.Kind -notin $Kinds) { continue }
            # The slug is lossy, so two folders can share a project directory: the
            # recorded cwd decides. A sidecar has none yet and rides on the folder.
            if ($Path -and $rec.Cwd -and -not (Test-PathEqual $rec.Cwd $Path)) { continue }
            $out.Add($rec)
        }
    }
    return ($out.ToArray() | Sort-Object LastWrite -Descending)
}

# --- resume target ladder -------------------------------------------------------------------
#   1. explicit -SessionId       (must exist as a transcript; an id is never guessed)
#   2. launcher registry         (sessions this kit opened, newest transcript first)
#   3. transcript scan, -Days    (interactive CLI sessions only)
#   4. the CLI's own picker      (only with -AllowPicker and a folder to open it in)
# The folder a session is reopened in is always the one RECORDED for it:
# `claude --resume <id>` finds a session from anywhere, and then works in whatever
# directory it was started from.
function Resolve-ResumeTarget {
    param(
        [string]$Path,
        [string]$SessionId,
        [int]$Days = 30,
        [switch]$AllowPicker,
        [switch]$AllowSidecar
    )
    $none = { param($reason) [pscustomobject]@{ Mode = 'none'; SessionId = $null; Cwd = $Path; Source = $null; Title = $null; Reason = $reason } }
    $kinds = if ($AllowSidecar) { @('interactive', 'sidecar') } else { @('interactive') }

    if ($SessionId) {
        if (-not (Test-SessionIdFormat $SessionId)) { return (& $none "Not a session id: $SessionId") }
        $found = $null
        foreach ($d in @(Get-ChildItem -LiteralPath (Get-ClaudeProjectsDir) -Directory -ErrorAction SilentlyContinue)) {
            $candidate = Join-Path $d.FullName ($SessionId + '.jsonl')
            if (Test-Path -LiteralPath $candidate) { $found = Get-ClaudeSessionRecord -TranscriptPath $candidate; break }
        }
        if (-not $found) { return (& $none "No transcript exists for session $SessionId.") }
        if ($found.Kind -notin $kinds) { return (& $none "Session $SessionId is '$($found.Kind)', not an interactive CLI session.") }
        $cwd = if ($found.Cwd) { $found.Cwd } else { $Path }
        if (-not $cwd) { return (& $none "Session $SessionId records no working directory.") }
        return [pscustomobject]@{ Mode = 'resume-id'; SessionId = $SessionId; Cwd = $cwd; Source = 'explicit'; Title = $found.Title; Reason = $null }
    }

    $best = $null
    foreach ($r in @(Get-RegisteredSessions -Days $Days)) {
        if ($Path -and -not (Test-PathEqual $r.Cwd $Path)) { continue }
        $t = Join-Path (Get-ProjectTranscriptDir $r.Cwd) ($r.SessionId + '.jsonl')
        # Registered but never written: the person closed it before saying anything.
        if (-not (Test-Path -LiteralPath $t)) { continue }
        $rec = Get-ClaudeSessionRecord -TranscriptPath $t
        if ($rec.Kind -ne 'interactive') { continue }
        if (-not $best -or $rec.LastWrite -gt $best.LastWrite) {
            $best = [pscustomobject]@{ SessionId = $r.SessionId; Cwd = $r.Cwd; LastWrite = $rec.LastWrite; Title = $rec.Title }
        }
    }
    if ($best) {
        return [pscustomobject]@{ Mode = 'resume-id'; SessionId = $best.SessionId; Cwd = $best.Cwd; Source = 'registry'; Title = $best.Title; Reason = $null }
    }

    $scanned = @(Get-ClaudeSessions -Path $Path -Days $Days -Kinds $kinds)
    foreach ($s in $scanned) {
        $cwd = if ($s.Cwd) { $s.Cwd } else { $Path }
        if (-not $cwd) { continue }
        return [pscustomobject]@{ Mode = 'resume-id'; SessionId = $s.SessionId; Cwd = $cwd; Source = 'scan'; Title = $s.Title; Reason = $null }
    }

    if ($AllowPicker -and $Path) {
        return [pscustomobject]@{ Mode = 'picker'; SessionId = $null; Cwd = $Path; Source = 'picker'; Title = $null
            Reason = "No registered or recent session for this folder; handing over to the CLI's own picker." }
    }
    return (& $none "No resumable interactive session found in the last $Days days.")
}

# --- executables ------------------------------------------------------------------------------
function Resolve-ClaudeBinary {
    # An explicit override wins. resume-after-reboot.ps1 resolves in the same order.
    if ($env:CLAUDE_CODE_BIN -and (Test-Path -LiteralPath $env:CLAUDE_CODE_BIN -PathType Leaf)) { return $env:CLAUDE_CODE_BIN }
    # -CommandType Application: a profile function or alias named `claude` must not win.
    # A real .exe is preferred over an npm-style .cmd shim: a shim runs through cmd.exe,
    # which is no place for free text (see Test-ClaudeShim).
    $cmds = @(Get-Command claude -CommandType Application -All -ErrorAction SilentlyContinue)
    $exe = $cmds | Where-Object { $_.Source -match '\.exe\z' } | Select-Object -First 1
    if ($exe) { return $exe.Source }
    if ($cmds.Count -gt 0) { return $cmds[0].Source }
    # RunOnce and -NoProfile shells see a thinner PATH; these carry the common installs.
    $candidates = @(
        (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\claude\claude.exe'),
        (Join-Path $env:APPDATA 'npm\claude.cmd'),
        (Join-Path $env:USERPROFILE '.bun\bin\claude.exe')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return $null
}

# The host for the RunOnce entry. The path is written now and executed at the NEXT
# logon, so it must survive updates: `Get-Command pwsh` resolves to the versioned
# MSIX location, which moves on every PowerShell update and would leave an entry
# that fails at logon with nothing to show for it. Prefer the version-free alias.
function Resolve-PowerShellHost {
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
    if (Test-Path -LiteralPath $alias) { return $alias }
    $pwsh = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pwsh -and $pwsh.Source -notmatch '\\WindowsApps\\Microsoft\.PowerShell_') { return $pwsh.Source }
    return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

function Resolve-WindowsTerminal {
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
    if (Test-Path -LiteralPath $alias) { return $alias }
    $wt = Get-Command wt.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($wt) { return $wt.Source }
    return $null
}
