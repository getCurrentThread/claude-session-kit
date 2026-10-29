# claude-session-kit

[English](README.md) · 한국어

**Windows**용 [Claude Code](https://claude.com/claude-code) 플러그인입니다. 스킬 하나가 세션의 일생
전체를 맡습니다 — 시작하고, 찾고, 다시 열고, 재부팅을 건너 이어 가고, 크래시 뒤에 되살립니다:

| | 이렇게 말하면 | 일어나는 일 |
|---|---|---|
| **새 세션 열기** | "새 임시 작업 켜줘", "`<별칭>` 폴더 켜줘", "`<별칭>`에 Opus xhigh로 켜서 이거 넘겨줘" | 새 임시 폴더나 등록된 작업 폴더에서 Windows Terminal 새 탭이 열리고 `claude`가 실행됩니다(이름을 붙이거나, 말한 모델과 effort로 켜거나, 일을 넘기는 첫 프롬프트를 줄 수도 있습니다). |
| **이전 세션 다시 열기** | "아까 그 세션 다시 켜줘", "배포 얘기하던 세션 찾아서 켜줘" | 목록에서 고르거나, 제목으로, 또는 그 안에서 한 말로 찾은 이전 세션이 기록된 폴더에서 새 탭으로 다시 열립니다. 이미 열려 있는 세션은 두 번 열지 않습니다. |
| **재부팅하고 이어서** | "재부팅하고 이어서 해" | 상태를 저장하고 1회용 재개를 등록한 뒤 Windows를 재시작합니다. 로그인하면 **같은 세션이 다음에 할 일을 이미 전달받은 채 이어지고**, 함께 열려 있던 다른 세션도 각자 탭으로 돌아옵니다. |
| **크래시 후 복구** | "아까 열려 있던 세션들 다시 켜줘", "크래시 전 세션 복구해줘" | 크래시, 창 닫힘, 예기치 않은 재시작 뒤에 열려 있던 세션을 보여 주고, 각자의 폴더에서 시작할 때의 권한 모드로 다시 엽니다. |

이 저장소는 원래 `reboot-continue`였고, 런처를 합치면서 이름을 바꿨습니다. 그 스킬을 쓰다
오셨다면 [CHANGELOG.md](CHANGELOG.md)를 보세요.

## 요구 사항

Windows 10/11 · [PowerShell 7](https://aka.ms/powershell) (`pwsh`) · Claude Code CLI (2.1.302에서
테스트했습니다. `claude agents --json`은 2.1.145 이상이 필요하고, 그보다 오래된 버전에서는 CLI 자체의
프로세스별 기록으로 대신합니다) · Windows Terminal 권장 (없으면 일반 콘솔 창을 씁니다).

**플러그인은 훅 두 개를 설치합니다.** `SessionStart`와 `SessionEnd`는 플러그인이 켜져 있는 동안
**모든** Claude Code 세션에서 `skills/session/scripts/track-session.ps1`을 실행합니다 — 셸 없이 직접,
각각 `pwsh`로 약 0.5초씩 걸립니다(시작 훅은 백그라운드에서 돕니다). 열려 있는 대화형 세션마다 작은
파일 하나(세션 id, 폴더, transcript 경로, 시작 권한 모드)를
`%USERPROFILE%\.claude\claude-session-kit\open-sessions\`에 쓰고, 세션을 일부러 끝내면 지우며,
아무것도 출력하지 않습니다. **크래시 후 복구**가 다시 여는 것이 이 기록입니다. 예약 실행, SDK(`-p`),
백그라운드 세션은 기록하지 않습니다. 플러그인을 끄면 훅도 빠집니다.

## 설치

플러그인으로:

```
claude plugin marketplace add getCurrentThread/claude-session-kit
claude plugin install claude-session-kit@claude-session-kit
```

또는 Claude Code가 플러그인을 자동으로 읽는 곳에 클론합니다(설치 단계가 없고, 고친 내용은 다음
세션부터 바로 적용됩니다):

```powershell
git clone https://github.com/getCurrentThread/claude-session-kit "$env:USERPROFILE\.claude\skills\claude-session-kit"
```

어느 쪽이든 스킬 이름은 **`claude-session-kit:session`**입니다. 플러그인 스킬에는 슬래시 단축
이름이 붙지 않아 `/launch`나 `/reboot-continue`는 없지만, 직접 칠 일은 거의 없습니다: 요청한
내용을 보고 스킬이 실행됩니다.

`npx skills add`는 지원하지 않습니다.

둘 다 있으면 설치된 플러그인이 우선하고 `~\.claude\skills\` 아래의 클론은 읽히지 않습니다
(`claude plugin list`에 그렇게 나옵니다). 킷을 고치는 중이라면 클론만 두세요.

## 별칭

작업 폴더 별칭은 개인 설정이라 플러그인 밖
`%USERPROFILE%\.claude\claude-session-kit\aliases.json`에 둡니다.
[examples/aliases.example.json](examples/aliases.example.json)에서 시작하세요:

```json
{
  "version": 2,
  "tempTask": { "root": "%USERPROFILE%\\Downloads", "prefix": "test" },
  "aliases": {
    "blog": {
      "path": "C:\\work\\blog",
      "triggers": ["blog folder", "블로그 폴더"],
      "note": "'블로그'라고만 하면 보통 이 폴더가 아니라 운영 중인 사이트를 말한다: 열기 전에 물어볼 것."
    }
  }
}
```

`triggers`는 이 폴더를 뜻하는 문구입니다. `note`는 애매한 언급을 어떻게 다룰지 Claude에게 직접 쓴
말로 알려 줍니다. `confirm: true`면 일치하더라도 열기 전에 묻습니다. `path`는 절대 경로이고,
`%USERPROFILE%` 같은 `%VAR%` 참조는 펼쳐집니다(`tempTask.root`에서도). 예전의 평평한 형식
`{ "name": "path" }`도 그대로 읽힙니다. Claude에게 "별칭 추가해줘"라고 하면 이 파일을 고칩니다 —
스킬은 절대 고치지 않습니다.

## 각 부분의 동작

**새 세션 열기.** `new-temp-task.ps1`은 `<root>\<prefix><N>`을 만듭니다 — N은 디스크에 있는 폴더*와*
transcript 기록으로만 남은 폴더를 모두 세므로, 새 임시 폴더가 예전 폴더의 대화를 물려받는 일이
없습니다. `open-workspace.ps1`은 별칭이나 명시한 경로를 엽니다. 모르는 별칭은 오류이고, 절대 추측하지
않습니다. 모든 세션은 자기 `--session-id`로 시작하고 `sessions.jsonl`에 기록됩니다. 최상위 세션으로
시작합니다: Windows Terminal이 새 탭에 넘겨줄 요청한 세션의 표식(`CLAUDECODE`,
`CLAUDE_CODE_CHILD_SESSION`, 세션 id와 entrypoint, …)을 먼저 지웁니다 — 이것을 물려받은 `claude`는
transcript 저장을 끕니다. 백그라운드 세션(`claude --bg`)에서 요청하면 작업 폴더(`CLAUDE_JOB_DIR`)도
지웁니다. 이것을 물려받은 탭은 그 작업에 합류해 작업 이름을 가져가고, 그 뒤로도 계속 따라갑니다.

`-Name "<name>"`은 그 이름으로 세션을 시작하므로(`claude --name`) CLI 자체 피커, 탭 제목, 이 킷의
목록에 모두 그 이름이 보입니다. 따옴표, 백슬래시, `%`, `& | < > ^ !`가 든 이름은 거절합니다
(`INVALID_NAME`): Windows Terminal은 넘겨주는 명령줄을 다시 나누므로, 이것들이 `claude`의 추가 인자로
바뀌어 버립니다.

`-Model`, `-Effort`, `-Prompt:'<text>'`는 말한 모델과 effort로(킷은 어느 쪽도 직접 고르지 않습니다)
첫 메시지와 함께 세션을 시작합니다 — 보통 "이 hand-off 노트를 읽고 따르라"는 내용이고, 노트는 미리
써 둡니다. 프롬프트는 같은 명령줄에 실려 갑니다. Windows Terminal 1.24에서 실측한 결과 줄바꿈, `;`,
맨 앞의 `-`, 한글, 이모지, 8000자는 그대로 가지만, `"`, 정의된 `%NAME%`, 옆에 공백이 없는 탭, 공백
뒤 맨 끝의 백슬래시는 바뀝니다. 이런 모양은 고치지 않고 거절합니다(`INVALID_PROMPT`) — `%`는 탭에
어떤 이름이 정의돼 있는지 킷이 알 수 없으므로 두 개만 있어도 거절합니다 — 빈 프롬프트와 8000자를
넘는 프롬프트도 마찬가지이고, 모두 무엇이든 만들기 전에 거절합니다. 프롬프트는 출력하거나 로그에
남기지 않습니다(`promptChars`만 남깁니다). npm `.cmd` shim 뒤에서는 프롬프트를 거절하고
(`CLAUDE_IS_SHIM`), 모델이나 effort만 주는 것은 괜찮습니다. 명령줄은 프로세스 목록에 보이므로
프롬프트에 비밀 정보를 넣지 마세요.

hand-off는 양쪽 끝에 이름을 붙여, 두 세션이 Claude Code 자체의 SendMessage로 서로 연락할 수 있게
합니다: 새 세션은 항상 `-Name`으로 시작하고(결과의 `name`이 ListAgents에서의 주소입니다), 프롬프트는
보고할 곳으로 요청한 세션의 이름을 알려 줍니다.

**이전 세션 다시 열기.** `resume-session.ps1`은 이 순서로 세션을 고릅니다: **런처 레지스트리** →
**최근 30일 대화형 transcript 스캔** → 그 폴더에서 **CLI 자체 피커**(`claude --resume`). 지금 열려
있는 세션은 — 요청한 세션도 — 건너뜁니다(`-Fork`일 때는 아님). 예약 실행이나 SDK 실행이 쓴
transcript는 후보가 아니고, `claude --continue`는 절대 쓰지 않습니다 — 폴더에서 가장 최근 것을
가리지 않고 다시 여는데, 그것이 자동화의 대화일 수 있기 때문입니다.

- **두 번 열지 않음.** 탭을 열기 전에 킷은 지금 열려 있는 세션을 확인합니다(`claude agents --json`.
  실패하면 CLI의 프로세스별 기록을 쓰되, 그 PID가 살아 있고 *또한* 기록된 시각에 시작했거나, 시작
  시각이 없으면 claude/node 프로세스일 때만 셉니다). 열려 있는 세션은 `ALREADY_RUNNING`으로
  거절합니다 — 한 대화에 탭 두 개가 붙으면 한 transcript에 쓰기가 뒤섞입니다. `-Fork`
  (`--fork-session`)는 그래도 허용합니다: 새 id(`--session-id`)로 시작하는 새 대화이고 다른 실행처럼
  기록되므로, 그 폴더를 다음에 다시 열 때 찾을 수 있습니다(CLI 피커에서 만든 포크는 아닙니다: 그 id는
  CLI만 압니다). 백그라운드 세션(`claude agents`)도 거절하며, 결과에 `claude attach`에 줄 작업 id가
  나옵니다.
- **제목.** 목록에는 CLI가 만든 제목보다 직접 붙인 이름(`/rename`, `--name`)이 먼저 보이고, 둘 다
  없으면 처음 입력한 내용을 씁니다(`titleSource`가 어느 쪽인지 알려 줍니다). 제목은 transcript 전체가
  아니라 앞부분과 마지막 64 KB에서 읽습니다.
- **검색.** `search-sessions.ps1 -Query:"<words>"`는 제목, 폴더 이름, 메시지에 모든 단어가 들어
  있는(한글 포함) 세션을 찾아 제목 > 폴더 > 메시지 본문 순으로 정렬하고 한 줄 발췌를 붙입니다. 직접
  입력한 내용과 Claude의 답만 검색하고 도구 출력은 검색하지 않습니다. `rg`가 설치돼 있으면 사전
  필터로 씁니다.
- **권한 모드.** `--permission-mode <mode>`로 시작했고 일부러 끝내지 않은 세션(창 닫힘, 크래시,
  정전으로 훅 기록이 남은 세션)은 같은 모드로 다시 엽니다. `/exit` 뒤에는 기본 모드로 돌아옵니다.
  킷은 모드를 직접 고르지 않고, `bypassPermissions`는 절대 되살리지 않습니다 —
  `droppedPermissionMode`로 알리고, 세션은 평소처럼 권한을 묻는 상태로 돌아옵니다.

**크래시 후 복구.** 위의 훅은 일부러 끝내지 않은 모든 대화형 세션의 기록을 남깁니다(`/exit`,
Ctrl+C, `/clear`, `/resume`, 로그아웃은 기록을 지우고, 창 닫힘·크래시·정전은 남깁니다).
`restore-open.ps1`은 지금 실행 중이 아니고 transcript가 아직 있는 기록을 보여 주고, 기록된 폴더에서
전부 또는 일부를 다시 열거나(`-All`, `-Ids <sessionId>,…`) 잊습니다(`-Forget`, `-ForgetAll`). 각
세션은 transcript에 기록된 폴더에서 열리고(훅 자체의 cwd는 `cd`나 worktree로 옮겨졌을 수 있습니다),
요청한 세션은 후보에 넣지 않습니다. 폴더 신뢰는 다른 곳과 마찬가지로 세션마다 확인합니다. Claude
Code는 창 닫힘과 크래시를 구별하지 못하므로, 탭을 닫은 세션은 다시 열거나 잊을 때까지 모두 목록에
나옵니다.

**보관 기간.** Claude Code는 시작할 때 `cleanupPeriodDays`(기본 30)보다 오래된 transcript를 지우고,
지워진 세션은 목록·검색·재개 어디에도 나오지 않습니다. `list-sessions.ps1`은 이 설정을 알려
주고(읽기만 합니다 — 킷의 어떤 것도 `settings.json`을 쓰지 않습니다) 30일 이하면 경고합니다. 큰 값으로
올리되 **0은 절대 안 됩니다**(v2.1.89부터 거부되고, 그 전 버전은 "아무것도 저장하지 않음"으로
읽습니다). 또는 `archive-sessions.ps1`로 transcript를 백업합니다(`-All`은 모든 대화형 transcript,
`-List`는 보관된 것 보기). 보관본은 아무것도 다시 읽지 않는 단순 사본이고, 대화 파일만 담습니다
(세션의 `subagents\`, `tool-results\` 폴더는 아님).

**재부팅하고 이어서**는 일부러 두 단계입니다:

```
reboot-plan.ps1      폴더, 세션, 프롬프트, 정확한 RunOnce 명령을 정하고, 아직 지켜보고 있을 때
  │                  실패할 수 있는 것을 모두 확인한 뒤 plan.json과 1회용 토큰을 씁니다.
  │                  그 밖에는 아무것도 바꾸지 않습니다.
  ▼
reboot-commit.ps1 -Token <t>
                     상태 폴더 아래에 재개 스크립트 사본을 고정해 두고, state.json을 쓰고,
                     HKCU\…\RunOnce를 설정하고, `shutdown /r /t 30`을 실행합니다.
  ▼
(로그인) RunOnce → Windows Terminal → <state>\runtime\resume.ps1
                     → claude --resume <session-id> -- "<continuation prompt>"
```

- `reboot-commit.ps1`은 Windows를 재시작하거나 RunOnce 값을 쓸 수 있는 **유일한** 파일이고, 테스트가
  이를 강제합니다. 권한 허용 목록에 넣지 마세요 — 실행 전 확인이 마지막 잠금입니다.
- `plan.json`은 그냥 파일이므로 커밋 단계는 거기서 실행할 것을 하나도 가져오지 않습니다: RunOnce
  명령은 계획 단계가 만드는 모양과 토큰 하나하나까지 같아야 하고, 설치된 PowerShell(과 Windows
  Terminal)을 가리켜야 하며, 등록하기 전에 다시 만들어집니다. RunOnce 명령이나 고정 스크립트 경로를
  고친 계획은 거절하고(`PLAN_INVALID`), 10분이 지났거나 미래 날짜인 계획도 거절합니다. 폴더, 세션 id,
  프롬프트는 있는 그대로 재생되므로 `plan.json`은 `state.json`만큼 민감합니다 — 이 장치가 지키는 것은
  로그인 때 실행되는 명령이지 상태 폴더 전체가 아닙니다.
- 재개할 세션은 재부팅 **전에** 정해집니다: 명시한 id는 그 폴더에 기록된 대화형 transcript가 있어야
  하고, 없으면 실행 중인 세션(`CLAUDE_CODE_SESSION_ID`), 그다음 그 폴더의 가장 최근 대화형
  transcript입니다. 일치하는 것이 없으면 프롬프트를 실은 새 세션이 되고, 계획에 그렇게 나옵니다.
- 프롬프트는 `--` 뒤의 인자 하나로 `claude.exe`에 넘깁니다(네이티브 명령줄을 느슨하게 만드는 Windows
  PowerShell 5.1과 pwsh 7.0–7.2에서는 재개 스크립트가 명령줄을 직접 만듭니다). `claude`가 npm식
  `.cmd` shim이면 프롬프트를 명령줄에 **절대** 넣지 않습니다 — `cmd.exe`가 그 안의 `&`, `|`,
  `%VAR%`, 따옴표를 해석하고 첫 줄 뒤를 모두 버리기 때문입니다 — 대신 `resume-prompt.txt`에 쓰고
  명령줄은 그 파일만 가리킵니다.
- **다른 열린 세션도 돌아옵니다.** 재부팅하면 열린 Claude 세션이 모두 꺼지므로, 계획에는
  transcript와 폴더가 있고 폴더가 신뢰된 다른 열린 대화형 세션(최대 8개)도 `alsoResume`으로 들어가고,
  나머지는 이유와 함께 `skipped`에 들어갑니다. transcript가 `-MaxIdleHours`(기본 24)보다 오래 쓰이지
  않은 세션은 `IDLE`로 건너뜁니다: 실행 중이지만 아무도 보지 않는 터미널에 있는 세션입니다. 로그인하면
  각 세션이 자기 탭에서 `claude --resume <id>`로 **프롬프트 없이** 열리고, 인계 메모는 요청한 세션만
  받습니다. `-OnlyThis`는 요청한 세션만 되살립니다. 커밋 단계는 `plan.json`에서 가져오는 다른 모든
  것처럼 이 목록도 다시 검증합니다(UUID, 실제로 있는 로컬 폴더, 중복 없음, 상한).
- **인계 메모는 모양이 정해져 있습니다** — 왜 재시작했는지, 무엇을 끝냈는지, 무엇을 시도했다
  실패했는지, 다음 단계, 먼저 실행해 볼 확인 명령 — 그래서 재개된 세션이 상황을 알고 시작합니다.
- **낡은 상태는 거절합니다.** 아직 대기 중인 재개 위에 계획을 세우면 다른 세션의 재개를 조용히
  덮어쓰지 않고 `RESUME_PENDING`을 돌려주고(정말 덮어쓰려면 `-Replace`), 30분이 넘은 프롬프트 파일 —
  예전 재부팅에서 남은 메모 — 은 `PROMPT_STALE`을 돌려줍니다(정말 쓰려면 `-AllowStalePrompt`).
- 로그인할 때 저장된 폴더가 없으면(아직 연결되지 않은 드라이브) 아무것도 실행하지 않고 상태를 남겨
  두므로, 손으로 다시 재개할 수 있습니다. 다른 세션의 폴더가 없으면 그 세션만 건너뜁니다.
- RunOnce는 플러그인 안이 아니라 재개 스크립트의 **고정 사본**을 가리킵니다: 설치된 플러그인은
  버전별 캐시 폴더에 있어서, 다음 로그인 전에 업데이트되면 조용히 실패하는 죽은 항목이 남기
  때문입니다.
- 일부러 1회용입니다: RunOnce는 스스로 지워지고 재개 스크립트는 실행 전에 `state.json`을 보관하므로,
  다시 실행하다 실패해도 반복되지 않습니다.
- 로그인은 여전히 직접 합니다(비밀번호를 저장하지 않습니다). 재개된 세션의 권한 확인도 평소와
  같습니다. 중단하려면 `shutdown /a`나 `reboot-cancel.ps1`을 씁니다.

**폴더 신뢰 — fail closed.** 폴더의 `.claude/settings.json`은 훅과 MCP 서버를 실행할 수 있으므로,
Claude Code는 폴더마다 한 번 신뢰하는지 묻습니다. 런처가 연 탭은 아무도 모르게 이 질문에서 멈춰
있기 쉬우므로, 킷은 먼저 `~/.claude.json`을 확인하고 신뢰되지 않은 폴더면 **세션을 켜지 않고 알려
줍니다** — 폴더가 무엇을 싣고 있는지(`ships`: 훅, MCP 서버, 허용 규칙, env 키) 보여 주고, 진행할
방법 하나를 제안합니다: 신뢰하고 열기(`-TrustFolder`). 그러라고 하면 킷이
`projects[<folder>].hasTrustDialogAccepted: true`를 직접 씁니다 — 질문에 답할 때 쓰이는 바로 그
값입니다 — 그리고 탭은 **질문 없이** 시작합니다. 그 뒤로는 그 폴더의 훅, MCP 서버, 설정이 계속
적용됩니다.

`-TrustFolder`는 킷이 `~/.claude.json`에 쓰는 유일한 경우입니다. Claude Code 자신이 그 파일에 쓸 때
잡는 잠금(`~/.claude.json.lock`)을 잡고, 그 안에서 파일을 다시 읽고, 그 키 하나만 바꾸고, 이름 바꾸기
한 번으로 파일을 교체하며, 이전 사본을 상태 폴더에 `claude.json.before-trust`로 남깁니다. 드라이브
루트, 홈 폴더와 그 위는 거절하고(`TRUST_REFUSED`), 잠금이 잡혀 있거나 파일을 해석할 수 없으면 쓰지
않고 실패합니다(`TRUST_WRITE_FAILED`). git 저장소는 신뢰된 상위 폴더의 신뢰를 물려받지 않고, 저장소
안의 폴더를 신뢰하면 저장소 전체를 신뢰하게 된다는 점에 주의하세요.

## 상태 파일

모든 것은 `%USERPROFILE%\.claude\claude-session-kit\`에 있습니다 — `aliases.json`, `sessions.jsonl`
(레지스트리), `open-sessions\`(열린 대화형 세션마다 하나, 훅이 씀), `plan.json` / `state.json` /
`state.last.json`(재부팅), `next-prompt-<id>.txt`, `resume-prompt.txt`(`.cmd` shim일 때만),
`runtime\resume.ps1`(고정 사본), `archive\`(`archive-sessions.ps1`을 실행했을 때만; transcript의 단순
사본), `kit.log`. 이어 갈 프롬프트는 재개에 필요하므로 상태 파일에 저장되지만, 로그에는 **절대** 쓰지
않고(길이와 짧은 해시 앞부분만 기록합니다) `-Status`로도 보여 주지 않습니다.

알아 둘 부작용: 열린 세션을 확인할 때 읽기 전용 질의인 `claude agents --json`을 실행합니다. 다른
`claude` 시작과 마찬가지로 이것이 `~/.claude.json`을 갱신할 수 있습니다(새 설정 파일은 1회
마이그레이션을 거칩니다). 킷 자체는 그 파일을 쓰지 않습니다.

## 스크립트

모두 `skills/session/scripts/` 아래에 있고, 모두 JSON 객체 하나(`ok`, `code`, `message`, …)를
출력합니다:

| 스크립트 | 하는 일 | 부작용 |
|---|---|---|
| `list-aliases.ps1` | 별칭 표 | 없음 |
| `list-sessions.ps1` | 재개할 수 있는 세션(제목, `running`, 보관 기간 설정 포함) | 없음 |
| `search-sessions.ps1 -Query:` | 제목, 폴더 이름, 메시지 본문으로 세션 찾기 | 없음 |
| `list-candidates.ps1` | 가장 많이 쓴 폴더(이미 등록된 폴더에는 `alias`가 붙음) | 없음 |
| `new-temp-task.ps1 [-Name] [-Model] [-Effort] [-Prompt:]` | 새 임시 폴더 + 새 세션 | 폴더, 터미널 탭 |
| `open-workspace.ps1 -Alias\|-Path [-Name] [-Model] [-Effort] [-Prompt:]` | 작업 폴더에서 새 세션 | 터미널 탭 |
| `resume-session.ps1 [-Alias\|-Path] [-SessionId] [-Fork]` | 세션 다시 열기 | 터미널 탭 |
| `restore-open.ps1 [-All\|-Ids\|-Forget\|-ForgetAll]` | 크래시나 창 닫힘으로 열린 채 남은 세션 | 터미널 탭; 다시 열 수 없는 기록 정리; `-Forget`은 기록 삭제 |
| `archive-sessions.ps1 [-All] [-List]` | transcript 백업 | `archive\`에 복사 |
| `reboot-plan.ps1` | 재부팅 후 재개 계획 | `plan.json`만 씀 |
| `reboot-commit.ps1 -Token` | **등록 + 재부팅** | RunOnce, `shutdown /r` |
| `reboot-cancel.ps1 [-Status]` | 취소 / 확인 | 자기가 만든 RunOnce와 상태 삭제 |
| `track-session.ps1` | SessionStart/SessionEnd 훅(직접 쓰지 않음) | `open-sessions\<id>.json` 쓰기/삭제 |

## 테스트

```powershell
pwsh -NoProfile -File tests/run-tests.ps1
```

Pester도 네트워크도 쓰지 않습니다. 버리는 샌드박스(`CLAUDE_SESSION_KIT_HOME`, `CLAUDE_CONFIG_DIR`)에서
돌고, 탭을 열지 않고, 재부팅을 예약하지 않고, 진짜 `claude`를 실행하지 않으며(대역이
`claude agents --json`에 답합니다), 정확한 RunOnce 문자열, `wt` 인자 목록, `claude` argv를 검증합니다.
훅에는 녹화해 둔 훅 입력을 stdin으로 넣고, 여러 세션 재개는 PowerShell 7과 Windows PowerShell 5.1
양쪽에서 `wt`와 `claude`의 대역을 상대로 돌립니다. 재개 스크립트는 실제로 실행하되 `claude`의 대역 —
`.cmd` shim과 argv를 기록하는 작은 `.exe` — 만 상대하며, 따옴표, `&`, `%VAR%`, 줄바꿈이 가득한
프롬프트를 넣습니다. 위조한 `plan.json` 파일로 커밋을 시도해(`-Simulate`) 하나하나 거절되는지
확인합니다.

실행 시 넘기는 첫 프롬프트는 첫 단계까지만 테스트합니다: 기록용 `.exe`를 `wt` 자리에 두고, 통과하는
모든 프롬프트 모양이 PowerShell 7과 Legacy 인자 모드(7.0–7.2가 쓰는 방식)에서 정확한 인자 목록으로
도착하는지 봅니다. 두 번째 단계 — `wt`가 자식의 명령줄을 다시 만드는 일 — 는 Windows Terminal 안에서
일어나 어떤 대역도 볼 수 없습니다. 이 단계는 손으로 한 번 실측했고(Windows Terminal 1.24, 실제 탭,
argv를 기록하는 자식), 테스트는 거절 목록을 그 실측 결과에 고정해 둘 뿐 실제 `wt`를 다시 확인하지는
않습니다.

## 제거

먼저 대기 중인 재개가 없는지 확인하세요 — Claude에게 "대기 중인 재부팅 재개 취소해줘"라고 하거나
취소 스크립트를 직접 실행합니다(플러그인 설치라면
`~\.claude\plugins\cache\claude-session-kit\claude-session-kit\<version>\` 아래에 있습니다):

```powershell
pwsh -NoProfile -File "$env:USERPROFILE\.claude\skills\claude-session-kit\skills\session\scripts\reboot-cancel.ps1"
```

그다음:

```powershell
claude plugin uninstall claude-session-kit@claude-session-kit                # 또는 클론한 폴더 삭제
claude plugin marketplace remove claude-session-kit
Remove-Item -Recurse -Force "$env:USERPROFILE\.claude\claude-session-kit"    # 별칭, 레지스트리, 로그, 보관본
```

훅은 플러그인과 함께 사라집니다. 마지막 줄은 `archive\`도 지웁니다 — Claude Code가 이미 정리한
transcript의 유일한 사본이므로, 남겨 두려면 먼저 다른 곳으로 옮기세요.

## 라이선스

MIT
