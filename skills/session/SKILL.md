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

# session — 새 세션 열기 · 이전 세션 다시 열기 · 재부팅 후 이어가기

이 스킬은 **실제로 부작용을 낸다**: 터미널 탭을 띄우고, 가장 무거운 분기는 **컴퓨터를 재부팅한다.**
그래서 먼저 어느 분기인지 정하고(§0), 그 분기의 게이트를 통과한 뒤에만 스크립트를 실행한다.

스크립트는 전부 이 스킬 폴더의 `scripts/`에 있고, **PowerShell 7(`pwsh`)** 로 실행한다:

```
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/<스크립트>.ps1" <인자>
```

`${CLAUDE_SKILL_DIR}`는 이 스킬이 로드된 폴더다(플러그인 설치본은 버전이 붙은 캐시 경로라서 고정
경로를 외워 쓰면 안 된다). 모든 스크립트는 **stdout에 JSON 한 줄**을 낸다 — `ok`와 `code`로
분기하고, `message`는 사용자에게 전할 설명이다. 메시지는 영어로 나오니 사용자 언어로 옮겨 전한다.

## 0. 분기 선택 — 애매하면 실행하지 말고 되묻는다

| 사용자가 원하는 것 | 분기 | 되돌릴 수 있나 |
|---|---|---|
| 새 세션을 **연다** (새 임시 작업, 등록된 별칭, 직접 준 경로) | §1 Launch | 탭 하나 — 닫으면 끝 |
| 예전 세션을 **다시 연다** | §2 Resume | 기존 대화에 이어 쓴다 |
| **컴퓨터를 재부팅**하고 이 세션을 이어간다 | §3 Reboot | **재부팅은 되돌릴 수 없다** |
| 예약된 재부팅·재개를 취소하거나 확인한다 | §4 Cancel / Status | 읽기·정리 전용 |

- **"이어서 / 다시 / 아까 그거"는 분기를 정하는 단어가 아니다.** 여는 동사(켜줘·열어줘)에 붙으면 §2,
  "재부팅"에 붙으면 §3이다. 둘 다 없으면 아무것도 실행하지 않고 되묻는다.
- "세션 다시 시작할까?", "재시작해야 하나?" 같은 **의문문·제안문은 어떤 분기의 승인도 아니다.**
- "세션 재시작"은 컴퓨터 재부팅이 아니다. 컴퓨터를 끄는 분기(§3)는 사용자가 **컴퓨터/윈도우
  재부팅**을 말했을 때만 후보가 된다.

## 1. Launch — 새 세션 열기

**Gate 1 (발동 조건).** 메시지에 **명시적 실행 의도**("켜줘", "열어줘", "실행해", "새로 시작")가 있고,
그 대상이 **클로드/세션**이거나 **작업 폴더**("… 폴더 켜줘", "새 임시 작업 켜줘")일 때만 실행한다.
대화 중에 프로젝트·제품·폴더 이름만 나온 경우("… 관련해서 궁금한 게 있는데")는 절대 발동하지 않는다.

**Gate 2 (무엇을 열지).** 별칭 표는 이 파일에 없다 — 개인 경로이므로 상태 폴더의 `aliases.json`에
있고, 판단 전에 **한 번** 읽는다:

```
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/list-aliases.ps1"
```

각 별칭은 `path`, `triggers`(이 별칭을 뜻하는 문구), `note`(애매한 단독 언급을 어떻게 처리할지),
`confirm`(true면 맞아 보여도 열기 전에 확인)을 가진다. 규칙:

1. 사용자 문구가 어떤 별칭의 `triggers`에 맞으면 그 별칭이다.
2. 맞는 트리거 없이 이름만 걸치면 그 별칭의 `note`를 **그대로 따른다** — 다른 별칭이 기본값이라고
   적혀 있으면 그쪽, "발동하지 않는다/되묻는다"라고 적혀 있으면 되묻는다.
3. 어느 쪽으로도 확정되지 않으면 **추측해서 열지 않는다.** "어느 폴더를 여시려는 건가요?"라고 묻는다.
4. "새 임시 작업 / 새 test 폴더"는 별칭이 아니라 `new-temp-task.ps1`이다.

**실행.**

```
# 새 임시 작업 폴더(<root>\<prefix><N>)를 만들고 거기서 연다
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/new-temp-task.ps1"
# 등록된 별칭
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/open-workspace.ps1" -Alias <이름>
# 사용자가 경로를 직접 준 경우에만
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/open-workspace.ps1" -Path "<절대경로>"
```

세션은 기존 Windows Terminal 창의 새 탭으로 열린다(`wt`가 없으면 새 콘솔 창). 연 세션은 ID와 폴더가
레지스트리(`sessions.jsonl`)에 기록되어 나중에 §2가 그것을 찾는다.

### `UNTRUSTED_WORKSPACE` — 세션을 켜지 않았다 (fail-closed)

