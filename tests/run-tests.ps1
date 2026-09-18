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
