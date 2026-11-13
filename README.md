# claude-session-kit

A [Claude Code](https://claude.com/claude-code) plugin for **Windows** with one skill,
`claude-session-kit:session`, that runs the whole life of a session in Windows Terminal tabs:

| | You say | What happens |
|---|---|---|
| **Launch** | "open a new claude session", "open the `<alias>` folder on Opus xhigh and hand this off" | A new tab runs `claude` in a fresh scratch folder or a registered workspace, optionally named, on the model and effort you said, with a first prompt. |
| **Resume** | "reopen my last session", "find the session where we talked about the deploy and reopen it" | An earlier session, picked from the registry, a list or a search, reopens in the folder recorded for it. |
| **Reboot and continue** | "reboot and continue" | Windows restarts; after logon this session continues with a hand-off prompt, and the other open sessions come back in their own tabs. |
| **Restore** | "reopen the sessions I had open" | Sessions lost to a crash or a closed window reopen, each with the permission mode it was started with. |

What Claude is told to do, and every result `code`, is in [skills/session/SKILL.md](skills/session/SKILL.md)
and `skills/session/references/`. Why a script does what it does is in its help block and comments.

## Requirements

Windows 10/11 · PowerShell 7 (`pwsh`; `-TrustFolder` and the tests need 7.5 or later) · Claude Code CLI
(last checked on 2.1.312; `claude agents --json` needs 2.1.145 or later) · Windows Terminal (without it
a plain console window is used).

While the plugin is enabled, its `SessionStart` and `SessionEnd` hooks run
`skills/session/scripts/track-session.ps1` in **every** Claude Code session (about half a second of
`pwsh` each, no output). They keep one small record per open interactive session under
`open-sessions\`, which is what Restore reopens.

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
- **RunOnce points at a frozen copy**, `runtime\resume.ps1` in the state folder, because a plugin
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
- **The kit never picks a model, an effort or a permission mode**, and never replays `bypassPermissions`.
- **A launched tab is a top-level session**: the asking session's environment markers
  (`$script:InheritedSessionVariables`) are dropped first, or the new `claude` saves no transcript.
- **Nothing personal is in the repository.** Aliases and state live in the state folder, and the tests
  scan the tree and the git history for the words listed in `private-tokens.txt` there.

## State

Everything is in `%USERPROFILE%\.claude\claude-session-kit\`:

| File | Holds |
|---|---|
| `aliases.json` | your workspace aliases |
| `sessions.jsonl` | the registry of sessions the kit opened, which Resume reads first |
| `open-sessions\` | one record per open interactive session, written by the hooks |
| `plan.json`, `state.json`, `state.last.json` | a planned, a pending and the last reboot resume; they hold the hand-off prompt |
| `runtime\resume.ps1`, `resume-prompt.txt` | the frozen logon script; the prompt file used only with a `.cmd` shim |
| `claude.json.before-trust` | `~/.claude.json` as it was before the last `-TrustFolder` write |
| `archive\` | plain copies of transcripts, only if you run `archive-sessions.ps1` |
| `kit.log`, `kit.log.1` | the log and its previous megabyte |

Hand-off notes are written to the asking session's scratchpad under `%TEMP%\claude\`, so do not empty
Temp while a hand-off session still works. Asking which sessions are open runs `claude agents --json`,
which like any `claude` start may update `~/.claude.json`.

## Scripts

All under `skills/session/scripts/`. Each prints one JSON object (`ok`, `code`, `message`, …) and
exits 0 when done, 1 when refused, 2 on an internal error.

| Script | Does | Side effects |
|---|---|---|
| `list-aliases.ps1` | the alias table | none |
| `list-sessions.ps1` | sessions that could be resumed, with title, `running` and the retention setting | none |
| `search-sessions.ps1 -Query:` | sessions by title, folder name or message text | none |
| `list-candidates.ps1` | most-used folders (`alias` is set on those already registered) | none |
| `new-temp-task.ps1 [-Name] [-Model] [-Effort] [-Prompt:]` | new scratch folder + new session | folder, terminal tab |
| `open-workspace.ps1 -Alias\|-Path [-Name] [-Model] [-Effort] [-Prompt:]` | new session in a workspace | terminal tab |
| `resume-session.ps1 [-Alias\|-Path] [-SessionId] [-Fork] [-NoPicker]` | reopen a session | terminal tab |
| `restore-open.ps1 [-All\|-Ids\|-Forget\|-ForgetAll]` | sessions left open by a crash or closed window | terminal tabs; prunes records that can never be reopened; `-Forget` deletes records |
| `archive-sessions.ps1 [-All] [-List]` | back up transcripts before Claude Code's `cleanupPeriodDays` deletes them | copies into `archive\` |
| `reboot-plan.ps1` | plan a reboot-and-resume | writes `plan.json` only |
| `reboot-commit.ps1 -Token` | **register + reboot** | RunOnce, `shutdown /r` |
| `reboot-cancel.ps1 [-Status]` | cancel / inspect | removes its own RunOnce + state |
| `track-session.ps1` | the SessionStart/SessionEnd hook (not for direct use) | writes/deletes `open-sessions\<id>.json` |

`-TrustFolder` is taken by the four scripts that open a tab.

## Tests

```powershell
pwsh -NoProfile -File tests/run-tests.ps1
```

No Pester, no network; PowerShell 7.5 or later. Everything runs in a throwaway sandbox
(`CLAUDE_SESSION_KIT_HOME`, `CLAUDE_CONFIG_DIR`): no tab opens, no reboot is scheduled
(`reboot-commit.ps1` runs with `-Simulate` only) and the real `claude` never runs. Stand-ins answer
`claude agents --json` and record the argv they get.

Not covered, on purpose: Windows PowerShell 5.1 or Legacy argument mode as the logon host, the
console fallback without Windows Terminal, the search fallback without `rg`, the PID-record fallback
when `claude agents --json` fails, and v1 (flat) alias files. What Windows Terminal does to a prompt
when it rebuilds the tab's command line cannot be seen by a stand-in either.

To release, set the same `version` in `.claude-plugin/plugin.json` and twice in
`.claude-plugin/marketplace.json`; a test checks that they agree.

## Uninstall

First cancel any pending resume, because RunOnce would otherwise fire at the next logon:

```powershell
pwsh -NoProfile -File "$env:USERPROFILE\.claude\skills\claude-session-kit\skills\session\scripts\reboot-cancel.ps1"
```

Then delete the cloned folder (or `claude plugin uninstall claude-session-kit@claude-session-kit`) and
`%USERPROFILE%\.claude\claude-session-kit`. That state folder includes `archive\`, the only copy of any
transcript Claude Code has since cleaned up, so move it first if you want to keep it.

## License

MIT
