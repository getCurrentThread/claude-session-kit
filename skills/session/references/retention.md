# Retention and archive

`${CLAUDE_SKILL_DIR}` below is the skill folder SKILL.md was loaded from.

Claude Code deletes transcripts older than `cleanupPeriodDays` (default 30, in `settings.json` in the
Claude config folder), and a deleted session cannot be listed, searched or resumed. When
`list-sessions.ps1` returns a `warning` (`retentionDays` is 30 or less), relay it once and offer the
two ways to keep older sessions. `retentionDays` comes from the user's own `settings.json` only: an
organisation's managed settings or a project's settings can set a lower value, which then wins.
`retentionDays: null` with a `warning` means that file's value is not a whole number of 1 or more,
or the file is not strict JSON: relay the warning.

- **Raise the setting** to a large value such as 3650 — **never 0**: since v2.1.89 it is rejected, and
  older versions took 0 as "save no transcripts". No script in this kit writes `settings.json`; the
  user changes it, or asks you to as a separate edit.
- **Back them up** — copying only, read-only towards Claude Code's own folder:

```
# the sessions this kit opened (the registry)
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/archive-sessions.ps1"
# plus every interactive transcript from the last -Days days
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/archive-sessions.ps1" -All [-Days 30]
# what the archive holds: ids, folders, sizes, dates -- never content
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/archive-sessions.ps1" -List
```

`ARCHIVED` counts `copied` / `upToDate` / `failed`; a transcript is copied only when its archive copy
is missing, smaller or older, and nothing is ever deleted. Only the conversation file is copied,
not the session's `subagents\` or `tool-results\` folders. Copies land in
`<state folder>\archive\<project folder>\<sessionId>.jsonl`. The archive is a backup that nothing
in this kit reads back: to reopen an archived session after Claude Code deleted it, the user first
raises `cleanupPeriodDays` above the session's age (the copy keeps its old date, so Claude Code's next
start would delete it again), then copies the file by hand into the same project folder under
`~/.claude/projects`; resume it with `resume-session.ps1 -SessionId <id>` using the id from
`ARCHIVE_LIST` — its old date keeps it out of the list and the search.
