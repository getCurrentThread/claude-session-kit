# claude-session-kit

A [Claude Code](https://claude.com/claude-code) plugin for **Windows** with one skill,
`claude-session-kit:session`, that opens, reopens and carries sessions in Windows Terminal tabs:

| | You say | What happens |
|---|---|---|
| **Launch** | "open a new claude session", "open the `<alias>` folder on Opus xhigh and hand this off" | A new tab runs `claude` in a fresh scratch folder or a registered workspace, optionally named, on the model and effort you said, with a first prompt. |
| **Resume** | "reopen my last session", "reopen the sessions I had open" | An earlier session, the last one the kit opened or one picked from a list, reopens in the folder recorded for it. |
| **Reboot and continue** | "reboot and continue" | Windows restarts; after logon this session continues with a hand-off prompt, and the other open sessions come back in their own tabs. |

What Claude is told to do, and every result `code`, is in [skills/session/SKILL.md](skills/session/SKILL.md)
and `skills/session/references/`. Why a script does what it does is in its help block and comments.

## Requirements

Windows 10/11 · PowerShell 7 (`pwsh`; `-TrustFolder` and the tests need 7.5 or later) · Claude Code CLI
(last checked on 2.1.323, see [Tests](#tests); `claude agents --json` needs 2.1.145 or later) · Windows Terminal (without it
a plain console window is used).

## Install

Clone it where Claude Code auto-loads plugins (edits are live in the next session):

```powershell
git clone https://github.com/getCurrentThread/claude-session-kit "$env:USERPROFILE\.claude\skills\claude-session-kit"
```

or install it as a plugin:

```
claude plugin marketplace add getCurrentThread/claude-session-kit
claude plugin install claude-session-kit@claude-session-kit
```

If both exist, the installed plugin wins and the clone is not loaded. Work on the kit with the clone alone.

## Aliases

Workspace aliases are personal, so they live outside the repository, in
`%USERPROFILE%\.claude\claude-session-kit\aliases.json`. Copy
[examples/aliases.example.json](examples/aliases.example.json): `path` is absolute (`%VAR%` is
expanded), `triggers` are the phrases that mean this folder, `note` tells Claude what to do with an
ambiguous mention, and `confirm: true` makes it ask before opening. `tempTask` sets the scratch root
and folder prefix. Ask Claude to "add an alias" and it edits this file, never the skill.

## Rules the code keeps

The tests enforce these. Do not trade one away for a feature.

- **Only `reboot-commit.ps1` restarts Windows or writes the RunOnce value.** Keep it out of the
  permission allowlist: its prompt is the last lock. `reboot-plan.ps1` writes `plan.json` and a
  one-time token and nothing else. The commit takes nothing executable from `plan.json`: it
  re-renders the RunOnce command and refuses a plan that was edited, is over ten minutes old or is
  dated in the future.
- **RunOnce points at a frozen copy** of `resume-after-reboot.ps1`, `runtime\resume.ps1` in the state folder, because a plugin
  update moves the versioned cache folder. That script is self-contained and loads nothing from `lib\`.
- **An untrusted folder fails closed** (`UNTRUSTED_WORKSPACE`, with what the folder ships).
  `-TrustFolder` is the kit's only write to `~/.claude.json`: under Claude Code's own lock, one key,
  with the previous copy kept as `claude.json.before-trust`. A drive root and the home folder are refused.
- **Only interactive transcripts are resumed**, never a scheduled or SDK run, and `claude --continue`
  is never used. A session that is open now is never opened a second time (`ALREADY_RUNNING`).
- **A prompt goes after `--`, and is never printed or logged**, only its length. Shapes Windows
  Terminal would change (a `"`, a `%NAME%` pair, a tab, a trailing backslash) are refused, not
  repaired: `Get-PromptRefusal` holds what was measured by hand on Windows Terminal 1.24. Behind an
  npm `.cmd` shim a launch prompt is refused, and a reboot prompt travels in `resume-prompt.txt`.
- **The kit never picks a model, an effort or a permission mode.**
- **A launched tab is a top-level session**: the asking session's environment markers
  (`$script:InheritedSessionVariables`) are dropped first, or the new `claude` saves no transcript.
- **Nothing personal is in the repository.** Aliases and state live in the state folder, and the tests
  scan the tree and the git history for the words listed in `private-tokens.txt` there.

## State

Everything is in `%USERPROFILE%\.claude\claude-session-kit\`:

| File | Holds |
|---|---|
| `aliases.json` | your workspace aliases |
| `sessions.jsonl` | the sessions the kit opened (id, folder, time), which Resume reads first |
| `plan.json`, `state.json`, `state.last.json` | a planned, a pending and the last reboot resume; they hold the hand-off prompt |
| `runtime\resume.ps1`, `resume-prompt.txt` | the frozen logon script; the prompt file used only with a `.cmd` shim |
| `claude.json.before-trust` | `~/.claude.json` as it was before the last `-TrustFolder` write |
| `private-tokens.txt` | words the tests must never find in the repository, one per line |
| `kit.log`, `kit.log.1` | the log and its previous megabyte |

`sessions.jsonl` is what makes "my last session" mean the last one the kit opened: the newest
transcript under `~/.claude/projects` is usually another tool's. `claude agents --json` says which
sessions are open now.

Hand-off notes are written to the asking session's scratchpad under `%TEMP%\claude\`, so do not empty
Temp while a hand-off session still works. Asking which sessions are open runs `claude agents --json`,
which like any `claude` start may update `~/.claude.json`.

## Scripts

All under `skills/session/scripts/`. Each prints one JSON object (`ok`, `code`, `message`, …) and
exits 0 when done, 1 when refused, 2 on an internal error.

| Script | Does | Side effects |
|---|---|---|
| `list-aliases.ps1` | the alias table | none |
| `list-sessions.ps1 [-Alias\|-Path] [-Days] [-Top]` | sessions that could be resumed, with title, `source` (opened by the kit or not) and `running` | none |
| `new-temp-task.ps1 [-Name] [-Model] [-Effort] [-Prompt:]` | new scratch folder + new session | folder, terminal tab |
| `open-workspace.ps1 -Alias\|-Path [-Name] [-Model] [-Effort] [-Prompt:]` | new session in a workspace | terminal tab |
| `resume-session.ps1 [-Alias\|-Path] [-SessionId] [-Days]` | reopen a session | terminal tab |
| `reboot-plan.ps1 [-WorkDir] [-PromptFile] [-SessionId] [-OnlyThis] [-NoReboot]` | plan a reboot-and-resume | writes `plan.json` only |
| `reboot-commit.ps1 -Token` | **register + reboot** | RunOnce, `shutdown /r` |
| `reboot-cancel.ps1 [-Status]` | cancel / inspect | removes its own RunOnce + state |

`-TrustFolder` is taken by the three scripts that open a tab.

## Tests

```powershell
pwsh -NoProfile -File tests/run-tests.ps1
```

No Pester, no network; PowerShell 7.5 or later. Everything runs in a throwaway sandbox
(`CLAUDE_SESSION_KIT_HOME`, `CLAUDE_CONFIG_DIR`): no tab opens, no reboot is scheduled
(`reboot-commit.ps1` runs with `-Simulate` only) and the real `claude` never runs. Stand-ins answer
`claude agents --json` and record the argv they get.

Not covered, on purpose: Windows PowerShell 5.1 or Legacy argument mode as the logon host, the
console fallback without Windows Terminal, the PID-record fallback when `claude agents --json`
fails, and `reboot-cancel.ps1` without `-Status` (it would abort a real pending shutdown). What
Windows Terminal does to a prompt when it rebuilds the tab's command line cannot be seen by a
stand-in either.

Checked by hand on 2026-11-14 with Claude Code 2.1.323, Windows Terminal 1.24 and PowerShell 7.7.0,
because the suite cannot: repeat these after a Claude Code or Windows Terminal update.

- **A real tab.** `new-temp-task.ps1 -Name -Model -Effort -Prompt:` returned `LAUNCHED`; `claude.exe`
  ran under `WindowsTerminal.exe` in the new folder with the name given, saved an interactive
  transcript whose first message was the prompt, answered it, and was added to `sessions.jsonl`.
  `open-workspace.ps1 -Path -Name` opened a tab in an existing folder the same way (without a prompt).
- **"My last session".** With that session closed, `resume-session.ps1` without arguments reopened it
  in its folder (`RESUMED`); with it open, `-SessionId` got `ALREADY_RUNNING`. That run alone cannot
  show the launch list winning over newer transcripts. That was checked read-only against the real
  session list: the rule chose the session the kit had opened last although 33 closed sessions
  started some other way were newer, and with the launch list taken out it chose one of those.
- **Cancel.** After a `-NoReboot` commit had written the real RunOnce value and `state.json`, and
  with a restart pending (`shutdown /r /t 600`, scheduled by hand), `reboot-cancel.ps1` aborted the
  restart and removed both (`CANCELLED`); a second run said `NOTHING_PENDING`.
- **Reboot and continue.** `reboot-plan.ps1`, then `reboot-commit.ps1 -Token` (`REBOOT_SCHEDULED`):
  Windows logged the restart request from `shutdown.exe` at the commit and was back up 82 seconds
  later. After logon RunOnce opened a terminal by itself. The planned session resumed in its folder
  (`claude.exe` under `pwsh.exe` under `WindowsTerminal.exe`) with the 2,374-character hand-off note
  as its next message, unchanged; the other open session came back in a tab of its own without a
  prompt; three background sessions were skipped (`NOT_INTERACTIVE`). The RunOnce value was gone and
  `state.json` had become `state.last.json`.

To release, set the same `version` in `.claude-plugin/plugin.json` and twice in
`.claude-plugin/marketplace.json`; a test checks that they agree.

## Uninstall

First cancel any pending resume, because RunOnce would otherwise fire at the next logon:

```powershell
pwsh -NoProfile -File "$env:USERPROFILE\.claude\skills\claude-session-kit\skills\session\scripts\reboot-cancel.ps1"
```

Then delete the cloned folder (or `claude plugin uninstall claude-session-kit@claude-session-kit`) and
`%USERPROFILE%\.claude\claude-session-kit`.

## License

MIT
