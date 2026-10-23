# claude-session-kit

A [Claude Code](https://claude.com/claude-code) plugin for **Windows** with one skill that runs the
whole life of a session — start, find, reopen, carry across a reboot, bring back after a crash:

| | You say | What happens |
|---|---|---|
| **Launch** | "open a new claude session", "새 임시 작업 켜줘", "`<alias>` 폴더 켜줘" | A new Windows Terminal tab opens in a fresh scratch folder or a registered workspace, running `claude` (optionally under a name). |
| **Resume** | "reopen my last session", "아까 그 세션 다시 켜줘", "배포 얘기하던 세션 찾아서 켜줘" | An earlier session — picked from the list, by title, or found by what was said in it — is reopened in a new tab, in the folder it was recorded in. A session that is already open is never opened twice. |
| **Reboot and continue** | "reboot and continue", "재부팅하고 이어서 해" | State is saved, a one-shot resume is registered, Windows restarts, and after you log in the **same session continues, already told what to do next** — and the other sessions that were open come back in their own tabs. |
| **Restore** | "reopen the sessions I had open", "아까 열려 있던 세션들 다시 켜줘" | After a crash, a closed window or an unplanned restart, the sessions that were open are listed and reopened, each in its own folder with the permission mode it was started with. |

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
      "triggers": ["blog folder", "블로그 폴더"],
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
on that prompt unseen, so the kit checks `~/.claude.json` **read-only** first and, for an untrusted
folder, **refuses to start the session and says so**. You then open the folder yourself once, or tell
Claude to go ahead (`-AllowUntrusted`), in which case the prompt appears in the new tab and you answer
it. The kit never writes `hasTrustDialogAccepted`. Note that a git repository does not inherit trust
from a trusted parent folder.

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
| `new-temp-task.ps1 [-Name]` | new scratch folder + new session | folder, terminal tab |
| `open-workspace.ps1 -Alias\|-Path [-Name]` | new session in a workspace | terminal tab |
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

---

## 한국어 요약

Windows용 Claude Code 플러그인입니다. 스킬 하나(`claude-session-kit:session`)가 세션의 실행 → 찾기 →
재개 → 재부팅 연속 → 크래시 복구를 맡습니다.

- **새 세션 열기** — "새 임시 작업 켜줘", "`<별칭>` 폴더 켜줘". Windows Terminal 새 탭에서 `claude`를
  띄웁니다. `-Name`으로 이름을 붙이면 CLI 피커에도 같은 이름이 보입니다.
- **이전 세션 다시 열기** — "아까 그 세션 다시 켜줘". 런처 레지스트리 → 최근 30일 transcript 스캔 →
  CLI 기본 피커 순으로 고릅니다. 제목(`/rename` > 자동 제목 > 첫 입력)과 내용 검색
  (`search-sessions.ps1`)으로도 찾습니다. 이미 열려 있는 세션은 두 번 열지 않고(`ALREADY_RUNNING`),
  시작할 때의 권한 모드를 그대로 쓰되 `bypassPermissions`는 절대 되살리지 않습니다. 크론·SDK 세션은
  후보가 아니고 `--continue`는 쓰지 않습니다.
- **재부팅하고 이어서** — "재부팅하고 이어서 해". 계획(`reboot-plan`)과 실행(`reboot-commit`)이 분리돼
  있고, 재부팅할 수 있는 파일은 `reboot-commit.ps1` 하나뿐입니다. 로그인하면 같은 세션이 이어지고,
  함께 열려 있던 다른 세션(최대 8개)도 프롬프트 없이 각자 탭으로 돌아옵니다. 대기 중인 재개를
  덮어쓰거나(`RESUME_PENDING`) 30분 넘은 메모를 다시 쓰는 것(`PROMPT_STALE`)은 거부합니다.
- **크래시 후 복구** — "아까 열려 있던 세션들 다시 켜줘". 플러그인 훅(SessionStart/SessionEnd)이 열린
  대화형 세션을 기록하고 일부러 끝낸 세션만 지웁니다. 창 닫힘·크래시·정전으로 남은 세션을
  `restore-open.ps1`이 보여 주고 다시 엽니다.
- **보관 기간** — Claude Code는 `cleanupPeriodDays`(기본 30일)가 지난 transcript를 지웁니다. 30일 이하면
  경고하고(설정은 읽기만 합니다, 0은 금지), `archive-sessions.ps1`로 사본을 남길 수 있습니다.

별칭은 플러그인 밖 `%USERPROFILE%\.claude\claude-session-kit\aliases.json`에 둡니다. 신뢰되지 않은
폴더에서는 세션을 **켜지 않고 알려줍니다**(fail-closed) — `hasTrustDialogAccepted`를 대신 쓰지 않습니다.
비밀번호를 저장하지 않는 반자동 설계라 로그인은 직접 합니다.

## License

MIT
