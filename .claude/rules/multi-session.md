# 멀티 세션 운영 규칙 (영구)

> REVERB JP를 동시에 여러 Claude Code 세션으로 작업할 때 충돌·작업 손실을 막기 위한 규칙.
> 모든 세션·모든 에이전트에 영구 적용.

## 핵심 원칙

- **한 시점에 한 작업만이면** → 메인 폴더(`~/Documents/projects/reverb-jp`)에서 그대로 작업해도 충돌 없음
- **동시에 두 개 이상의 작업을 진행하면** → 작업마다 별도 git worktree(전시장)와 feature 브랜치를 사용
- 같은 기능을 여러 세션이 동시에 수정하는 패턴은 금지 (의미 없고 충돌 유발)

## 비유 (사용자 안내용 — 비개발자 친화)

- 메인 폴더 = 본 거실 (감독이 OK한 작품만 들여놓음)
- worktree 폴더 = 전시장 (인부 자유 작업장)
- feature 브랜치 = 그 전시장의 도면
- PR + 머지 = 전시장 작품을 본 거실로 옮기기
- 충돌 = 두 인부가 같은 거실에서 같은 벽에 작업해서 망친 상황

## 권장 워크플로

### 1단계 — 세션 시작
- 메인 폴더(`~/Documents/projects/reverb-jp`)에서 `/새세션 작업이름` 호출
- Claude가 자동으로 `~/Documents/projects/reverb-jp-{작업이름}` worktree + `feature/{작업이름}` 브랜치 생성
- 사용자는 새 터미널을 열고 그 폴더에서 Claude Code 세션을 시작

### 2단계 — 세션 안 작업
- 코드 수정·`bash dev/build.sh`·commit·push 모두 그 worktree 안에서만 수행
- push 대상은 항상 `feature/{작업이름}` 브랜치 (dev·main 직접 push 금지)
- 마이그레이션 새로 만들 일이 있으면 §마이그레이션 번호 룰 참조

### 3단계 — 세션 종료
- worktree 안에서 `/세션종료` 호출
- Claude가 reviewer 검수·빌드·commit·push·PR 생성을 자동 진행
- PR URL 안내 받음

### 4단계 — PR 머지 후 정리
- 사용자가 GitHub에서 PR 직접 검토·머지 (자동 머지는 위험해서 안 함)
- 머지 완료 후 메인 폴더에서:
  ```bash
  cd ~/Documents/projects/reverb-jp
  git worktree remove ../reverb-jp-{작업이름}
  git branch -D feature/{작업이름}
  git pull origin dev
  ```
- 또는 추후 `/세션정리` 단축키 도입 시 자동화

## REVERB JP 특화 충돌 포인트

### 마이그레이션 번호 (가장 흔한 충돌)
- `supabase/migrations/`는 번호 순차 파일로 관리됨. 새 파일을 만들기 전 반드시 `ls supabase/migrations/ | tail -5` 로 마지막 번호를 확인
- **규칙**: 마이그레이션 새 파일 추가는 **한 세션에서만** 진행. 다른 세션은 그 PR이 dev에 머지된 후 `git pull origin dev` → 자기 worktree에 반영 후 그다음 번호 사용
- Claude가 마이그레이션 추가 작업 받으면 자동 점검: 다른 worktree에서 같은 번호 작업 중인지 확인이 어려우므로, 사용자에게 「마이그레이션 새로 만들 일이 다른 세션에서도 있나?」 한 번 묻기
- **worktree에서 만든 마이그레이션 파일은 메인 폴더 트리에 안 보인다** — 사용자에게 "SQL Editor에서 실행" 안내 시 반드시 **파일 절대경로를 먼저 명시**할 것. 상세: `.claude/rules/supabase.md` 「마이그레이션/SQL 실행 안내 시 절대경로 명시」

### 빌드 산출물 (`index.html`/`admin/index.html`)
- `dev/build.sh`는 `index.html`/`admin/index.html`을 덮어씀
- 각 worktree에는 자체 빌드 산출물이 따로 있어 worktree 간 충돌 없음
- 단 같은 브랜치(feature/X)에서 두 세션이 commit하면 충돌 가능 — feature 브랜치도 한 세션에서만 다루기

### dev 브랜치 직접 push 금지
- dev 브랜치는 「본 거실」 — 작품을 옮기는 곳이지 작업하는 곳이 아님
- worktree에서는 항상 feature 브랜치로 push, PR로 dev에 머지
- 메인 폴더(dev 브랜치)에서 직접 작업하는 시나리오는 **단일 세션 + 시퀀셜 작업**일 때만

### Playwright(브라우저 테스트) 단일 자원 — 동시 실행 금지 (2026-06-05)
- Playwright 는 `.mcp.json` 에서 `--extension` 모드로 설정돼 **사용자의 단일 크롬 1개**에 붙는다(새 브라우저를 띄우는 게 아님). 연결은 한 번에 하나만 잡힌다.
- 두 세션이 동시에 qa-test(Playwright)를 돌리면 **나중 연결이 기존 연결을 끊어**, 먼저 돌던 테스트가 멈춘다.
- **규칙: qa-test 는 한 번에 한 세션만.** 개발 세션이 배포 전 자동으로 호출하지 말 것 — reverb-reviewer 가 "qa 권장: light/full/skip" 만 보고하고, **다른 세션이 Playwright 를 안 쓰는 걸 확인 + 사용자 트리거 후 단일 세션에서** 실행한다.
- 에이전트 정의 `.claude/agents/reverb-qa-tester.md` 「실행 전 필수」 + 호출 의무는 `.claude/rules/git.md`/`interaction.md` 에 반영됨.

### 운영 배포(main)는 별도 단계
- dev 머지가 끝나도 운영 자동 반영 안 됨
- 운영 배포는 `dev → main` PR을 별도로 만들어야 함 (`.claude/rules/git.md` 참조)
- 사용자 명시 지시 없으면 `/세션종료` 단계에서 운영 배포까지 자동 진행 금지

## Claude 가 자동으로 챙겨야 할 동작

세션 시작 시 (특히 Claude Code 세션이 worktree 폴더에서 시작될 때):

1. `git rev-parse --show-toplevel`로 현재 위치 확인
2. 만약 worktree 안이면 사용자에게 한 줄 안내:
   ```
   📁 현재 위치: {WORKTREE}
   🌿 브랜치: feature/{X}
   💡 작업 끝나면 /세션종료 호출하세요.
   ```
3. 만약 메인 폴더이고 사용자 요청이 「동시에 다른 기능을 추가로 하고 싶다」 류면 `/새세션` 단축키를 안내

## 사용 시점 요약

| 상황 | 권장 |
|---|---|
| 한 사람·한 작업 (시퀀셜) | 메인 폴더에서 그대로. worktree 불필요 |
| 동시에 다른 기능 둘 이상 | 작업마다 `/새세션`로 worktree 분리 |
| 한 작업이 너무 길어져 다른 작업 끼워넣고 싶음 | 끼워넣을 작업만 `/새세션` |
| 다른 사람과 같이 작업 | 사람마다 `/새세션` |

## 관련 규칙·단축키

- `.claude/commands/새세션.md` — `/새세션 X` 단축키
- `.claude/commands/세션종료.md` — `/세션종료` 단축키
- `.claude/rules/git.md` — 커밋 컨벤션·운영 배포 가드
- `.claude/rules/build.md` — `bash dev/build.sh` 의무
- `.claude/rules/interaction.md` — 약어 풀어쓰기·AskUserQuestion 사용
