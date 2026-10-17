#requires -Version 7.0
<#
.SYNOPSIS
  Test suite for claude-session-kit. No Pester, no network, no terminal tab, no reboot.

.DESCRIPTION
  Everything runs against a throwaway sandbox: CLAUDE_SESSION_KIT_HOME redirects
  the kit's state and CLAUDE_CONFIG_DIR redirects Claude Code's config/projects, so
  a person's real aliases, registry and ~/.claude.json are never read or written.
  Scripts that would open a tab are only ever driven into their refusal paths,
  reboot-commit.ps1 is only ever run with -Simulate, and the resume script is only
  ever pointed (CLAUDE_CODE_BIN) at stand-ins for `claude` that record their argv.

      pwsh -NoProfile -File tests/run-tests.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
# The scripts print UTF-8; this process decodes what it captures with ITS console
# encoding. Without this, a non-ASCII temp path (a Hangul account name on a CP949
# console) comes back as mojibake and correct code fails the suite.
$script:savedOutEnc = $null
try { $script:savedOutEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch {}
$repo    = Split-Path -Parent $PSScriptRoot
$scripts = Join-Path $repo 'skills\session\scripts'

$script:pass = 0; $script:fail = 0; $script:skipped = 0
function Check([string]$Name, [scriptblock]$Test) {
    try {
        $r = & $Test
        if ($r -is [bool] -and -not $r) { throw 'returned false' }
        $script:pass++; Write-Host "  ok    $Name"
    } catch {
        $script:fail++; Write-Host "  FAIL  $Name -- $($_.Exception.Message)" -ForegroundColor Red
    }
}
function Skip([string]$Name, [string]$Why) { $script:skipped++; Write-Host "  skip  $Name -- $Why" -ForegroundColor DarkYellow }
function Same($Actual, $Expected) {
    $a = ($Actual | ConvertTo-Json -Compress -Depth 6); $e = ($Expected | ConvertTo-Json -Compress -Depth 6)
    if ($a -cne $e) { throw "expected $e but got $a" }
    return $true
}
function Throws([scriptblock]$Block) { try { & $Block | Out-Null } catch { return $true }; throw 'expected an exception' }

# --- sandbox ---------------------------------------------------------------------
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('csk-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$kitHome = Join-Path $sandbox 'kit'
$cfgDir  = Join-Path $sandbox 'claude'
$work    = Join-Path $sandbox 'work'
New-Item -ItemType Directory -Force -Path $kitHome, (Join-Path $cfgDir 'projects'), $work | Out-Null
$saved = @{ kit = $env:CLAUDE_SESSION_KIT_HOME; cfg = $env:CLAUDE_CONFIG_DIR; sid = $env:CLAUDE_SESSION_ID; csid = $env:CLAUDE_CODE_SESSION_ID; bin = $env:CLAUDE_CODE_BIN }
$env:CLAUDE_SESSION_KIT_HOME = $kitHome
$env:CLAUDE_CONFIG_DIR = $cfgDir
$env:CLAUDE_SESSION_ID = $null
$env:CLAUDE_CODE_SESSION_ID = $null   # the suite may itself be running inside a Claude Code session
$env:CLAUDE_CODE_BIN = $null
$env:CSK_TEST_WORK = $work

$runOnceKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
function Get-RealRunOnce { try { (Get-ItemProperty -Path $runOnceKey -Name 'ClaudeRebootContinue' -ErrorAction Stop).ClaudeRebootContinue } catch { $null } }
$runOnceBefore = Get-RealRunOnce

function Invoke-Script([string]$Name, [string[]]$Arguments = @()) {
    $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scripts $Name) @Arguments 2>&1
    $code = $LASTEXITCODE
    $text = @($out | ForEach-Object { "$_" }) -join "`n"
    $json = $null
    try { $json = ($text -split "`n" | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json } catch {}
    return [pscustomobject]@{ ExitCode = $code; Json = $json; Text = $text }
}

function New-Transcript([string]$Cwd, [string]$Entrypoint, [datetime]$When, [string]$SubDir, [string]$Title) {
    $id = [guid]::NewGuid().ToString()
    $dir = Join-Path (Join-Path $cfgDir 'projects') (ConvertTo-ProjectSlug $Cwd)
    if ($SubDir) { $dir = Join-Path $dir $SubDir }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $lines = @((@{ type = 'mode'; sessionId = $id } | ConvertTo-Json -Compress))
    if ($Entrypoint) { $lines += (@{ type = 'user'; entrypoint = $Entrypoint; cwd = $Cwd; sessionId = $id } | ConvertTo-Json -Compress) }
    if ($Title) { $lines += (@{ type = 'ai-title'; aiTitle = $Title; sessionId = $id } | ConvertTo-Json -Compress) }
    $file = Join-Path $dir ($id + '.jsonl')
    [IO.File]::WriteAllLines($file, $lines)
    (Get-Item $file).LastWriteTime = $When
    return $id
}

try {
    . (Join-Path $scripts 'lib\Core.State.ps1')

    Write-Host "`nCore.Pure"
    Check 'slug: every non-alphanumeric char, Hangul included, is one dash' {
        Same (ConvertTo-ProjectSlug 'C:\Users\someone\Documents\한글 폴더.v2') 'C--Users-someone-Documents-------v2'
    }
    Check 'slug: trailing separator is dropped, drive root is kept' {
        (Same (ConvertTo-ProjectSlug 'C:\work\') 'C--work') -and (Same (ConvertTo-ProjectSlug 'C:\') 'C--')
    }
    Check 'argv: new session carries --session-id' {
        Same (Get-ClaudeArgs -Mode new -SessionId '11111111-1111-1111-1111-111111111111') @('--session-id', '11111111-1111-1111-1111-111111111111')
    }
    Check 'argv: the prompt always follows --' {
        Same (Get-ClaudeArgs -Mode resume -SessionId '11111111-1111-1111-1111-111111111111' -Prompt 'go on') @('--resume', '11111111-1111-1111-1111-111111111111', '--', 'go on')
    }
    Check 'argv: fork goes before --' {
        Same (Get-ClaudeArgs -Mode resume -SessionId '11111111-1111-1111-1111-111111111111' -Fork -Prompt 'x') @('--resume', '11111111-1111-1111-1111-111111111111', '--fork-session', '--', 'x')
    }
    Check 'argv: picker is a bare --resume and refuses a prompt' {
        (Same (Get-ClaudeArgs -Mode picker) @('--resume')) -and (Throws { Get-ClaudeArgs -Mode picker -Prompt 'x' })
    }
    Check 'argv: resume refuses anything that is not a session id' { Throws { Get-ClaudeArgs -Mode resume -SessionId 'latest' } }
    Check 'argv: a name and a replayed permission mode go first; bypassPermissions is never replayed' {
        (Same (Get-ClaudeArgs -Mode new -SessionId '11111111-1111-1111-1111-111111111111' -Name 'blog refactor' -PermissionMode plan) @('--permission-mode', 'plan', '--name', 'blog refactor', '--session-id', '11111111-1111-1111-1111-111111111111')) -and
        (Throws { Get-ClaudeArgs -Mode resume -SessionId '11111111-1111-1111-1111-111111111111' -PermissionMode bypassPermissions }) -and
        (Throws { Get-ClaudeArgs -Mode new -PermissionMode 'Plan' }) -and
        (Throws { Get-ClaudeArgs -Mode new -Name "two`nlines" })
    }
    Check 'session id: a trailing line feed is not part of a UUID' {
        (Test-SessionIdFormat '11111111-1111-1111-1111-111111111111') -and -not (Test-SessionIdFormat "11111111-1111-1111-1111-111111111111`n") -and
        (Throws { Get-ClaudeArgs -Mode resume -SessionId "11111111-1111-1111-1111-111111111111`n" })
    }
    Check 'shim: .cmd and .bat are shims, .exe is not' {
        (Test-ClaudeShim 'C:\npm\claude.cmd') -and (Test-ClaudeShim 'C:\npm\CLAUDE.BAT') -and -not (Test-ClaudeShim 'C:\bin\claude.exe') -and -not (Test-ClaudeShim '')
    }
    Check 'quoting: spaces, embedded quotes, trailing backslash' {
        (Same (ConvertTo-QuotedArgument 'plain') 'plain') -and
        (Same (ConvertTo-QuotedArgument 'a b') '"a b"') -and
        (Same (ConvertTo-QuotedArgument 'say "hi"') '"say \"hi\""') -and
        (Same (ConvertTo-QuotedArgument 'C:\dir with space\') '"C:\dir with space\\"')
    }
    Check 'wt: exact argument list, ; escaped, child after --' {
        Same (New-WtArgumentList -WorkDir 'C:\a;b' -Exe 'C:\bin\claude.exe' -Arguments @('--resume', 'x')) @('-w', '0', 'nt', '-d', 'C:\a\;b', '--', 'C:\bin\claude.exe', '--resume', 'x')
    }
    Check 'RunOnce: exact command, new window, no workdir, no prompt' {
        Same (New-RunOnceCommand -PowerShellExe 'C:\p\pwsh.exe' -ResumeScript 'C:\k\runtime\resume.ps1' -WtExe 'C:\w\wt.exe') 'C:\w\wt.exe -w new nt -- C:\p\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File C:\k\runtime\resume.ps1'
    }
    Check 'RunOnce: paths with spaces are quoted; 260 is the ceiling' {
        $c = New-RunOnceCommand -PowerShellExe 'C:\Program Files\pwsh.exe' -ResumeScript 'C:\k\resume.ps1'
        (Same $c '"C:\Program Files\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -File C:\k\resume.ps1') -and
        (Test-RunOnceCommandLength ('x' * 260)) -and -not (Test-RunOnceCommandLength ('x' * 261))
    }
    Check 'temp index: union of disk and history, bare prefix counts as 0' {
        (Same (Get-NextTempIndex -Prefix 'test' -DiskNames @('test', 'test2', 'test6', 'testing') -HistorySlugs @('C--U-Downloads-test7', 'C--U-Downloads-test30', 'C--U-Downloads-test-9', 'C--Other-test99') -RootSlug 'C--U-Downloads') 31) -and
        (Same (Get-NextTempIndex -Prefix 'test' -DiskNames @('test')) 1) -and
        (Same (Get-NextTempIndex -Prefix 'test') 1)
    }
    Check 'temp index: a timestamp-like suffix is ignored instead of overflowing' {
        Same (Get-NextTempIndex -Prefix 'test' -DiskNames @('test4', 'test20240101120000') -HistorySlugs @('C--U-Downloads-test20240101120000', 'C--U-Downloads-test7') -RootSlug 'C--U-Downloads') 8
    }
    Check 'transcript head: cli is interactive, anything else is automated' {
        $i = Get-TranscriptHeadInfo -Lines @('{"type":"mode","sessionId":"s"}', '{"type":"user","entrypoint":"cli","cwd":"C:\\Users\\x\\p","sessionId":"s"}')
        $a = Get-TranscriptHeadInfo -Lines @('{"entrypoint":"sdk-cli","cwd":"C:\\x"}')
        $n = Get-TranscriptHeadInfo -Lines @('{"entrypoint":"something-new","cwd":"C:\\x"}')
        (Same $i.Kind 'interactive') -and (Same $i.Cwd 'C:\Users\x\p') -and (Same $a.Kind 'automated') -and (Same $n.Kind 'automated')
    }
    Check 'transcript head: sidecar and unknown are told apart; last title wins' {
        $s = Get-TranscriptHeadInfo -Lines @('{"type":"last-prompt","sessionId":"s"}', '{"type":"mode","sessionId":"s"}')
        $u = Get-TranscriptHeadInfo -Lines @('{"type":"queue-operation"}')
        $t = Get-TranscriptHeadInfo -Lines @('{"type":"ai-title","aiTitle":"first"}', '{"type":"ai-title","aiTitle":"second \"q\""}')
        (Same $s.Kind 'sidecar') -and (Same $u.Kind 'unknown') -and (Same $t.Title 'second "q"')
    }
    Check 'aliases: v1 flat map and v2 document both load' {
        $v1 = @(ConvertFrom-AliasDocument ('{"proj":"C:\\p","Count":"C:\\c"}' | ConvertFrom-Json))
        $v2 = @(ConvertFrom-AliasDocument ('{"version":2,"tempTask":{"prefix":"t"},"aliases":{"proj":{"path":"C:\\p","triggers":["the project"],"note":"n","confirm":true}}}' | ConvertFrom-Json))
        (Same @($v1.name) @('proj', 'Count')) -and (Same $v1[1].path 'C:\c') -and
        (Same @($v2.name) @('proj')) -and (Same $v2[0].triggers @('the project')) -and (Same $v2[0].confirm $true)
    }

    Write-Host "`nCore.State (sandbox)"
    $plain   = New-Item -ItemType Directory -Force -Path (Join-Path $work 'trusted-parent\plain') | ForEach-Object FullName
    $repoDir = New-Item -ItemType Directory -Force -Path (Join-Path $work 'trusted-parent\repo\src') | ForEach-Object FullName
    New-Item -ItemType Directory -Force -Path (Join-Path $work 'trusted-parent\repo\.git') | Out-Null
    $declined = New-Item -ItemType Directory -Force -Path (Join-Path $work 'declined') | ForEach-Object FullName
    $trustedRepo = New-Item -ItemType Directory -Force -Path (Join-Path $work 'okrepo\deep') | ForEach-Object FullName
    New-Item -ItemType File -Force -Path (Join-Path $work 'okrepo\.git') | Out-Null     # worktree-style .git FILE
    $cfg = @{ projects = @{
            (ConvertTo-TrustPath (Join-Path $work 'trusted-parent')).ToLowerInvariant() = @{ hasTrustDialogAccepted = $true }
            (ConvertTo-TrustPath $declined) = @{ hasTrustDialogAccepted = $false }
            (ConvertTo-TrustPath (Join-Path $work 'okrepo')) = @{ hasTrustDialogAccepted = $true }
        } }
    [IO.File]::WriteAllText((Join-Path $cfgDir '.claude.json'), ($cfg | ConvertTo-Json -Depth 5))
    $cfgHash = (Get-FileHash (Join-Path $cfgDir '.claude.json')).Hash

    if (Get-GitRootOrNull -Path $sandbox) {
        Skip 'trust: inheritance tests' 'the temp folder itself sits inside a git repository'
    } else {
        Check 'trust: a plain folder inherits from a trusted ancestor (key case-insensitive)' { Test-WorkspaceTrusted -Path $plain }
        Check 'trust: a repository does NOT inherit from a trusted parent' { -not (Test-WorkspaceTrusted -Path $repoDir) }
        Check 'trust: an entry holding false is not trust' { -not (Test-WorkspaceTrusted -Path $declined) }
        Check 'trust: inside a trusted repo (.git as a FILE) is trusted via the root' { Test-WorkspaceTrusted -Path $trustedRepo }
        Check 'trust: unknown folder, missing or corrupt config all mean untrusted' {
            $bad = Join-Path $sandbox 'bad.json'; 'not json' | Set-Content $bad
            -not (Test-WorkspaceTrusted -Path $work) -and
            -not (Test-WorkspaceTrusted -Path $plain -ConfigFile (Join-Path $sandbox 'absent.json')) -and
            -not (Test-WorkspaceTrusted -Path $plain -ConfigFile $bad)
        }
        Check 'trust: the key reported for a repo subfolder is the repo root' { Same (Get-TrustKey -Path $repoDir) (ConvertTo-TrustPath (Join-Path $work 'trusted-parent\repo')) }
    }

    $now = Get-Date
    $old    = New-Transcript -Cwd $plain -Entrypoint 'cli' -When $now.AddDays(-3) -Title 'older work'
    $newer  = New-Transcript -Cwd $plain -Entrypoint 'cli' -When $now.AddHours(-2) -Title 'newer work'
    $cron   = New-Transcript -Cwd $plain -Entrypoint 'sdk-cli' -When $now.AddMinutes(-5)
    $sub    = New-Transcript -Cwd $plain -Entrypoint 'cli' -When $now.AddMinutes(-1) -SubDir 'subagents'
    $stale  = New-Transcript -Cwd $plain -Entrypoint 'cli' -When $now.AddDays(-45)
    $side   = New-Transcript -Cwd $plain -Entrypoint $null -When $now.AddMinutes(-20)   # a stale sidecar

    Check 'sessions: newest interactive first; cron, subfolder, stale and sidecar excluded' {
        Same @((Get-ClaudeSessions -Path $plain -Days 30).SessionId) @($newer, $old)
    }
    Check 'sessions: a transcript recorded for another cwd in the same slug dir is skipped' {
        $foreign = [guid]::NewGuid().ToString()
        $dir = Join-Path (Join-Path $cfgDir 'projects') (ConvertTo-ProjectSlug $plain)
        [IO.File]::WriteAllLines((Join-Path $dir "$foreign.jsonl"), @((@{ entrypoint = 'cli'; cwd = 'C:\somewhere\else'; sessionId = $foreign } | ConvertTo-Json -Compress)))
        $foreign -notin @((Get-ClaudeSessions -Path $plain).SessionId)
    }
    Check 'resume ladder: scan is used while the registry is empty' {
        $t = Resolve-ResumeTarget -Path $plain
        (Same $t.Mode 'resume-id') -and (Same $t.SessionId $newer) -and (Same $t.Source 'scan') -and (Same $t.Title 'newer work')
    }
    Check 'registry: append, read back, survive a damaged line' {
        Register-LaunchedSession -SessionId $old -Cwd $plain -Alias 'p' -Source open
        Add-Content -LiteralPath (Get-KitPath registry) -Value '{ this is not json'
        Register-LaunchedSession -SessionId ([guid]::NewGuid().ToString()) -Cwd $plain -Source new   # never written: no transcript
        $r = @(Get-RegisteredSessions)
        (Same $r.Count 2) -and (Same $r[0].SessionId $old) -and (Same $r[0].Alias 'p')
    }
    Check 'resume ladder: a registered session wins over a newer unregistered one' {
        $t = Resolve-ResumeTarget -Path $plain
        (Same $t.SessionId $old) -and (Same $t.Source 'registry')
    }
    Check 'resume ladder: explicit id must exist and be interactive' {
        (Same (Resolve-ResumeTarget -SessionId $newer).Cwd $plain) -and
        (Same (Resolve-ResumeTarget -SessionId $cron).Mode 'none') -and
        (Same (Resolve-ResumeTarget -SessionId ([guid]::NewGuid().ToString())).Mode 'none')
    }
    Check 'resume ladder: picker only with a folder and only when allowed' {
        (Same (Resolve-ResumeTarget -Path $declined -AllowPicker).Mode 'picker') -and
        (Same (Resolve-ResumeTarget -Path $declined).Mode 'none')
    }
    Check 'paths: UNC is refused with either kind of slash' {
        ($null -eq (Resolve-WorkspacePath '\\localhost\C$\Windows')) -and ($null -eq (Resolve-WorkspacePath '//localhost/C$/Windows'))
    }
    Check 'digest never contains the text' { (Get-TextDigest 'secret plan') -notmatch 'secret' }

    Write-Host "`nRunning sessions (stand-in claude; nothing is launched)"
    $agentsDir = New-Item -ItemType Directory -Force -Path (Join-Path $sandbox 'agents') | ForEach-Object FullName
    $agentsOk = Join-Path $agentsDir 'claude.cmd'
    [IO.File]::WriteAllText($agentsOk, "@echo off`r`necho [{`"pid`":4242,`"cwd`":`"C:\\w`",`"kind`":`"interactive`",`"sessionId`":`"$newer`",`"name`":`"n`",`"status`":`"idle`"},{`"kind`":`"background`",`"sessionId`":`"not-a-uuid`"}]`r`n")
    $agentsBad = Join-Path $agentsDir 'broken.cmd'
    [IO.File]::WriteAllText($agentsBad, "@echo off`r`nexit /b 1`r`n")
    Check 'running: `claude agents --json` is read, rows without a session id are dropped' {
        try { $env:CLAUDE_CODE_BIN = $agentsOk; $r = @(Get-RunningSessions) } finally { $env:CLAUDE_CODE_BIN = $null }
        (Same $r.Count 1) -and (Same $r[0].SessionId $newer) -and (Same $r[0].Pid 4242) -and (Same $r[0].Source 'agents')
    }
    Check 'running: without the CLI, a PID record counts only while that process lives with the recorded start time' {
        $sessDir = New-Item -ItemType Directory -Force -Path (Join-Path $cfgDir 'sessions') | ForEach-Object FullName
        $me = Get-Process -Id $PID
        $start = $me.StartTime.ToUniversalTime().ToFileTimeUtc()
        $dead = 4; while (Get-Process -Id $dead -ErrorAction SilentlyContinue) { $dead += 4 }
        $alive = [guid]::NewGuid().ToString(); $reused = [guid]::NewGuid().ToString(); $gone = [guid]::NewGuid().ToString()
        @{ "$PID.json" = @{ pid = $PID; sessionId = $alive; cwd = $plain; kind = 'interactive'; procStart = "$start" }
           'reused.json' = @{ pid = $PID; sessionId = $reused; cwd = $plain; kind = 'interactive'; procStart = "$($start + 1)" }
           "$dead.json" = @{ pid = $dead; sessionId = $gone; cwd = $plain; kind = 'interactive' } }.GetEnumerator() |
            ForEach-Object { [IO.File]::WriteAllText((Join-Path $sessDir $_.Key), ($_.Value | ConvertTo-Json)) }
        try { $env:CLAUDE_CODE_BIN = $agentsBad; $r = @(Get-RunningSessions) } finally { $env:CLAUDE_CODE_BIN = $null; Remove-Item -LiteralPath $sessDir -Recurse -Force }
        (Same @($r.SessionId) @($alive)) -and (Same $r[0].Source 'pidfile')
    }
    Check 'launch: a session that is already open is not opened a second time; a fork still is allowed through' {
        $probe = Join-Path $agentsDir 'probe.ps1'
        [IO.File]::WriteAllText($probe, @'
param($Lib, $Dir, $Id)
. $Lib
function Start-ClaudeTerminal { 'stub' }
function Register-LaunchedSession {}
$dup  = Invoke-SessionLaunch -WorkDir $Dir -Mode resume -SessionId $Id -AllowUntrusted
$fork = Invoke-SessionLaunch -WorkDir $Dir -Mode resume -SessionId $Id -Fork -AllowUntrusted
@{ dup = $dup.code; fork = $fork.code } | ConvertTo-Json -Compress
'@)
        try {
            $env:CLAUDE_CODE_BIN = $agentsOk
            $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $probe -Lib (Join-Path $scripts 'lib\Core.Effects.ps1') -Dir $plain -Id $newer 2>&1 | Select-Object -Last 1
        } finally { $env:CLAUDE_CODE_BIN = $null }
        $o = "$out" | ConvertFrom-Json
        (Same $o.dup 'ALREADY_RUNNING') -and ($o.fork -like 'RESUMED*')
    }

    Write-Host "`nScripts (sandbox; nothing is launched)"
    $aliasDoc = @{ version = 2; tempTask = @{ root = $declined; prefix = 'scratch' }; aliases = @{
            good = @{ path = $plain; triggers = @('the good one'); note = 'n' }
            gone = @{ path = (Join-Path $work 'missing') }
            nope = @{ path = $declined }
            envy = @{ path = '%CSK_TEST_WORK%\okrepo' }
        } }
    [IO.File]::WriteAllText((Get-KitPath aliases), ($aliasDoc | ConvertTo-Json -Depth 5))

    Check 'list-aliases: one JSON object with every alias and the temp settings' {
        $r = Invoke-Script 'list-aliases.ps1'
        (Same $r.ExitCode 0) -and (Same $r.Json.code 'ALIASES') -and (Same $r.Json.count 4) -and (Same $r.Json.tempTask.prefix 'scratch') -and
        (Same (@($r.Json.aliases | Where-Object name -eq 'gone')[0].exists) $false)
    }
    Check 'aliases: %VARS% in an alias path are expanded' {
        $row = @((Invoke-Script 'list-aliases.ps1').Json.aliases | Where-Object name -eq 'envy')[0]
        (Same $row.path (Join-Path $work 'okrepo')) -and (Same $row.exists $true)
    }
    Check 'aliases: a broken aliases.json is named in the error, whichever script hits it' {
        $good = Get-Content (Get-KitPath aliases) -Raw
        [IO.File]::WriteAllText((Get-KitPath aliases), '{ broken')
        $a = Invoke-Script 'list-aliases.ps1'; $o = Invoke-Script 'open-workspace.ps1' @('-Alias', 'good')
        [IO.File]::WriteAllText((Get-KitPath aliases), $good)
        (Same $a.Json.code 'ALIASES_UNREADABLE') -and (Same $o.Json.code 'INTERNAL_ERROR') -and ($o.Json.message -match 'aliases\.json is not valid JSON')
    }
    Check 'open-workspace: unknown alias is refused, nothing is guessed' {
        $r = Invoke-Script 'open-workspace.ps1' @('-Alias', 'typo')
        (Same $r.ExitCode 1) -and (Same $r.Json.code 'ALIAS_NOT_FOUND') -and ('good' -in $r.Json.known)
    }
    Check 'open-workspace: missing folder is refused' { Same (Invoke-Script 'open-workspace.ps1' @('-Alias', 'gone')).Json.code 'PATH_NOT_FOUND' }
    Check 'open-workspace: untrusted folder fails closed' {
        $r = Invoke-Script 'open-workspace.ps1' @('-Alias', 'nope')
        (Same $r.ExitCode 1) -and (Same $r.Json.code 'UNTRUSTED_WORKSPACE') -and (Same $r.Json.trustKey (ConvertTo-TrustPath $declined))
    }
    Check 'resume-session: untrusted folder fails closed' { Same (Invoke-Script 'resume-session.ps1' @('-Path', $declined)).Json.code 'UNTRUSTED_WORKSPACE' }
    Check 'resume-session: nothing to resume is an error, not a guess' {
        Same (Invoke-Script 'resume-session.ps1' @('-Path', $declined, '-NoPicker', '-AllowUntrusted')).Json.code 'NO_RESUMABLE_SESSION'
    }
    Check 'new-temp-task: untrusted root creates no folder' {
        $r = Invoke-Script 'new-temp-task.ps1'
        (Same $r.Json.code 'UNTRUSTED_WORKSPACE') -and -not (Get-ChildItem -LiteralPath $declined -Directory)
    }
    Check 'list-sessions: registry first, then scan, no automation' {
        $r = Invoke-Script 'list-sessions.ps1' @('-Alias', 'good')
        (Same @($r.Json.sessions.sessionId | Sort-Object) @(@($old, $newer) | Sort-Object)) -and (Same (@($r.Json.sessions | Where-Object sessionId -eq $old)[0].source) 'registry')
    }
    Check 'list-candidates: groups by recorded cwd and marks aliased folders' {
        $r = Invoke-Script 'list-candidates.ps1' @('-IncludeTemp')
        $row = @($r.Json.candidates | Where-Object { $_.path -eq $plain })[0]
        # 3 = both recent sessions plus the 45-day-old one: this listing looks back 90 days
        (Same $r.Json.code 'CANDIDATES') -and (Same $row.sessions 3) -and (Same $row.alias 'good')
    }

    Write-Host "`nTitles, search and retention (sandbox)"
    # Own folders, so nothing here becomes the "newest session" the reboot tests below expect.
    $titled = New-Item -ItemType Directory -Force -Path (Join-Path $work 'trusted-parent\titled') | ForEach-Object FullName
    $finds  = New-Item -ItemType Directory -Force -Path (Join-Path $work 'trusted-parent\finds') | ForEach-Object FullName
    # A transcript from records; user/assistant ones get the entrypoint and cwd a CLI transcript carries.
    function New-Chat([string]$Cwd, [object[]]$Records, [string]$Entrypoint = 'cli', [string]$SubDir, [string]$Id = [guid]::NewGuid().ToString()) {
        $dir = Join-Path (Join-Path $cfgDir 'projects') (ConvertTo-ProjectSlug $Cwd)
        if ($SubDir) { $dir = Join-Path $dir $SubDir }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $lines = foreach ($r in $Records) {
            if ($r['type'] -in 'user', 'assistant') { $r = $r + @{ entrypoint = $Entrypoint; cwd = $Cwd } }
            ($r + @{ sessionId = $Id }) | ConvertTo-Json -Compress -Depth 6
        }
        [IO.File]::WriteAllLines((Join-Path $dir "$Id.jsonl"), [string[]]$lines)
        return $Id
    }
    function Say([string]$Text) { @{ type = 'user'; message = @{ role = 'user'; content = $Text } } }
    function Reply([string]$Text) { @{ type = 'assistant'; message = @{ role = 'assistant'; content = @(@{ type = 'text'; text = $Text }) } } }
    function Titled([string]$Kind, [string]$Text) { if ($Kind -eq 'custom') { @{ type = 'custom-title'; customTitle = $Text } } else { @{ type = 'ai-title'; aiTitle = $Text } } }
    function Json($o) { $o | ConvertTo-Json -Compress -Depth 6 }

    Check 'titles: the last custom-title wins over any ai-title, even a later one' {
        $t = Get-TranscriptHeadInfo -Lines @((Json (Titled custom 'first name')), (Json (Titled ai 'summary')), (Json (Titled custom 'renamed')), (Json (Titled ai 'later summary')))
        (Same $t.Title 'renamed') -and (Same $t.TitleSource 'custom')
    }
    Check 'titles: then the last ai-title; then the first real prompt (no meta, <command> text, tool output or CLI notice) as one short line' {
        $meta = '{"type":"user","isMeta":true,"message":{"role":"user","content":"injected caveat"}}'
        $cmd  = '{"type":"user","message":{"role":"user","content":"<command-name>/model</command-name>"}}'
        $tool = '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"output"}]}}'
        $esc  = '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}'
        $note = '{"type":"user","promptSource":"system","origin":{"kind":"task-notification"},"message":{"role":"user","content":"task done"}}'
        $sum  = '{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued"}}'
        $ai   = Get-TranscriptHeadInfo -Lines @((Json (Titled ai 'one')), (Json (Titled ai 'two')))
        $p    = Get-TranscriptHeadInfo -Lines @($meta, $cmd, $tool, $esc, $note, $sum, '{"type":"user","message":{"role":"user","content":"  fix the\n\n login   bug "}}', (Json (Say 'second prompt')))
        $long = Get-TranscriptHeadInfo -Lines @((Json (Say ('word ' * 60))))
        $none = Get-TranscriptHeadInfo -Lines @($meta, $cmd, $tool, $esc, $note, $sum)
        (Same $ai.Title 'two') -and (Same $ai.TitleSource 'ai') -and (Same $p.Title 'fix the login bug') -and (Same $p.TitleSource 'prompt') -and
        ($long.Title.Length -le 80) -and $long.Title.EndsWith('...') -and ($null -eq $none.Title) -and ($null -eq $none.TitleSource)
    }
    Check 'one line: whitespace collapses, cuts are marked, the window keeps the term, no half surrogate pair' {
        $smile = [char]::ConvertFromUtf32(0x1F600)
        $s = ConvertTo-OneLine -Text (('alpha ' * 30) + "needle`n" + ('omega ' * 30)) -Max 120 -Term 'NEEDLE'
        $end = ConvertTo-OneLine -Text (('x' * 76) + $smile + ('y' * 50)) -Max 80
        $lead = ConvertTo-OneLine -Text (('a' * 10) + $smile + ('b' * 39) + 'needle' + ('c' * 100)) -Max 120 -Term 'needle'
        ($s.Length -le 120) -and ($s -match 'needle omega') -and $s.StartsWith('...') -and $s.EndsWith('...') -and
        (Same $end (('x' * 76) + '...')) -and ($lead -match 'needle') -and ($lead -notmatch '[\uD800-\uDFFF]') -and ($lead.Length -le 120)
    }
    Check 'titles: a /rename far past the old 120-line head (and past 64 KB) is found in the tail window' {
        $recs = @((Titled ai 'early summary'), (Say 'start the work')) + @(1..200 | ForEach-Object { Reply (('filler ' * 90) + $_) }) + @((Titled custom 'renamed late'), (Reply 'after the rename'))
        $file = Join-Path (Get-ProjectTranscriptDir $titled) ((New-Chat -Cwd $titled -Records $recs) + '.jsonl')
        $rec = Get-ClaudeSessionRecord -TranscriptPath $file
        ((Get-Item $file).Length -gt 64KB) -and (Same $rec.Kind 'interactive') -and (Same $rec.Title 'renamed late') -and (Same $rec.TitleSource 'custom')
    }
    Check '-Name: reaches the claude argv and the registry; list-sessions shows it until the transcript records a title' {
        $probe = Join-Path $sandbox 'nameprobe.ps1'
        [IO.File]::WriteAllText($probe, @'
param($Lib, $Dir)
. $Lib
function Start-ClaudeTerminal { param($WorkDir, $ClaudeExe, $ClaudeArgs) $script:argv = $ClaudeArgs; 'stub' }
$r = Invoke-SessionLaunch -WorkDir $Dir -Mode new -Source open -Name 'blog refactor' -AllowUntrusted
@{ sessionId = $r.sessionId; argv = $script:argv } | ConvertTo-Json -Compress
'@)
        try {
            $env:CLAUDE_CODE_BIN = $agentsOk
            $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $probe -Lib (Join-Path $scripts 'lib\Core.Effects.ps1') -Dir $titled 2>&1 | Select-Object -Last 1
        } finally { $env:CLAUDE_CODE_BIN = $null }
        $o = "$out" | ConvertFrom-Json
        $script:namedId = $o.sessionId
        $reg = @(Get-RegisteredSessions | Where-Object SessionId -eq $o.sessionId)
        New-Chat -Cwd $titled -Records @((Say '<command-name>/clear</command-name>')) -Id $o.sessionId | Out-Null   # written, no title yet
        $row = @((Invoke-Script 'list-sessions.ps1' @('-Path', $titled)).Json.sessions | Where-Object sessionId -eq $o.sessionId)[0]
        $wired = @('open-workspace.ps1', 'new-temp-task.ps1' | Where-Object { (Get-Content (Join-Path $scripts $_) -Raw) -match 'Invoke-SessionLaunch[^\r\n]*-Name \$Name' })
        (Same @($o.argv[0..1]) @('--name', 'blog refactor')) -and (Same $reg.Count 1) -and (Same $reg[0].Name 'blog refactor') -and
        (Same $row.title 'blog refactor') -and (Same $row.titleSource 'custom') -and (Same $wired.Count 2)
    }
    Check 'registry: a row written before names existed still loads' {
        $legacy = [guid]::NewGuid().ToString()
        Add-Content -LiteralPath (Get-KitPath registry) -Value (@{ sessionId = $legacy; cwd = $titled; alias = $null; source = 'open'; startedAt = (Get-Date).ToString('o') } | ConvertTo-Json -Compress)
        $r = @(Get-RegisteredSessions | Where-Object SessionId -eq $legacy)
        (Same $r.Count 1) -and (Same $r[0].Name '')
    }

    $sTitle = New-Chat -Cwd $finds -Records @((Titled ai 'deploy pipeline notes'), (Say 'how do we roll back the release'), (Reply 'run the rollback script, then redeploy'))
    $sBody  = New-Chat -Cwd $finds -Records @((Titled ai 'stage incident'), (Say 'the deploy failed again on stage'), (Reply ('checked the logs. ' + ('filler text ' * 30) + "the 배포 key expired`nrotate it and retry")),
        (Say '<bash-stdout>shelltokenzz=1</bash-stdout><bash-stderr></bash-stderr>'))
    $sAuto  = New-Chat -Cwd $finds -Entrypoint 'sdk-cli' -Records @((Say 'deploy rollback release 배포 expired'), (Reply 'deploy'))
    $sSub   = New-Chat -Cwd $finds -SubDir 'subagents' -Records @((Say 'deploy rollback release 배포 expired'))
    # the body-only session is the newer one, so only the title weight can rank the other first
    (Get-Item (Join-Path (Get-ProjectTranscriptDir $finds) "$sTitle.jsonl")).LastWriteTime = (Get-Date).AddHours(-3)
    (Get-Item (Join-Path (Get-ProjectTranscriptDir $finds) "$sBody.jsonl")).LastWriteTime = (Get-Date).AddHours(-1)

    Check 'search: every term has to match, case-insensitive; automated and subagent transcripts never come back' {
        $r = Invoke-Script 'search-sessions.ps1' @('-Query', 'ROLLBACK release', '-Path', $finds)
        $split = Invoke-Script 'search-sessions.ps1' @('-Query', 'deploy expired', '-Path', $finds)   # OR would also bring back $sTitle
        (Same $r.ExitCode 0) -and (Same $r.Json.code 'SEARCH_RESULTS') -and (Same @($r.Json.sessions.sessionId) @($sTitle)) -and (Same $r.Json.total 1) -and
        (Same @($split.Json.sessions.sessionId) @($sBody))
    }
    Check 'search: the asking session (CLAUDE_CODE_SESSION_ID) is left out, and command output is not message text' {
        try { $env:CLAUDE_CODE_SESSION_ID = $sTitle; $r = Invoke-Script 'search-sessions.ps1' @('-Query', 'deploy', '-Path', $finds) } finally { $env:CLAUDE_CODE_SESSION_ID = $null }
        $shell = Invoke-Script 'search-sessions.ps1' @('-Query', 'shelltokenzz', '-Path', $finds)
        (Same @($r.Json.sessions.sessionId) @($sBody)) -and (Same $shell.Json.code 'SEARCH_RESULTS') -and (Same $shell.Json.total 0)
    }
    Check 'search: a Hangul term matches message text' {
        $r = Invoke-Script 'search-sessions.ps1' @('-Query', '배포', '-Path', $finds)
        (Same @($r.Json.sessions.sessionId) @($sBody)) -and (Same @($r.Json.sessions[0].matchedIn) @('body'))
    }
    Check 'search: a title hit outranks a newer session that only mentions the term' {
        $r = Invoke-Script 'search-sessions.ps1' @('-Query', 'deploy', '-Path', $finds)
        (Same @($r.Json.sessions.sessionId) @($sTitle, $sBody)) -and ($r.Json.sessions[0].score -gt $r.Json.sessions[1].score) -and
        (Same @($r.Json.sessions[0].matchedIn) @('title', 'body')) -and (Same $r.Json.sessions[0].titleSource 'ai')
    }
    Check 'search: the snippet is one line of at most 120 characters around the first message hit' {
        $r = Invoke-Script 'search-sessions.ps1' @('-Query', 'expired', '-Path', $finds)
        $snip = $r.Json.sessions[0].snippet
        (Same $r.Json.sessions[0].sessionId $sBody) -and ($snip.Length -le 120) -and ($snip -notmatch '[\r\n]') -and ($snip -match 'expired rotate') -and $snip.StartsWith('...')
    }
    Check 'search: no match is an empty SEARCH_RESULTS, not an error' {
        $r = Invoke-Script 'search-sessions.ps1' @('-Query', 'zz-no-such-term-zz')
        (Same $r.ExitCode 0) -and (Same $r.Json.code 'SEARCH_RESULTS') -and (Same $r.Json.total 0) -and (Same @($r.Json.sessions).Count 0)
    }
    # hide rg: drop every PATH entry that holds rg.exe, keep the pwsh that runs the scripts
    $noRgPath = (@(Split-Path (Get-Process -Id $PID).Path) + @($env:PATH -split ';' | Where-Object { $_ -and -not (Test-Path -LiteralPath (Join-Path $_ 'rg.exe')) })) -join ';'
    $savedPath = $env:PATH
    try { $env:PATH = $noRgPath; $rgHidden = -not (Get-Command rg.exe -CommandType Application -ErrorAction SilentlyContinue) } finally { $env:PATH = $savedPath }
    if (-not (Get-Command rg.exe -CommandType Application -ErrorAction SilentlyContinue)) {
        Skip 'search: the rg and Select-String prefilters give the same results' 'rg is not on PATH'
    } elseif (-not $rgHidden) {
        Skip 'search: the rg and Select-String prefilters give the same results' 'rg.exe sits next to pwsh and cannot be hidden'
    } else {
        Check 'search: the rg and Select-String prefilters give the same results' {
            $queries = @('deploy', '배포', 'ROLLBACK release', 'expired', 'zz-no-such-term-zz', 'deploy expired')
            $withRg = @($queries | ForEach-Object { Invoke-Script 'search-sessions.ps1' @('-Query', $_) })
            try {
                $env:PATH = $noRgPath
                $noRg = @($queries | ForEach-Object { Invoke-Script 'search-sessions.ps1' @('-Query', $_) })
            } finally { $env:PATH = $savedPath }
            for ($i = 0; $i -lt $queries.Count; $i++) {
                if ($withRg[$i].Json.prefilter -ne 'rg' -or $noRg[$i].Json.prefilter -ne 'select-string') { throw "query #$($i + 1) did not run both prefilters" }
                Same (Json $noRg[$i].Json.sessions) (Json $withRg[$i].Json.sessions) | Out-Null
                if (@($withRg[$i].Json.sessions | ForEach-Object sessionId) | Where-Object { $_ -in $sAuto, $sSub }) { throw "query #$($i + 1) returned an automated or subagent transcript" }
            }
            Same (@($withRg[0].Json.sessions.sessionId) | Where-Object { $_ -in $sTitle, $sBody }) @($sTitle, $sBody)
        }
    }

    $archive = Get-KitPath archive
    $namedSrc = Join-Path (Get-ProjectTranscriptDir $titled) "$script:namedId.jsonl"
    $namedCopy = Join-Path (Join-Path $archive (ConvertTo-ProjectSlug $titled)) "$script:namedId.jsonl"
    Check 'archive: copies the transcripts of registered sessions, then reports them up to date' {
        $first = Invoke-Script 'archive-sessions.ps1'
        $second = Invoke-Script 'archive-sessions.ps1'
        $oldCopy = Join-Path (Join-Path $archive (ConvertTo-ProjectSlug $plain)) "$old.jsonl"
        (Same $first.Json.code 'ARCHIVED') -and ($first.Json.copied -ge 2) -and (Same $first.Json.failed 0) -and (Test-Path -LiteralPath $oldCopy) -and
        ((Get-FileHash $namedCopy).Hash -eq (Get-FileHash $namedSrc).Hash) -and
        (Same $second.Json.copied 0) -and (Same $second.Json.upToDate $first.Json.copied)
    }
    Check 'archive: a transcript that grew is copied again; -All widens to every interactive transcript, never an automated one' {
        Add-Content -LiteralPath $namedSrc -Value '{"type":"last-prompt","sessionId":"x"}'
        $grown = Invoke-Script 'archive-sessions.ps1'
        $all = Invoke-Script 'archive-sessions.ps1' @('-All')
        $ids = @(Get-ChildItem -LiteralPath $archive -Recurse -Filter '*.jsonl' | ForEach-Object BaseName)
        (Same $grown.Json.copied 1) -and ((Get-FileHash $namedCopy).Hash -eq (Get-FileHash $namedSrc).Hash) -and
        ($all.Json.copied -gt 0) -and ($sTitle -in $ids) -and ($sAuto -notin $ids) -and ($cron -notin $ids) -and ($sSub -notin $ids)
    }
    Check 'archive -List: ids, folders, sizes and dates -- never content' {
        $l = Invoke-Script 'archive-sessions.ps1' @('-List')
        $row = @($l.Json.archives | Where-Object sessionId -eq $sTitle)[0]
        (Same $l.Json.code 'ARCHIVE_LIST') -and (Same $l.Json.total @(Get-ChildItem -LiteralPath $archive -Recurse -Filter '*.jsonl').Count) -and
        (Same @($row.PSObject.Properties.Name) @('sessionId', 'cwd', 'size', 'date')) -and (Same $row.cwd $finds) -and ($row.size -gt 0) -and
        ($l.Text -notmatch 'rollback|pipeline|blog refactor|renamed late')
    }

    $settingsFile = Join-Path $cfgDir 'settings.json'
    Check 'retention: no cleanupPeriodDays means the 30-day default; list-sessions warns, NO_RESUMABLE_SESSION carries it' {
        $r = Invoke-Script 'list-sessions.ps1'
        $n = Invoke-Script 'resume-session.ps1' @('-Path', $declined, '-NoPicker', '-AllowUntrusted')
        $d = Get-TranscriptRetention
        (Same $d.Days 30) -and (Same $d.Source 'default') -and (Same $r.Json.retentionDays 30) -and ($r.Json.warning -match 'cleanupPeriodDays') -and
        ($r.Json.warning -match 'never 0') -and ($r.Json.warning -match 'archive-sessions') -and (Same $n.Json.code 'NO_RESUMABLE_SESSION') -and (Same $n.Json.retentionDays 30)
    }
    Check 'retention: a large cleanupPeriodDays silences the warning, 0 is not a period, and settings.json is never written' {
        [IO.File]::WriteAllText($settingsFile, '{"cleanupPeriodDays": 3650, "theme": "dark"}')
        $before = (Get-FileHash $settingsFile).Hash
        $r = Invoke-Script 'list-sessions.ps1'
        foreach ($run in @(@('search-sessions.ps1', '-Query', 'deploy'), @('archive-sessions.ps1', '-All'), @('archive-sessions.ps1', '-List'),
                @('resume-session.ps1', '-Path', $declined, '-NoPicker', '-AllowUntrusted'))) { Invoke-Script $run[0] @($run | Select-Object -Skip 1) | Out-Null }
        $large = Get-TranscriptRetention
        $untouched = (Get-FileHash $settingsFile).Hash -eq $before
        [IO.File]::WriteAllText($settingsFile, '{"cleanupPeriodDays": 0}')
        $zero = Get-TranscriptRetention
        Remove-Item -LiteralPath $settingsFile
        (Same $r.Json.retentionDays 3650) -and ('warning' -notin $r.Json.PSObject.Properties.Name) -and (Same $large.Source 'settings') -and $untouched -and
        (Same $zero.Days 30) -and (Same $zero.Source 'default')
    }
    Check 'settings.json is named only by the read-only helper and the warning, and nothing writes it' {
        $code = @{}   # source without help blocks and comments, as the Structure checks read it
        foreach ($f in Get-ChildItem -LiteralPath $scripts -Recurse -Filter '*.ps1') {
            $t = [regex]::Replace([IO.File]::ReadAllText($f.FullName), '(?s)<#.*?#>', '')
            $code[$f.Name] = ($t -split "`r?`n" | ForEach-Object { $_ -replace '(^|\s)#.*$', '' }) -join "`n"
        }
        $named = @($code.Keys | Where-Object { $code[$_] -match 'settings\.json' } | Sort-Object)
        $writers = @($code.Keys | Where-Object {
                $code[$_] -match '(Set-Content|Out-File|Add-Content|Clear-Content|WriteAll|AppendAll|Copy-Item|Move-Item|New-Item|Remove-Item|::Move|::Copy|::Create|::Replace)[^\n]*(settingsFile|settings\.json)'
            })
        (Same $named @('Core.State.ps1', 'list-sessions.ps1')) -and (Same $writers @())
    }

    Write-Host "`nLaunch environment (a stand-in wt records what the tab would get; nothing is launched)"
    Check "launch: the tab gets none of the calling session's markers, and keeps the user's settings" {
        $stub = New-Item -ItemType Directory -Force -Path (Join-Path $sandbox 'wtstub') | ForEach-Object FullName
        [IO.File]::WriteAllText((Join-Path $stub 'wt.cmd'), "@set> `"%~dp0env.txt`"`r`n")
        $probe = Join-Path $stub 'probe.ps1'
        [IO.File]::WriteAllText($probe, @'
param($Lib, $Wt)
. $Lib
function Resolve-WindowsTerminal { $Wt }
function Show-TerminalWindow {}
foreach ($n in @($script:InheritedSessionVariables) + 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT') { Set-Item "Env:$n" 'parent' }
$env:CLAUDE_CODE_USE_POWERSHELL_TOOL = 'mine'
Start-ClaudeTerminal -WorkDir $PSScriptRoot -ClaudeExe 'claude.exe' -ClaudeArgs @('--session-id', '11111111-1111-1111-1111-111111111111') | Out-Null
'@)
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $probe -Lib (Join-Path $scripts 'lib\Core.Effects.ps1') -Wt (Join-Path $stub 'wt.cmd') 2>&1 | Out-Null
        $seen = @(Get-Content -LiteralPath (Join-Path $stub 'env.txt'))
        $leaked = @($seen | ForEach-Object { ($_ -split '=', 2)[0] } | Where-Object { $_ -in (@($script:InheritedSessionVariables) + 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT') })
        (Same $leaked @()) -and ('CLAUDE_CODE_USE_POWERSHELL_TOOL=mine' -in $seen)
    }

    Write-Host "`nReboot path (sandbox; -Simulate only)"
    $promptFile = Join-Path $sandbox 'prompt.txt'
    [IO.File]::WriteAllText($promptFile, "재부팅 후 이어서: SECRET-MARKER-123`nnext step")
    Check 'reboot-plan: untrusted folder is refused' { Same (Invoke-Script 'reboot-plan.ps1' @('-WorkDir', $declined)).Json.code 'UNTRUSTED_WORKSPACE' }
    $plan = Invoke-Script 'reboot-plan.ps1' @('-WorkDir', $plain, '-PromptFile', $promptFile, '-DelaySeconds', '5')
    Check 'reboot-plan: plans the newest interactive session, never the cron one' {
        (Same $plan.ExitCode 0) -and (Same $plan.Json.code 'REBOOT_PLANNED') -and (Same $plan.Json.sessionId $newer) -and (Same $plan.Json.sessionMode 'resume')
    }
    Check 'reboot-plan: a LIVE sidecar (the asking session, still buffering) is preferred; a stale one never is' {
        $liveSide = New-Transcript -Cwd $plain -Entrypoint $null -When (Get-Date).AddSeconds(-30)
        $r = Invoke-Script 'reboot-plan.ps1' @('-WorkDir', $plain)
        Remove-Item -LiteralPath (Join-Path (Get-ProjectTranscriptDir $plain) "$liveSide.jsonl")
        (Same $r.Json.sessionId $liveSide) -and ($r.Json.sessionId -ne $side)
    }
    Check 'reboot-plan: an explicit id must exist, be interactive and belong to this folder' {
        $elsewhere = New-Transcript -Cwd $declined -Entrypoint 'cli' -When (Get-Date).AddMinutes(-3)
        $unknown = Invoke-Script 'reboot-plan.ps1' @('-WorkDir', $plain, '-SessionId', ([guid]::NewGuid().ToString()))
        $auto    = Invoke-Script 'reboot-plan.ps1' @('-WorkDir', $plain, '-SessionId', $cron)
        $foreign = Invoke-Script 'reboot-plan.ps1' @('-WorkDir', $plain, '-SessionId', $elsewhere)
        $good    = Invoke-Script 'reboot-plan.ps1' @('-WorkDir', $plain, '-SessionId', $old)
        (Same $unknown.Json.code 'SESSION_REJECTED') -and (Same $auto.Json.code 'SESSION_REJECTED') -and (Same $auto.Json.kind 'automated') -and
        (Same $foreign.Json.code 'SESSION_REJECTED') -and (Same $foreign.Json.recordedCwd $declined) -and
        (Same $good.Json.sessionId $old) -and (Same $good.Json.sessionSource 'explicit')
    }
    Check 'reboot-plan: CLAUDE_CODE_SESSION_ID pins the asking session, but never an automated one' {
        try {
            $env:CLAUDE_CODE_SESSION_ID = $old;  $mine = Invoke-Script 'reboot-plan.ps1' @('-WorkDir', $plain)
            $env:CLAUDE_CODE_SESSION_ID = $cron; $auto = Invoke-Script 'reboot-plan.ps1' @('-WorkDir', $plain)
        } finally { $env:CLAUDE_CODE_SESSION_ID = $null }
        (Same $mine.Json.sessionId $old) -and (Same $mine.Json.sessionSource 'env') -and (Same $auto.Json.sessionId $newer) -and (Same $auto.Json.sessionSource 'scan:interactive')
    }
    Check 'reboot-plan: an empty prompt file falls back to the default prompt' {
        $empty = Join-Path $sandbox 'empty.txt'; [IO.File]::WriteAllBytes($empty, [byte[]]@())
        $r = Invoke-Script 'reboot-plan.ps1' @('-WorkDir', $plain, '-PromptFile', $empty)
        (Same $r.Json.code 'REBOOT_PLANNED') -and ($r.Json.prompt -ne 'empty')
    }
    $plan = Invoke-Script 'reboot-plan.ps1' @('-WorkDir', $plain, '-PromptFile', $promptFile, '-DelaySeconds', '5')
    Check 'reboot-plan: delay is floored at 30s and the prompt is not echoed' { (Same $plan.Json.delaySeconds 30) -and ($plan.Text -notmatch 'SECRET-MARKER') }
    Check 'reboot-plan: RunOnce targets the frozen copy under the kit home, within 260 chars' {
        ($plan.Json.runOnce.Contains((Join-Path $kitHome 'runtime\resume.ps1'))) -and ($plan.Json.runOnce.Length -le 260) -and ($plan.Json.runOnce -notmatch [regex]::Escape($repo))
    }
    Check 'reboot-plan: writes a plan and nothing else' {
        (Test-Path (Get-KitPath plan)) -and -not (Test-Path (Get-KitPath state)) -and -not (Test-Path (Get-KitPath runtime)) -and ((Get-RealRunOnce) -eq $runOnceBefore)
    }
    Check 'reboot-commit: a wrong token registers nothing' {
        $r = Invoke-Script 'reboot-commit.ps1' @('-Token', 'deadbeef', '-Simulate')
        (Same $r.Json.code 'TOKEN_MISMATCH') -and -not (Test-Path (Get-KitPath state))
    }
    Check 'reboot-commit: an expired plan is refused and discarded' {
        $p = Get-Content (Get-KitPath plan) -Raw | ConvertFrom-Json
        $fresh = Get-Content (Get-KitPath plan) -Raw
        $p.created_at = (Get-Date).AddMinutes(-11).ToString('o')
        [IO.File]::WriteAllText((Get-KitPath plan), ($p | ConvertTo-Json -Depth 5))
        $r = Invoke-Script 'reboot-commit.ps1' @('-Token', $plan.Json.token, '-Simulate')
        $gone = -not (Test-Path (Get-KitPath plan))
        [IO.File]::WriteAllText((Get-KitPath plan), $fresh)
        (Same $r.Json.code 'PLAN_EXPIRED') -and $gone
    }
    # Commits an edited copy of the current plan and puts the genuine one back.
    function Invoke-ForgedCommit([scriptblock]$Edit) {
        $fresh = Get-Content (Get-KitPath plan) -Raw
        $p = $fresh | ConvertFrom-Json
        & $Edit $p
        [IO.File]::WriteAllText((Get-KitPath plan), ($p | ConvertTo-Json -Depth 5))
        $r = Invoke-Script 'reboot-commit.ps1' @('-Token', $plan.Json.token, '-Simulate')
        [IO.File]::WriteAllText((Get-KitPath plan), $fresh)
        return $r
    }
    $frozenPath = Join-Path $kitHome 'runtime\resume.ps1'
    Check 'reboot-commit: a RunOnce that is not the rendered shape is refused -- another program, a prefix, extra arguments' {
        $a = Invoke-ForgedCommit { param($p) $p.runonce = 'C:\evil\x.exe' }
        $b = Invoke-ForgedCommit { param($p) $p.runonce = "C:\evil\x.exe --anything $frozenPath" }
        $c = Invoke-ForgedCommit { param($p) $p.runonce = $p.runonce + ' -EncodedCommand AAAA' }
        $d = Invoke-ForgedCommit { param($p) $p.runonce = $p.runonce -replace '-ExecutionPolicy Bypass -File', '-ExecutionPolicy Bypass -Command' }
        (Same @($a.Json.code, $b.Json.code, $c.Json.code, $d.Json.code) @('PLAN_INVALID', 'PLAN_INVALID', 'PLAN_INVALID', 'PLAN_INVALID')) -and -not (Test-Path (Get-KitPath state))
    }
    Check 'reboot-commit: a host that is not an installed pwsh/powershell is refused' {
        $fake = Join-Path $sandbox 'pwsh.exe'; [IO.File]::WriteAllText($fake, 'not a host')
        $a = Invoke-ForgedCommit { param($p) $p.runonce = "$fake -NoProfile -ExecutionPolicy Bypass -File $frozenPath" }
        $b = Invoke-ForgedCommit { param($p) $p.runonce = "C:\absent\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $frozenPath" }
        (Same $a.Json.code 'PLAN_INVALID') -and (Same $b.Json.code 'PLAN_INVALID') -and -not (Test-Path (Get-KitPath state))
    }
    Check 'reboot-commit: the frozen copy cannot be redirected out of the state folder' {
        $out = Join-Path $kitHome '..\escaped\resume.ps1'
        $r = Invoke-ForgedCommit { param($p) $p.runtime_script = $out; $p.runonce = $p.runonce.Replace($frozenPath, $out) }
        (Same $r.Json.code 'PLAN_INVALID') -and -not (Test-Path (Join-Path $sandbox 'escaped'))
    }
    Check 'reboot-commit: a plan dated in the future is refused like an expired one' {
        $fresh = Get-Content (Get-KitPath plan) -Raw
        $r = Invoke-ForgedCommit { param($p) $p.created_at = (Get-Date).AddYears(50).ToString('o') }
        [IO.File]::WriteAllText((Get-KitPath plan), $fresh)   # PLAN_EXPIRED deletes the plan
        Same $r.Json.code 'PLAN_EXPIRED'
    }
    Check 'reboot-commit -Simulate: state + frozen script written, plan consumed, registry untouched' {
        # A resume_source smuggled into the plan is ignored: what gets frozen is the script next to reboot-commit.ps1.
        $evil = Join-Path $sandbox 'evil.ps1'; [IO.File]::WriteAllText($evil, 'Write-Host pwned')
        $p = Get-Content (Get-KitPath plan) -Raw | ConvertFrom-Json
        $p | Add-Member -NotePropertyName resume_source -NotePropertyValue $evil -Force
        [IO.File]::WriteAllText((Get-KitPath plan), ($p | ConvertTo-Json -Depth 5))
        $r = Invoke-Script 'reboot-commit.ps1' @('-Token', $plan.Json.token, '-Simulate')
        $state = Get-Content (Get-KitPath state) -Raw | ConvertFrom-Json
        $frozen = Join-Path (Get-KitPath runtime) 'resume.ps1'
        (Same $r.Json.code 'SIMULATED') -and (Same $state.session_id $newer) -and (Same $state.workdir $plain) -and ($state.prompt -match 'SECRET-MARKER') -and
        ((Get-FileHash $frozen).Hash -eq (Get-FileHash (Join-Path $scripts 'resume-after-reboot.ps1')).Hash) -and
        -not (Test-Path (Get-KitPath plan)) -and ((Get-RealRunOnce) -eq $runOnceBefore)
    }
    Check 'reboot-commit: a kit home spelled with ".." plans and commits like the canonical one' {
        try {
            $env:CLAUDE_SESSION_KIT_HOME = Join-Path $kitHome '..\kit'
            $p = Invoke-Script 'reboot-plan.ps1' @('-WorkDir', $plain, '-PromptFile', $promptFile)
            $c = Invoke-Script 'reboot-commit.ps1' @('-Token', $p.Json.token, '-Simulate')
        } finally { $env:CLAUDE_SESSION_KIT_HOME = $kitHome }
        (Same $p.Json.code 'REBOOT_PLANNED') -and (Same $c.Json.code 'SIMULATED') -and (Same $c.Json.runOnce $p.Json.runOnce) -and ($c.Json.runOnce -notmatch '\.\.')
    }
    Check 'reboot-commit: a plan is single-use' { Same (Invoke-Script 'reboot-commit.ps1' @('-Token', $plan.Json.token, '-Simulate')).Json.code 'NO_PLAN' }
    Check 'resume (frozen copy) -DryRun: resolves, keeps state, never logs the prompt' {
        $frozen = Join-Path (Get-KitPath runtime) 'resume.ps1'
        $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $frozen -DryRun 2>&1 | Out-String
        $log = Get-Content (Get-KitPath log) -Raw
        ($LASTEXITCODE -eq 0 -or $out -match 'claude binary not found') -and (Test-Path (Get-KitPath state)) -and ($out -notmatch 'SECRET-MARKER') -and ($log -notmatch 'SECRET-MARKER') -and ($out -match [regex]::Escape($newer) -or $out -match 'not found')
    }
    Check 'frozen resume script parses under Windows PowerShell 5.1' {
        $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path $ps51)) { return $true }
        $n = & $ps51 -NoProfile -Command "`$e=`$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$(Join-Path $scripts 'resume-after-reboot.ps1')',[ref]`$null,[ref]`$e); `$e.Count"
        Same ([int]$n) 0
    }
    Check 'reboot-cancel -Status: reports without printing the prompt' {
        $r = Invoke-Script 'reboot-cancel.ps1' @('-Status')
        (Same $r.Json.code 'STATUS') -and (Same $r.Json.state.sessionId $newer) -and ($r.Text -notmatch 'SECRET-MARKER') -and ($r.Json.state.promptLength -gt 0)
    }
    # --- the resume script, run for real against stand-ins for `claude` -----------------
    $frozen = Join-Path (Get-KitPath runtime) 'resume.ps1'
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    function Set-ResumeState([string]$WorkDir, [string]$PromptText) {
        $s = [ordered]@{ session_id = $newer; workdir = $WorkDir; prompt = $PromptText; created_at = (Get-Date).ToString('o') }
        [IO.File]::WriteAllText((Get-KitPath state), ($s | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    }
    function Invoke-Resume([string]$HostExe, [string]$ClaudeBin, [string[]]$Extra = @()) {
        try {
            $env:CLAUDE_CODE_BIN = $ClaudeBin
            $out = & $HostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $frozen @Extra 2>&1 | Out-String
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $out }
        } finally { $env:CLAUDE_CODE_BIN = $null }
    }
    $nasty = "finish step 2 `"then & echo pwned> INJECTED.marker & rem `" done`nsecond line with %USERNAME% and `"C:\some dir\`""

    Check 'resume: a missing working directory launches nothing and keeps the state' {
        Set-ResumeState (Join-Path $work 'vanished') 'go on'
        $r = Invoke-Resume 'pwsh' '' @('-DryRun')
        (Same $r.ExitCode 1) -and ($r.Text -match 'not found') -and (Test-Path (Get-KitPath state))
    }
    Check 'resume: with a .cmd shim the prompt travels in a file, never through cmd.exe' {
        $shimDir = New-Item -ItemType Directory -Force -Path (Join-Path $sandbox 'shim') | ForEach-Object FullName
        $shim = Join-Path $shimDir 'claude.cmd'
        [IO.File]::WriteAllText($shim, "@echo off`r`necho %*> `"%~dp0args.txt`"`r`n")
        Set-ResumeState $plain $nasty
        $r = Invoke-Resume 'pwsh' $shim
        $argsSeen = Get-Content (Join-Path $shimDir 'args.txt') -Raw
        $handed = [IO.File]::ReadAllText((Join-Path $kitHome 'resume-prompt.txt'))
        -not (Get-ChildItem -LiteralPath $sandbox -Recurse -Filter 'INJECTED.marker') -and
        ($argsSeen -match [regex]::Escape("--resume $newer --")) -and ($argsSeen -match 'resume-prompt\.txt') -and ($argsSeen -notmatch 'pwned|USERNAME') -and
        ($handed -ceq $nasty) -and -not (Test-Path (Get-KitPath state)) -and (Test-Path (Get-KitPath stateLast)) -and ($r.Text -notmatch 'pwned')
    }
    # A real executable that records its argv: built with the C# compiler that ships with Windows PowerShell 5.1.
    $echoExe = Join-Path $sandbox 'echoargs\claude.exe'
    if (Test-Path $ps51) {
        New-Item -ItemType Directory -Force -Path (Split-Path $echoExe) | Out-Null
        $src = 'using System; using System.IO; using System.Text; public static class P { public static int Main(string[] a) { var sb = new StringBuilder(); foreach (var s in a) sb.AppendLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(s))); File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "argv.txt"), sb.ToString()); return 0; } }'
        $srcFile = Join-Path (Split-Path $echoExe) 'echoargs.cs'
        [IO.File]::WriteAllText($srcFile, $src)
        try { & $ps51 -NoProfile -NonInteractive -Command "Add-Type -Path '$srcFile' -OutputAssembly '$echoExe' -OutputType ConsoleApplication" 2>&1 | Out-Null } catch {}
    }
    if (Test-Path $echoExe) {
        function Get-EchoedArgs { @(Get-Content (Join-Path (Split-Path $echoExe) 'argv.txt') | Where-Object { $_ } | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }) }
        Check 'resume: to a real .exe the prompt arrives as ONE intact argument (PowerShell 7)' {
            Set-ResumeState $plain $nasty
            Invoke-Resume 'pwsh' $echoExe | Out-Null
            $a = Get-EchoedArgs
            (Same $a.Count 4) -and (Same @($a[0..2]) @('--resume', $newer, '--')) -and ($a[3] -ceq $nasty)
        }
        # Hosts that build native command lines loosely: a prompt that STARTS with a quote is
        # the shape pre-escaping cannot save, so the script renders the command line itself.
        $tricky = @('open "C:\dir\" and continue, then look in C:\some dir\', '"run the check"', 'x\" y', $nasty)
        Check 'resume: the same holds under Windows PowerShell 5.1' {
            foreach ($t in $tricky) {
                Set-ResumeState $plain $t
                Invoke-Resume $ps51 $echoExe | Out-Null
                $a = Get-EchoedArgs
                if ($a.Count -ne 4 -or $a[3] -cne $t) { throw "prompt #$([array]::IndexOf($tricky, $t) + 1) arrived as $($a.Count) argument(s)" }
            }
            $true
        }
        Check "resume: ...and under pwsh in 'Legacy' argument-passing mode (what 7.0-7.2 always use)" {
            foreach ($t in $tricky) {
                Set-ResumeState $plain $t
                try {
                    $env:CLAUDE_CODE_BIN = $echoExe
                    & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "`$PSNativeCommandArgumentPassing = 'Legacy'; & '$frozen'" 2>&1 | Out-Null
                } finally { $env:CLAUDE_CODE_BIN = $null }
                $a = Get-EchoedArgs
                if ($a.Count -ne 4 -or $a[3] -cne $t) { throw "prompt #$([array]::IndexOf($tricky, $t) + 1) arrived as $($a.Count) argument(s)" }
            }
            $true
        }
    } else {
        Skip 'resume: argv round trip through a real .exe' 'could not build the argv-echo helper (needs Windows PowerShell 5.1)'
    }
    Check "the sandbox's .claude.json was never written" { (Get-FileHash (Join-Path $cfgDir '.claude.json')).Hash -eq $cfgHash }

    Write-Host "`nStructure"
    $all = Get-ChildItem -LiteralPath $scripts -Recurse -Filter *.ps1
    function Code([IO.FileInfo]$f) {   # source with comments and help blocks removed
        $t = [IO.File]::ReadAllText($f.FullName)
        $t = [regex]::Replace($t, '(?s)<#.*?#>', '')
        return (($t -split "`r?`n" | ForEach-Object { $_ -replace '(^|\s)#.*$', '' }) -join "`n")
    }
    Check 'only reboot-commit.ps1 can restart Windows' {
        $hits = @($all | Where-Object { (Code $_) -match 'shutdown(\.exe)?\s+/[rsgh]|Restart-Computer|Stop-Computer' } | ForEach-Object Name)
        Same $hits @('reboot-commit.ps1')
    }
    Check 'only reboot-commit.ps1 writes the RunOnce value' {
        $hits = @($all | Where-Object { (Code $_) -match '(Set|New)-ItemProperty' } | ForEach-Object Name)
        Same $hits @('reboot-commit.ps1')
    }
    Check 'reboot-plan.ps1 cannot start a process, and the reboot scripts load no Effects' {
        $plan = Code (Get-Item (Join-Path $scripts 'reboot-plan.ps1'))
        $lonely = @('reboot-commit.ps1', 'reboot-cancel.ps1', 'resume-after-reboot.ps1') | ForEach-Object { Code (Get-Item (Join-Path $scripts $_)) }
        ($plan -notmatch 'Core\.Effects|Start-Process|Start-ClaudeTerminal|wt\.exe\s') -and -not ($lonely -match 'lib\\Core\.')
    }
    Check 'only Core.Effects.ps1 starts a terminal' {
        $hits = @($all | Where-Object { (Code $_) -match 'Start-Process|&\s*\$wt\b' } | ForEach-Object Name)
        Same $hits @('Core.Effects.ps1')
    }
    Check '`claude --continue` is never emitted' { -not ($all | Where-Object { (Code $_) -match "['""]--continue['""]|['""]-c['""]" }) }
    Check 'nothing writes ~/.claude.json or names hasTrustDialogAccepted outside the read-only check' {
        $named = @($all | Where-Object { (Code $_) -match 'hasTrustDialogAccepted' } | ForEach-Object Name)
        $state = Code (Get-Item (Join-Path $scripts 'lib\Core.State.ps1'))
        (Same $named @('Core.State.ps1')) -and ($state -notmatch '(Set-Content|Out-File|WriteAllText|Add-Content)[^\n]*(ConfigFile|claude\.json)')
    }
    Check 'every script is pure ASCII (Windows PowerShell 5.1 reads BOM-less files as ANSI)' {
        $bad = @($all | Where-Object { [IO.File]::ReadAllText($_.FullName) -match '[^\x00-\x7F]' } | ForEach-Object Name)
        Same $bad @()
    }
    Check 'manifests are valid and the plugin declares no "skills" key (it would replace auto-scan)' {
        $p = Get-Content (Join-Path $repo '.claude-plugin\plugin.json') -Raw | ConvertFrom-Json
        $m = Get-Content (Join-Path $repo '.claude-plugin\marketplace.json') -Raw | ConvertFrom-Json
        (Same $p.name 'claude-session-kit') -and ('skills' -notin $p.PSObject.Properties.Name) -and (Same $m.plugins[0].name $p.name) -and (Same $m.plugins[0].version $p.version) -and
        (Test-Path (Join-Path $repo 'skills\session\SKILL.md'))
    }
    Check 'SKILL.md uses ${CLAUDE_SKILL_DIR}, not a fixed install path or %USERPROFILE%' {
        $s = Get-Content (Join-Path $repo 'skills\session\SKILL.md') -Raw
        ($s -match [regex]::Escape('${CLAUDE_SKILL_DIR}')) -and ($s -notmatch '%USERPROFILE%') -and ($s -notmatch '\.claude[\\/]skills[\\/]')
    }
    # The list of a person's private words must not itself be published, so it lives
    # outside the repository: one token per line in <kit state>\private-tokens.txt.
    $tokensFile = Join-Path (Join-Path $env:USERPROFILE '.claude\claude-session-kit') 'private-tokens.txt'
    if (Test-Path -LiteralPath $tokensFile) {
        Check 'no private token appears in the tracked tree or anywhere in git history' {
            $tokens = @(Get-Content -LiteralPath $tokensFile -Encoding UTF8 | Where-Object { $_.Trim() -and -not $_.StartsWith('#') } | ForEach-Object Trim)
            # An installed copy (plugin cache) is not a git work tree: scan every file there.
            $files = if (Test-Path -LiteralPath (Join-Path $repo '.git')) {
                @(& git -C $repo ls-files --cached --others --exclude-standard) | ForEach-Object { Join-Path $repo $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
            } else {
                @(Get-ChildItem -LiteralPath $repo -Recurse -File -Force | ForEach-Object FullName)
            }
            if (-not $files) { throw 'found no files to scan' }
            $leaks = @(foreach ($f in $files) { $t = [IO.File]::ReadAllText($f); foreach ($k in $tokens) { if ($t.IndexOf($k, [StringComparison]::OrdinalIgnoreCase) -ge 0) { "$([IO.Path]::GetFileName($f)): token #$([array]::IndexOf($tokens, $k) + 1)" } } })
            # A public repository serves its whole history -- every old commit, message and
            # author line -- not just the current tree. Only the token's NUMBER is reported.
            if (Test-Path -LiteralPath (Join-Path $repo '.git')) {
                $enc = [Console]::OutputEncoding
                try {
                    [Console]::OutputEncoding = [Text.Encoding]::UTF8
                    $history = @(& git -C $repo -c core.quotepath=false log --all -p '--format=%H%n%an <%ae>%n%cn <%ce>%n%B') -join "`n"
                } finally { [Console]::OutputEncoding = $enc }
                if (-not $history) { throw 'git history could not be read' }
                foreach ($k in $tokens) { if ($history.IndexOf($k, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $leaks += "git history: token #$([array]::IndexOf($tokens, $k) + 1)" } }
            }
            if ($leaks) { throw ($leaks -join '; ') }
            $true
        }
    } else {
        Skip 'private-token scan' "no $tokensFile"
    }
} finally {
    try { if ($script:savedOutEnc) { [Console]::OutputEncoding = $script:savedOutEnc } } catch {}
    $env:CLAUDE_SESSION_KIT_HOME = $saved.kit; $env:CLAUDE_CONFIG_DIR = $saved.cfg; $env:CLAUDE_SESSION_ID = $saved.sid
    $env:CLAUDE_CODE_SESSION_ID = $saved.csid; $env:CLAUDE_CODE_BIN = $saved.bin; $env:CSK_TEST_WORK = $null
    try { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction Stop } catch {}
}

Write-Host ("`n{0} passed, {1} failed, {2} skipped" -f $script:pass, $script:fail, $script:skipped)
if ($script:fail -gt 0) { exit 1 }
