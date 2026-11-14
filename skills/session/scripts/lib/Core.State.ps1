# Core.State.ps1 -- reads and writes files; registers nothing, and starts only the
# read-only `claude agents --json` (Get-RunningSessions).
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
# directory instead of a person's real aliases and state.
#
# Returned in canonical form (no '..', no 8.3 short names): reboot-plan.ps1 renders
# the RunOnce command from it and reboot-commit.ps1 compares that command with its
# own idea of the path, so both have to arrive at the same string.
function Get-KitRoot {
    $root = if ($env:CLAUDE_SESSION_KIT_HOME) { $env:CLAUDE_SESSION_KIT_HOME } else { Join-Path (Join-Path $env:USERPROFILE '.claude') $script:KitName }
    return [IO.Path]::GetFullPath($root)
}

function Get-KitPath {
    param([Parameter(Mandatory)][ValidateSet('aliases', 'registry', 'state', 'plan', 'log', 'runtime', 'trustBackup')][string]$Name)
    $root = Get-KitRoot
    switch ($Name) {
        'aliases' { Join-Path $root 'aliases.json' }
        'registry' { Join-Path $root 'sessions.jsonl' }
        'state' { Join-Path $root 'state.json' }
        'plan' { Join-Path $root 'plan.json' }
        'log' { Join-Path $root 'kit.log' }
        'runtime' { Join-Path $root 'runtime' }
        'trustBackup' { Join-Path $root 'claude.json.before-trust' }
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
        [string]$Message
    )
    $o = [ordered]@{ ok = $Ok; code = $Code }
    if ($Message) { $o.message = $Message }
    Write-Output ($o | ConvertTo-Json -Compress -Depth 6)
}

# Prints a result table and ends the script: 0 = done, 1 = refused or failed in an
# expected way (the JSON says which), 2 is reserved for the catch-all in each script.
function Exit-WithResult {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Result)
    Write-Output ($Result | ConvertTo-Json -Compress -Depth 6)
    if ($Result['ok']) { exit 0 } else { exit 1 }
}

# A prompt is never logged or echoed, only its length: it routinely holds absolute
# paths, branch names and plans, and logs are what people paste into bug reports.
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

# --- folder trust -----------------------------------------------------------------
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
# Only Set-WorkspaceTrusted writes that file, and only on -TrustFolder: accepting
# trust removes the one gate between opening a folder and running the hooks, MCP
# servers and settings that folder ships with, so it happens only when the person
# asked for it. When the answer is unclear the answer is "untrusted": the worst
# case is one refused launch.
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

# What accepting trust would switch on: the project settings, local settings and
# .mcp.json of the folder and of its trust root. Counts and server names only.
function Get-WorkspaceShips {
    param([Parameter(Mandatory)][string]$Path)
    $files = [System.Collections.Generic.List[string]]::new()
    $mcp = [System.Collections.Generic.List[string]]::new()
    $hooks = 0; $allow = 0; $envKeys = 0
    $dirs = @(ConvertTo-NormalizedPath $Path)
    $git = Get-GitRootOrNull -Path $Path
    if ($git -and -not (Test-PathEqual $git $Path)) { $dirs += ConvertTo-NormalizedPath $git }
    foreach ($dir in $dirs) {
        foreach ($rel in @('.claude\settings.json', '.claude\settings.local.json', '.mcp.json')) {
            $file = Join-Path $dir $rel
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
            $files.Add($file)
            try { $doc = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable } catch { continue }
            if ($doc -isnot [System.Collections.IDictionary]) { continue }
            if ($rel -eq '.mcp.json') {
                if ($doc['mcpServers'] -is [System.Collections.IDictionary]) { foreach ($k in $doc['mcpServers'].Keys) { $mcp.Add([string]$k) } }
                continue
            }
            if ($doc['hooks'] -is [System.Collections.IDictionary]) {
                foreach ($entries in $doc['hooks'].Values) { foreach ($m in @($entries)) { if ($m -is [System.Collections.IDictionary]) { $hooks += @($m['hooks'] | Where-Object { $_ }).Count } } }
            }
            if ($doc['permissions'] -is [System.Collections.IDictionary]) { $allow += @($doc['permissions']['allow'] | Where-Object { $_ }).Count }
            if ($doc['env'] -is [System.Collections.IDictionary]) { $envKeys += $doc['env'].Count }
        }
    }
    return [ordered]@{ files = @($files); hooks = $hooks; mcpServers = @($mcp | Select-Object -Unique); allowRules = $allow; envKeys = $envKeys }
}

