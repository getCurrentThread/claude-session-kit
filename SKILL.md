---
name: reboot-continue
description: >-
  Carries a Claude Code session across a Windows reboot: saves state (working directory,
  session ID, next-step prompt), registers a resume script under RunOnce, then reboots so
  the session reopens and picks up where it left off. Use it for work that needs a restart
  — Windows Update, driver or feature installs, WSL/Docker/Hyper-V setup, registry edits —
  or whenever an installer demands a reboot and the user wants to resume automatically
  (재부팅하고 이어서 해, 재부팅 필요하면 알아서 재부팅해, reboot and continue). Cancelling
  or checking a scheduled resume (재부팅 취소, 재개 예약 확인) is this skill too.
---

# reboot-continue

Windows 재부팅을 넘어 Claude Code 세션을 자동으로 이어가는 스킬.

**동작 원리**: `scripts/request-reboot.ps1`이 (1) 재개 상태를
`~\.claude\reboot-continue\state.json`에 저장하고, (2) `HKCU\...\RunOnce`에
`scripts/resume-after-reboot.ps1`을 등록한 뒤(다음 로그온에 딱 1회 실행 후 자동 삭제),
(3) `shutdown /r`로 재부팅한다. 로그온하면 Windows Terminal이 열리고
`claude --resume <세션ID> -- "<계속 프롬프트>"`가 자동 실행된다.

> **경로 표기**: 아래 명령은 전부 PowerShell에서 실행된다. `%USERPROFILE%`는 cmd.exe에서만
> 확장되므로 PowerShell에서는 **반드시 `$env:USERPROFILE`** 를 쓴다. Write 도구에 넘기는
> 경로는 변수가 아니라 확장된 절대경로(`C:\Users\<사용자>\...`)여야 한다.

## 재부팅 절차 (기본 흐름)

1. **사용자 확인 — 재부팅은 항상 직전 턴의 명시적 승인이 필요하다.** 사용자가 **이번 턴에
   자기 말로** 재부팅을 지시했으면("재부팅해줘", "재부팅하고 이어서 해") 바로 진행한다.
   그렇지 않으면 — 위임문("알아서 해줘", "필요하면 알아서")만 있었거나, 설치 프로그램이
   재부팅을 요구했거나, 앞선 턴에서 승인했더라도 — "재부팅이 필요합니다. 지금 재부팅하고
   로그인 후 자동으로 이어서 진행할까요?"라고 **먼저 묻고 답을 받는다.**
   위임문은 재부팅에 대한 상시 승인이 아니다. 한 턴의 마찰이 기계를 끄는 것보다 싸다.

2. **다음 단계 메모 남기기**: 재개된 세션의 첫 입력이 될 continuation prompt를
   `<홈>\.claude\reboot-continue\next-prompt.txt`에 **Write 도구로**(UTF-8 보장,
   콘솔 코드페이지 문제 회피) 작성한다 — Write에는 확장된 절대경로를 넘긴다.
   반드시 포함할 내용:
   - 무엇 때문에 재부팅했는지 (예: "Hyper-V 기능 설치 후 재부팅함")
   - 지금까지 완료된 단계 요약
   - 재부팅 직후 해야 할 다음 단계 (검증 명령 포함. 예: "먼저 `wsl --status`로 설치 확인")

3. **세션 ID 파악** (가능하면): 자신의 스크래치패드 디렉토리 경로에서 UUID 세그먼트를 추출한다
   — 경로 패턴 `...\Temp\claude\<프로젝트>\<UUID>\scratchpad`의 `<UUID>`가 현재 세션 ID다.
   추출이 안 되면 생략해도 된다. 스크립트가 현재 프로젝트의 최신 전사(`*.jsonl`)에서 자동
   탐지하고, 그마저 실패하면 재개 시 `claude --continue`로 폴백한다.

4. **스크립트 실행**:
   ```
   pwsh -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\skills\reboot-continue\scripts\request-reboot.ps1" -PromptFile "$env:USERPROFILE\.claude\reboot-continue\next-prompt.txt" -WorkDir "<프로젝트 절대경로>" -SessionId "<세션UUID>" -DelaySeconds 30
   ```
   - `-SessionId`는 3단계에서 얻었을 때만 넘긴다.
   - 사용자가 직접 재부팅하겠다고 하면 `-NoReboot`를 추가한다(등록만 하고 재부팅 안 함).
   - **무엇이 등록될지 먼저 보고 싶으면 `-DryRun`** — 해석된 세션 ID와 RunOnce 명령줄을
     출력만 하고 파일·레지스트리를 건드리지 않으며 재부팅도 예약하지 않는다.

5. **마무리 안내 후 턴 종료**: 사용자에게 알린다 — "N초 후 재부팅됩니다. 취소하려면
   `shutdown /a`. 로그인하면 터미널이 자동으로 열리고 이 세션이 이어집니다."
   **재부팅이 예약된 뒤에는 추가 도구 호출을 하지 말고 즉시 턴을 끝낸다** (진행 중이던
   장시간 작업이 재부팅에 잘리지 않도록).

## 취소 / 상태 확인

- 취소(예약된 재부팅 중단 + RunOnce·상태 제거):
  ```
  pwsh -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\skills\reboot-continue\scripts\request-reboot.ps1" -Cancel
  ```
- 현재 등록 상태 확인: 같은 스크립트에 `-Status`.

## 주의사항

- 이 스킬은 **시스템을 재부팅한다**. 사용자 승인 없이는 절대 `-NoReboot` 없이 실행하지 않는다.
- 저장하지 않은 다른 앱의 작업이 있을 수 있으므로 `-DelaySeconds`는 30초 미만으로 줄이지 않는다.
- 재개된 세션에서 권한 프롬프트는 평소처럼 표시된다(자동 승인 아님).
- 재개 스크립트는 실행 직전에 state.json을 state.last.json으로 옮기므로 재실행 루프가 생기지
  않는다. 문제 발생 시 로그: `~\.claude\reboot-continue\resume.log`.
- **크론·SDK 세션은 절대 재개 대상이 아니다.** 스케줄된 작업의 전사는 사람이 켠 세션과 같은
  프로젝트 폴더에 쌓이고 종종 그중 가장 최신이다. 세션 자동 탐지는 `entrypoint`가 `cli`인
  전사(또는 아직 버퍼링 중인 현재 세션의 메타데이터 사이드카)만 고르며, 후보를 못 찾으면
  기존 대화를 잘못 잇는 대신 **프롬프트를 실은 새 세션으로 시작한다**. `--continue`는
  쓰지 않는다 — 그 폴더의 최신 대화를 그대로 열기 때문에 자동화의 전사에 이어붙을 수 있다.
