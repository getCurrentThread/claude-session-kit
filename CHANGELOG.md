# Changelog

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
