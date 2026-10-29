# claude-session-kit

English · [Korean](README-ko.md)

A [Claude Code](https://claude.com/claude-code) plugin for **Windows** with one skill that runs the
whole life of a session — start, find, reopen, carry across a reboot, bring back after a crash:

| | You say | What happens |
|---|---|---|
| **Launch** | "open a new claude session", "start a new scratch task", "open the `<alias>` folder", "open a session in `<alias>` on Opus xhigh and hand this off" | A new Windows Terminal tab opens in a fresh scratch folder or a registered workspace, running `claude` (optionally under a name, on the model and effort you name, with a first prompt that hands it the work). |
| **Resume** | "reopen my last session", "find the session where we talked about the deploy and reopen it" | An earlier session — picked from the list, by title, or found by what was said in it — is reopened in a new tab, in the folder it was recorded in. A session that is already open is never opened twice. |
| **Reboot and continue** | "reboot and continue", "restart the computer and pick up where we left off" | State is saved, a one-shot resume is registered, Windows restarts, and after you log in the **same session continues, already told what to do next** — and the other sessions that were open come back in their own tabs. |
| **Restore** | "reopen the sessions I had open", "recover the sessions from before the crash" | After a crash, a closed window or an unplanned restart, the sessions that were open are listed and reopened, each in its own folder with the permission mode it was started with. |

This repository used to be `reboot-continue`. It was renamed when the launcher was merged in; see
[CHANGELOG.md](CHANGELOG.md) if you are coming from that skill.

## Requirements

Windows 10/11 · [PowerShell 7](https://aka.ms/powershell) (`pwsh`) · Claude Code CLI (tested on
2.1.302; `claude agents --json` needs 2.1.145 or later, and older versions fall back to the CLI's own
per-process records) · Windows Terminal recommended (without it a plain console window is used).

**The plugin installs two hooks.** `SessionStart` and `SessionEnd` run
`skills/session/scripts/track-session.ps1` in **every** Claude Code session while the plugin is
enabled — directly, with no shell, about half a second of `pwsh` each (the start hook runs in the
background). They write one small file per open interactive session (its id, folder, transcript path
and start permission mode) to `%USERPROFILE%\.claude\claude-session-kit\open-sessions\`, delete it
when the session is ended on purpose, and print nothing. That record is what **Restore** reopens.
Scheduled, SDK (`-p`) and background sessions are never recorded. Disabling the plugin removes the
hooks.

## Install

As a plugin:

```
claude plugin marketplace add getCurrentThread/claude-session-kit
claude plugin install claude-session-kit@claude-session-kit
```

or clone it where Claude Code auto-loads plugins (no install step; edits are live in the next session):

```powershell
git clone https://github.com/getCurrentThread/claude-session-kit "$env:USERPROFILE\.claude\skills\claude-session-kit"
```

Either way the skill is **`claude-session-kit:session`**. Plugin skills never get a bare slash alias —
there is no `/launch` or `/reboot-continue` — but you rarely type it: the skill is triggered by what
you ask for.

`npx skills add` is not supported.

If both exist, the installed plugin wins and the cloned copy under `~\.claude\skills\` is not loaded
(`claude plugin list` says so). Working on the kit? Use the clone alone.

## Aliases

Workspace aliases are personal, so they live outside the plugin, in
`%USERPROFILE%\.claude\claude-session-kit\aliases.json`. Start from
[examples/aliases.example.json](examples/aliases.example.json):

```json
{
  "version": 2,
  "tempTask": { "root": "%USERPROFILE%\\Downloads", "prefix": "test" },
  "aliases": {
    "blog": {
      "path": "C:\\work\\blog",
      "triggers": ["blog folder", "my blog"],
      "note": "A bare mention of 'blog' usually means the live site, not this folder: ask before opening."
    }
  }
}
```

`triggers` are the phrases that mean this folder. `note` tells Claude what to do with an ambiguous
mention, in your own words. `confirm: true` makes Claude ask before opening even on a match. `path`
is an absolute path; `%VAR%` references such as `%USERPROFILE%` are expanded, in `tempTask.root` too.
The older flat form `{ "name": "path" }` still loads. Ask Claude to "add an alias" and it edits this file
— never the skill.

## How each part works

**Launch.** `new-temp-task.ps1` creates `<root>\<prefix><N>` — N counts folders on disk *and* folders
that survive only as transcript history, so a new scratch folder never inherits an old one's
conversations. `open-workspace.ps1` opens an alias or an explicit path; an unknown alias is an error,
never a guess. Every session is started with its own `--session-id` and recorded in `sessions.jsonl`.
It is started as a top-level session: the asking session's markers (`CLAUDECODE`,
`CLAUDE_CODE_CHILD_SESSION`, its session id and entrypoint, …), which Windows Terminal would otherwise
pass to the new tab, are dropped first — a `claude` that inherits them turns transcript saving off.
Asked from a background session (`claude --bg`), the job folder (`CLAUDE_JOB_DIR`) is dropped too; a
tab that inherits it joins the job and takes, and keeps following, the job's name.

`-Name "<name>"` starts the session under that name (`claude --name`), so the CLI's own picker, the
tab title and this kit's lists all show it. A name with quotes, backslashes, `%` or `& | < > ^ !` is
refused (`INVALID_NAME`): Windows Terminal re-splits the command line it hands on and would turn
those into extra `claude` arguments.

`-Model`, `-Effort` and `-Prompt:'<text>'` start the session on the model and effort you named (the
kit never picks either) with a first message — typically "read this hand-off note and follow it",
the note written beforehand. The prompt rides on that same command line. Measured on Windows
Terminal 1.24, it keeps line breaks, `;`, a leading `-`, Hangul, emoji and 8000 characters, but
changes a `"`, a `%NAME%` that is defined, a tab with no space beside it and a trailing backslash
after a space. Those shapes are refused (`INVALID_PROMPT`) rather than repaired — any pair of `%`
signs, since the kit cannot know which names the tab defines — as are blank prompts and prompts over
8000 characters, before anything is created. The prompt is never printed or logged
(`promptChars` only). Behind an npm `.cmd` shim a prompt is refused (`CLAUDE_IS_SHIM`); a model or an
effort alone is fine. Keep secrets out of the prompt: a command line shows in the process list.

A hand-off names both ends, so the two sessions can reach each other with Claude Code's own
SendMessage: the new session is always started with `-Name` (the result's `name` is its address in
ListAgents), and the prompt tells it the asking session's name to report back to.

**Resume.** `resume-session.ps1` picks a session in this order: the **launcher registry** → a **scan of
interactive transcripts from the last 30 days** → the **CLI's own picker** (`claude --resume`) in that
folder. Sessions that are open right now — the asking one included — are skipped (not by `-Fork`). Transcripts written
by scheduled or SDK runs are never candidates, and `claude --continue` is never used — it reopens
whatever is newest in a folder, which may be an automation's conversation.

- **Never twice.** Before a tab is opened the kit asks which sessions are open right now
  (`claude agents --json`; failing that, the CLI's per-process records, each counted only while that
  PID is alive *and* started at the recorded time, or with no start time is a claude/node process). A
  session that is open is refused with
  `ALREADY_RUNNING` — two tabs on one conversation interleave their writes into one transcript.
  `-Fork` (`--fork-session`) is still allowed: it is a new conversation, started under a new id
  (`--session-id`) that is recorded like any launch, so the next resume of that folder finds it (a
  fork made in the CLI's picker is not: only the CLI knows its id). A background session
  (`claude agents`) is refused too; the result names the job id `claude attach` takes.
- **Titles.** Lists show the name you gave (`/rename`, `--name`) over the CLI's generated title, and
  fall back to the first thing you typed (`titleSource` says which). The title is read from the head
  and the last 64 KB of the transcript, not the whole file.
- **Search.** `search-sessions.ps1 -Query:"<words>"` finds sessions whose title, folder name or messages
  contain every word (Hangul included), ranked title > folder > message text, with a one-line
  snippet. Only what you typed and what Claude answered is searched — not tool output. `rg` is used
  as a prefilter when it is installed.
- **Permission mode.** A session started with `--permission-mode <mode>` and not ended on purpose (a
  closed window, a crash or a power cut left its hook record) is reopened with the same mode. After
  `/exit` it comes back in the default mode. The kit never chooses one, and `bypassPermissions` is
  never replayed — it is reported as `droppedPermissionMode` and the session comes back with normal
  prompts.

**Restore.** The hooks above leave a record for every interactive session that was not ended on
purpose (`/exit`, Ctrl+C, `/clear`, `/resume`, logout delete it; a closed window, a crash or a power cut
leave it). `restore-open.ps1` lists the records whose session is not running now and whose transcript
still exists, reopens all or some of them (`-All`, `-Ids <sessionId>,…`) in their recorded folders, or
forgets them (`-Forget`, `-ForgetAll`). Each opens in the folder its transcript records (the hook's
own cwd can have moved with a `cd` or a worktree), and the asking session is never offered. Folder
trust is checked per session, as everywhere else. Claude Code cannot tell a closed window from a
crash, so every session whose tab was closed is listed until it is reopened or forgotten.

**Retention.** Claude Code deletes transcripts older than `cleanupPeriodDays` (default 30) at startup,
and a deleted session cannot be listed, searched or resumed. `list-sessions.ps1` reports the setting
(read-only — nothing in the kit writes `settings.json`) and warns when it is 30 days or less. Raise
it to a large value, **never 0** (rejected since v2.1.89; older versions read it as "save nothing"),
or back transcripts up with `archive-sessions.ps1` (`-All` for every interactive transcript, `-List`
to see what is kept). The archive is a plain copy that nothing reads back, of the conversation file
only (not the session's `subagents\` or `tool-results\` folders).

**Reboot and continue** is two steps on purpose:

```
reboot-plan.ps1      resolves folder, session, prompt and the exact RunOnce command; checks everything
  │                  that can fail while you are still watching; writes plan.json + a one-time token.
  │                  Changes nothing else.
  ▼
reboot-commit.ps1 -Token <t>
                     freezes a copy of the resume script under the state folder, writes state.json,
                     sets HKCU\…\RunOnce, runs `shutdown /r /t 30`.
  ▼
(logon) RunOnce → Windows Terminal → <state>\runtime\resume.ps1
                     → claude --resume <session-id> -- "<continuation prompt>"
```

- `reboot-commit.ps1` is the **only** file that can restart Windows or write the RunOnce value; the
  test suite enforces that. Keep it out of your permission allowlist — its prompt is the last lock.
- `plan.json` is just a file, so the commit step takes nothing executable from it: the RunOnce command
  must be, token for token, the shape the plan step renders, naming an installed PowerShell (and
  Windows Terminal), and it is re-rendered before it is registered. A plan whose RunOnce command or
  frozen-script path was edited is refused (`PLAN_INVALID`), as is one older than ten minutes or
  dated in the future. The folder, session id and prompt are replayed as found, so `plan.json` is as
  sensitive as `state.json` — this guards the command that runs at logon, not the whole state folder.
- The session to resume is settled **before** the reboot: an explicit id must have an interactive
  transcript recorded in that folder, otherwise the running session (`CLAUDE_CODE_SESSION_ID`), then
  the newest interactive transcript in the folder. No match means a fresh session carrying the
  prompt — and the plan says so.
- The prompt is passed to `claude.exe` as one argument after `--` (on Windows PowerShell 5.1 and
  pwsh 7.0–7.2, which build native command lines loosely, the resume script renders the command
  line itself). If `claude` is an npm-style `.cmd`
  shim, it is **never** put on the command line — `cmd.exe` would interpret `&`, `|`, `%VAR%` and
  quotes in it and drop everything after the first line — but written to `resume-prompt.txt`, and
  the command line only points at that file.
- **The other open sessions come back too.** A reboot would kill every open Claude session, so the
  plan also lists the other open interactive sessions (at most eight) whose transcript and folder
  exist and whose folder is trusted — `alsoResume`, with the rest under `skipped` and a reason. A
  session whose transcript has not been written for over `-MaxIdleHours` (default 24) is skipped as
  `IDLE`: it is running, but in a terminal nobody looks at. After
  logon each opens in its own tab with `claude --resume <id>` and **no prompt**; only the asking
  session gets the handoff. `-OnlyThis` brings back the asking session alone. The commit step
  re-validates that list (UUIDs, existing local folders, no duplicates, the cap) like everything else
  it takes from `plan.json`.
- **The handoff note has a fixed shape** — why the machine restarted, what is done, what was tried and
  failed, the next steps, and the command to verify first — so the resumed session starts informed.
- **Stale state is refused.** A plan over a resume that is still pending returns `RESUME_PENDING`
  instead of silently replacing another session's resume (`-Replace` to mean it), and a prompt file
  older than 30 minutes — a note left from an earlier reboot — returns `PROMPT_STALE`
  (`-AllowStalePrompt` to mean it).
- If the saved folder is missing at logon (a drive not connected yet), nothing is launched and the
  state is kept, so the resume can be run again by hand. A missing folder for one of the other
  sessions skips that session only.
- RunOnce points at a **frozen copy** of the resume script, never into the plugin: an installed plugin
  lives in a versioned cache directory, and an update before the next logon would otherwise leave a
  dead entry that fails silently.
- One-shot by design: RunOnce deletes itself, and the resume script archives `state.json` before
  launching, so a failing relaunch cannot loop.
- You still log in yourself (no stored passwords), and permission prompts in the resumed session
  behave as usual. Abort with `shutdown /a` or `reboot-cancel.ps1`.

**Folder trust — fail closed.** Claude Code asks once per folder whether you trust it, because a
folder's `.claude/settings.json` can run hooks and MCP servers. A tab opened by a launcher tends to sit
on that prompt unseen, so the kit checks `~/.claude.json` first and, for an untrusted folder,
**refuses to start the session and says so** — listing what the folder ships (`ships`: hooks, MCP
servers, allow rules, env keys) — and offers one way on: trust it and open it (`-TrustFolder`). Say
yes and the kit writes `projects[<folder>].hasTrustDialogAccepted: true` itself — what answering the
prompt writes — and the tab starts with **no prompt**. The folder's hooks, MCP servers and settings
then apply, for good.

`-TrustFolder` is the kit's only write to `~/.claude.json`. It takes the lock Claude Code itself uses
for that file (`~/.claude.json.lock`), re-reads the file inside it, changes that one key, replaces the
file in one rename and keeps the previous copy as `claude.json.before-trust` in the state folder. It
refuses a drive root, the home folder and anything above it (`TRUST_REFUSED`), and fails closed when
the lock is held or the file does not parse (`TRUST_WRITE_FAILED`). Note that a git repository does
not inherit trust from a trusted parent folder, and that trusting a folder inside a repository trusts
the whole repository.

## State

Everything lives in `%USERPROFILE%\.claude\claude-session-kit\` — `aliases.json`, `sessions.jsonl`
(registry), `open-sessions\` (one record per open interactive session, written by the hooks),
`plan.json` / `state.json` / `state.last.json` (reboot), `next-prompt-<id>.txt`, `resume-prompt.txt` (only
with a `.cmd` shim), `runtime\resume.ps1` (frozen copy), `archive\` (only if you run
`archive-sessions.ps1`; plain copies of transcripts), `kit.log`. The continuation prompt is stored in
the state files because the resume needs it; it is **never** written to the log (which records its
length and a short hash prefix) or echoed by `-Status`.

Side effect worth knowing: asking which sessions are open runs `claude agents --json`, a read-only
query. Like any `claude` start it may update `~/.claude.json` (a fresh config gets its one-time
migration). The kit itself never writes that file.

## Scripts

All under `skills/session/scripts/`, all print one JSON object (`ok`, `code`, `message`, …):

| Script | Does | Side effects |
|---|---|---|
| `list-aliases.ps1` | the alias table | none |
| `list-sessions.ps1` | sessions that could be resumed, with title, `running` and the retention setting | none |
| `search-sessions.ps1 -Query:` | sessions by title, folder name or message text | none |
| `list-candidates.ps1` | most-used folders (`alias` is set on those already registered) | none |
| `new-temp-task.ps1 [-Name] [-Model] [-Effort] [-Prompt:]` | new scratch folder + new session | folder, terminal tab |
| `open-workspace.ps1 -Alias\|-Path [-Name] [-Model] [-Effort] [-Prompt:]` | new session in a workspace | terminal tab |
| `resume-session.ps1 [-Alias\|-Path] [-SessionId] [-Fork]` | reopen a session | terminal tab |
| `restore-open.ps1 [-All\|-Ids\|-Forget\|-ForgetAll]` | sessions left open by a crash or closed window | terminal tabs; prunes records that can never be reopened; `-Forget` deletes records |
| `archive-sessions.ps1 [-All] [-List]` | back up transcripts | copies into `archive\` |
| `reboot-plan.ps1` | plan a reboot-and-resume | writes `plan.json` only |
| `reboot-commit.ps1 -Token` | **register + reboot** | RunOnce, `shutdown /r` |
| `reboot-cancel.ps1 [-Status]` | cancel / inspect | removes its own RunOnce + state |
| `track-session.ps1` | the SessionStart/SessionEnd hook (not for direct use) | writes/deletes `open-sessions\<id>.json` |

## Tests

```powershell
pwsh -NoProfile -File tests/run-tests.ps1
```

No Pester, no network. Runs in a throwaway sandbox (`CLAUDE_SESSION_KIT_HOME`, `CLAUDE_CONFIG_DIR`),
opens no tab, schedules no reboot, never runs the real `claude` (a stand-in answers
`claude agents --json`), and asserts the exact RunOnce string, `wt` argument list and `claude` argv.
The hook is fed recorded hook input on stdin; the multi-session resume runs against stand-ins for
`wt` and `claude` under both PowerShell 7 and Windows PowerShell 5.1. The resume script is run for real, but only against stand-ins for `claude` — a `.cmd`
shim and a small argv-recording `.exe` — fed a prompt full of quotes, `&`, `%VAR%` and line breaks.
Forged `plan.json` files are committed (`-Simulate`) to check that each one is refused.

A launch's first prompt is tested up to the first hop only: with the recording `.exe` standing in
for `wt`, every prompt shape that passes reaches it as the exact argument list, under PowerShell 7 and
in Legacy argument mode (what 7.0–7.2 use). The second hop — `wt` rebuilding the child's command
line — happens inside Windows Terminal, where no stand-in can see it. It was measured once by hand
(Windows Terminal 1.24, a real tab, an argv-recording child), and the tests pin the refusal list to
what that measurement showed; they do not re-check a live `wt`.

## Uninstall

First make sure no resume is pending — ask Claude to "cancel any pending reboot resume", or run the
cancel script yourself (for a plugin install it sits under
`~\.claude\plugins\cache\claude-session-kit\claude-session-kit\<version>\`):

```powershell
pwsh -NoProfile -File "$env:USERPROFILE\.claude\skills\claude-session-kit\skills\session\scripts\reboot-cancel.ps1"
```

Then:

```powershell
claude plugin uninstall claude-session-kit@claude-session-kit                # or delete the cloned folder
claude plugin marketplace remove claude-session-kit
Remove-Item -Recurse -Force "$env:USERPROFILE\.claude\claude-session-kit"    # aliases, registry, logs, archive
```

The hooks go with the plugin. The last line also deletes `archive\` — the only copy of any transcript
Claude Code has since cleaned up — so move it somewhere first if you want to keep it.

## License

MIT