Claude Code는 폴더를 처음 열 때 신뢰 여부를 묻고, 그 답이 있어야 그 폴더의 훅·MCP·권한 설정을
적용한다. 런처가 연 탭은 그 프롬프트에 멈춘 채 아무도 못 보고 지나치기 쉬우므로, **신뢰되지 않은
폴더에서는 아예 켜지 않는다.** §2·§3도 같은 코드를 같은 뜻으로 낸다. 이 응답을 받으면:

1. **그대로 알린다** — "이 폴더는 아직 Claude Code에서 신뢰되지 않아서 세션을 켜지 않았습니다."
2. 왜 필요한지 한 줄 — 그 폴더의 `.claude/settings.json` 훅·MCP 서버가 세션 시작과 함께 실행된다.
3. 선택지를 준다:
   - **직접 연다** — 사용자가 터미널에서 그 폴더로 가서 `claude`를 실행하고 프롬프트에 답한다.
   - **그래도 켠다** — 사용자가 명시적으로 그러라고 하면 같은 명령에 `-AllowUntrusted`를 붙여 다시
     실행한다. 새 탭에 신뢰 프롬프트가 뜨고 **사용자가 직접 답해야 한다.**
4. `isRepo: true`면 덧붙인다 — **git 리포는 부모 폴더의 신뢰를 상속받지 않는다.** 상위 폴더가
   신뢰돼 있어도 리포(`trustKey`)는 따로 신뢰해야 한다.

**절대 하지 않는 것:** `~/.claude.json`의 `hasTrustDialogAccepted`를 직접 써서 프롬프트를 건너뛰지
않는다. 사용자를 대신해 신뢰를 수락하는 일이고, 그 폴더의 훅·MCP 설정이 검토 없이 실행된다.
사용자가 요청해도 대신 쓰지 않고 위 3번으로 안내한다.

### 그 밖의 코드

`ALIAS_NOT_FOUND`(`known`에 등록된 이름이 온다)·`NO_ALIASES`·`PATH_NOT_FOUND` — 어떤 경로도 추측하지
말고 사용자에게 묻는다. `CLAUDE_NOT_FOUND` — `claude` 실행 파일을 못 찾았다.

## 2. Resume — 이전 세션 다시 열기

Gate 1과 같은 조건(여는 동사 + 세션/폴더)에 "이어서 / 다시 / 아까"가 붙은 경우다.

```
# 특정 폴더의 세션
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/resume-session.ps1" -Alias <이름>
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/resume-session.ps1" -Path "<절대경로>"
# 폴더를 말하지 않았을 때 — 전체에서 가장 최근
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/resume-session.ps1"
# 목록에서 고른 특정 세션
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/resume-session.ps1" -SessionId <uuid>
```

고르는 순서: **① 런처 레지스트리**(이 스킬이 연 세션) → **② 최근 30일 transcript 스캔**(사람이 켠
대화형 세션만) → **③ CLI 기본 피커**(그 폴더에서 `claude --resume`; 폴더를 알 때만). 결과의
`chosenFrom`이 어디서 골랐는지, `title`이 어떤 대화인지 알려준다 — **무엇을 다시 열었는지 사용자에게
말한다.**

여러 개 중에 골라야 하거나("어제 하던 거 말고 그 전 거") 확신이 없으면, 먼저 목록을 보여주고 고르게 한다:

```
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/list-sessions.ps1" [-Alias <이름> | -Path "<경로>"]
```

안전 규칙:

- **세션 ID를 추측하지 않는다.** 스크립트가 준 ID나 목록의 ID만 쓴다.
- 탭은 항상 그 세션에 **기록된 폴더**에서 열린다(스크립트가 처리한다).
- 크론·SDK가 남긴 transcript는 후보가 아니다. `claude --continue`는 쓰지 않는다 — 그 폴더의 최신
  대화를 그대로 열기 때문에 자동화의 대화에 이어붙을 수 있다.
- `-Fork`(원본을 건드리지 않고 복사본으로 재개)는 사용자가 "복사해서 / 원본은 건드리지 마"라고 했을 때만.
- `PICKER_OPENED` — 자동으로 고를 수 없어서 CLI 피커를 열어 두었다. 사용자가 그 탭에서 직접 고른다.
- `NO_RESUMABLE_SESSION` — 다시 열 세션이 없다. 새로 열지(§1) 묻는다. 멋대로 새 세션으로 바꾸지 않는다.

## 3. Reboot — 재부팅하고 이 세션 이어가기

**동작 원리.** 두 단계다. `reboot-plan.ps1`이 **무엇이 등록될지 전부 계산해서 보여주고**(폴더, 재개할
세션, RunOnce 명령) 1회용 토큰을 낸다 — 이 단계는 아무것도 바꾸지 않는다. `reboot-commit.ps1 -Token`
만이 재개 스크립트의 고정 사본을 만들고, `state.json`을 쓰고, `HKCU\…\RunOnce`에 등록하고,
`shutdown /r`을 실행한다. 로그온하면 터미널이 열리고 `claude --resume <세션ID> -- "<프롬프트>"`가 돈다.