# The refusal for a folder Claude Code does not trust yet, with what trusting it would switch on.
function New-UntrustedRefusal {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Message)
    return [ordered]@{
        ok = $false; code = 'UNTRUSTED_WORKSPACE'; path = $Path
        trustKey = (Get-TrustKey -Path $Path); isRepo = [bool](Get-GitRootOrNull -Path $Path)
        ships = (Get-WorkspaceShips -Path $Path); message = $Message
    }
}

# The one writer of ~/.claude.json, for -TrustFolder. It writes what answering the
# trust prompt writes -- projects[<trust key>].hasTrustDialogAccepted = true -- under
# the lock Claude Code itself takes for that file (a `<file>.lock` DIRECTORY, the
# proper-lockfile convention), re-reading the file inside the lock so a running
# session's last write is never lost, and replacing it in one rename.
function Set-WorkspaceTrusted {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ConfigFile = (Get-ClaudeConfigFile),
        [int]$LockAttempts = 30
    )
    $key = Get-TrustKey -Path $Path
    $userHome = ConvertTo-TrustPath (ConvertTo-NormalizedPath $env:USERPROFILE)
    # A drive root, the home folder or anything above it would hand trust to every
    # folder below; Claude Code itself never persists trust for the home folder.
    if ($key -notmatch '/' -or $key -ieq $userHome -or $userHome.StartsWith($key + '/', [StringComparison]::OrdinalIgnoreCase)) {
        return [ordered]@{
            ok = $false; code = 'TRUST_REFUSED'; trustKey = $key
            message = 'The kit does not mark a drive root or the home folder (or a folder above it) as trusted: every folder below would be trusted with it. Nothing was written or opened.'
        }
    }
    if (Test-WorkspaceTrusted -Path $Path -ConfigFile $ConfigFile) {
        return [ordered]@{ ok = $true; code = 'ALREADY_TRUSTED'; trustKey = $key; written = $false }
    }
    $fail = { param($why) [ordered]@{ ok = $false; code = 'TRUST_WRITE_FAILED'; trustKey = $key; message = "Could not mark the folder trusted ($why). Nothing was written or opened." } }
    if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) { return (& $fail 'Claude Code has no config file yet: run claude once') }
    # ConvertFrom-Json -DateKind (below) exists from PowerShell 7.5 on.
    if ($PSVersionTable.PSVersion -lt [version]'7.5') { return (& $fail "this needs PowerShell 7.5 or later; this is $($PSVersionTable.PSVersion)") }

    # mkdir is the lock: it fails atomically when the directory exists. .NET's
    # CreateDirectory succeeds on an existing one, so the Win32 call is used.
    if (-not ('ClaudeSessionKit.NativeDir' -as [type])) {
        Add-Type -Namespace ClaudeSessionKit -Name NativeDir -MemberDefinition '[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool CreateDirectoryW(string path, IntPtr security);'
    }
    $lock = $ConfigFile + '.lock'
    $held = $false
    for ($i = 0; $i -lt $LockAttempts -and -not $held; $i++) {
        $held = [ClaudeSessionKit.NativeDir]::CreateDirectoryW($lock, [IntPtr]::Zero)
        if (-not $held) {
            if ([Runtime.InteropServices.Marshal]::GetLastWin32Error() -ne 183) { break }   # anything but ERROR_ALREADY_EXISTS
            Start-Sleep -Milliseconds 100
        }
    }
    if (-not $held) { return (& $fail 'another Claude Code process holds the config lock; try again') }

    $tmp = '{0}.csk-{1}.tmp' -f $ConfigFile, [guid]::NewGuid().ToString('N')
    try {
        $text = [IO.File]::ReadAllText($ConfigFile)
        # -DateKind String: without it every ISO date in the file comes back reformatted.
        $config = $text | ConvertFrom-Json -AsHashtable -DateKind String
        if ($config -isnot [System.Collections.IDictionary]) { return (& $fail 'the config file is not a JSON object') }
        if ($config['projects'] -isnot [System.Collections.IDictionary]) { $config['projects'] = [ordered]@{} }
        $entry = $config['projects'][$key]
        if ($entry -is [System.Collections.IDictionary]) { $entry['hasTrustDialogAccepted'] = $true }
        else { $config['projects'][$key] = [ordered]@{ hasTrustDialogAccepted = $true } }
        # A truncated document must never reach the disk: a depth overflow is an error, not a warning.
        $json = $config | ConvertTo-Json -Depth 100 -WarningAction Stop
        $back = $json | ConvertFrom-Json -AsHashtable -DateKind String
        if (($back | ConvertTo-Json -Depth 100 -Compress) -cne ($config | ConvertTo-Json -Depth 100 -Compress)) { return (& $fail 'the rewritten file did not read back the same') }
        [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
        Copy-Item -LiteralPath $ConfigFile -Destination (Get-KitPath trustBackup) -Force
        [IO.File]::Move($tmp, $ConfigFile, $true)
    } catch {
        return (& $fail $_.Exception.Message)
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction Ignore
        try { [IO.Directory]::Delete($lock) } catch {}
    }
    Write-KitLog ("trust written key={0}" -f $key)
    return [ordered]@{ ok = $true; code = 'TRUSTED'; trustKey = $key; written = $true }
}

