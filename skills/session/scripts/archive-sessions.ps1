#requires -Version 7.0
<#
.SYNOPSIS
  Backs up transcripts before Claude Code's own cleanup deletes them.

.DESCRIPTION
  Claude Code deletes transcripts older than cleanupPeriodDays (default 30). This
  copies them to <kit state>\archive\<project slug>\<sessionId>.jsonl:
    (default)  the sessions in the kit registry (sessions.jsonl)
    -All       those, plus every interactive transcript from the last -Days days
  A transcript is copied only when its archive copy is missing, smaller or older.
  Nothing is ever deleted, and ~/.claude/projects is only read. The archive is a
  backup: nothing in this kit restores from it.

  -List shows what the archive holds -- ids, folders, sizes, dates -- never content.

  Prints one JSON object. code: ARCHIVED | ARCHIVE_LIST
#>
[CmdletBinding()]
param(
    [switch]$All,
    [int]$Days = 30,
    [switch]$List
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\Core.State.ps1"

try {
    Initialize-KitState | Out-Null
    $archive = Get-KitPath archive

    if ($List) {
        $rows = @(Get-ChildItem -LiteralPath $archive -Filter '*.jsonl' -File -Recurse -Depth 1 -ErrorAction SilentlyContinue |
                Where-Object { Test-SessionIdFormat $_.BaseName } | Sort-Object LastWriteTime -Descending | ForEach-Object {
                    [ordered]@{
                        sessionId = $_.BaseName; cwd = (Get-ClaudeSessionRecord -TranscriptPath $_.FullName).Cwd
                        size = $_.Length; date = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                    }
                })
        Exit-WithResult ([ordered]@{ ok = $true; code = 'ARCHIVE_LIST'; archiveDir = $archive; total = $rows.Count; archives = $rows })
    }

    # sessionId -> live transcript path
    $sources = [ordered]@{}
    # Every registry row, however old: a long-lived session can outlast any window.
    foreach ($r in @(Get-RegisteredSessions -Days 36500)) {
        $t = Join-Path (Get-ProjectTranscriptDir $r.Cwd) ($r.SessionId + '.jsonl')
        if (Test-Path -LiteralPath $t -PathType Leaf) { $sources[$r.SessionId] = $t }
    }
    if ($All) {
        foreach ($s in @(Get-ClaudeSessions -Days $Days)) { $sources[$s.SessionId] = $s.TranscriptPath }
    }

    $copied = 0; $upToDate = 0; $failed = 0
    foreach ($id in @($sources.Keys)) {
        $src = Get-Item -LiteralPath $sources[$id] -ErrorAction Ignore
        # Claude Code's own cleanup may have deleted it since the list was made
        if (-not $src) { $failed++; continue }
        # the folder name under projects/, as Claude Code spelled it
        $destDir = Join-Path $archive $src.Directory.Name
        $dest = Join-Path $destDir ($id + '.jsonl')
        $old = Get-Item -LiteralPath $dest -ErrorAction SilentlyContinue
        if ($old -and $old.Length -ge $src.Length -and $old.LastWriteTimeUtc -ge $src.LastWriteTimeUtc) { $upToDate++; continue }

        # Copied to a temporary name and moved over the old copy only when complete:
        # a half-written backup must never replace a whole one.
        $stamp = $src.LastWriteTimeUtc   # taken BEFORE the copy: a write during it makes the next run copy again
        $tmp = $dest + '.partial'
        try {
            New-Item -ItemType Directory -Force -Path $destDir | Out-Null
            $in = [IO.File]::Open($src.FullName, 'Open', 'Read', 'ReadWrite, Delete')   # a live session holds it open
            try {
                $out = [IO.File]::Open($tmp, 'Create', 'Write', 'None')
                try { $in.CopyTo($out) } finally { $out.Dispose() }
            } finally { $in.Dispose() }
            [IO.File]::SetLastWriteTimeUtc($tmp, $stamp)
            [IO.File]::Move($tmp, $dest, $true)
            $copied++
        } catch {
            $failed++
            Write-KitLog ("archive failed session={0}: {1}" -f $id, $_.Exception.Message)
            Remove-Item -LiteralPath $tmp -Force -ErrorAction Ignore   # only our own unfinished copy
        }
    }

    Exit-WithResult ([ordered]@{
            ok = $true; code = 'ARCHIVED'; scope = $(if ($All) { 'all' } else { 'registry' }); days = $(if ($All) { $Days } else { $null })
            archiveDir = $archive; copied = $copied; upToDate = $upToDate; failed = $failed
            message = "$copied transcript(s) copied, $upToDate already up to date, $failed failed."
        })
} catch {
    Write-KitResult -Ok $false -Code 'INTERNAL_ERROR' -Message $_.Exception.Message
    exit 2
}
