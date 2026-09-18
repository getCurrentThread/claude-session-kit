# claude-session-kit

A [Claude Code](https://claude.com/claude-code) plugin for **Windows** with one skill that does three
things to sessions:

| | You say | What happens |
|---|---|---|
| **Launch** | "open a new claude session", "새 임시 작업 켜줘", "`<alias>` 폴더 켜줘" | A new Windows Terminal tab opens in a fresh scratch folder or a registered workspace, running `claude`. |
| **Resume** | "reopen my last session", "아까 그 세션 다시 켜줘" | An earlier session is reopened in a new tab, in the folder it was recorded in. |
| **Reboot and continue** | "reboot and continue", "재부팅하고 이어서 해" | State is saved, a one-shot resume is registered, Windows restarts, and after you log in the **same session continues, already told what to do next.** |

This repository used to be `reboot-continue`. It was renamed when the launcher was merged in; see
[CHANGELOG.md](CHANGELOG.md) if you are coming from that skill.

## Requirements

Windows 10/11 · [PowerShell 7](https://aka.ms/powershell) (`pwsh`) · Claude Code CLI ·
Windows Terminal recommended (without it a plain console window is used).

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
mention, in your own words. `confirm: true` makes Claude ask before opening even on a match. The
older flat form `{ "name": "path" }` still loads. Ask Claude to "add an alias" and it edits this file
— never the skill.

## How each part works

**Launch.** `new-temp-task.ps1` creates `<root>\<prefix><N>` — N counts folders on disk *and* folders
that survive only as transcript history, so a new scratch folder never inherits an old one's
conversations. `open-workspace.ps1` opens an alias or an explicit path; an unknown alias is an error,
never a guess. Every session is started with its own `--session-id` and recorded in `sessions.jsonl`.

**Resume.** `resume-session.ps1` picks a session in this order: the **launcher registry** → a **scan of
interactive transcripts from the last 30 days** → the **CLI's own picker** (`claude --resume`) in that
folder. Transcripts written by scheduled or SDK runs are never candidates, and `claude --continue` is
never used — it reopens whatever is newest in a folder, which may be an automation's conversation.

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
(registry), `plan.json` / `state.json` / `state.last.json` (reboot), `next-prompt.txt`,
`runtime\resume.ps1` (frozen copy), `kit.log`. The continuation prompt is stored in the state files
because the resume needs it; it is **never** written to the log or echoed by `-Status`.

## Scripts

All under `skills/session/scripts/`, all print one JSON object (`ok`, `code`, `message`, …):

| Script | Does | Side effects |
|---|---|---|
| `list-aliases.ps1` | the alias table | none |
| `list-sessions.ps1` | sessions that could be resumed | none |
| `list-candidates.ps1` | most-used folders without an alias | none |
| `new-temp-task.ps1` | new scratch folder + new session | folder, terminal tab |
| `open-workspace.ps1 -Alias\|-Path` | new session in a workspace | terminal tab |
| `resume-session.ps1 [-Alias\|-Path] [-SessionId]` | reopen a session | terminal tab |
| `reboot-plan.ps1` | plan a reboot-and-resume | writes `plan.json` only |
| `reboot-commit.ps1 -Token` | **register + reboot** | RunOnce, `shutdown /r` |
| `reboot-cancel.ps1 [-Status]` | cancel / inspect | removes its own RunOnce + state |

## Tests

```powershell
pwsh -NoProfile -File tests/run-tests.ps1
```

No Pester, no network. Runs in a throwaway sandbox (`CLAUDE_SESSION_KIT_HOME`, `CLAUDE_CONFIG_DIR`),
opens no tab, schedules no reboot, and asserts the exact RunOnce string, `wt` argument list and
`claude` argv.

## Uninstall

```powershell
pwsh -NoProfile -File "<plugin>\skills\session\scripts\reboot-cancel.ps1"   # make sure nothing is pending
claude plugin uninstall claude-session-kit                                   # or delete the cloned folder
Remove-Item -Recurse -Force "$env:USERPROFILE\.claude\claude-session-kit"    # aliases, registry, logs
```

---

## 한국어 요약

Windows용 Claude Code 플러그인입니다. 스킬 하나(`claude-session-kit:session`)가 세 가지를 합니다.

- **새 세션 열기** — "새 임시 작업 켜줘", "`<별칭>` 폴더 켜줘". Windows Terminal 새 탭에서 `claude`를 띄웁니다.
- **이전 세션 다시 열기** — "아까 그 세션 다시 켜줘". 런처 레지스트리 → 최근 30일 transcript 스캔 →
  CLI 기본 피커 순으로 고릅니다. 크론·SDK 세션은 후보가 아니고 `--continue`는 쓰지 않습니다.
- **재부팅하고 이어서** — "재부팅하고 이어서 해". 계획(`reboot-plan`)과 실행(`reboot-commit`)이 분리돼
  있고, 재부팅할 수 있는 파일은 `reboot-commit.ps1` 하나뿐입니다. 로그인하면 같은 세션이 이어집니다.

별칭은 플러그인 밖 `%USERPROFILE%\.claude\claude-session-kit\aliases.json`에 둡니다. 신뢰되지 않은
폴더에서는 세션을 **켜지 않고 알려줍니다**(fail-closed) — `hasTrustDialogAccepted`를 대신 쓰지 않습니다.
비밀번호를 저장하지 않는 반자동 설계라 로그인은 직접 합니다.

## License

MIT