# --- aliases ----------------------------------------------------------------------------
function Read-AliasDocument {
    $file = Get-KitPath aliases
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try {
        $doc = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    } catch {
        # Reaches the model as INTERNAL_ERROR from whichever script needed an alias,
        # so the message has to say which file to fix.
        throw "aliases.json is not valid JSON ($file): $($_.Exception.Message)"
    }
    if ($doc -isnot [System.Collections.IDictionary]) { throw "aliases.json is not a JSON object ($file)." }
    return $doc
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

# A script's -Alias / -Path to the folder it works in. Scope is $null when neither was
# given; Refusal is the ALIAS_NOT_FOUND / PATH_NOT_FOUND to print, -Suffix appended to
# its message. An alias that is not registered is an error: no other folder is guessed.
function Resolve-AliasOrPath {
    param([string]$Alias, [string]$Path, [string]$Suffix = '')
    $out = [pscustomobject]@{ Scope = $null; Alias = $null; Refusal = $null }
    if ($Alias) {
        $entry = Find-Alias -Name $Alias
        if (-not $entry) {
            $out.Refusal = [ordered]@{ ok = $false; code = 'ALIAS_NOT_FOUND'; alias = $Alias; known = @(Get-AliasTable | ForEach-Object name); message = "Alias '$Alias' is not registered.$Suffix" }
            return $out
        }
        $out.Alias = $entry.name
        $Path = $entry.path
    }
    if ($Path) {
        $out.Scope = Resolve-WorkspacePath $Path
        if (-not $out.Scope) { $out.Refusal = [ordered]@{ ok = $false; code = 'PATH_NOT_FOUND'; path = $Path; alias = $out.Alias; message = "That folder does not exist.$Suffix" } }
    }
    return $out
}

function Get-TempTaskSettings {
    $root = Join-Path $env:USERPROFILE 'Downloads'
    $prefix = 'test'
    try {
        $tt = (Read-AliasDocument)['tempTask']
        if ($tt['root']) { $root = [Environment]::ExpandEnvironmentVariables([string]$tt['root']) }
        if ($tt['prefix']) { $prefix = [string]$tt['prefix'] }
    } catch {}
    return [pscustomobject]@{ Root = $root; Prefix = $prefix }
}

# --- launched sessions ---------------------------------------------------------------------
# sessions.jsonl is append-only: one JSON object per line, one line per session this
# kit opened. Resume looks here FIRST: it holds only sessions a person started on
# purpose, while the newest transcript on the machine is usually another tool's.
# It is never rewritten in place, and a damaged line costs that line, not the file.
function Register-LaunchedSession {
    param([Parameter(Mandatory)][string]$SessionId, [Parameter(Mandatory)][string]$Cwd)
    # alias and source are read by nothing here; the 0.4.0 reader runs in strict mode and drops a row without them
    $record = [ordered]@{ sessionId = $SessionId; cwd = $Cwd; alias = $null; source = $null; startedAt = (Get-Date).ToString('o') } | ConvertTo-Json -Compress
    $mutex = [Threading.Mutex]::new($false, 'Local\ClaudeSessionKitRegistry')
    $held = $false
    try {
        try { $held = $mutex.WaitOne(3000) } catch [Threading.AbandonedMutexException] { $held = $true }
        [IO.File]::AppendAllText((Get-KitPath registry), $record + "`n", [Text.UTF8Encoding]::new($false))
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

# Rows SessionId, Cwd for the sessions launched in the last -Days days.
function Get-RegisteredSessions {
    param([int]$Days = 30)
    $file = Get-KitPath registry
    if (-not (Test-Path -LiteralPath $file)) { return }
    $cutoff = (Get-Date).AddDays(-$Days)
    foreach ($line in [IO.File]::ReadAllLines($file)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $r = $line | ConvertFrom-Json
            if (-not (Test-SessionIdFormat $r.sessionId) -or -not $r.cwd) { continue }
            # "o"-format timestamps are auto-converted to DateTime by ConvertFrom-Json on PS7.
            $started = if ($r.startedAt -is [datetime]) { $r.startedAt } else { [datetime]::Parse([string]$r.startedAt) }
            if ($started -ge $cutoff) { [pscustomobject]@{ SessionId = [string]$r.sessionId; Cwd = [string]$r.cwd } }
        } catch { continue }
    }
}

# --- transcripts ---------------------------------------------------------------------------
# Reads the first -HeadLines lines and the last -TailBytes bytes, never the middle:
# transcripts of 10+ MB are common. The CLI appends its custom-title / ai-title
# records again as a session goes on -- across 152 real transcripts the last one
# always ended within 40 KB of the end of the file -- so the tail holds the latest.
function Get-ClaudeSessionRecord {
    param([Parameter(Mandatory)][string]$TranscriptPath, [int]$HeadLines = 120, [int]$TailBytes = 64KB)

    $lines = @()
    $tail = @()
    try {
        $fs = [IO.File]::Open($TranscriptPath, 'Open', 'Read', 'ReadWrite, Delete')   # a live session holds it open
        try {
            $reader = [IO.StreamReader]::new($fs, [Text.Encoding]::UTF8)
            # Collected as output, never List.Add($line): PowerShell hands every .NET method
            # argument to AMSI, and a transcript line can be megabytes (536 transcripts: 6.4 s against 0.6 s).
            $n = 0
            $lines = @(while ($n -lt $HeadLines -and $null -ne ($line = $reader.ReadLine())) { $n++; $line })
            if (-not $reader.EndOfStream) {
                $start = [Math]::Max(0, $fs.Length - $TailBytes)
                # One byte early, so the first piece is always a part line to drop: empty
                # when the window starts right at a line start, never a whole line.
                $fs.Position = [Math]::Max(0, $start - 1)
                $tail = @([IO.StreamReader]::new($fs, [Text.Encoding]::UTF8).ReadToEnd() -split "`r?`n")
                if ($start -gt 0) { $tail = @($tail | Select-Object -Skip 1) }
            }
        } finally { $fs.Dispose() }
    } catch {
        return [pscustomobject]@{
            SessionId = $null; Kind = 'unreadable'; Cwd = $null; Title = $null
            LastWrite = [datetime]::MinValue; TranscriptPath = $TranscriptPath
        }
    }
    $info = Get-TranscriptHeadInfo -Lines $lines -TailLines $tail
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
        [string[]]$Kinds = @('interactive')
    )
    $projectsDir = Get-ClaudeProjectsDir
    if (-not (Test-Path -LiteralPath $projectsDir)) { return }

    $dirs = if ($Path) {
        $one = Join-Path $projectsDir (ConvertTo-ProjectSlug $Path)
        if (Test-Path -LiteralPath $one) { @(Get-Item -LiteralPath $one) } else { @() }
    } else {
        @(Get-ChildItem -LiteralPath $projectsDir -Directory -ErrorAction SilentlyContinue)
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

# --- running sessions (READ ONLY) ------------------------------------------------------------
# Which conversations are open right now. `claude agents --json` is the documented
# answer (Claude Code 2.1.145+) and the only process this file starts: a read-only
# query with fixed arguments. When it is missing or fails, the CLI's own per-process
# records (<claude home>\sessions\<pid>.json) are read instead, and one counts only
# while that PID is alive AND was started at the recorded time (or, with no start time
# to compare, is a claude or node process) -- Windows reuses PIDs, so a live PID alone
# may be anybody's process.
# Rows: SessionId, Pid, Kind (interactive | background | ...), Cwd, Name, Status, Source.
function Get-RunningSessions {
    $rows = $null
    $claude = Resolve-ClaudeBinary
    if ($claude) {
        try {
            $psi = [Diagnostics.ProcessStartInfo]::new($claude)
            $psi.ArgumentList.Add('agents'); $psi.ArgumentList.Add('--json')
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
            $p = [Diagnostics.Process]::Start($psi)
            $out = $p.StandardOutput.ReadToEndAsync(); $null = $p.StandardError.ReadToEndAsync()
            if ($p.WaitForExit(10000) -and $p.ExitCode -eq 0) {
                $rows = @(foreach ($r in @($out.Result | ConvertFrom-Json -AsHashtable)) {
                        if (-not $r -or -not (Test-SessionIdFormat ([string]$r['sessionId']))) { continue }
                        [pscustomobject]@{
                            SessionId = [string]$r['sessionId']; Pid = $r['pid']; Kind = [string]$r['kind']; Cwd = [string]$r['cwd']
                            Name = [string]$r['name']; Status = [string]$(if ($r['status']) { $r['status'] } else { $r['state'] }); Source = 'agents'
                            # a background row's short job id: what `claude attach` takes (a sessionId it does not)
                            JobId = [string]$r['id']
                        }
                    })
            } else {
                # The whole tree: behind a .cmd shim the hung claude holds our stdout open.
                try { $p.Kill($true) } catch {}
            }
        } catch { $rows = $null }
    }
    if ($null -ne $rows) { return $rows }

    $dir = Join-Path (Get-ClaudeHome) 'sessions'
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try { $r = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable } catch { continue }
        if (-not $r -or -not (Test-SessionIdFormat ([string]$r['sessionId'])) -or -not $r['pid']) { continue }
        $proc = Get-Process -Id ([int]$r['pid']) -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        # procStart is the creation time as a FILETIME. Without it, or with the start time
        # unreadable (an elevated process), a live PID still counts when it is a claude or
        # node process: a refused duplicate is cheaper than two tabs writing one transcript.
        $started = $null
        try { $started = $proc.StartTime.ToUniversalTime().ToFileTimeUtc() } catch {}
        if ($r['procStart'] -and $null -ne $started) { if ($started -ne [long]$r['procStart']) { continue } }
        elseif ($proc.ProcessName -notin 'claude', 'node') { continue }
        [pscustomobject]@{
            # these records spell a background session 'bg'; `claude agents --json` says 'background'
            SessionId = [string]$r['sessionId']; Pid = [int]$r['pid']; Kind = $(if ($r['kind'] -eq 'bg') { 'background' } else { [string]$r['kind'] }); Cwd = [string]$r['cwd']
            Name = [string]$r['name']; Status = [string]$r['status']; Source = 'pidfile'; JobId = ''
        }
    }
}

# --- resume target --------------------------------------------------------------------------
# A session's transcript in whichever project folder holds it: /cd, EnterWorktree and
# ExitWorktree move it to another folder's slug. $null when there is none.
function Find-SessionTranscript {
    param([Parameter(Mandatory)][string]$SessionId)
    if (-not (Test-SessionIdFormat $SessionId)) { return $null }
    foreach ($d in @(Get-ChildItem -LiteralPath (Get-ClaudeProjectsDir) -Directory -ErrorAction SilentlyContinue)) {
        $candidate = Join-Path $d.FullName ($SessionId + '.jsonl')
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

# The session to reopen, in -Path when given:
#   1. an explicit -SessionId (it must exist as an interactive transcript; never guessed)
#   2. a session this kit opened (sessions.jsonl), the one written to last
#   3. the newest interactive transcript of the last -Days days
# -RunningSessions (Get-RunningSessions rows) and the asking session are skipped by
# the automatic choice: the newest session is
# usually the one asking, and an open one cannot be reopened anyway. An explicit id
# is not skipped; the launch refuses it. SessionId is $null, with a Reason, when
# there is nothing to reopen. The folder is always the one RECORDED for the session:
# `claude --resume <id>` finds a session from anywhere, then works in whatever
# directory it was started from.
function Resolve-ResumeTarget {
    param(
        [string]$Path,
        [string]$SessionId,
        [int]$Days = 30,
        [object[]]$RunningSessions = @()
    )
    $none = { param($reason) [pscustomobject]@{ SessionId = $null; Cwd = $Path; Title = $null; Reason = $reason } }

    if ($SessionId) {
        if (-not (Test-SessionIdFormat $SessionId)) { return (& $none "Not a session id: $SessionId") }
        $candidate = Find-SessionTranscript -SessionId $SessionId
        if (-not $candidate) { return (& $none "No transcript exists for session $SessionId.") }
        $found = Get-ClaudeSessionRecord -TranscriptPath $candidate
        if ($found.Kind -ne 'interactive') { return (& $none "Session $SessionId is '$($found.Kind)', not an interactive CLI session.") }
        $cwd = if ($found.Cwd) { $found.Cwd } else { $Path }
        if (-not $cwd) { return (& $none "Session $SessionId records no working directory.") }
        return [pscustomobject]@{ SessionId = $SessionId; Cwd = $cwd; Title = $found.Title; Reason = $null }
    }

    $open = @{}
    foreach ($o in @($RunningSessions)) { if ($o -and $o.SessionId) { $open[[string]$o.SessionId] = $true } }
    # The asking session is open whatever the CLI could tell us.
    if ($env:CLAUDE_CODE_SESSION_ID) { $open[$env:CLAUDE_CODE_SESSION_ID] = $true }
    $best = $null
    foreach ($r in @(Get-RegisteredSessions -Days $Days)) {
        if ($open.ContainsKey($r.SessionId) -or ($Path -and -not (Test-PathEqual $r.Cwd $Path))) { continue }
        $t = Join-Path (Get-ProjectTranscriptDir $r.Cwd) ($r.SessionId + '.jsonl')
        # Registered but never written: the person closed it before saying anything.
        if (-not (Test-Path -LiteralPath $t)) { continue }
        $rec = Get-ClaudeSessionRecord -TranscriptPath $t
        if ($rec.Kind -eq 'interactive' -and (-not $best -or $rec.LastWrite -gt $best.LastWrite)) {
            # the folder is the one recorded at launch
            $best = [pscustomobject]@{ SessionId = $r.SessionId; Cwd = $r.Cwd; LastWrite = $rec.LastWrite; Title = $rec.Title }
        }
    }
    if ($best) { return [pscustomobject]@{ SessionId = $best.SessionId; Cwd = $best.Cwd; Title = $best.Title; Reason = $null } }

    $skipped = 0
    foreach ($s in @(Get-ClaudeSessions -Path $Path -Days $Days)) {
        if ($open.ContainsKey($s.SessionId)) { $skipped++; continue }
        $cwd = if ($s.Cwd) { $s.Cwd } else { $Path }
        if (-not $cwd) { continue }
        return [pscustomobject]@{ SessionId = $s.SessionId; Cwd = $cwd; Title = $s.Title; Reason = $null }
    }
    if ($skipped) { return (& $none "No closed interactive session found in the last $Days days; $skipped open right now (this one counts) were skipped.") }
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
