---
name: session
description: >-
  Windows session tools for Claude Code, three jobs in one skill. (1) LAUNCH: open a NEW
  Claude Code session in a Windows Terminal tab — a fresh scratch folder or a registered
  workspace alias — only when the user gives an explicit launch verb together with
  "Claude"/"session" or a workspace (클로드 켜줘, 새 임시 작업 켜줘, 세션 열어줘, <별칭> 폴더
  켜줘, open a new claude session). (2) RESUME: reopen an EARLIER session in a new tab (아까
  그 세션 다시 켜줘, <별칭> 폴더 이어서 켜줘, reopen my last session). (3) REBOOT-AND-CONTINUE:
  carry the CURRENT session across a Windows restart — save the next-step prompt, register
  a one-shot resume, restart, and pick up after logon — for work that needs a restart
  (Windows Update, driver or feature installs, WSL/Docker/Hyper-V, registry edits) when the
  user asks to reboot and continue (재부팅하고 이어서 해, reboot and continue); cancelling or
  checking a scheduled resume (재부팅 취소, 재개 예약 확인) is this skill too. Never fire on a
  bare mention of a project, product or folder name without a launch verb, and never treat
  "restart the session" as a request to restart the computer.
---

# session — launch a session · reopen an earlier one · reboot and continue

This skill has **real side effects**: it opens terminal tabs, and its heaviest branch **restarts the
computer.** So decide which branch applies first (§0), and run a script only after that branch's gate
has been passed.

Every script lives in this skill's `scripts/` folder and runs under **PowerShell 7 (`pwsh`)**:

```
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/<script>.ps1" <arguments>
```

`${CLAUDE_SKILL_DIR}` is the folder this skill was loaded from. An installed plugin sits in a
versioned cache path, so never memorise or hard-code a location. Every script prints **one JSON
object on stdout** — branch on `ok` and `code`; `message` is the explanation for the user. Messages
are in English: relay them in the user's language. Any script can also return `INTERNAL_ERROR`
(exit code 2): relay its `message` and do not retry blindly.

The rules below apply to the user's words in whatever language they are spoken.

## 0. Pick the branch — when in doubt, ask instead of running

| The user wants to | Branch | Reversible? |
|---|---|---|
| **open** a new session (new scratch task, a registered alias, a path they gave) | §1 Launch | one tab — close it and it is gone |
| **reopen** an earlier session | §2 Resume | appends to an existing conversation |
| **restart the computer** and continue this session | §3 Reboot | **a restart cannot be undone** |
| cancel or inspect a scheduled restart/resume | §4 Cancel / Status | read and clean-up only |

