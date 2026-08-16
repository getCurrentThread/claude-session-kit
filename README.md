# reboot-continue

A [Claude Code](https://claude.com/claude-code) skill for **Windows** that survives OS reboots:
when a task requires a reboot (Windows Update, driver/feature installs, WSL/Hyper-V setup, …),
Claude saves its state, reboots the machine, and — after you log back in — a terminal opens
automatically with the **same session resumed and already told what to do next**.

No more "reboot, reopen the terminal, find the session, explain where we were".

## How it works

```
Claude hits a step that needs a reboot
  │
  ├─ 1. writes a continuation prompt (what's done / what's next)
  │       → %USERPROFILE%\.claude\reboot-continue\next-prompt.txt
  ├─ 2. request-reboot.ps1
  │       • saves state.json  (workdir, session id, prompt)
  │       • registers HKCU\...\RunOnce  →  resume-after-reboot.ps1  (one-shot)
  │       • shutdown /r /t 30
  ▼
Windows reboots … you log in
  │
  └─ RunOnce fires once → Windows Terminal opens in the saved workdir
        → claude --resume <session-id> "<continuation prompt>"
        → the session continues exactly where it left off
```

- **Session id** is resolved automatically (explicit arg → `CLAUDE_SESSION_ID` → newest
  transcript in `~\.claude\projects\<project>\`), with a `claude --continue` fallback.
- **One-shot by design**: RunOnce deletes itself after firing, and the resume script archives
  `state.json` before launching, so a failed relaunch can never loop.
- **Semi-automatic on purpose**: you still log in yourself (no stored passwords), and
  permission prompts in the resumed session behave as usual. Pair with
  [Sysinternals Autologon](https://learn.microsoft.com/sysinternals/downloads/autologon)
  if you want fully unattended reboots on a personal, BitLocker-protected machine.

## Install

```powershell
git clone https://github.com/getCurrentThread/reboot-continue "$env:USERPROFILE\.claude\skills\reboot-continue"
```

or with the [Skills CLI](https://skills.sh):

```
npx skills add getCurrentThread/reboot-continue
```

That's it — Claude Code picks up the skill from `~\.claude\skills\`. Next time a task needs a
reboot, ask Claude to "재부팅하고 이어서 해" / "reboot and continue", or let it invoke the
skill on its own when an installer demands a restart.

## Manual usage

```powershell
$s = "$env:USERPROFILE\.claude\skills\reboot-continue\scripts\request-reboot.ps1"

# Register + reboot in 30s (state auto-detected from the current directory)
powershell -NoProfile -ExecutionPolicy Bypass -File $s -Prompt "Reboot done. Continue." 

# Register only; you reboot whenever you like
powershell -NoProfile -ExecutionPolicy Bypass -File $s -NoReboot

# Abort a pending reboot and unregister everything
powershell -NoProfile -ExecutionPolicy Bypass -File $s -Cancel

# Inspect what is currently registered
powershell -NoProfile -ExecutionPolicy Bypass -File $s -Status
```

Options: `-Prompt <text>` / `-PromptFile <utf8-file>` (continuation prompt),
`-SessionId <uuid>`, `-WorkDir <path>`, `-DelaySeconds <n>` (default 30),
`-NoReboot`, `-Cancel`, `-Status`.

Files live under `%USERPROFILE%\.claude\reboot-continue\` (`state.json`, `state.last.json`,
`resume.log`) — the skill directory itself stays clean.

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\skills\reboot-continue\scripts\request-reboot.ps1" -Cancel
Remove-Item -Recurse -Force "$env:USERPROFILE\.claude\skills\reboot-continue"
Remove-Item -Recurse -Force "$env:USERPROFILE\.claude\reboot-continue" -ErrorAction SilentlyContinue
```

---

## 한국어 요약

재부팅이 필요한 작업에서 "재부팅 → 로그인 → 터미널 열기 → 세션 찾기 → 상황 설명"을 전부
자동화하는 Claude Code 스킬입니다(Windows 전용). 재부팅 전에 상태와 "다음 단계" 프롬프트를
저장하고 RunOnce에 재개 스크립트를 등록 → 로그인하면 Windows Terminal이 자동으로 열리며
`claude --resume`으로 같은 세션이 이어집니다.

- 설치: 위 `git clone` 또는 `npx skills add getCurrentThread/reboot-continue`
- 사용: 작업 중 "재부팅하고 이어서 해"라고 하면 Claude가 알아서 처리
- 취소: `request-reboot.ps1 -Cancel` (예약 재부팅 중단 + 등록 해제)
- 비밀번호를 저장하지 않는 반자동 설계입니다. 완전 무인이 필요하면 Sysinternals Autologon을
  얹으세요(개인 PC + BitLocker 권장).

## License

MIT
