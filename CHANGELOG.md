# Changelog

## Unreleased

- **A session launched from a background session gets its own name.** A background session
  (`claude --bg`) has `CLAUDE_JOB_DIR` in its environment, and the launcher passed it on. Every tab
  opened from there joined that job: it took the job's name as its own title (`always-on` on five
  sessions in different folders) and followed each later rename of it. The launcher now drops
  `CLAUDE_JOB_DIR` with the other session markers. Sessions launched before this fix keep the name
  they recorded; `/rename` in that tab changes it.

## 0.2.0 — the whole session lifecycle

- **Restore after a crash or a closed window.** The plugin now ships `SessionStart`/`SessionEnd`
  hooks (`hooks/hooks.json` → `track-session.ps1`, run directly with no shell, the start hook in the
  background). They record each open interactive session under `open-sessions\` and delete the
  record when the session is ended on purpose; `restore-open.ps1` lists and reopens what a crash, a
  closed window or a power cut left behind. These hooks run in every session while the plugin is
  enabled.
- **Reboot and continue brings the other open sessions back too** (at most eight, each re-checked:
  interactive transcript, existing folder, trusted), in their own tabs and without a prompt.
  `-OnlyThis` keeps the old behaviour. The handoff note has a fixed template.
- **Stale-state guards.** `reboot-plan.ps1` refuses to plan over a resume that is still pending
  (`RESUME_PENDING`, `-Replace`) and refuses a prompt file older than 30 minutes (`PROMPT_STALE`,
  `-AllowStalePrompt`).
- **A session that is already open is never opened twice** (`ALREADY_RUNNING`), from resume, restore
  or anywhere else. Open sessions come from `claude agents --json`, or from the CLI's per-process
  records checked by PID and process start time. `list-sessions.ps1` marks them `running`.
- **The permission mode a session was started with is replayed** on resume and restore. The kit never
  picks one, and `bypassPermissions` is never replayed (`droppedPermissionMode`).
- **Titles.** A `/rename` or `--name` title now wins over the generated one wherever it sits in the
  transcript (head + last 64 KB are read), with the first typed prompt as a fallback; `titleSource`
  says which. `open-workspace.ps1` and `new-temp-task.ps1` take `-Name`.
- **Search.** `search-sessions.ps1 -Query` finds sessions by title, folder name or message text (every word
  must match; title > folder > text), with a one-line snippet; `rg` is used when installed.
- **Retention.** `list-sessions.ps1` reports `cleanupPeriodDays` (read-only) and warns at 30 days or
  less; `archive-sessions.ps1` copies transcripts into `archive\` before Claude Code deletes them.
- **Hardening from review.** A `-Name` that Windows Terminal or a `.cmd` shim would re-split into
  extra `claude` arguments (quotes, backslashes, `%`, `& | < > ^ !`, control characters) is refused
  with `INVALID_NAME`, before `new-temp-task.ps1` creates its folder. The hook reads its input as
  UTF-8, so a non-ASCII folder or profile path is recorded on a CP949/CP437 console. Restore opens
  each session in its transcript's folder and never offers the asking session. Run again by hand,
  the logon script skips any session (the primary too) that is already open. The no-`wt` fallbacks
  open folders whose names hold `[ ]`. A stale PID record without a start time counts as running only
  for a claude/node process, and a timed-out `claude agents` is killed with its whole process tree.
  Search matches a folder by its own name, not every parent in its path, and the `Select-String`
  fallback matches ordinally like `rg`. The archive finds a registered transcript that moved into a
  worktree's project folder and flushes each copy to disk before it replaces the old one; the
  title tail window no longer drops a line that starts exactly on its edge.
- **Second review.** Resuming the latest session skips sessions that are open (it used to pick the
  asking one and stop at `ALREADY_RUNNING`). `-Fork` creates the copy under a new `--session-id`
  and records it, so the next resume of that folder finds the copy; the picker forks too (unrecorded).
  Restore finds a crashed session whose transcript moved with `/cd` or a worktree instead of dropping
  its record, and a moved session opens in the folder it moved to (the last `relocated` record, as the
  CLI decides). The archive indexes the project folders once instead of once per missing registry row.
  `reboot-plan.ps1` reports an empty or partial `state.json` as `RESUME_PENDING` and refuses a
  handoff dated in the future; the logon script waits for missing extra folders once (30 s in all,
  not 30 s each). A background session gets `claude attach <jobId>` advice instead of "switch to
  that tab".
  `--permission-mode default` is recorded as `manual`. An invalid `cleanupPeriodDays` or a
  settings file that is not strict JSON is reported as such, and `7.0` counts as 7. A typed prompt
  that starts with `<` can be a title, and a first-prompt title scores as message text in search.
  Docs: one handoff file per session (`next-prompt-<id>.txt`), `-Query:` (a term may start with
  `-`), titles and snippets are data, restore lists closed windows too.
- Tests: the suite never runs the real `claude` (a stand-in answers `claude agents --json`), and a
  check fails if it ever does. It opens no console window.

## 0.1.1

- **A launched session is a top-level session again.** Claude Code writes its own session's markers
  (`CLAUDECODE`, `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_ENTRYPOINT`, …)
  into the environment of every command it runs, and Windows Terminal hands the caller's environment
  to the tab it opens. A `claude` started that way took itself for the asking session's child and
  turned transcript saving off (`Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION
  marker`), so nothing it did could be resumed. The launcher now drops those markers before it opens
  the tab; user settings in the environment pass through unchanged. The reboot path was not
  affected: RunOnce starts from a fresh logon environment.

## 0.1.0 — merged into `claude-session-kit`

The standalone `reboot-continue` skill and a workspace launcher became one plugin with one skill,
`claude-session-kit:session`. The repository was renamed from `reboot-continue`.

### If you used `reboot-continue`

1. **Cancel anything pending first.** The old RunOnce value points into the old folder; delete the
   folder first and a scheduled resume is lost without a trace.
   `powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\skills\reboot-continue\scripts\request-reboot.ps1" -Cancel`