1. **사용자 확인 — 재부팅은 항상 직전 턴의 명시적 승인이 필요하다.** 사용자가 **이번 턴에 자기 말로**
   컴퓨터 재부팅을 지시했으면("재부팅해줘", "재부팅하고 이어서 해") 진행한다. 그렇지 않으면 —
   위임문("알아서 해줘", "필요하면 알아서")만 있었거나, 설치 프로그램이 재부팅을 요구했거나, 앞선
   턴에서 승인했더라도 — "재부팅이 필요합니다. 지금 재부팅하고 로그인 후 자동으로 이어서
   진행할까요?"라고 **먼저 묻고 답을 받는다.** 위임문은 상시 승인이 아니다. 한 턴의 마찰이 기계를
   끄는 것보다 싸다. **§1·§2의 요청("켜줘", "이어서 켜줘")은 이 분기의 승인이 될 수 없다.**

2. **다음 단계 메모.** 재개된 세션의 첫 입력이 될 프롬프트를 상태 폴더의 `next-prompt.txt`
   (`<홈>\.claude\claude-session-kit\next-prompt.txt`)에 **Write 도구로**(UTF-8 보장) 쓴다. Write에는
   변수가 아니라 확장된 절대경로를 넘긴다. 반드시 포함: 왜 재부팅했는지 / 지금까지 끝낸 단계 /
   재부팅 직후 할 일(검증 명령 포함, 예: "먼저 `wsl --status`로 설치 확인").

3. **세션 ID** (가능하면): 자신의 스크래치패드 경로 `…\Temp\claude\<프로젝트>\<UUID>\scratchpad`의
   `<UUID>`가 현재 세션 ID다. 못 얻으면 생략한다 — 스크립트가 이 폴더의 최신 **대화형** transcript에서
   찾는다.

4. **계획(읽기 전용):**
   ```
   pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/reboot-plan.ps1" -WorkDir "<프로젝트 절대경로>" -PromptFile "<next-prompt.txt 절대경로>" -SessionId <UUID>
   ```
   `REBOOT_PLANNED`의 `sessionMode`를 본다: `resume`이면 그 세션을 잇고, **`fresh`면 이을 세션을 못
   찾아 프롬프트만 실은 새 세션으로 시작한다** — 이 경우 사용자에게 그 사실을 알리고 진행 여부를
   확인한다. 사용자가 직접 재부팅하겠다고 하면 `-NoReboot`(등록만).

5. **실행(파괴적 — 1번의 승인이 있을 때만):**
   ```
   pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/reboot-commit.ps1" -Token <token>
   ```
   토큰은 10분 뒤 만료되고 한 번만 쓸 수 있다.

6. **마무리 안내 후 즉시 턴 종료.** "30초 후 재부팅됩니다. 취소하려면 `shutdown /a`. 로그인하면
   터미널이 자동으로 열리고 이 세션이 이어집니다." **재부팅이 예약된 뒤에는 추가 도구 호출을 하지
   않는다.**

주의:

- **`reboot-commit.ps1`은 권한 허용 목록에 넣지 않는다.** 이 파일에 걸리는 권한 프롬프트가 마지막
  잠금장치다. 다른 스크립트는 재부팅할 수 없게 만들어져 있고 테스트가 그것을 검사한다.
- 지연은 30초 미만으로 줄일 수 없다(저장하지 않은 다른 앱의 작업이 있을 수 있다).
- 재개된 세션에서도 권한 프롬프트는 평소처럼 뜬다(자동 승인 아님).
- **크론·SDK 세션은 절대 재개 대상이 아니다.** 같은 프로젝트 폴더에 쌓이고 종종 가장 최신이지만,
  대화형 transcript만 후보가 된다.
- 문제가 생기면 로그는 `<홈>\.claude\claude-session-kit\kit.log` (프롬프트 본문은 기록하지 않는다).

## 4. Cancel / Status — 읽기·정리 전용

```
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/reboot-cancel.ps1"          # 예약된 재부팅 중단 + RunOnce·상태 제거
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/reboot-cancel.ps1" -Status  # 확인만
```

이 스크립트는 재부팅을 **시작할 수 없다.** "취소"·"확인" 요청에 §3의 스크립트를 실행하지 않는다.
`NOTHING_PENDING`이면 예약된 것이 없었다고 그대로 알린다.

## 별칭 추가·수정

사용자가 "이 폴더도 별칭 추가해줘: `<이름>` = `<경로>`"라고 하면:

1. 경로가 실제로 있는지 확인한다(없으면 만들지 말고 되묻는다).
2. 어떤 문구로 발동시킬지(`triggers`), 그 이름이 단독으로 쓰일 때 다른 뜻은 아닌지(`note`)를 묻는다.
3. `list-aliases.ps1` 결과의 `file` 경로에 있는 `aliases.json`을 Edit 도구로 고친다(적용 전 최종 확인).
   형식은 리포의 `examples/aliases.example.json`과 같다.

**이 SKILL.md나 스킬 폴더의 어떤 파일에도 별칭·경로를 적지 않는다.** 스킬 폴더는 git 리포이거나
업데이트마다 교체되는 플러그인 캐시다 — 개인 경로를 둘 곳이 아니다.

새 후보가 필요하면(읽기 전용):

```
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/list-candidates.ps1"
```