- **Continuation words ("continue", "again", "the one from before") do not pick a branch.** Attached
  to an open verb ("open", "turn on", "launch" — or fused with it: "reopen", "resume my last
  session") they mean §2; attached to "reboot"/"restart the computer" they mean §3. With neither,
  run nothing and ask.
- A **question or a suggestion** ("should we restart the session?", "do I need to restart?") is never
  approval for any branch.
- "Restart the session" is not a restart of the computer. The branch that turns the machine off (§3)
  is a candidate only when the user spoke of rebooting/restarting **the computer or Windows**. It is
  not §2 either — ask what the user wants.

## 1. Launch — open a new session

**Gate 1 (when to fire).** Run only when the message carries an **explicit intent to launch** ("open",
"turn on", "launch", "fire up", "start a new …") and its object is **Claude / a session** or **a
workspace folder** ("open the … folder", "start a new scratch task"). A project, product or folder name that
merely comes up in conversation ("I have a question about …") never fires this skill.

**Gate 2 (what to open).** The alias table is not in this file — it holds personal paths, so it lives
in `aliases.json` in the state folder. Read it **once** before deciding:

```
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/list-aliases.ps1"
```

Each alias has `path`, `triggers` (phrases that mean this alias), `note` (what to do with an ambiguous
or bare mention) and `confirm` (true = ask before opening even when it looks right). Rules:

1. If the user's phrase matches an alias's `triggers`, that is the alias.
2. If only the name brushes past without a matching trigger, follow that alias's `note` **to the
   letter** — if it names another alias as the default, use that one; if it says not to fire or to
   ask, ask.
3. If neither settles it, **do not guess.** Ask which folder they mean.
4. "A new scratch task / a new test folder" is not an alias — it is `new-temp-task.ps1`.

**Run.**

```
# create the next scratch folder (<root>\<prefix><N>) and open a session in it
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/new-temp-task.ps1"
# a registered alias
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/open-workspace.ps1" -Alias <name>
# only when the user gave the path themselves
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/open-workspace.ps1" -Path "<absolute path>"
```

The session opens as a new tab in the existing Windows Terminal window (a plain console window when
`wt` is absent). Its id and folder are recorded in the registry (`sessions.jsonl`), which is where §2
looks first.

Success codes are `LAUNCHED` here and `RESUMED` / `PICKER_OPENED` in §2. After a rerun with
`-AllowUntrusted` in a folder that really is untrusted, each becomes `<CODE>_UNTRUSTED`: the tab is
open but parked on the trust prompt — tell the user to answer it there.

### `UNTRUSTED_WORKSPACE` — no session was started (fail closed)

Claude Code asks once per folder whether the user trusts it, and applies that folder's hooks, MCP
servers and permission settings only after the answer. A tab opened by a launcher tends to sit on
that prompt unseen, so **an untrusted folder is not opened at all.** §2 and §3 return the same code
with the same meaning. When you get it:

1. **Say so plainly** — this folder is not trusted in Claude Code yet, so no session was started.
2. One line on why it matters — that folder's `.claude/settings.json` hooks and MCP servers run as
   soon as a session starts there.
3. Offer the choices:
   - **Open it themselves** — the user goes to the folder in a terminal, runs `claude`, and answers
     the prompt.
   - **Open it anyway** — only if the user explicitly says so, rerun the same command with
     `-AllowUntrusted`. The trust prompt appears in the new tab and **the user has to answer it.**
4. If `isRepo` is true, add: **a git repository does not inherit trust from its parent folder.** Even
   under a trusted parent, the repository (`trustKey`) has to be trusted on its own.

**Never:** write `hasTrustDialogAccepted` into `~/.claude.json` to skip the prompt. That accepts trust
on the user's behalf and lets the folder's hooks and MCP settings run unreviewed. Even if the user
asks, do not write it for them — point them to step 3.

### Other codes

`ALIAS_NOT_FOUND` (`known` lists the registered names), `NO_ALIASES`, `PATH_NOT_FOUND` — do not guess
a path; ask the user. `CLAUDE_NOT_FOUND` — the `claude` executable could not be located.

## 2. Resume — reopen an earlier session

Same condition as Gate 1 (an open verb plus a session or folder), with a continuation word attached.

```
# a session in a particular folder
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/resume-session.ps1" -Alias <name>
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/resume-session.ps1" -Path "<absolute path>"
# no folder mentioned — the newest session this kit opened; if there is none, the newest interactive one anywhere
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/resume-session.ps1"
# a specific session picked from the list
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/resume-session.ps1" -SessionId <uuid>
```

Selection order: **(1) the launcher registry** (sessions this skill opened) → **(2) a scan of
transcripts from the last 30 days** (interactive sessions a person started, nothing else) → **(3) the
CLI's own picker** (`claude --resume` in that folder; only when a folder is known). `chosenFrom` in
the result says where the session came from and `title` says which conversation it is (absent when
the CLI recorded none) — **tell the user what was reopened.** The registry wins even over a newer
session that was started by hand, so when the user asks for their *last* session and no folder
narrows it down, look at the list first.

When there are several to choose from ("not yesterday's, the one before") or you are not sure, show
the list first and let the user pick:

```
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/list-sessions.ps1" [-Alias <name> | -Path "<path>"]
```

The list holds the newest `-Top` rows (default 15) from the last `-Days` days (default 30). When
`total` is larger than the number of rows returned, say so, and narrow with `-Alias`/`-Path` or rerun
with a larger `-Top`/`-Days` (`resume-session.ps1` takes `-Days` too).

Safety rules:

- **Never guess a session id.** Use only an id a script returned or one from the list.
- The tab always opens in the folder **recorded** for that session (the script handles it).
- Transcripts left by scheduled or SDK runs are never candidates.
- **Never run `claude --continue`**, not even as a fallback when a script fails — it reopens whatever
  is newest in the folder, which can append to an automation's conversation.
- `-Fork` (resume into a copy, leaving the original untouched) only when the user said to copy it or
  not to touch the original.
- `PICKER_OPENED` — nothing could be chosen automatically, so the CLI picker was opened. The user
  picks in that tab.
- `NO_RESUMABLE_SESSION` — there is nothing to reopen. Ask whether to start a new one (§1); do not
  silently switch to a new session.

## 3. Reboot — restart the computer and continue this session

**How it works.** Two steps. `reboot-plan.ps1` **works out and shows everything that would be
registered** (folder, session to resume, the RunOnce command) and issues a one-time token — this step
changes nothing. Only `reboot-commit.ps1 -Token` freezes a copy of the resume script, writes
`state.json`, registers `HKCU\…\RunOnce` and runs `shutdown /r`. After logon a terminal opens and runs
`claude --resume <session id> -- "<prompt>"`.

1. **Confirm with the user — a restart always needs explicit approval in the user's latest message.** If
   the user told you **in this turn, in their own words,** to restart the computer ("reboot", "reboot
   and continue"), proceed. Otherwise — a delegation only ("do whatever is needed", "handle it"), an
   installer demanding a restart, or approval given in an earlier turn — **ask first and wait for the
   answer**: the computer needs to restart; restart Windows now and continue automatically after you
   log back in? A delegation is not standing approval. One turn of friction is cheaper than turning
   the machine off. **A §1 or §2 request ("open", "open it again") can never be approval for this
   branch.**

2. **Leave the next-step note.** Write the prompt that becomes the resumed session's first input to
   `next-prompt.txt` in the state folder (`<home>\.claude\claude-session-kit\next-prompt.txt`) **with
   the Write tool** (guarantees UTF-8). Give Write the expanded absolute path, not a variable. It must
   say: why the machine was restarted / what is done so far / what to do right after the restart,
   including a verification command (for example: first check the install with `wsl --status`).

3. **Session id** (if you can): in your own scratchpad path `…\Temp\claude\<project>\<UUID>\scratchpad`
   the `<UUID>` is the current session id. If you cannot get it, leave `-SessionId` out — the script
   reads the running session's id from the `CLAUDE_CODE_SESSION_ID` environment variable, and failing
   that takes the newest **interactive** transcript in this folder. Never pass an id you are not sure
   of: `SESSION_REJECTED` means that id has no transcript, is not an interactive session, or belongs
   to another folder (`recordedCwd` says which).

4. **Plan (read-only):**
   ```
   pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/reboot-plan.ps1" -WorkDir "<absolute project path>" -PromptFile "<absolute path of next-prompt.txt>" -SessionId <UUID>
   ```
   Read the `REBOOT_PLANNED` result before going on:
   - `sessionMode`: `resume` continues that session; **`fresh` means no session to continue was found
     and a new session carrying only the prompt will start** — tell the user and confirm first.
   - `sessionSource`: `explicit` or `env` is this session. `scan:interactive` / `scan:sidecar` is the
     newest session found in the folder, which is a different conversation when two are open there —
     check `sessionId` against your own, and confirm with the user if you cannot.
   - `promptDelivery`: `file` means `claude` is an npm-style `.cmd` shim here, so after logon the
     prompt is handed over in `resume-prompt.txt` instead of on the command line. Nothing to do.

   If the user wants to restart by hand, add `-NoReboot` (registers only).

5. **Commit (destructive — only with the approval from step 1):**
   ```
   pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/reboot-commit.ps1" -Token <token>
   ```
   The token expires after ten minutes and works once.

6. **Branch on `code` and tell the user.**
   - `REBOOT_SCHEDULED` — the computer restarts in `delaySeconds` seconds; `shutdown /a` aborts; after
     logon a terminal opens by itself and this session continues. Say that, then **end the turn at
     once and make no further tool calls.**
   - `RESUME_REGISTERED` (`-NoReboot`) — nothing restarts now; the resume fires at the next logon after
     the user restarts by hand. Say that, then end the turn.
   - `SHUTDOWN_FAILED` — Windows refused the restart, but the resume **is still registered**. Say so,
     offer to cancel it (§4), then end the turn.
   - `NO_PLAN`, `TOKEN_MISMATCH`, `PLAN_EXPIRED`, `PLAN_INVALID` — nothing was registered. Go back to
     step 4 and plan again. The approval from step 1 still stands only while it is the user's latest
     message; otherwise ask again. Never retry with a guessed token, and never edit `plan.json`.

Notes:

- **Keep `reboot-commit.ps1` out of any permission allowlist.** The permission prompt on this one file
  is the last lock. Every other script is built so that it cannot restart the machine, and the tests
  check that.
- The delay cannot go below 30 seconds (other apps may hold unsaved work).
- Permission prompts behave as usual in the resumed session (nothing is auto-approved).
- **Scheduled and SDK sessions are never resume targets.** They pile up in the same project folder and
  are often the newest, but only interactive transcripts are candidates — plus this session's own
  just-started transcript (a "sidecar"), and only while it is under ten minutes old.
- If the saved folder is missing at logon (a drive that is not connected yet), nothing is launched and
  the state is kept; the terminal says how to run the resume again.
- If something goes wrong, the log is `<home>\.claude\claude-session-kit\kit.log` (the prompt body is
  never written to it).

## 4. Cancel / Status — read and clean-up only

```
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/reboot-cancel.ps1"          # abort the scheduled restart + remove RunOnce and state
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/reboot-cancel.ps1" -Status  # inspect only
```

This script **cannot start** a restart. For a "cancel" or "check" request, never run the §3 scripts.
On `NOTHING_PENDING`, say exactly that: nothing was scheduled. On `RUNONCE_NOT_REMOVED`, the resume
may still fire at the next logon — tell the user.

## Adding or changing an alias

When the user says something like "add an alias for this folder too: `<name>` = `<path>`":

1. Check that the path really exists (if not, do not create it — ask).
2. Ask which phrases should select it (`triggers`), and whether the bare name can mean something else
   (`note`).
3. Edit the `aliases.json` at the `file` path reported by `list-aliases.ps1` (confirm before
   applying); when the code was `NO_ALIASES` the file does not exist yet, so create it. The format is
   the one in `${CLAUDE_SKILL_DIR}/../../examples/aliases.example.json`. A `path` is an absolute
   path; `%VAR%` references in it are expanded.
4. Run `list-aliases.ps1` again. `ALIASES_UNREADABLE` means the JSON is broken — fix it before
   anything else, because every script that takes `-Alias` fails until it parses.

**Never write an alias or a path into this SKILL.md or any file in the skill folder.** The skill
folder is either a git repository or a plugin cache that is replaced on every update — no place for
personal paths.

To look for new candidates (read-only):

```
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/list-candidates.ps1"
```

It lists the most-used folders. A row whose `alias` is not null is already registered — do not offer
it as a new candidate.