2. Remove `~\.claude\skills\reboot-continue` — otherwise the old and new skills both answer
   "reboot and continue".
3. Install the plugin (see README).

### What changed

- **Slash name.** `/reboot-continue` is gone; the skill is `claude-session-kit:session`. Asking in
  plain language works as before.
- **Two steps.** `request-reboot.ps1` is split into `reboot-plan.ps1` (read-only, prints what will be
  registered, issues a token) and `reboot-commit.ps1 -Token` (registers and reboots).
  `-Cancel`/`-Status` moved to `reboot-cancel.ps1`, which loads none of the shared code.
- **RunOnce points at a frozen copy** of the resume script under the state folder, not into the
  skill/plugin folder, and no longer carries the working directory (kept under the 260-character
  RunOnce limit).
- **Folder trust is checked** before planning a reboot or opening any session; an untrusted folder is
  refused (`UNTRUSTED_WORKSPACE`) rather than left waiting on an unseen prompt.
- **The prompt is never logged.** The log records only its length and a short SHA-256 prefix.
  `-Status` no longer prints it.
- **The prompt never passes through `cmd.exe`.** When `claude` is an npm-style `.cmd` shim, the resume
  script hands the prompt over in `resume-prompt.txt` and the command line only points at the file —
  `cmd.exe` would otherwise interpret `&`, `|`, `%VAR%` and quotes in it and drop everything after the
  first line. A real `claude.exe` is preferred when both are on PATH.
- **`reboot-commit.ps1` takes nothing executable from `plan.json`.** The RunOnce command is accepted
  only in the exact shape `reboot-plan.ps1` renders, with an installed PowerShell/Windows Terminal,
  and is re-rendered before it is registered; the script that gets frozen is always the one shipped
  next to `reboot-commit.ps1`. A plan dated in the future is refused like an expired one.
- **A session id is verified before the reboot, not after.** `reboot-plan.ps1 -SessionId` is refused
  unless the transcript exists, is interactive and belongs to the folder; the running session is
  taken from `CLAUDE_CODE_SESSION_ID`.
- **A stale metadata-only transcript is never chosen** as the session to resume.
- **A missing working directory at logon launches nothing** and keeps the state, instead of starting
  Claude somewhere else.
- State moved from `~\.claude\reboot-continue\` to `~\.claude\claude-session-kit\`. The RunOnce value
  name (`ClaudeRebootContinue`) is unchanged; the new resume script still reads an old `state.json`
  for one release.
- Requires PowerShell 7 for everything except the resume script itself, which still parses under
  Windows PowerShell 5.1.

Unchanged: scheduled/SDK transcripts are never resumed, `claude --continue` is never used, the prompt
is passed after `--`, the reboot delay cannot go below 30 seconds.

### New

- Launch: new scratch folder, registered aliases (`aliases.json`), explicit paths.
- Resume: launcher registry → 30-day transcript scan → the CLI's own picker.
- Test suite (`tests/run-tests.ps1`).
