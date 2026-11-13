#requires -Version 7.5
<#
.SYNOPSIS
  Test suite for claude-session-kit. No Pester, no network, no terminal tab, no reboot.

.DESCRIPTION
  Everything runs against a throwaway sandbox: CLAUDE_SESSION_KIT_HOME redirects
  the kit's state and CLAUDE_CONFIG_DIR redirects Claude Code's config/projects, so
  a person's real aliases, registry and ~/.claude.json are never read or written.
  Scripts that would open a tab run into a refusal or against a stubbed launcher,
  reboot-commit.ps1 is only ever run with -Simulate, and the resume script is only
  ever pointed (CLAUDE_CODE_BIN) at stand-ins for `claude` that record their argv.
  PowerShell 7.5: the trust tests read with ConvertFrom-Json -DateKind, like the writer.

  Not covered, on purpose: Windows PowerShell 5.1 or Legacy argument mode as the logon
  host, the console fallback without Windows Terminal, the search fallback without rg,
  the PID-record fallback when `claude agents --json` fails, and v1 (flat) alias files.

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
$saved = @{ kit = $env:CLAUDE_SESSION_KIT_HOME; cfg = $env:CLAUDE_CONFIG_DIR; csid = $env:CLAUDE_CODE_SESSION_ID; bin = $env:CLAUDE_CODE_BIN }
$env:CLAUDE_SESSION_KIT_HOME = $kitHome
$env:CLAUDE_CONFIG_DIR = $cfgDir
$env:CLAUDE_CODE_SESSION_ID = $null   # the suite may itself be running inside a Claude Code session
# The real `claude` never runs here: a first run migrates CLAUDE_CONFIG_DIR/.claude.json and starts a
# daemon for it. Every test that needs another stand-in sets its own and comes back to this one.
$noClaude = Join-Path $sandbox 'claude-none.cmd'
[IO.File]::WriteAllText($noClaude, "@echo off`r`necho []`r`n")
$env:CLAUDE_CODE_BIN = $noClaude
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
    $idA = '11111111-1111-1111-1111-111111111111'; $idB = '22222222-2222-2222-2222-222222222222'
    Check 'slug: every non-alphanumeric char, Hangul included, is one dash; a trailing separator is dropped, a drive root kept' {
        (Same (ConvertTo-ProjectSlug 'C:\Users\someone\Documents\한글 폴더.v2') 'C--Users-someone-Documents-------v2') -and
        (Same (ConvertTo-ProjectSlug 'C:\work\') 'C--work') -and (Same (ConvertTo-ProjectSlug 'C:\') 'C--')
    }
    Check 'argv: exact shapes -- options first, the prompt last after --, a fork under its own id, a bare picker' {
        (Same (Get-ClaudeArgs -Mode new -SessionId $idA -Name 'blog refactor' -Model 'claude-opus-5-5' -Effort xhigh -Prompt 'read the note' -PermissionMode plan) @(
                '--permission-mode', 'plan', '--name', 'blog refactor', '--model', 'claude-opus-5-5', '--effort', 'xhigh', '--session-id', $idA, '--', 'read the note')) -and
        (Same (Get-ClaudeArgs -Mode resume -SessionId $idA -Fork -Prompt 'x') @('--resume', $idA, '--fork-session', '--', 'x')) -and
        (Same (Get-ClaudeArgs -Mode resume -SessionId $idA -Fork -ForkSessionId $idB) @('--resume', $idA, '--fork-session', '--session-id', $idB)) -and
        (Same (Get-ClaudeArgs -Mode picker) @('--resume')) -and (Same (Get-ClaudeArgs -Mode picker -Fork) @('--resume', '--fork-session'))
    }
    Check 'argv: refused -- an id that is not a UUID (a trailing line feed counts), a prompt for the picker, bypassPermissions, a mode in the wrong case, a two-line name' {
        $refused = @(
            { Get-ClaudeArgs -Mode resume -SessionId 'latest' }, { Get-ClaudeArgs -Mode resume -SessionId "$idA`n" },
            { Get-ClaudeArgs -Mode resume -SessionId $idA -Fork -ForkSessionId 'x' }, { Get-ClaudeArgs -Mode picker -Prompt 'x' },
            { Get-ClaudeArgs -Mode resume -SessionId $idA -PermissionMode bypassPermissions }, { Get-ClaudeArgs -Mode new -PermissionMode 'Plan' },
            { Get-ClaudeArgs -Mode new -Name "two`nlines" })
        $i = 0
        foreach ($case in $refused) { $i++; try { & $case | Out-Null } catch { continue }; throw "case #$i was accepted" }
        $true
    }
    Check 'argv: a name wt or a .cmd shim would re-split is refused; plain and Hangul names pass' {
        $bad = @('PR "fix login" review', 'R&D', "tab`there", 'C:\my notes\', '%USERNAME% notes', 'a|b', 'x^y', 'hi!')
        $refused = @($bad | Where-Object { (Get-NameRefusal $_) -and (Throws { Get-ClaudeArgs -Mode new -Name $_ }) })
        (Same $refused.Count $bad.Count) -and (Same (Get-NameRefusal $bad[0]).code 'INVALID_NAME') -and
        ($null -eq (Get-NameRefusal "blog refactor (v2) - it's done; ok")) -and ($null -eq (Get-NameRefusal ([string]::new([char[]](0xBE14, 0xB85C, 0xADF8)))))
    }
    Check 'argv: a model is one plain word in any vendor form; an effort is a CLI level in lower case' {
        $good = @('opus', 'claude-opus-5-5', 'claude-opus-5-5[1m]', 'us.anthropic.claude-opus-5-5-v1:0', 'claude-opus-5-5@20261001', 'arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/abc')
        $bad = @('-p', 'opus 5.5', 'opus;x', '"opus"', '%MODEL%', "opus`n")
        $refused = @($bad | Where-Object { $r = Get-ModelRefusal $_; $r -and $r.code -eq 'INVALID_MODEL' -and (Throws { Get-ClaudeArgs -Mode new -Model $_ }) })
        (Same @($good | Where-Object { Get-ModelRefusal $_ }) @()) -and (Same $refused.Count $bad.Count) -and
        (Same @('low', 'medium', 'high', 'xhigh', 'max' | Where-Object { Get-EffortRefusal $_ }) @()) -and (Same (Get-EffortRefusal 'XHIGH').code 'INVALID_EFFORT') -and
        (Throws { Get-ClaudeArgs -Mode new -Effort 'XHIGH' }) -and (Throws { Get-ClaudeArgs -Mode new -Effort 'ultra' })
    }
    # Each shape was sent once through a real Windows Terminal tab to an argv-recording exe
    # (see Get-PromptRefusal): what arrived changed must be refused, as must a blank or
    # over-long prompt; what arrived intact must pass. Two shapes arrived intact and are
    # refused anyway, because the rule is coarser than wt: a %...% pair is a variable once
    # the tab defines that name, and a trailing backslash breaks once there is a space.
    $changedByWt = @('say "hi" now', '"run the check" please', 'a"b', 'x\" y', 'look at %PATH% here', '%USERPROFILE%', "a`tb", 'open C:\some dir\',
        '   ', "`r`n", ('x' * 8001), '50% done and 30% left', 'C:\dir\')
    $intactThroughWt = @("line one`nline two", "line one`r`nline two", "a`nb", 'first; second', 'stop here;', 'a\;b c', 'C:\dir\x', 'only 50% done',
        '-x starts with a dash', ('한글 위임 ' + [char]::ConvertFromUtf32(0x1F680) + ' done'), 'R&D | a<b> ^c !d', 'cost $5 and `n and $env:PATH', "it's fine",
        'C:\Users\someone\.claude\handoffs\task-2026-10-29.md 위임 문서를 끝까지 읽고, 지시대로 진행해줘.', (('abcdefg ' * 999) + '한글'))
    Check 'prompt: every shape a real wt tab changed is refused, every shape it kept passes; a refusal never echoes the prompt' {
        $refused = @($changedByWt | Where-Object { $r = Get-PromptRefusal $_; $r -and $r.code -eq 'INVALID_PROMPT' -and (Throws { Get-ClaudeArgs -Mode new -Prompt $_ }) })
        $passed = @($intactThroughWt | Where-Object { -not (Get-PromptRefusal $_) -and ((Get-ClaudeArgs -Mode new -Prompt $_)[-1] -ceq $_) })
        $json = Get-PromptRefusal 'SECRET-MARKER "x"' | ConvertTo-Json -Compress
        $thrown = try { Get-ClaudeArgs -Mode new -Prompt 'SECRET-MARKER "x"' } catch { $_.Exception.Message }
        (Same $refused.Count $changedByWt.Count) -and (Same $passed.Count $intactThroughWt.Count) -and ($json -notmatch 'SECRET') -and
        ($thrown -notmatch 'SECRET') -and (Same (Get-PromptRefusal ('x' * 8001)).promptChars 8001)
    }
    Check 'wt and RunOnce: exact command lines -- ; escaped for wt, a path with spaces quoted, a trailing backslash doubled, 260 the RunOnce ceiling' {
        (Same (New-WtArgumentList -WorkDir 'C:\a;b' -Exe 'C:\bin\claude.exe' -Arguments @('--resume', 'x')) @('-w', '0', 'nt', '-d', 'C:\a\;b', '--', 'C:\bin\claude.exe', '--resume', 'x')) -and
        (Same (New-RunOnceCommand -PowerShellExe 'C:\p\pwsh.exe' -ResumeScript 'C:\k\runtime\resume.ps1' -WtExe 'C:\w\wt.exe') 'C:\w\wt.exe -w new nt -- C:\p\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File C:\k\runtime\resume.ps1') -and
        (Same (New-RunOnceCommand -PowerShellExe 'C:\Program Files\pwsh.exe' -ResumeScript 'C:\k\resume.ps1') '"C:\Program Files\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -File C:\k\resume.ps1') -and
        (Same (ConvertTo-QuotedArgument 'say "hi"') '"say \"hi\""') -and (Same (ConvertTo-QuotedArgument 'C:\dir with space\') '"C:\dir with space\\"') -and
        (Test-RunOnceCommandLength ('x' * 260)) -and -not (Test-RunOnceCommandLength ('x' * 261))
    }
    Check 'temp index: union of disk and history, a bare prefix counts as 0, a timestamp-like suffix is ignored' {
        (Same (Get-NextTempIndex -Prefix 'test' -DiskNames @('test', 'test2', 'test6', 'testing') -HistorySlugs @('C--U-Downloads-test7', 'C--U-Downloads-test30', 'C--U-Downloads-test-9', 'C--Other-test99') -RootSlug 'C--U-Downloads') 31) -and
        (Same (Get-NextTempIndex -Prefix 'test' -DiskNames @('test')) 1) -and (Same (Get-NextTempIndex -Prefix 'test') 1) -and
        (Same (Get-NextTempIndex -Prefix 'test' -DiskNames @('test4', 'test20240101120000') -HistorySlugs @('C--U-Downloads-test20240101120000', 'C--U-Downloads-test7') -RootSlug 'C--U-Downloads') 8)
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
        Check 'trust: a plain folder inherits it (key case-insensitive), as does a folder inside a trusted repo (.git as a FILE); a repo under a trusted parent, an entry holding false, an unknown folder and a missing or corrupt config do not' {
            $bad = Join-Path $sandbox 'bad.json'; 'not json' | Set-Content $bad
            (Test-WorkspaceTrusted -Path $plain) -and (Test-WorkspaceTrusted -Path $trustedRepo) -and
            -not (Test-WorkspaceTrusted -Path $repoDir) -and -not (Test-WorkspaceTrusted -Path $declined) -and -not (Test-WorkspaceTrusted -Path $work) -and
            -not (Test-WorkspaceTrusted -Path $plain -ConfigFile (Join-Path $sandbox 'absent.json')) -and -not (Test-WorkspaceTrusted -Path $plain -ConfigFile $bad) -and
            (Same (Get-TrustKey -Path $repoDir) (ConvertTo-TrustPath (Join-Path $work 'trusted-parent\repo')))   # a subfolder's key is the repo root
        }

        # The writer runs against copies: the sandbox's own .claude.json must stay byte-identical (checked at the end).
        $trustCfg = Join-Path $sandbox 'trust-cfg.json'
        $rich = '{"firstStartTime":"2026-10-25T00:54:42.123Z","numStartups":1793059505666,"cost":0.1,"k":1,"K":2,"s":"한글","projects":{"C:/x":{"allowedTools":[],"hasTrustDialogAccepted":false}},"deep":{"l":[[1],[]],"o":{}}}'
        Check 'trust write: adds only projects[<repo root>].hasTrustDialogAccepted; dates, case-only keys and the rest survive' {
            [IO.File]::WriteAllText($trustCfg, $rich)
            $r = Set-WorkspaceTrusted -Path $repoDir -ConfigFile $trustCfg
            $key = ConvertTo-TrustPath (Join-Path $work 'trusted-parent\repo')
            $expect = $rich | ConvertFrom-Json -AsHashtable -DateKind String
            $expect.projects[$key] = [ordered]@{ hasTrustDialogAccepted = $true }
            $got = Get-Content -LiteralPath $trustCfg -Raw | ConvertFrom-Json -AsHashtable -DateKind String
            (Same $r.code 'TRUSTED') -and (Same $r.trustKey $key) -and (Same ($got | ConvertTo-Json -Depth 20 -Compress) ($expect | ConvertTo-Json -Depth 20 -Compress)) -and
            ((Get-Content -LiteralPath $trustCfg -Raw) -match '"2026-10-25T00:54:42\.123Z"') -and (Test-WorkspaceTrusted -Path $repoDir -ConfigFile $trustCfg) -and
            -not (Test-Path -LiteralPath "$trustCfg.lock") -and -not @(Get-ChildItem -LiteralPath $sandbox -Filter '*.tmp') -and (Test-Path -LiteralPath (Get-KitPath trustBackup))
        }
        Check 'trust write: a second call writes nothing; home, a drive root and the folders above home are refused' {
            $hash = (Get-FileHash $trustCfg).Hash
            $again = Set-WorkspaceTrusted -Path $repoDir -ConfigFile $trustCfg
            $codes = @($env:USERPROFILE, 'C:\', (Split-Path -Parent $env:USERPROFILE)) | ForEach-Object { (Set-WorkspaceTrusted -Path $_ -ConfigFile $trustCfg).code }
            (Same $again.code 'ALREADY_TRUSTED') -and (Same $again.written $false) -and (Same $codes @('TRUST_REFUSED', 'TRUST_REFUSED', 'TRUST_REFUSED')) -and ((Get-FileHash $trustCfg).Hash -eq $hash)
        }
        Check 'trust write: a held lock, a corrupt file or no file at all fails closed and writes nothing' {
            $hash = (Get-FileHash $trustCfg).Hash
            New-Item -ItemType Directory -Path "$trustCfg.lock" | Out-Null
            $held = Set-WorkspaceTrusted -Path $plain -ConfigFile $trustCfg -LockAttempts 2
            $kept = (Test-Path -LiteralPath "$trustCfg.lock") -and ((Get-FileHash $trustCfg).Hash -eq $hash)
            [IO.Directory]::Delete("$trustCfg.lock")
            $bad = Join-Path $sandbox 'trust-bad.json'; [IO.File]::WriteAllText($bad, '{ broken')
            $corrupt = Set-WorkspaceTrusted -Path $declined -ConfigFile $bad
            $none = Set-WorkspaceTrusted -Path $declined -ConfigFile (Join-Path $sandbox 'trust-none.json')
            (Same $held.code 'TRUST_WRITE_FAILED') -and $kept -and (Same $corrupt.code 'TRUST_WRITE_FAILED') -and (Same (Get-Content -LiteralPath $bad -Raw) '{ broken') -and
            -not (Test-Path -LiteralPath "$bad.lock") -and (Same $none.code 'TRUST_WRITE_FAILED') -and -not (Test-Path -LiteralPath (Join-Path $sandbox 'trust-none.json'))
        }
    }

    $now = Get-Date
    $old    = New-Transcript -Cwd $plain -Entrypoint 'cli' -When $now.AddDays(-3) -Title 'older work'
    $newer  = New-Transcript -Cwd $plain -Entrypoint 'cli' -When $now.AddHours(-2) -Title 'newer work'
    $cron   = New-Transcript -Cwd $plain -Entrypoint 'sdk-cli' -When $now.AddMinutes(-5)
    $sub    = New-Transcript -Cwd $plain -Entrypoint 'cli' -When $now.AddMinutes(-1) -SubDir 'subagents'
    $stale  = New-Transcript -Cwd $plain -Entrypoint 'cli' -When $now.AddDays(-45)
    $side   = New-Transcript -Cwd $plain -Entrypoint $null -When $now.AddMinutes(-20)   # a stale sidecar

    Check 'sessions: newest interactive first; cron, subfolder, stale, sidecar and a transcript recorded for another cwd in the same slug dir are excluded' {
        $foreign = [guid]::NewGuid().ToString()
        $dir = Join-Path (Join-Path $cfgDir 'projects') (ConvertTo-ProjectSlug $plain)
        [IO.File]::WriteAllLines((Join-Path $dir "$foreign.jsonl"), @((@{ entrypoint = 'cli'; cwd = 'C:\somewhere\else'; sessionId = $foreign } | ConvertTo-Json -Compress)))
        Same @((Get-ClaudeSessions -Path $plain -Days 30).SessionId) @($newer, $old)
    }
    Check 'resume ladder, empty registry: the scan picks the newest closed session; an open one (a running row, or the asking one) is skipped unless forking' {
        $t = Resolve-ResumeTarget -Path $plain
        $byRow = Resolve-ResumeTarget -Path $plain -RunningSessions @([pscustomobject]@{ SessionId = $newer })
        try { $env:CLAUDE_CODE_SESSION_ID = $newer; $byEnv = Resolve-ResumeTarget -Path $plain } finally { $env:CLAUDE_CODE_SESSION_ID = $null }
        $fork = Resolve-ResumeTarget -Path $plain -RunningSessions @([pscustomobject]@{ SessionId = $newer }) -IncludeOpen
        $allOpen = Resolve-ResumeTarget -Path $plain -RunningSessions @([pscustomobject]@{ SessionId = $newer }, [pscustomobject]@{ SessionId = $old })
        (Same $t.Mode 'resume-id') -and (Same $t.SessionId $newer) -and (Same $t.Source 'scan') -and (Same $t.Title 'newer work') -and
        (Same $byRow.SessionId $old) -and (Same $byRow.Source 'scan') -and (Same $byEnv.SessionId $old) -and
        (Same (Resolve-ResumeTarget -SessionId $newer -RunningSessions @([pscustomobject]@{ SessionId = $newer })).SessionId $newer) -and   # explicit: the launch refuses it
        (Same $fork.SessionId $newer) -and (Same $allOpen.Mode 'none')
    }
    Check 'registry: append, read back, survive a damaged line and a row written before names existed' {
        Register-LaunchedSession -SessionId $old -Cwd $plain -Alias 'p' -Source open
        Add-Content -LiteralPath (Get-KitPath registry) -Value '{ this is not json'
        # no name key, and never written: no transcript
        Add-Content -LiteralPath (Get-KitPath registry) -Value (@{ sessionId = [guid]::NewGuid().ToString(); cwd = $plain; alias = $null; source = 'new'; startedAt = (Get-Date).ToString('o') } | ConvertTo-Json -Compress)
        $r = @(Get-RegisteredSessions)
        (Same $r.Count 2) -and (Same $r[0].SessionId $old) -and (Same $r[0].Alias 'p') -and (Same $r[1].Name '')
    }
    Check 'resume ladder, with a registry: a registered session wins over a newer one unless it is open; an explicit id must exist and be interactive; the picker only for a folder, when allowed' {
        $t = Resolve-ResumeTarget -Path $plain
        $skip = Resolve-ResumeTarget -Path $plain -RunningSessions @([pscustomobject]@{ SessionId = $old })
        (Same $t.SessionId $old) -and (Same $t.Source 'registry') -and (Same $skip.SessionId $newer) -and (Same $skip.Source 'scan') -and
        (Same (Resolve-ResumeTarget -SessionId $newer).Cwd $plain) -and
        (Same (Resolve-ResumeTarget -SessionId $cron).Mode 'none') -and
        (Same (Resolve-ResumeTarget -SessionId ([guid]::NewGuid().ToString())).Mode 'none') -and
        (Same (Resolve-ResumeTarget -Path $declined -AllowPicker).Mode 'picker') -and
        (Same (Resolve-ResumeTarget -Path $declined).Mode 'none')
    }
    Check 'paths: UNC is refused with either kind of slash' {
        ($null -eq (Resolve-WorkspacePath '\\localhost\C$\Windows')) -and ($null -eq (Resolve-WorkspacePath '//localhost/C$/Windows'))
    }

    Write-Host "`nRunning sessions (stand-in claude; nothing is launched)"
    $agentsDir = New-Item -ItemType Directory -Force -Path (Join-Path $sandbox 'agents') | ForEach-Object FullName
    $agentsOk = Join-Path $agentsDir 'claude.cmd'
    $bgId = [guid]::NewGuid().ToString()
    [IO.File]::WriteAllText($agentsOk, "@echo off`r`necho [{`"pid`":4242,`"cwd`":`"C:\\w`",`"kind`":`"interactive`",`"sessionId`":`"$newer`",`"name`":`"n`",`"status`":`"idle`"},{`"kind`":`"background`",`"sessionId`":`"not-a-uuid`"},{`"kind`":`"background`",`"sessionId`":`"$bgId`",`"id`":`"ab12cd34`",`"state`":`"blocked`"}]`r`n")
    $agentsBad = Join-Path $agentsDir 'broken.cmd'
    [IO.File]::WriteAllText($agentsBad, "@echo off`r`nexit /b 1`r`n")
    Check 'running: `claude agents --json` is read; rows without a session id are dropped; a background row keeps its job id (what `claude attach` takes)' {
        try { $env:CLAUDE_CODE_BIN = $agentsOk; $r = @(Get-RunningSessions) } finally { $env:CLAUDE_CODE_BIN = $noClaude }
        (Same $r.Count 2) -and (Same $r[0].SessionId $newer) -and (Same $r[0].Pid 4242) -and (Same $r[0].Source 'agents') -and
        (Same $r[1].SessionId $bgId) -and (Same $r[1].Kind 'background') -and (Same $r[1].JobId 'ab12cd34')
    }
    Check 'launch: a session that is already open is not opened a second time; a fork still is, under a new recorded id' {
        $probe = Join-Path $agentsDir 'probe.ps1'
        [IO.File]::WriteAllText($probe, @'
param($Lib, $Dir, $Id)
. $Lib
function Start-ClaudeTerminal { param($WorkDir, $ClaudeExe, $ClaudeArgs) $script:argv = $ClaudeArgs; 'stub' }
function Register-LaunchedSession { param($SessionId) $script:reg = $SessionId }
$dup  = Invoke-SessionLaunch -WorkDir $Dir -Mode resume -SessionId $Id
$fork = Invoke-SessionLaunch -WorkDir $Dir -Mode resume -SessionId $Id -Fork
$bg = Invoke-SessionLaunch -WorkDir $Dir -Mode resume -SessionId $Id -RunningSessions @([pscustomobject]@{ SessionId = $Id; Kind = 'background'; Pid = $null; Name = $null; JobId = 'ab12cd34' })
@{ dup = $dup.code; fork = $fork.code; forkId = $fork.sessionId; forkedFrom = $fork.forkedFrom; forkArgv = $script:argv; reg = $script:reg
   bg = $bg.code; bgMessage = $bg.message; bgJob = $bg.jobId } | ConvertTo-Json -Compress
'@)
        try {
            $env:CLAUDE_CODE_BIN = $agentsOk
            $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $probe -Lib (Join-Path $scripts 'lib\Core.Effects.ps1') -Dir $plain -Id $newer 2>&1 | Select-Object -Last 1
        } finally { $env:CLAUDE_CODE_BIN = $noClaude }
        $o = "$out" | ConvertFrom-Json
        (Same $o.dup 'ALREADY_RUNNING') -and (Same $o.fork 'RESUMED') -and (Test-SessionIdFormat $o.forkId) -and ($o.forkId -ne $newer) -and
        (Same $o.forkedFrom $newer) -and (Same $o.reg $o.forkId) -and (Same @($o.forkArgv) @('--resume', $newer, '--fork-session', '--session-id', $o.forkId)) -and
        (Same $o.bg 'ALREADY_RUNNING') -and ($o.bgMessage -match 'claude attach ab12cd34') -and (Same $o.bgJob 'ab12cd34')
    }

    Write-Host "`nScripts (sandbox; nothing is launched)"
    $aliasDoc = @{ version = 2; tempTask = @{ root = $declined; prefix = 'scratch' }; aliases = @{
            good = @{ path = $plain; triggers = @('the good one'); note = 'n' }
            gone = @{ path = (Join-Path $work 'missing') }
            nope = @{ path = $declined }
            envy = @{ path = '%CSK_TEST_WORK%\okrepo' }
        } }
    [IO.File]::WriteAllText((Get-KitPath aliases), ($aliasDoc | ConvertTo-Json -Depth 5))

    Check 'list-aliases: one JSON object with every alias, its triggers and the temp settings; %VARS% in a path are expanded' {
        $r = Invoke-Script 'list-aliases.ps1'
        $row = @{}; foreach ($a in $r.Json.aliases) { $row[$a.name] = $a }
        (Same $r.ExitCode 0) -and (Same $r.Json.code 'ALIASES') -and (Same $r.Json.count 4) -and (Same $r.Json.tempTask.prefix 'scratch') -and
        (Same @($row.good.triggers) @('the good one')) -and (Same $row.gone.exists $false) -and (Same $row.envy.path (Join-Path $work 'okrepo')) -and (Same $row.envy.exists $true)
    }
    Check 'aliases: a broken aliases.json is named in the error, whichever script hits it; a missing one is NO_ALIASES' {
        $file = Get-KitPath aliases; $good = Get-Content $file -Raw
        try {
            [IO.File]::WriteAllText($file, '{ broken')
            $a = Invoke-Script 'list-aliases.ps1'; $o = Invoke-Script 'open-workspace.ps1' @('-Alias', 'good')
            Remove-Item $file
            $none = Invoke-Script 'open-workspace.ps1' @('-Alias', 'good')
        } finally { [IO.File]::WriteAllText($file, $good) }
        (Same $a.Json.code 'ALIASES_UNREADABLE') -and (Same $o.Json.code 'INTERNAL_ERROR') -and ($o.Json.message -match 'aliases\.json') -and (Same $none.Json.code 'NO_ALIASES')
    }
    Check 'refusals: an unknown alias, a missing folder, an untrusted folder and nothing to resume each get their code and exit 1; nothing is guessed' {
        $cases = @(
            @('open-workspace.ps1', 'ALIAS_NOT_FOUND', '-Alias', 'typo'),
            @('open-workspace.ps1', 'PATH_NOT_FOUND', '-Alias', 'gone'),
            @('open-workspace.ps1', 'UNTRUSTED_WORKSPACE', '-Alias', 'nope'),
            @('resume-session.ps1', 'UNTRUSTED_WORKSPACE', '-Path', $declined),
            @('resume-session.ps1', 'NO_RESUMABLE_SESSION', '-Path', $declined, '-NoPicker'),
            @('list-sessions.ps1', 'ALIAS_NOT_FOUND', '-Alias', 'typo'),
            @('search-sessions.ps1', 'PATH_NOT_FOUND', '-Query', 'x', '-Path', (Join-Path $sandbox 'no-such-folder')),
            @('reboot-plan.ps1', 'UNTRUSTED_WORKSPACE', '-WorkDir', $declined))
        $got = foreach ($c in $cases) {
            $arguments = @($c | Select-Object -Skip 2)
            $r = Invoke-Script $c[0] $arguments
            if ($r.Json.code -ne $c[1] -or $r.ExitCode -ne 1) { throw "$($c[0]) $($arguments -join ' ') gave $($r.Json.code), exit $($r.ExitCode)" }
            $r
        }
        ('good' -in $got[0].Json.known) -and (Same $got[2].Json.trustKey (ConvertTo-TrustPath $declined)) -and ($null -ne $got[7].Json.ships)
    }
    Check 'new-temp-task: a refused prompt or an untrusted root creates no folder; the prompt is never printed' {
        $p = Invoke-Script 'new-temp-task.ps1' @('-Prompt:SECRET-MARKER say "hi"', '-TrustFolder')
        $u = Invoke-Script 'new-temp-task.ps1'
        (Same @($p.Json.code, $p.ExitCode, $u.Json.code) @('INVALID_PROMPT', 1, 'UNTRUSTED_WORKSPACE')) -and
        ($p.Text -notmatch 'SECRET') -and ($null -ne $u.Json.ships) -and -not (Get-ChildItem -LiteralPath $declined -Directory)
    }
    Check 'open-workspace: -Prompt:"-x ..." binds as text and still stops at an untrusted folder; a refused prompt says only its length' {
        $r = Invoke-Script 'open-workspace.ps1' @('-Alias', 'nope', '-Model', 'haiku', '-Effort', 'low', '-Prompt:-x starts with a dash')
        $bad = Invoke-Script 'open-workspace.ps1' @('-Alias', 'nope', '-Prompt:look at %PATH%')
        (Same $r.Json.code 'UNTRUSTED_WORKSPACE') -and (Same $bad.Json.code 'INVALID_PROMPT') -and (Same $bad.Json.promptChars 14) -and ($bad.Text -notmatch 'look at')
    }
    Check 'list-sessions: registry first, then scan, no automation; each row says whether that session is open right now' {
        try { $env:CLAUDE_CODE_BIN = $agentsOk; $r = Invoke-Script 'list-sessions.ps1' @('-Alias', 'good') } finally { $env:CLAUDE_CODE_BIN = $noClaude }
        $rowOld = @($r.Json.sessions | Where-Object sessionId -eq $old)[0]; $rowNewer = @($r.Json.sessions | Where-Object sessionId -eq $newer)[0]
        (Same @($r.Json.sessions.sessionId | Sort-Object) @(@($old, $newer) | Sort-Object)) -and (Same $rowOld.source 'registry') -and
        (Same $rowNewer.running $true) -and (Same $rowOld.running $false)
    }
    Check 'list-candidates: groups by recorded cwd and marks aliased folders' {
        $r = Invoke-Script 'list-candidates.ps1' @('-IncludeTemp')
        $row = @($r.Json.candidates | Where-Object { $_.path -eq $plain })[0]
        # 3 = both recent sessions plus the 45-day-old one: this listing looks back 90 days
        (Same $r.Json.code 'CANDIDATES') -and (Same $row.sessions 3) -and (Same $row.alias 'good')
    }

    Write-Host "`nOpen sessions and restore (sandbox)"
    $hookScript = Join-Path $scripts 'track-session.ps1'
    $openDir = Get-KitPath openSessions
    function Get-OpenRecordFile([string]$Id) { Join-Path $openDir "$Id.json" }
    function New-HookInput([string]$Event, [string]$Id, [hashtable]$Extra = @{}) {
        $o = [ordered]@{ session_id = $Id; transcript_path = (Join-Path (Get-ProjectTranscriptDir $plain) "$Id.jsonl"); cwd = $plain; hook_event_name = $Event }
        foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] }
        return ($o | ConvertTo-Json -Compress)
    }
    # Hands the hook its input on stdin, the way Claude Code does. CLAUDE_PID is always set
    # explicitly: inherited from a session running this suite, it would name the real claude.
    function Invoke-Hook([string]$Json, [string]$Entrypoint = 'cli', [string]$ClaudePid = '') {
        $keep = @{ ep = $env:CLAUDE_CODE_ENTRYPOINT; cp = $env:CLAUDE_PID }
        try {
            $env:CLAUDE_CODE_ENTRYPOINT = $Entrypoint; $env:CLAUDE_PID = $ClaudePid
            $out = $Json | & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $hookScript 2>&1
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = (@($out | ForEach-Object { "$_" }) -join "`n") }
        } finally { $env:CLAUDE_CODE_ENTRYPOINT = $keep.ep; $env:CLAUDE_PID = $keep.cp }
    }

    Check 'start mode: read off the claude command line, split by the C runtime''s backslash and quote rules; a prompt that merely mentions the flag is not the flag' {
        (Same (Split-CommandLine 'a "b c" d\\"e f" "g\"h" i\j') @('a', 'b c', 'd\e f', 'g"h', 'i\j')) -and
        (Same (Split-CommandLine 'x "a ""b"" c" d') @('x', 'a "b" c', 'd')) -and
        (Same (Get-StartPermissionMode '"C:\bin\claude.exe" --permission-mode plan --name "a b"') 'plan') -and
        (Same (Get-StartPermissionMode 'claude.exe --permission-mode=acceptEdits') 'acceptEdits') -and
        (Same (Get-StartPermissionMode 'claude.exe --permission-mode plan --dangerously-skip-permissions') 'bypassPermissions') -and
        ($null -eq (Get-StartPermissionMode 'claude.exe "fix the --permission-mode plan bug"')) -and
        ($null -eq (Get-StartPermissionMode 'claude.exe "say \"--permission-mode plan\" now"')) -and
        ($null -eq (Get-StartPermissionMode 'claude.exe --resume x -- --permission-mode plan')) -and
        ($null -eq (Get-StartPermissionMode 'claude.exe --permission-mode "plan & calc"')) -and
        ($null -eq (Get-StartPermissionMode '')) -and
        (Same (Get-StartPermissionMode 'claude.exe --permission-mode default') 'manual')   # Manual's config value, under the name the CLI lists
    }
    Check 'hook: an interactive SessionStart records the session and the mode it started with, and prints nothing' {
        # A stand-in for the claude process, so its command line carries the flag.
        $sleeper = Join-Path $sandbox 'sleeper.ps1'; [IO.File]::WriteAllText($sleeper, 'Start-Sleep -Seconds 60')
        $psi = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        foreach ($a in '-NoProfile', '-File', $sleeper, '--permission-mode', 'plan') { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $fake = [Diagnostics.Process]::Start($psi)
        $id = [guid]::NewGuid().ToString()
        try { $r = Invoke-Hook (New-HookInput 'SessionStart' $id @{ source = 'startup' }) -ClaudePid $fake.Id } finally { try { $fake.Kill() } catch {} }
        $rec = Get-Content -LiteralPath (Get-OpenRecordFile $id) -Raw | ConvertFrom-Json
        Remove-OpenSessionRecord -SessionId $id   # it has no transcript: restore-open would prune it
        (Same $r.ExitCode 0) -and (Same $r.Text '') -and (Same $rec.sessionId $id) -and (Same $rec.cwd $plain) -and
        (Same $rec.permissionMode 'plan') -and (Same $rec.source 'startup') -and ($rec.transcriptPath -like "*$id.jsonl")
    }
    Check 'hook: the input is read as UTF-8 under any console code page (949 here), so a Korean folder is recorded intact' {
        $dir = Join-Path $work '한글 폴더'
        $id = [guid]::NewGuid().ToString()
        $in = Join-Path $sandbox 'hook-input.json'
        $json = [ordered]@{ session_id = $id; transcript_path = (Join-Path (Get-ProjectTranscriptDir $dir) "$id.jsonl"); cwd = $dir; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($in, $json, [Text.UTF8Encoding]::new($false))
        # A console of its own (CreateNoWindow): chcp changes that one, never this suite's.
        $psi = [Diagnostics.ProcessStartInfo]::new($env:ComSpec)
        $psi.Arguments = "/d /c chcp 949 >nul & `"$((Get-Process -Id $PID).Path)`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$hookScript`" < `"$in`""
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.Environment['CLAUDE_CODE_ENTRYPOINT'] = 'cli'; $psi.Environment['CLAUDE_PID'] = ''
        $p = [Diagnostics.Process]::Start($psi); $p.WaitForExit()
        $rec = Get-Content -LiteralPath (Get-OpenRecordFile $id) -Raw -Encoding UTF8 | ConvertFrom-Json
        Remove-OpenSessionRecord -SessionId $id
        (Same $rec.cwd $dir) -and ($rec.transcriptPath -like "*$id.jsonl")
    }
    Check 'hook: SDK, background and unmarked sessions are never recorded' {
        $sdk = [guid]::NewGuid().ToString(); $bg = [guid]::NewGuid().ToString(); $bare = [guid]::NewGuid().ToString()
        $a = Invoke-Hook (New-HookInput 'SessionStart' $sdk) -Entrypoint 'sdk-cli'
        $sessDir = New-Item -ItemType Directory -Force -Path (Join-Path $cfgDir 'sessions') | ForEach-Object FullName
        [IO.File]::WriteAllText((Join-Path $sessDir '999999.json'), '{"pid":999999,"kind":"background","entrypoint":"cli"}')
        try { $b = Invoke-Hook (New-HookInput 'SessionStart' $bg) -ClaudePid '999999' } finally { Remove-Item -LiteralPath $sessDir -Recurse -Force }
        $c = Invoke-Hook (New-HookInput 'SessionStart' $bare) -Entrypoint ''
        (Same @($a.ExitCode, $b.ExitCode, $c.ExitCode) @(0, 0, 0)) -and (Same ($a.Text + $b.Text + $c.Text) '') -and
        -not (Test-Path (Get-OpenRecordFile $sdk)) -and -not (Test-Path (Get-OpenRecordFile $bg)) -and -not (Test-Path (Get-OpenRecordFile $bare))
    }
    Check 'hook: a deliberate SessionEnd deletes the record; other and unknown reasons keep it' {
        $ends = [ordered]@{ prompt_input_exit = $false; clear = $false; resume = $false; logout = $false; other = $true; 'some-future-reason' = $true }
        foreach ($reason in @($ends.Keys)) {
            $id = [guid]::NewGuid().ToString()
            Set-OpenSessionRecord -SessionId $id -Cwd $plain -Source startup
            $r = Invoke-Hook (New-HookInput 'SessionEnd' $id @{ reason = $reason })
            if ($r.ExitCode -ne 0 -or $r.Text) { throw "SessionEnd/$reason printed or failed" }
            if ((Test-Path (Get-OpenRecordFile $id)) -ne $ends[$reason]) { throw "SessionEnd/$reason left the record in the wrong state" }
            Remove-OpenSessionRecord -SessionId $id
        }
        $true
    }
    Check 'hook: malformed input or a bad session id exits 0, prints nothing and writes nothing' {
        $before = @(Get-ChildItem -LiteralPath $openDir -Name)
        foreach ($in in @('', 'not json', '[1,2]', '{"hook_event_name":"SessionStart","session_id":"..\\..\\escape"}',
                '{"hook_event_name":"SessionStart","session_id":"11111111-1111-1111-1111-111111111111\n"}')) {
            $r = Invoke-Hook $in
            if ($r.ExitCode -ne 0 -or $r.Text) { throw "input '$in' gave exit $($r.ExitCode) / '$($r.Text)'" }
        }
        (Same @(Get-ChildItem -LiteralPath $openDir -Name) $before) -and -not (Get-ChildItem -LiteralPath $sandbox -Recurse -Filter 'escape*')
    }
    Check 'hooks.json: SessionStart and SessionEnd run track-session.ps1 directly, no shell; SessionEnd is not async' {
        $h = Get-Content -LiteralPath (Join-Path $repo 'hooks\hooks.json') -Raw | ConvertFrom-Json
        $target = '${CLAUDE_PLUGIN_ROOT}/skills/session/scripts/track-session.ps1'
        $each = foreach ($ev in 'SessionStart', 'SessionEnd') {
            $hs = @($h.hooks.$ev | ForEach-Object { $_.hooks })
            if ($hs.Count -ne 1 -or $hs[0].type -ne 'command' -or $hs[0].command -ne 'pwsh' -or @($hs[0].args)[-1] -cne $target) { throw "$ev is not the track-session hook" }
            $hs[0]
        }
        (Test-Path (Join-Path $repo ($target -replace '^\$\{CLAUDE_PLUGIN_ROOT\}/', ''))) -and ('-NoProfile' -in $each[0].args) -and -not $each[1].PSObject.Properties['async']
    }

    # restore-open: transcripts in folders of their own, so the reboot tests' "newest session" stays theirs.
    $restoreDir = New-Item -ItemType Directory -Force -Path (Join-Path $work 'trusted-parent\restore') | ForEach-Object FullName
    $restoreUntrusted = New-Item -ItemType Directory -Force -Path (Join-Path $work 'restore-untrusted') | ForEach-Object FullName
    function Add-OpenSession([string]$Cwd, [string]$Entrypoint, [datetime]$When, [string]$Title, [string]$Mode) {
        $id = New-Transcript -Cwd $Cwd -Entrypoint $Entrypoint -When $When -Title $Title
        Set-OpenSessionRecord -SessionId $id -Cwd $Cwd -TranscriptPath (Join-Path (Get-ProjectTranscriptDir $Cwd) "$id.jsonl") -PermissionMode $Mode -Source startup
        return $id
    }
    $liveId = Add-OpenSession $restoreDir 'cli' (Get-Date).AddMinutes(-1) 'still open'
    $lostA = Add-OpenSession $restoreDir 'cli' (Get-Date).AddMinutes(-10) 'lost A' 'plan'
    $lostB = Add-OpenSession $restoreUntrusted 'cli' (Get-Date).AddMinutes(-5) 'lost B' 'bypassPermissions'
    $autoId = Add-OpenSession $restoreDir 'sdk-cli' (Get-Date).AddMinutes(-2) $null
    $vanished = Add-OpenSession $restoreDir 'cli' (Get-Date).AddMinutes(-3) 'vanished'
    Remove-Item -LiteralPath (Join-Path (Get-ProjectTranscriptDir $restoreDir) "$vanished.jsonl")
    $restoreAgents = Join-Path $agentsDir 'restore-claude.cmd'
    [IO.File]::WriteAllText($restoreAgents, "@echo off`r`necho [{`"pid`":4343,`"cwd`":`"C:\\w`",`"kind`":`"interactive`",`"sessionId`":`"$liveId`",`"status`":`"idle`"}]`r`n")
    function Invoke-Restore([string[]]$Arguments = @()) {
        try { $env:CLAUDE_CODE_BIN = $restoreAgents; return (Invoke-Script 'restore-open.ps1' $Arguments) } finally { $env:CLAUDE_CODE_BIN = $noClaude }
    }
    # Runs a script with the launcher stubbed: the stub records each tab instead of opening it.
    $launchLog = Join-Path $agentsDir 'launches.jsonl'
    $stubRunner = Join-Path $agentsDir 'stub-runner.ps1'
    [IO.File]::WriteAllText($stubRunner, @'
param($Lib, $Script, $Log, $ArgsJson)
. $Lib
function Start-ClaudeTerminal { param($WorkDir, $ClaudeExe, $ClaudeArgs) Add-Content -LiteralPath $Log -Value (@{ dir = $WorkDir; argv = @($ClaudeArgs) } | ConvertTo-Json -Compress); 'stub' }
function Register-LaunchedSession {}
$line = '. "$PSScriptRoot\lib\Core.Effects.ps1"'
$src = [IO.File]::ReadAllText($Script)
# Without that line removed, the script would load the real launcher over the stubs.
if (-not $src.Contains($line)) { throw 'the script no longer loads Core.Effects the expected way' }
$src = $src.Replace($line, '') -replace '(?m)^#requires.*$', ''
$splat = $ArgsJson | ConvertFrom-Json -AsHashtable
& ([scriptblock]::Create($src)) @splat
'@)
    function Invoke-Stubbed([string]$Name, [string]$ArgsJson) {
        Remove-Item -LiteralPath $launchLog -ErrorAction Ignore
        try {
            $env:CLAUDE_CODE_BIN = $restoreAgents
            $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $stubRunner -Lib (Join-Path $scripts 'lib\Core.Effects.ps1') -Script (Join-Path $scripts $Name) -Log $launchLog -ArgsJson $ArgsJson 2>&1
        } finally { $env:CLAUDE_CODE_BIN = $noClaude }
        $json = $null; try { $json = (@($out | ForEach-Object { "$_" }) | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json } catch {}
        $tabs = @(if (Test-Path -LiteralPath $launchLog) { Get-Content -LiteralPath $launchLog | ForEach-Object { $_ | ConvertFrom-Json } })
        return [pscustomobject]@{ Json = $json; Tabs = $tabs }
    }

    Check 'restore-open: lists only sessions that are not running, newest first; prunes vanished and automated records; never offers the asking session' {
        $r = Invoke-Restore
        try { $env:CLAUDE_CODE_SESSION_ID = $lostB; $asking = Invoke-Restore } finally { $env:CLAUDE_CODE_SESSION_ID = $null }
        (Same $r.ExitCode 0) -and (Same $r.Json.code 'OPEN_SESSIONS') -and (Same @($r.Json.sessions.sessionId) @($lostB, $lostA)) -and
        (Same @($r.Json.sessions.n) @(1, 2)) -and (Same $r.Json.sessions[1].title 'lost A') -and (Same $r.Json.sessions[1].permissionMode 'plan') -and
        (Same $r.Json.sessions[1].cwdExists $true) -and (Same $r.Json.pruned 2) -and
        (Test-Path (Get-OpenRecordFile $liveId)) -and -not (Test-Path (Get-OpenRecordFile $vanished)) -and -not (Test-Path (Get-OpenRecordFile $autoId)) -and
        (Same @($asking.Json.sessions.sessionId) @($lostA))
    }
    Check 'restore-open: -Forget takes "3,<id>" as pwsh -File hands it over and opens nothing; a row not in the list or two actions are refused' {
        $extra = Add-OpenSession $restoreDir 'cli' (Get-Date).AddMinutes(-30) 'forget me'
        $extra2 = Add-OpenSession $restoreDir 'cli' (Get-Date).AddMinutes(-40) 'forget me too'
        $bad = Invoke-Restore @('-Forget', '3,9')
        $both = Invoke-Restore @('-All', '-Forget', '3')
        $kept = (Test-Path (Get-OpenRecordFile $extra)) -and (Test-Path (Get-OpenRecordFile $extra2))
        $f = Invoke-Restore @('-Forget', "3,$extra2")
        (Same $bad.Json.code 'NOT_IN_LIST') -and (Same @($bad.Json.notInList) @('9')) -and (Same $both.Json.code 'CONFLICTING_OPTIONS') -and $kept -and
        (Same $f.Json.code 'FORGOTTEN') -and (Same @($f.Json.forgotten.sessionId) @($extra, $extra2)) -and
        -not (Test-Path (Get-OpenRecordFile $extra)) -and -not (Test-Path (Get-OpenRecordFile $extra2)) -and
        (Test-Path (Get-OpenRecordFile $lostA)) -and (Test-Path (Get-OpenRecordFile $lostB))
    }
    Check 'restore-open -Ids and -All: each tab resumes in its transcript''s folder with its start mode; untrusted is refused; bypass is never replayed' {
        # After a `cd` and a compact the hook holds another cwd; the transcript's folder still wins.
        $sub = New-Item -ItemType Directory -Force -Path (Join-Path $restoreDir 'sub') | ForEach-Object FullName
        Set-OpenSessionRecord -SessionId $lostA -Cwd $sub -TranscriptPath (Join-Path (Get-ProjectTranscriptDir $restoreDir) "$lostA.jsonl") -PermissionMode 'plan' -Source compact
        $r = Invoke-Stubbed 'restore-open.ps1' '{"Ids":"1,2"}'   # one string, the way pwsh -File delivers it
        $all = Invoke-Stubbed 'restore-open.ps1' '{"All":true}'
        (Same $r.Json.code 'RESTORED') -and (Same $r.Json.opened 1) -and
        (Same @($r.Json.results.code) @('UNTRUSTED_WORKSPACE', 'RESUMED')) -and (Same $r.Json.results[0].droppedPermissionMode 'bypassPermissions') -and
        (Same $r.Json.results[1].permissionMode 'plan') -and (Same $r.Tabs.Count 1) -and (Same $r.Tabs[0].dir $restoreDir) -and
        (Same @($r.Tabs[0].argv) @('--permission-mode', 'plan', '--resume', $lostA)) -and
        (Same $all.Json.code 'RESTORED') -and (Same $all.Json.requested 2) -and (Same @($all.Json.results.code) @('UNTRUSTED_WORKSPACE', 'RESUMED')) -and (Same @($all.Tabs[0].argv)[-1] $lostA)
    }
    Check 'resume-session: replays the mode the session was started with' {
        $r = Invoke-Stubbed 'resume-session.ps1' "{`"SessionId`":`"$lostA`"}"
        (Same $r.Json.code 'RESUMED') -and (Same $r.Json.permissionMode 'plan') -and (Same @($r.Tabs[0].argv) @('--permission-mode', 'plan', '--resume', $lostA))
    }

    # -TrustFolder: each run gets its own copy of the config, so the sandbox's stays untouched.
    $shipper = New-Item -ItemType Directory -Force -Path (Join-Path $work 'shipper\.claude') | ForEach-Object { $_.Parent.FullName }
    [IO.File]::WriteAllText((Join-Path $shipper '.claude\settings.json'), '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"x"}]}]},"permissions":{"allow":["Bash(*)"]}}')
    [IO.File]::WriteAllText((Join-Path $shipper '.mcp.json'), '{"mcpServers":{"srv":{"command":"x"}}}')
    function Use-ConfigCopy([scriptblock]$Run) {
        $dir = Join-Path $sandbox ('cfg-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Copy-Item -LiteralPath (Join-Path $cfgDir '.claude.json') -Destination $dir
        $keep = $env:CLAUDE_CONFIG_DIR
        try { $env:CLAUDE_CONFIG_DIR = $dir; return (& $Run (Join-Path $dir '.claude.json')) } finally { $env:CLAUDE_CONFIG_DIR = $keep }
    }
    Check 'untrusted refusal lists what the folder ships (hooks, MCP servers, allow rules)' {
        $r = Invoke-Script 'open-workspace.ps1' @('-Path', $shipper)
        (Same $r.Json.code 'UNTRUSTED_WORKSPACE') -and (Same $r.Json.ships.hooks 1) -and (Same @($r.Json.ships.mcpServers) @('srv')) -and (Same $r.Json.ships.allowRules 1) -and (Same @($r.Json.ships.files).Count 2)
    }
    Check 'open-workspace -TrustFolder: marks the folder trusted, then opens it; a launch refused for another reason writes no trust' {
        Use-ConfigCopy {
            param($cfg)
            $hash = (Get-FileHash $cfg).Hash
            $bad = Invoke-Script 'open-workspace.ps1' @('-Path', $shipper, '-Name', 'R&D', '-TrustFolder')
            $unwritten = (Get-FileHash $cfg).Hash -eq $hash
            $r = Invoke-Stubbed 'open-workspace.ps1' (@{ Path = $shipper; TrustFolder = $true } | ConvertTo-Json -Compress)
            (Same $bad.Json.code 'INVALID_NAME') -and $unwritten -and (Same $r.Json.code 'LAUNCHED') -and (Same $r.Json.trustWritten $true) -and
            (Same $r.Json.trustKey (ConvertTo-TrustPath $shipper)) -and (Same $r.Tabs.Count 1) -and (Test-WorkspaceTrusted -Path $shipper -ConfigFile $cfg)
        }
    }
    Check 'new-temp-task -TrustFolder: an untrusted root is fine; only the NEW folder is trusted; a failed write leaves no folder' {
        $ok = Use-ConfigCopy {
            param($cfg)
            $r = Invoke-Stubbed 'new-temp-task.ps1' '{"TrustFolder":true}'
            $made = @(Get-ChildItem -LiteralPath $declined -Directory)
            $made | ForEach-Object { [IO.Directory]::Delete($_.FullName) }
            (Same $r.Json.code 'LAUNCHED') -and (Same $made.Count 1) -and (Same $r.Json.trustKey (ConvertTo-TrustPath $made[0].FullName)) -and
            (Test-WorkspaceTrusted -Path $made[0].FullName -ConfigFile $cfg) -and -not (Test-WorkspaceTrusted -Path $declined -ConfigFile $cfg)
        }
        # A fresh copy: in the first one the reused folder number is already trusted.
        $ok -and (Use-ConfigCopy {
            param($cfg)
            New-Item -ItemType Directory -Path "$cfg.lock" | Out-Null
            try { $f = Invoke-Stubbed 'new-temp-task.ps1' '{"TrustFolder":true}' } finally { [IO.Directory]::Delete("$cfg.lock") }
            (Same $f.Json.code 'TRUST_WRITE_FAILED') -and (Same $f.Tabs.Count 0) -and -not (Get-ChildItem -LiteralPath $declined -Directory)
        })
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

    Check 'transcript head: the last relocated record (a /cd or worktree move, in the tail) wins over the first cwd; the last custom-title wins over any ai-title, even a later one' {
        $head = '{"type":"user","entrypoint":"cli","cwd":"C:\\one","sessionId":"x","message":{"role":"user","content":"hi"}}'
        $moved = Get-TranscriptHeadInfo -Lines @($head) -TailLines @('{"type":"relocated","relocatedCwd":"C:\\two"}', '{"type":"relocated","relocatedCwd":"C:\\three"}')
        $t = Get-TranscriptHeadInfo -Lines @((Json (Titled custom 'first name')), (Json (Titled ai 'summary')), (Json (Titled custom 'renamed')), (Json (Titled ai 'later summary')))
        (Same $moved.Cwd 'C:\three') -and (Same $moved.Kind 'interactive') -and (Same (Get-TranscriptHeadInfo -Lines @($head)).Cwd 'C:\one') -and
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
        # typed by the person, so a prompt even though it opens with '<'; the wrappers carry no promptSource
        $lt   = Get-TranscriptHeadInfo -Lines @($cmd, '{"type":"user","promptSource":"typed","message":{"role":"user","content":"<div class=\"x\"> why is this wide"}}')
        (Same $ai.Title 'two') -and (Same $ai.TitleSource 'ai') -and (Same $p.Title 'fix the login bug') -and (Same $p.TitleSource 'prompt') -and
        ($long.Title.Length -le 80) -and $long.Title.EndsWith('...') -and ($null -eq $none.Title) -and ($null -eq $none.TitleSource) -and
        (Same $lt.Title '<div class="x"> why is this wide') -and (Same $lt.TitleSource 'prompt')
    }
    Check 'titles: a /rename far past the head (and past 64 KB) is found in the tail window' {
        $recs = @((Titled ai 'early summary'), (Say 'start the work')) + @(1..200 | ForEach-Object { Reply (('filler ' * 90) + $_) }) + @((Titled custom 'renamed late'), (Reply 'after the rename'))
        $file = Join-Path (Get-ProjectTranscriptDir $titled) ((New-Chat -Cwd $titled -Records $recs) + '.jsonl')
        $rec = Get-ClaudeSessionRecord -TranscriptPath $file
        ((Get-Item $file).Length -gt 64KB) -and (Same $rec.Kind 'interactive') -and (Same $rec.Title 'renamed late') -and (Same $rec.TitleSource 'custom')
    }
    Check '-Name: reaches the claude argv, the result and the registry; list-sessions shows it until the transcript records a title' {
        $probe = Join-Path $sandbox 'nameprobe.ps1'
        [IO.File]::WriteAllText($probe, @'
param($Lib, $Dir)
. $Lib
function Start-ClaudeTerminal { param($WorkDir, $ClaudeExe, $ClaudeArgs) $script:argv = $ClaudeArgs; 'stub' }
$r = Invoke-SessionLaunch -WorkDir $Dir -Mode new -Source open -Name 'blog refactor'
@{ sessionId = $r.sessionId; name = $r.name; argv = $script:argv } | ConvertTo-Json -Compress
'@)
        try {
            $env:CLAUDE_CODE_BIN = $agentsOk
            $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $probe -Lib (Join-Path $scripts 'lib\Core.Effects.ps1') -Dir $titled 2>&1 | Select-Object -Last 1
        } finally { $env:CLAUDE_CODE_BIN = $noClaude }
        $o = "$out" | ConvertFrom-Json
        $script:namedId = $o.sessionId
        $reg = @(Get-RegisteredSessions | Where-Object SessionId -eq $o.sessionId)
        New-Chat -Cwd $titled -Records @((Say '<command-name>/clear</command-name>')) -Id $o.sessionId | Out-Null   # written, no title yet
        $row = @((Invoke-Script 'list-sessions.ps1' @('-Path', $titled)).Json.sessions | Where-Object sessionId -eq $o.sessionId)[0]
        (Same @($o.argv[0..1]) @('--name', 'blog refactor')) -and (Same $o.name 'blog refactor') -and (Same $reg.Count 1) -and (Same $reg[0].Name 'blog refactor') -and
        (Same $row.title 'blog refactor') -and (Same $row.titleSource 'custom')
    }
    Check 'launch: the hand-off case (model, effort, first prompt) gives the exact argv; the prompt is in no result, record or log; a .cmd shim refuses only a prompt' {
        $probe = Join-Path $sandbox 'handoffprobe.ps1'
        [IO.File]::WriteAllText($probe, @'
param($Lib, $Dir, $Claude, $Prompt, $Model, $Effort)
. $Lib
function Resolve-ClaudeBinary { $Claude }
function Start-ClaudeTerminal { param($WorkDir, $ClaudeExe, $ClaudeArgs) $script:argv = $ClaudeArgs; 'stub' }
$script:argv = $null
$r = Invoke-SessionLaunch -WorkDir $Dir -Mode new -Source open -Model $Model -Effort $Effort -Prompt $Prompt
@{ result = $r; argv = $script:argv } | ConvertTo-Json -Compress -Depth 4
'@)
        $lib = Join-Path $scripts 'lib\Core.Effects.ps1'
        $note = 'Read the hand-off note to the end; SECRET-MARKER-7, then show a plan first.'
        function Launch($Claude, $Prompt, $Model, $Effort) {
            $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $probe -Lib $lib -Dir $titled -Claude $Claude -Prompt $Prompt -Model $Model -Effort $Effort 2>&1 | Select-Object -Last 1
            return [pscustomobject]@{ Text = "$out"; Json = ("$out" | ConvertFrom-Json) }
        }
        $a = Launch 'C:\bin\claude.exe' $note 'claude-opus-5-5' 'xhigh'
        $shim = Launch 'C:\npm\claude.cmd' $note 'claude-opus-5-5' 'xhigh'
        $modelOnly = Launch 'C:\npm\claude.cmd' '' 'haiku' ''
        $refused = Launch 'C:\bin\claude.exe' 'SECRET-MARKER-7 "quoted"' 'haiku' 'low'
        $id = $a.Json.result.sessionId
        $reg = @(Get-RegisteredSessions | Where-Object SessionId -eq $id)
        $wired = @('open-workspace.ps1', 'new-temp-task.ps1' | Where-Object { (Get-Content (Join-Path $scripts $_) -Raw) -match 'Invoke-SessionLaunch[^\r\n]*-Name \$Name -Model \$Model -Effort \$Effort -Prompt \$Prompt' })
        (Same $a.Json.argv @('--model', 'claude-opus-5-5', '--effort', 'xhigh', '--session-id', $id, '--', $note)) -and (Same $a.Json.result.code 'LAUNCHED') -and
        (Same $a.Json.result.model 'claude-opus-5-5') -and (Same $a.Json.result.effort 'xhigh') -and (Same $a.Json.result.promptChars $note.Length) -and
        (Same $reg.Count 1) -and (Select-String -LiteralPath (Get-KitPath log) -Pattern $id -SimpleMatch -Quiet) -and
        (($a.Json.result | ConvertTo-Json -Compress) -notmatch 'SECRET') -and -not (Select-String -LiteralPath (Get-KitPath registry), (Get-KitPath log) -Pattern 'SECRET' -SimpleMatch -CaseSensitive) -and
        (Same $shim.Json.result.code 'CLAUDE_IS_SHIM') -and ($null -eq $shim.Json.argv) -and
        (Same $modelOnly.Json.result.code 'LAUNCHED') -and (Same $modelOnly.Json.argv @('--model', 'haiku', '--session-id', $modelOnly.Json.result.sessionId)) -and
        (Same $refused.Json.result.code 'INVALID_PROMPT') -and ($null -eq $refused.Json.argv) -and ($refused.Text -notmatch 'SECRET') -and (Same $wired.Count 2)
    }

    $sTitle = New-Chat -Cwd $finds -Records @((Titled ai 'deploy pipeline notes'), (Say 'how do we roll back the release'), (Reply 'run the rollback script, then redeploy'))
    $sBody  = New-Chat -Cwd $finds -Records @((Titled ai 'stage incident'), (Say 'the deploy failed again on stage'), (Reply ('checked the logs. ' + ('filler text ' * 30) + "the 배포 key expired`nrotate it and retry")),
        (Say '<bash-stdout>shelltokenzz=1</bash-stdout><bash-stderr></bash-stderr>'))
    $sAuto  = New-Chat -Cwd $finds -Entrypoint 'sdk-cli' -Records @((Say 'deploy rollback release 배포 expired'), (Reply 'deploy'))
    $sSub   = New-Chat -Cwd $finds -SubDir 'subagents' -Records @((Say 'deploy rollback release 배포 expired'))
    # the body-only session is the newer one, so only the title weight can rank the other first
    (Get-Item (Join-Path (Get-ProjectTranscriptDir $finds) "$sTitle.jsonl")).LastWriteTime = (Get-Date).AddHours(-3)
    (Get-Item (Join-Path (Get-ProjectTranscriptDir $finds) "$sBody.jsonl")).LastWriteTime = (Get-Date).AddHours(-1)

    Check 'search: every term has to match (case-insensitive, Hangul too); a title hit outranks a newer body hit; automated and subagent transcripts, command output and a parent folder''s name never match' {
        $want = [ordered]@{
            'ROLLBACK release' = @($sTitle); 'deploy expired' = @($sBody)   # OR would also bring back $sTitle
            '배포' = @($sBody); 'deploy' = @($sTitle, $sBody); 'finds rollback' = @($sTitle)
            'shelltokenzz' = @(); 'trusted rollback' = @()   # command output; "trusted" is only a parent folder
        }
        $got = @{}
        foreach ($q in $want.Keys) {
            $got[$q] = $r = Invoke-Script 'search-sessions.ps1' @('-Query', $q, '-Path', $finds)
            $ids = @($r.Json.sessions | ForEach-Object sessionId) -join ','
            if ($r.ExitCode -ne 0 -or $r.Json.code -ne 'SEARCH_RESULTS' -or $ids -ne ($want[$q] -join ',')) { throw "'$q' gave $($r.Json.code) with $(@($r.Json.sessions).Count) row(s)" }
        }
        try { $env:CLAUDE_CODE_SESSION_ID = $sTitle; $mine = Invoke-Script 'search-sessions.ps1' @('-Query', 'deploy', '-Path', $finds) } finally { $env:CLAUDE_CODE_SESSION_ID = $null }
        $dash = Invoke-Script 'search-sessions.ps1' @('-Query:-p', '-Path', $finds)   # the documented colon form: a term may start with a dash
        $top = $got['deploy'].Json.sessions; $snip = $got['deploy expired'].Json.sessions[0].snippet
        ($top[0].score -gt $top[1].score) -and (Same @($top[0].matchedIn) @('title')) -and ($null -eq $top[0].snippet) -and
        (Same @($got['배포'].Json.sessions[0].matchedIn) @('body')) -and (Same @($got['finds rollback'].Json.sessions[0].matchedIn) @('cwd', 'body')) -and
        $snip -and ($snip.Length -le 120) -and ($snip -notmatch '[\r\n]') -and (Same @($mine.Json.sessions.sessionId) @($sBody)) -and (Same @($dash.Json.terms) @('-p'))
    }

    $archive = Get-KitPath archive
    Check 'archive: copies registered transcripts, reports them up to date, copies one that grew again; -All adds every interactive transcript, never an automated one; -List never shows content' {
        $src = Join-Path (Get-ProjectTranscriptDir $titled) "$script:namedId.jsonl"
        $copy = Join-Path (Join-Path $archive (ConvertTo-ProjectSlug $titled)) "$script:namedId.jsonl"
        $first = Invoke-Script 'archive-sessions.ps1'
        $again = Invoke-Script 'archive-sessions.ps1'
        Add-Content -LiteralPath $src -Value '{"type":"last-prompt","sessionId":"x"}'
        $grown = Invoke-Script 'archive-sessions.ps1'
        $all = Invoke-Script 'archive-sessions.ps1' @('-All')
        $ids = @(Get-ChildItem -LiteralPath $archive -Recurse -Filter '*.jsonl' | ForEach-Object BaseName)
        $l = Invoke-Script 'archive-sessions.ps1' @('-List')
        $row = @($l.Json.archives | Where-Object sessionId -eq $sTitle)[0]
        (Same $first.Json.code 'ARCHIVED') -and ($first.Json.copied -ge 2) -and (Same $first.Json.failed 0) -and
        (Same $again.Json.copied 0) -and (Same $again.Json.upToDate $first.Json.copied) -and
        (Same $grown.Json.copied 1) -and ((Get-FileHash $copy).Hash -eq (Get-FileHash $src).Hash) -and
        ($all.Json.copied -gt 0) -and ($sTitle -in $ids) -and ($sAuto -notin $ids) -and ($cron -notin $ids) -and ($sSub -notin $ids) -and
        (Same $l.Json.total $ids.Count) -and (Same @($row.PSObject.Properties.Name) @('sessionId', 'cwd', 'size', 'date')) -and ($l.Text -notmatch 'rollback|pipeline|blog refactor')
    }

    Check 'retention: 30 days by default, with a warning; a large cleanupPeriodDays silences it; only a whole number of 1 or more in strict JSON is a period; settings.json is never written' {
        $settingsFile = Join-Path $cfgDir 'settings.json'
        $default = Invoke-Script 'list-sessions.ps1'
        $none = Invoke-Script 'resume-session.ps1' @('-Path', $declined, '-NoPicker')
        try {
            [IO.File]::WriteAllText($settingsFile, '{"cleanupPeriodDays": 3650, "theme": "dark"}')
            $before = (Get-FileHash $settingsFile).Hash
            $large = Invoke-Script 'list-sessions.ps1'
            Invoke-Script 'search-sessions.ps1' @('-Query', 'deploy') | Out-Null; Invoke-Script 'archive-sessions.ps1' @('-All') | Out-Null
            $untouched = (Get-FileHash $settingsFile).Hash -eq $before
            $want = [ordered]@{
                '{"cleanupPeriodDays": 7.0}' = 'settings:7'; '{}' = 'default:30'; "`r`n" = 'default:30'; '{"cleanupPeriodDays": 1e20}' = 'invalid:'
                "{ // settings files are strict JSON`n `"cleanupPeriodDays`": 90 }" = 'invalid:'; '{"cleanupPeriodDays": 0}' = 'invalid:'
            }
            foreach ($text in $want.Keys) {
                [IO.File]::WriteAllText($settingsFile, $text)
                $t = Get-TranscriptRetention
                Same "$($t.Source):$($t.Days)" $want[$text] | Out-Null
            }
            $zero = Invoke-Script 'list-sessions.ps1'   # the file still holds 0
        } finally { Remove-Item -LiteralPath $settingsFile -ErrorAction Ignore }
        (Same @($default.Json.retentionDays, $none.Json.retentionDays, $large.Json.retentionDays) @(30, 30, 3650)) -and [bool]$default.Json.warning -and
        ('warning' -notin $large.Json.PSObject.Properties.Name) -and $untouched -and ($null -eq $zero.Json.retentionDays) -and [bool]$zero.Json.warning
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
foreach ($n in @($script:InheritedSessionVariables) + 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_JOB_DIR') { Set-Item "Env:$n" 'parent' }
$env:CLAUDE_CODE_USE_POWERSHELL_TOOL = 'mine'
Start-ClaudeTerminal -WorkDir $PSScriptRoot -ClaudeExe 'claude.exe' -ClaudeArgs @('--session-id', '11111111-1111-1111-1111-111111111111') | Out-Null
'@)
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $probe -Lib (Join-Path $scripts 'lib\Core.Effects.ps1') -Wt (Join-Path $stub 'wt.cmd') 2>&1 | Out-Null
        $seen = @(Get-Content -LiteralPath (Join-Path $stub 'env.txt'))
        $leaked = @($seen | ForEach-Object { ($_ -split '=', 2)[0] } | Where-Object { $_ -in (@($script:InheritedSessionVariables) + 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_JOB_DIR') })
        (Same $leaked @()) -and ('CLAUDE_CODE_USE_POWERSHELL_TOOL=mine' -in $seen)
    }

    Write-Host "`nReboot path (sandbox; -Simulate only)"
    $env:CLAUDE_CODE_BIN = $agentsBad
    $promptFile = Join-Path $sandbox 'prompt.txt'
    [IO.File]::WriteAllText($promptFile, "재부팅 후 이어서: SECRET-MARKER-123`nnext step")
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
    # The reported cwd is deliberately wrong: only the transcript's recorded cwd counts.
    $otherDir = New-Item -ItemType Directory -Force -Path (Join-Path $work 'trusted-parent\other ; folder') | ForEach-Object FullName
    $second = New-Transcript -Cwd $otherDir -Entrypoint 'cli' -When (Get-Date) -Title 'second work'
    $untrusted = New-Transcript -Cwd $declined -Entrypoint 'cli' -When (Get-Date)
    $background = [guid]::NewGuid().ToString()
    $missingTranscript = [guid]::NewGuid().ToString()
    $missingCwd = New-Transcript -Cwd (Join-Path $work 'vanished') -Entrypoint 'cli' -When (Get-Date)
    # still running, but untouched for three days (a terminal another app keeps alive)
    $idle = New-Transcript -Cwd $otherDir -Entrypoint 'cli' -When (Get-Date).AddDays(-3) -Title 'idle work'
    $multiAgents = Join-Path $agentsDir 'multi.cmd'
    $rows = @(
        @{ sessionId = $newer; kind = 'interactive' },
        @{ sessionId = $second; kind = 'interactive'; cwd = $declined },
        @{ sessionId = $second; kind = 'interactive' },
        @{ sessionId = $untrusted; kind = 'interactive' },
        @{ sessionId = $cron; kind = 'interactive' },
        @{ sessionId = $background; kind = 'background' },
        @{ sessionId = $missingTranscript; kind = 'interactive' },
        @{ sessionId = $missingCwd; kind = 'interactive' },
        @{ sessionId = $idle; kind = 'interactive' }
    )
    function Set-AgentRows($Rows) { [IO.File]::WriteAllText($multiAgents, "@echo off`r`necho $($Rows | ConvertTo-Json -Compress)`r`n") }
    Set-AgentRows $rows
    try {
        $env:CLAUDE_CODE_BIN = $multiAgents
        Check 'reboot-plan: only trusted interactive open sessions return, deduplicated and in recorded folders; one idle past -MaxIdleHours is skipped as IDLE until the window is widened; -OnlyThis plans none' {
            $r = Invoke-Script 'reboot-plan.ps1' @('-WorkDir', $plain, '-SessionId', $newer)
            $cut = @($r.Json.skipped | Where-Object { $_.sessionId -eq $idle })
            $wide = Invoke-Script 'reboot-plan.ps1' @('-WorkDir', $plain, '-SessionId', $newer, '-MaxIdleHours', '96')
            $only = Invoke-Script 'reboot-plan.ps1' @('-WorkDir', $plain, '-OnlyThis')
            (Same @($r.Json.alsoResume.sessionId) @($second)) -and (Same $r.Json.alsoResume[0].workdir $otherDir) -and (Same $r.Json.alsoResume[0].title 'second work') -and
            (Same @($r.Json.skipped.sessionId) @($untrusted, $cron, $background, $missingTranscript, $missingCwd, $idle)) -and
            (Same $cut[0].reason 'IDLE') -and (Same $cut[0].title 'idle work') -and [bool]$cut[0].lastWrite -and
            (Same @($wide.Json.alsoResume.sessionId) @($second, $idle)) -and (Same @($only.Json.alsoResume) @()) -and (Same @($only.Json.skipped) @())
        }
        Check 'reboot-plan: caps other sessions at eight and reports every cut' {
            $many = @(1..9 | ForEach-Object { @{ sessionId = (New-Transcript -Cwd $otherDir -Entrypoint 'cli' -When (Get-Date)); kind = 'interactive' } })
            Set-AgentRows $many
            $r = Invoke-Script 'reboot-plan.ps1' @('-WorkDir', $plain)
            Set-AgentRows $rows
            (Same $r.Json.alsoResume.Count 8) -and (Same $r.Json.skipped[0].reason 'LIMIT_REACHED') -and (Same $r.Json.skipped[0].sessionId $many[8].sessionId)
        }
        $plan = Invoke-Script 'reboot-plan.ps1' @('-WorkDir', $plain, '-PromptFile', $promptFile, '-DelaySeconds', '5')
    } finally { $env:CLAUDE_CODE_BIN = $agentsBad }
    Check 'reboot-plan: the delay is floored at 30s, the prompt is not echoed, RunOnce targets the frozen copy within 260 chars, and only a plan is written' {
        (Same $plan.Json.delaySeconds 30) -and ($plan.Text -notmatch 'SECRET-MARKER') -and
        ($plan.Json.runOnce.Contains((Join-Path $kitHome 'runtime\resume.ps1'))) -and ($plan.Json.runOnce.Length -le 260) -and ($plan.Json.runOnce -notmatch [regex]::Escape($repo)) -and
        (Test-Path (Get-KitPath plan)) -and -not (Test-Path (Get-KitPath state)) -and -not (Test-Path (Get-KitPath runtime)) -and ((Get-RealRunOnce) -eq $runOnceBefore)
    }
    Check 'reboot-commit: a wrong token registers nothing; a plan that expired or is dated in the future is refused and discarded' {
        $wrong = Invoke-Script 'reboot-commit.ps1' @('-Token', 'deadbeef', '-Simulate')
        $fresh = Get-Content (Get-KitPath plan) -Raw
        $codes = foreach ($when in (Get-Date).AddMinutes(-11), (Get-Date).AddYears(50)) {
            $p = $fresh | ConvertFrom-Json
            $p.created_at = $when.ToString('o')
            [IO.File]::WriteAllText((Get-KitPath plan), ($p | ConvertTo-Json -Depth 5))
            (Invoke-Script 'reboot-commit.ps1' @('-Token', $plan.Json.token, '-Simulate')).Json.code
            if (Test-Path (Get-KitPath plan)) { 'PLAN_KEPT' }
            [IO.File]::WriteAllText((Get-KitPath plan), $fresh)
        }
        (Same $wrong.Json.code 'TOKEN_MISMATCH') -and (Same @($codes) @('PLAN_EXPIRED', 'PLAN_EXPIRED')) -and -not (Test-Path (Get-KitPath state))
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
    foreach ($shape in @('non-array', 'non-UUID', 'missing-dir', 'UNC', 'relative', 'duplicate', 'primary', 'over-cap')) {
        Check "reboot-commit: forged others ($shape) is PLAN_INVALID without state" {
            $r = Invoke-ForgedCommit {
                param($p)
                $valid = [pscustomobject]@{ session_id = $second; workdir = $otherDir }
                $p.others = @($valid)
                switch ($shape) {
                    'non-array' { $p.others = $valid }
                    'non-UUID' { $valid.session_id = 'not-a-uuid' }
                    'missing-dir' { $valid.workdir = Join-Path $work 'absent' }
                    'UNC' { $valid.workdir = '\\localhost\C$\Windows' }
                    'relative' { $valid.workdir = '.' }
                    'duplicate' { $p.others = @($valid, $valid) }
                    'primary' { $valid.session_id = $p.session_id }
                    'over-cap' { $p.others = @(1..9 | ForEach-Object { [pscustomobject]@{ session_id = [guid]::NewGuid().ToString(); workdir = $plain } }) }
                }
            }
            (Same $r.Json.code 'PLAN_INVALID') -and -not (Test-Path (Get-KitPath state))
        }
    }
    $frozenPath = Join-Path $kitHome 'runtime\resume.ps1'
    Check 'reboot-commit: a RunOnce that is not the rendered shape is refused -- another program, a prefix, extra arguments' {
        $a = Invoke-ForgedCommit { param($p) $p.runonce = 'C:\evil\x.exe' }
        $b = Invoke-ForgedCommit { param($p) $p.runonce = "C:\evil\x.exe --anything $frozenPath" }
        $c = Invoke-ForgedCommit { param($p) $p.runonce = $p.runonce + ' -EncodedCommand AAAA' }
        $d = Invoke-ForgedCommit { param($p) $p.runonce = $p.runonce -replace '-ExecutionPolicy Bypass -File', '-ExecutionPolicy Bypass -Command' }
        (Same @($a.Json.code, $b.Json.code, $c.Json.code, $d.Json.code) @('PLAN_INVALID', 'PLAN_INVALID', 'PLAN_INVALID', 'PLAN_INVALID')) -and -not (Test-Path (Get-KitPath state))
    }
    Check 'reboot-commit: a host that is not an installed pwsh/powershell is refused; the frozen copy cannot be redirected out of the state folder' {
        $fake = Join-Path $sandbox 'pwsh.exe'; [IO.File]::WriteAllText($fake, 'not a host')
        $a = Invoke-ForgedCommit { param($p) $p.runonce = "$fake -NoProfile -ExecutionPolicy Bypass -File $frozenPath" }
        $b = Invoke-ForgedCommit { param($p) $p.runonce = "C:\absent\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $frozenPath" }
        $out = Join-Path $kitHome '..\escaped\resume.ps1'
        $c = Invoke-ForgedCommit { param($p) $p.runtime_script = $out; $p.runonce = $p.runonce.Replace($frozenPath, $out) }
        (Same @($a.Json.code, $b.Json.code, $c.Json.code) @('PLAN_INVALID', 'PLAN_INVALID', 'PLAN_INVALID')) -and
        -not (Test-Path (Get-KitPath state)) -and -not (Test-Path (Join-Path $sandbox 'escaped'))
    }
    Check 'reboot-commit -Simulate: state + frozen script written, the plan consumed (it works once), the registry untouched' {
        # A resume_source smuggled into the plan is ignored: what gets frozen is the script next to reboot-commit.ps1.
        $evil = Join-Path $sandbox 'evil.ps1'; [IO.File]::WriteAllText($evil, 'Write-Host pwned')
        $p = Get-Content (Get-KitPath plan) -Raw | ConvertFrom-Json
        $p | Add-Member -NotePropertyName resume_source -NotePropertyValue $evil -Force
        [IO.File]::WriteAllText((Get-KitPath plan), ($p | ConvertTo-Json -Depth 5))
        $r = Invoke-Script 'reboot-commit.ps1' @('-Token', $plan.Json.token, '-Simulate')
        $again = Invoke-Script 'reboot-commit.ps1' @('-Token', $plan.Json.token, '-Simulate')
        $state = Get-Content (Get-KitPath state) -Raw | ConvertFrom-Json
        $frozen = Join-Path (Get-KitPath runtime) 'resume.ps1'
        (Same $r.Json.code 'SIMULATED') -and (Same $state.session_id $newer) -and (Same $state.workdir $plain) -and (Same $state.others[0].session_id $second) -and (Same $state.others[0].workdir $otherDir) -and ($state.prompt -match 'SECRET-MARKER') -and
        ((Get-FileHash $frozen).Hash -eq (Get-FileHash (Join-Path $scripts 'resume-after-reboot.ps1')).Hash) -and
        -not (Test-Path (Get-KitPath plan)) -and (Same $again.Json.code 'NO_PLAN') -and ((Get-RealRunOnce) -eq $runOnceBefore)
    }
    Check 'reboot-plan: pending resume is refused with metadata; -Replace preserves state while planning' {
        $before = Get-Content (Get-KitPath state) -Raw
        $r = Invoke-Script 'reboot-plan.ps1' @('-WorkDir', $plain)
        $replace = Invoke-Script 'reboot-plan.ps1' @('-WorkDir', $plain, '-Replace')
        Remove-Item -LiteralPath (Get-KitPath plan)
        (Same $r.Json.code 'RESUME_PENDING') -and (Same $r.Json.ok $false) -and (Same $r.Json.sessionId $newer) -and
        (Same $r.Json.workdir $plain) -and $r.Json.createdAt -and (Same $replace.Json.code 'REBOOT_PLANNED') -and (Same (Get-Content (Get-KitPath state) -Raw) $before)
    }
    Check 'reboot-plan: a stale hand-off is refused; -AllowStalePrompt overrides explicitly' {
        (Get-Item $promptFile).LastWriteTime = (Get-Date).AddMinutes(-31)
        try {
            $r = Invoke-Script 'reboot-plan.ps1' @('-WorkDir', $plain, '-PromptFile', $promptFile, '-Replace')
            $override = Invoke-Script 'reboot-plan.ps1' @('-WorkDir', $plain, '-PromptFile', $promptFile, '-Replace', '-AllowStalePrompt')
            Remove-Item -LiteralPath (Get-KitPath plan)
        } finally { (Get-Item $promptFile).LastWriteTime = Get-Date }
        (Same $r.Json.code 'PROMPT_STALE') -and (Same $r.Json.ok $false) -and (Same $override.Json.code 'REBOOT_PLANNED')
    }
    Check 'reboot-cancel -Status: the pending session, the other session ids and folders -- never the hand-off' {
        $r = Invoke-Script 'reboot-cancel.ps1' @('-Status')
        (Same $r.Json.code 'STATUS') -and (Same $r.Json.state.sessionId $newer) -and ($r.Json.state.promptLength -gt 0) -and
        (Same $r.Json.state.othersCount 1) -and (Same $r.Json.state.others[0].sessionId $second) -and
        (Same $r.Json.state.others[0].workdir $otherDir) -and ($r.Text -notmatch 'SECRET-MARKER')
    }

    # --- the resume script (the frozen copy), run against stand-ins for `claude` ----------
    $frozen = Join-Path (Get-KitPath runtime) 'resume.ps1'
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    function Set-ResumeState([string]$WorkDir, [string]$PromptText, [array]$Others = @()) {
        $s = [ordered]@{ session_id = $newer; workdir = $WorkDir; prompt = $PromptText; others = $Others; created_at = (Get-Date).ToString('o') }
        [IO.File]::WriteAllText((Get-KitPath state), ($s | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    }
    function Invoke-Resume([string]$ClaudeBin, [string[]]$Extra = @()) {
        try {
            $env:CLAUDE_CODE_BIN = $ClaudeBin
            $out = & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $frozen @Extra 2>&1 | Out-String
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $out }
        } finally { $env:CLAUDE_CODE_BIN = $noClaude }
    }
    $nasty = "finish step 2 `"then & echo pwned> INJECTED.marker & rem `" done`nsecond line with %USERNAME% and `"C:\some dir\`""

    Check 'resume -DryRun: resolves, keeps state, never logs the prompt; a missing working directory launches nothing and keeps the state' {
        $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $frozen -DryRun 2>&1 | Out-String
        $dry = ($LASTEXITCODE -eq 0 -or $out -match 'claude binary not found') -and ($out -match [regex]::Escape($newer) -or $out -match 'not found')
        $log = Get-Content (Get-KitPath log) -Raw
        Set-ResumeState (Join-Path $work 'vanished') 'go on'
        $r = Invoke-Resume '' @('-DryRun')
        $dry -and ($out -notmatch 'SECRET-MARKER') -and ($log -notmatch 'SECRET-MARKER') -and
        (Same $r.ExitCode 1) -and ($r.Text -match 'not found') -and (Test-Path (Get-KitPath state))
    }
    Check 'resume: with a .cmd shim the prompt travels in a file, never through cmd.exe' {
        $shimDir = New-Item -ItemType Directory -Force -Path (Join-Path $sandbox 'shim') | ForEach-Object FullName
        $shim = Join-Path $shimDir 'claude.cmd'
        [IO.File]::WriteAllText($shim, "@echo off`r`necho %*> `"%~dp0args.txt`"`r`n")
        Set-ResumeState $plain $nasty
        $r = Invoke-Resume $shim
        $argsSeen = Get-Content (Join-Path $shimDir 'args.txt') -Raw
        $handed = [IO.File]::ReadAllText((Join-Path $kitHome 'resume-prompt.txt'))
        -not (Get-ChildItem -LiteralPath $sandbox -Recurse -Filter 'INJECTED.marker') -and
        ($argsSeen -match [regex]::Escape("--resume $newer --")) -and ($argsSeen -match 'resume-prompt\.txt') -and ($argsSeen -notmatch 'pwned|USERNAME') -and
        ($handed -ceq $nasty) -and -not (Test-Path (Get-KitPath state)) -and (Test-Path (Join-Path (Split-Path -Parent (Get-KitPath state)) 'state.last.json')) -and ($r.Text -notmatch 'pwned')
    }
    # A real executable that records its argv: built with the C# compiler that ships with Windows PowerShell 5.1.
    $echoExe = Join-Path $sandbox 'echo args ; bin\claude.exe'
    if (Test-Path $ps51) {
        New-Item -ItemType Directory -Force -Path (Split-Path $echoExe) | Out-Null
        $src = 'using System; using System.IO; using System.Text; public static class P { public static int Main(string[] a) { var sb = new StringBuilder(); foreach (var s in a) sb.AppendLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(s))); File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "argv.txt"), sb.ToString()); File.WriteAllText(Path.Combine(Environment.CurrentDirectory, "session-argv.txt"), sb.ToString()); return 0; } }'
        $srcFile = Join-Path (Split-Path $echoExe) 'echoargs.cs'
        [IO.File]::WriteAllText($srcFile, $src)
        try { & $ps51 -NoProfile -NonInteractive -Command "Add-Type -Path '$srcFile' -OutputAssembly '$echoExe' -OutputType ConsoleApplication" 2>&1 | Out-Null } catch {}
    }
    if (Test-Path $echoExe) {
        function Read-ArgFile([string]$File) { @(Get-Content -LiteralPath $File | Where-Object { $_ } | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }) }
        function Get-EchoedArgs { Read-ArgFile (Join-Path (Split-Path $echoExe) 'argv.txt') }
        Check 'resume: the prompt reaches a real .exe as ONE intact argument; each other session gets a wt tab of its own in its folder, without a prompt; the state is archived' {
            $thirdDir = New-Item -ItemType Directory -Force -Path (Join-Path $work 'trusted-parent\third folder') | ForEach-Object FullName
            $third = [guid]::NewGuid().ToString()
            Set-ResumeState $plain $nasty @(@{ session_id = $second; workdir = $otherDir }, @{ session_id = $third; workdir = $thirdDir })
            # The recording exe stands in for wt too: started in each tab's folder, it leaves the wt argument list there.
            try { $env:CLAUDE_SESSION_KIT_WT_BIN = $echoExe; $r = Invoke-Resume $echoExe } finally { $env:CLAUDE_SESSION_KIT_WT_BIN = $null }
            $tabs = foreach ($t in @($otherDir, $second), @($thirdDir, $third)) {
                Same (Read-ArgFile (Join-Path $t[0] 'session-argv.txt')) @('-w', '0', 'nt', '-d', ($t[0] -replace ';', '\;'), '--', ($echoExe -replace ';', '\;'), '--resume', $t[1])
            }
            (Same @($tabs) @($true, $true)) -and (Same (Get-EchoedArgs) @('--resume', $newer, '--', $nasty)) -and
            -not (Test-Path (Get-KitPath state)) -and (Test-Path (Join-Path $kitHome 'state.last.json')) -and ($r.Text -notmatch 'SECRET-MARKER|pwned')
        }
        # The first hop of a launch, pwsh -> wt, with the recording exe standing in for wt. The
        # second hop happens inside the real wt, where no stand-in can see it; it was measured
        # by hand (see Get-PromptRefusal), and $intactThroughWt holds what survived it.
        Check 'launch: every prompt that passes reaches wt as the exact argument list' {
            $probe = Join-Path $sandbox 'wtprobe.ps1'
            [IO.File]::WriteAllText($probe, @'
param($Lib, $Wt, $PromptList)
. $Lib
Set-Location -LiteralPath $PSScriptRoot
function Resolve-WindowsTerminal { $Wt }
function Show-TerminalWindow {}
$i = 0
foreach ($line in Get-Content -LiteralPath $PromptList) {
    $i++
    $p = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($line))
    $claudeArgs = Get-ClaudeArgs -Mode new -SessionId '11111111-1111-1111-1111-111111111111' -Model 'claude-opus-5-5[1m]' -Effort xhigh -Prompt $p
    Start-ClaudeTerminal -WorkDir $PSScriptRoot -ClaudeExe 'C:\bin\claude.exe' -ClaudeArgs $claudeArgs | Out-Null
    $seen = @(Get-Content -LiteralPath (Join-Path (Split-Path $Wt) 'argv.txt') | Where-Object { $_ } | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) })
    $want = New-WtArgumentList -WorkDir $PSScriptRoot -Exe 'C:\bin\claude.exe' -Arguments $claudeArgs
    if ((ConvertTo-Json $seen -Compress) -cne (ConvertTo-Json $want -Compress)) { "prompt #$i" }
}
'@)
            $list = Join-Path $sandbox 'wt-prompts.txt'
            [IO.File]::WriteAllLines($list, @($intactThroughWt | ForEach-Object { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_)) }))
            Same @(& pwsh -NoProfile -ExecutionPolicy Bypass -File $probe -Lib (Join-Path $scripts 'lib\Core.Effects.ps1') -Wt $echoExe -PromptList $list 2>&1 | ForEach-Object { "$_" }) @()
        }
    } else {
        Skip 'resume and launch: argv round trip through a real .exe' 'could not build the argv-echo helper (needs Windows PowerShell 5.1)'
    }
    Check "the sandbox's .claude.json was never written, and the real claude never ran against it" {
        ((Get-FileHash (Join-Path $cfgDir '.claude.json')).Hash -eq $cfgHash) -and -not (Test-Path -LiteralPath (Join-Path $cfgDir 'daemon'))
    }

    Write-Host "`nStructure"
    $all = Get-ChildItem -LiteralPath $scripts -Recurse -Filter *.ps1
    function Code([IO.FileInfo]$f) {   # source with comments and help blocks removed
        $t = [IO.File]::ReadAllText($f.FullName)
        $t = [regex]::Replace($t, '(?s)<#.*?#>', '')
        return (($t -split "`r?`n" | ForEach-Object { $_ -replace '(^|\s)#.*$', '' }) -join "`n")
    }
    function Using([string]$Pattern) { @($all | Where-Object { (Code $_) -match $Pattern } | ForEach-Object Name | Sort-Object) }
    Check 'only reboot-commit.ps1 can restart Windows or write the RunOnce value' {
        (Same (Using 'shutdown(\.exe)?\s+/[rsgh]|Restart-Computer|Stop-Computer') @('reboot-commit.ps1')) -and (Same (Using '(Set|New)-ItemProperty') @('reboot-commit.ps1'))
    }
    # The frozen resume script also opens other sessions after logon, without loading lib/. A .NET
    # start is allowed only there and for Core.State's fixed `claude agents --json` query.
    Check 'only Core.Effects.ps1 and resume-after-reboot.ps1 start a terminal; reboot-plan.ps1 opens none, and the reboot scripts load no lib' {
        $plan = Code (Get-Item (Join-Path $scripts 'reboot-plan.ps1'))
        $lonely = @('reboot-commit.ps1', 'reboot-cancel.ps1', 'resume-after-reboot.ps1') | ForEach-Object { Code (Get-Item (Join-Path $scripts $_)) }
        $added = @([regex]::Matches((Code (Get-Item (Join-Path $scripts 'lib\Core.State.ps1'))), 'ArgumentList\.Add\(([^)]*)\)') | ForEach-Object { $_.Groups[1].Value })
        (Same (Using 'Start-Process|&\s*\$wt\b') @('Core.Effects.ps1', 'resume-after-reboot.ps1')) -and
        (Same (Using 'Process\]::Start|ProcessStartInfo') @('Core.State.ps1', 'resume-after-reboot.ps1')) -and (Same $added @("'agents'", "'--json'")) -and
        ($plan -notmatch 'Core\.Effects|Start-Process|Start-ClaudeTerminal|wt\.exe\s') -and -not ($lonely -match 'lib\\Core\.')
    }
    Check '`claude --continue` is never emitted; only Set-WorkspaceTrusted names the trust key, and only Invoke-SessionLaunch (-TrustFolder) calls it' {
        -not (Using "['""]--continue['""]|['""]-c['""]") -and
        (Same (Using 'hasTrustDialogAccepted') @('Core.State.ps1')) -and (Same (Using 'Set-WorkspaceTrusted\s+-') @('Core.Effects.ps1'))
    }
    Check 'manifests are valid and the plugin declares no "skills" key (it would replace auto-scan)' {
        $p = Get-Content (Join-Path $repo '.claude-plugin\plugin.json') -Raw | ConvertFrom-Json
        $m = Get-Content (Join-Path $repo '.claude-plugin\marketplace.json') -Raw | ConvertFrom-Json
        (Same $p.name 'claude-session-kit') -and ('skills' -notin $p.PSObject.Properties.Name) -and (Same $m.plugins[0].name $p.name) -and (Same $m.plugins[0].version $p.version) -and (Same $m.metadata.version $p.version) -and
        (Test-Path (Join-Path $repo 'skills\session\SKILL.md'))
    }
    Check 'SKILL.md names every references/*.md and no other; all of them use ${CLAUDE_SKILL_DIR}, not a fixed install path or %USERPROFILE%' {
        $skill = Get-Item (Join-Path $repo 'skills\session\SKILL.md')
        $refs = @(Get-ChildItem (Join-Path $repo 'skills\session\references') -Filter '*.md')
        foreach ($f in @($skill) + $refs) {
            $s = Get-Content -LiteralPath $f.FullName -Raw
            if (-not ($s -match [regex]::Escape('${CLAUDE_SKILL_DIR}')) -or $s -match '%USERPROFILE%' -or $s -match '\.claude[\\/]skills[\\/]') { throw $f.Name }
        }
        $named = @([regex]::Matches((Get-Content $skill.FullName -Raw), 'references/([\w-]+\.md)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        ($named.Count -gt 0) -and (Same $named @($refs | ForEach-Object Name | Sort-Object))
    }
    Check 'SKILL.md itself still carries every safety gate (they must not move into references/)' {
        $s = Get-Content (Join-Path $repo 'skills\session\SKILL.md') -Raw
        $gates = @('a restart always needs explicit approval in the user''s latest message', 'out of any permission allowlist',
            'only with the step 1 approval still the user''s latest message', '`-TrustFolder` is used **only when the user''s latest message says so**',
            'Never write an alias or a path into this SKILL.md', 'even when only one row comes back')
        $missing = @($gates | Where-Object { -not $s.Contains($_) })
        if ($missing) { throw "missing: $($missing -join ' | ')" }
        $true
    }
    # The list of a person's private words must not itself be published, so it lives
    # outside the repository: one token per line in <kit state>\private-tokens.txt.
    $tokensFile = Join-Path (Join-Path $env:USERPROFILE '.claude\claude-session-kit') 'private-tokens.txt'
    if ((Test-Path -LiteralPath $tokensFile) -and (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
        Check 'no private token appears in the tracked tree or anywhere in git history' {
            $tokens = @(Get-Content -LiteralPath $tokensFile -Encoding UTF8 | Where-Object { $_.Trim() -and -not $_.StartsWith('#') } | ForEach-Object Trim)
            $files = @(& git -C $repo ls-files --cached --others --exclude-standard) | ForEach-Object { Join-Path $repo $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
            if (-not $files) { throw 'found no files to scan' }
            # A public repository serves its whole history -- every old commit, message and author line.
            $enc = [Console]::OutputEncoding
            try {
                [Console]::OutputEncoding = [Text.Encoding]::UTF8
                $history = @(& git -C $repo -c core.quotepath=false log --all -p '--format=%H%n%an <%ae>%n%cn <%ce>%n%B') -join "`n"
            } finally { [Console]::OutputEncoding = $enc }
            if (-not $history) { throw 'git history could not be read' }
            # Only the token's NUMBER is reported.
            $leaks = @(foreach ($k in $tokens) {
                    $n = [array]::IndexOf($tokens, $k) + 1
                    foreach ($f in $files) { if ([IO.File]::ReadAllText($f).IndexOf($k, [StringComparison]::OrdinalIgnoreCase) -ge 0) { "$([IO.Path]::GetFileName($f)): token #$n" } }
                    if ($history.IndexOf($k, [StringComparison]::OrdinalIgnoreCase) -ge 0) { "git history: token #$n" }
                })
            if ($leaks) { throw ($leaks -join '; ') }
            $true
        }
    } else {
        Skip 'private-token scan' "no $tokensFile, or not a git work tree"
    }
} finally {
    try { if ($script:savedOutEnc) { [Console]::OutputEncoding = $script:savedOutEnc } } catch {}
    $env:CLAUDE_SESSION_KIT_HOME = $saved.kit; $env:CLAUDE_CONFIG_DIR = $saved.cfg
    $env:CLAUDE_CODE_SESSION_ID = $saved.csid; $env:CLAUDE_CODE_BIN = $saved.bin; $env:CSK_TEST_WORK = $null
    try { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction Stop } catch {}
}

Write-Host ("`n{0} passed, {1} failed, {2} skipped" -f $script:pass, $script:fail, $script:skipped)
if ($script:fail -gt 0) { exit 1 }
