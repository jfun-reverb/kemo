# QA 자동 테스트 — Playwright 연결을 「확장 방식」 → 「원격 디버깅(CDP)」 전환

**작성일:** 2026-06-09
**작성:** 기획 세션 (설계·인계용 HANDOFF)
**인계 대상:** 개발 세션(.mcp.json 변경·검증) + 고문 세션(거버넌스 규칙·메모리 갱신)

---

## 목적·배경

사용자 요청: reverb 화면 자동 테스트(`reverb-qa-tester`, Playwright)가 크롬에 붙는 방식을 현재 **확장 프로그램 방식(`--extension`)**에서 **원격 디버깅 연결(`--cdp-endpoint`)**로 바꾼다.

**동기(사용자 확인):**
1. 자동 테스트가 **평소 쓰는 크롬을 차지**해서 작업이 방해됨 → 평소 크롬과 분리하고 싶음
2. **이미 로그인된 상태 그대로** 테스트하고 싶음(매번 로그인 자동화 회피)
3. 사용자가 **다른 프로젝트에서 크롤링(타 사이트 원격 접속·데이터 추출)에 원격 디버깅 패턴을 이미 사용** 중 → 손에 익은 방식으로 통일

---

## 현재 상태 (2026-06-09 확인 · planning.md 규칙 A)

### 설정·옵션 (확인 완료)
- `.mcp.json` (레포 루트): Playwright MCP 서버가 `["-y", "@playwright/mcp@latest", "--extension"]` 로 기동 — **확장 프로그램 방식**(사용자의 단일 크롬에 「Playwright Extension」으로 붙음).
- `@playwright/mcp --help` 실측: **`--cdp-endpoint <endpoint>`** = "CDP endpoint to connect to" 옵션 존재. 동반 옵션 `--cdp-header`, `--cdp-timeout`(기본 30000ms). → **전환 가능 확인.**

### 영향 파일 (전환 시 같이 고쳐야 함)
- `.mcp.json` — 기동 인자 변경 (핵심)
- `.claude/agents/reverb-qa-tester.md` — 「실행 전 필수」 절차(확장 연결 전제 → 전용 크롬 기동 전제)
- `.claude/rules/multi-session.md` — 「Playwright(브라우저 테스트) 단일 자원」 섹션(`--extension` 명시)
- `.claude/rules/interaction.md`, `.claude/rules/git.md` — qa-tester 호출 의무 문구 중 「--extension 모드」 언급
- `.claude/hooks/session-checklist.js` — Playwright 안내 문구
- `.claude/commands/서비스점검.md` — qa 관련 안내
- 메모리 `feedback_playwright_single_resource.md` — `--extension` 전제 서술

### 미해결 백로그·관련
- 메모리 `feedback_playwright_single_resource.md`(단일 자원·동시 실행 금지) — **전환 후에도 유지**(아래 의심 3 참조)

---

## 의심·경우의 수 (planning.md 규칙 B)

1. **크롬을 안 띄운 채 qa 호출 → 연결 실패**: 확장 방식은 평소 크롬에 자동으로 붙었지만, CDP 방식은 **사용자가 전용 크롬을 원격 디버깅 포트로 먼저 띄워둬야** MCP가 연결됨. 안 띄우면 qa 즉시 실패. → qa-tester 에이전트 「실행 전 필수」에 "전용 크롬 기동 확인" 단계 추가 필수.
2. **평소 크롬 안 뺏김(동기 ①)은 전용 프로필이 있어야 성립**: 그냥 원격 디버깅을 켜고 평소 크롬에 붙이면 동일하게 방해받음. **반드시 별도 `--user-data-dir`(전용 프로필) 크롬**을 띄워야 ①이 실제로 해결됨.
3. **동시 멀티세션 충돌은 그대로**: CDP로 바꿔도 같은 포트(예: 9222) = 같은 전용 크롬 1개를 공유하면 여전히 단일 자원. **「qa는 한 번에 한 세션만」 규칙 유지.** (세션마다 다른 포트/프로필로 띄우면 이론상 병렬 가능하나 관리 복잡·사고 위험 → 1차는 단일 유지 권장.)
4. **보안 — 크롤링과의 분리 필수**: 사용자가 크롤링도 하므로, **reverb 테스트용 크롬과 크롤링용 크롬을 프로필(또는 별도 크롬)로 분리.** 한 크롬에 ⓐreverb 관리자 로그인 + ⓑ열린 디버깅 포트 + ⓒ크롤링 자동화가 섞이면 포트 경유로 관리자 세션이 조작될 위험. 또한 디버깅 포트는 **localhost 바인딩 유지**(외부 노출 금지 — `--host 0.0.0.0` 같은 외부 공개 금지).
5. **확장 vs CDP 동작 차이**: 확장 방식은 사용자가 평소 크롬의 특정 탭을 공유. CDP 방식은 전용 크롬을 Playwright가 통째 제어 → 기존 qa 시나리오가 "사용자가 미리 열어둔 탭" 같은 전제를 깔고 있으면 점검 필요(현 시나리오는 navigate 부터 시작이라 대부분 무관 예상, 개발 세션 확인).
6. **로그인 세션 만료**: 전용 크롬의 reverb 로그인이 만료되면 그 크롬에서 한 번 재로그인 필요(동기 ②의 유지보수 비용).
7. **포트 점유 충돌**: 9222를 다른 프로세스가 쓰면 기동 실패 → 절차에 포트 확인 한 줄.

---

## 설계 / 변경 사항

### 1. `.mcp.json` 변경 (개발 또는 고문 세션)
```jsonc
// 변경 전
"playwright": { "command": "npx", "args": ["-y", "@playwright/mcp@latest", "--extension"] }
// 변경 후
"playwright": { "command": "npx", "args": ["-y", "@playwright/mcp@latest", "--cdp-endpoint", "http://localhost:9222"] }
```
- 포트(9222)는 표준값. 크롤링용과 겹치면 다른 포트로(예: 9333).

### 2. 사용자 운영 절차 (전용 크롬 기동 — qa 돌리기 전 1회)
macOS 기준, **평소 크롬과 분리된 전용 프로필**로 띄움:
```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --remote-debugging-port=9222 \
  --user-data-dir="$HOME/.chrome-reverb-qa"
```
- 이 전용 크롬에서 **reverb 개발서버(dev.globalreverb.com) 로그인 1회** 해두면 세션 유지 → 이후 qa 가 로그인된 상태로 시작.
- 이 크롬은 **reverb 테스트 전용** — 크롤링·개인 작업에 쓰지 말 것(의심 4).
- 슬래시 명령 또는 짧은 셸 별칭(alias)으로 만들어 두면 편함(개발 세션이 제안).

### 3. 거버넌스 규칙·메모리·에이전트 갱신 (고문 세션)
- `reverb-qa-tester.md` 「실행 전 필수」: "전용 크롬이 `--remote-debugging-port`로 떠 있는지 + reverb 로그인 상태인지 확인. 안 떠 있으면 사용자에게 기동 요청 후 중단."
- `multi-session.md` 「Playwright 단일 자원」: `--extension` → `--cdp-endpoint` 로 서술 갱신, **단일 세션 원칙 유지** 명시(의심 3).
- `interaction.md`/`git.md`/`session-checklist.js`/`서비스점검.md`: `--extension` 언급 문구 갱신.
- 메모리 `feedback_playwright_single_resource.md`: 방식 변경 반영(단일 자원·동시 금지 결론은 유지).

---

## 검증 방법 (전환 후, 단일 세션에서)
1. 전용 크롬을 위 명령으로 띄우고 dev 로그인.
2. `.mcp.json` 변경 후 Claude Code 세션 재시작(MCP 재로딩).
3. qa-tester light 1회 실행 → 전용 크롬에서 동작·로그인 유지 확인, 평소 크롬은 영향 없음 확인.
4. 크롬 안 띄운 채 호출 시 "연결 실패" 안내가 뜨는지(의심 1) 확인.

---

## 인계 — 누가 무엇을
- **개발(또는 고문) 세션:** `.mcp.json` 변경 + 검증(3·4) + 사용자용 기동 별칭/명령 정리.
- **고문 세션:** 거버넌스 규칙·메모리·에이전트 갱신(설계 3).
- **사용자:** 전용 크롬 기동 절차 습관화 + 테스트/크롤링 크롬 분리.

## 사용자 확인 필요
- 포트 번호(9222 표준 vs 크롤링과 겹치면 변경) — 개발 세션이 사용자 크롤링 포트 확인 후 확정.
- 동시 멀티세션 qa 병렬을 원하는지(권장: 1차는 단일 유지). 원하면 세션별 포트·프로필 분리 설계 추가.

## 구현 결과

**구현일:** 2026-06-09 (개발 세션 — `.mcp.json` 변경·검증 부분)
**관련 커밋:** (dev 커밋 — `chore(mcp): connect playwright via cdp-endpoint to dedicated qa chrome`)

### ⚠️ 초안 전제 오류 정정 (가장 중요 — 2026-06-09 검증 중 발견)
- **인계 문서가 가리킨 파일이 틀렸음.** 설계 §1·영향파일은 "프로젝트 레포 `.mcp.json` 의 playwright 를 바꾸면 reverb-qa-tester 에 적용된다"고 전제했으나, **reverb-qa-tester 는 프로젝트 `.mcp.json` 이 아니라 클로드 ecc 플러그인의 playwright(`mcp__plugin_ecc_playwright__*`)를 쓴다.**
  - 증거: 에이전트 정의 `tools:` 가 `mcp__plugin_ecc_playwright__browser_*` 고정 / `ToolSearch select:mcp__playwright__browser_navigate` → "없음"(프로젝트 `.mcp.json` 의 playwright 서버는 도구로 노출조차 안 됨) / qa-tester light 실행 시 내장 플러그인 사용·CDP 미반영 보고.
- **실제 변경 대상 = ecc 플러그인 `.mcp.json` 2곳** (git 비추적, `~/.claude/` 하위):
  - `~/.claude/plugins/marketplaces/ecc/.mcp.json`
  - `~/.claude/plugins/cache/ecc/ecc/1.10.0/.mcp.json`
  - 둘 다 `@playwright/mcp@0.0.69 --extension` → `--cdp-endpoint http://localhost:9222` 로 변경(0.0.69 도 `--help` 에 `--cdp-endpoint` 존재 확인).
- **프로젝트 레포 `.mcp.json` 변경은 원복**(효과 없음 — `--extension` 으로 되돌림).
- **빠진 것(개발 세션 범위 밖, 고문 세션 인계):** 거버넌스 규칙·에이전트·메모리 갱신(설계 §3) — `reverb-qa-tester.md`「실행 전 필수」/`multi-session.md`/`interaction.md`/`git.md`/`session-checklist.js`/`서비스점검.md`/`feedback_playwright_single_resource.md`. 이 파일들은 거버넌스 문서라 고문/기획 세션이 직접 수정(session-roles.md 경계).
- **달라진 것:** 포트는 9222 그대로 확정. 사용자 크롤링과 충돌 우려(§95)는 **실측으로 해소** — 9222 점유 크롬이 크롤링용이 아니라 인계 문서가 지정한 전용 프로필(`--user-data-dir=$HOME/.chrome-reverb-qa`)이었음.

### 구현 중 기술 결정 사항
- **9222 사전 점유 검증:** 변경 전 `lsof -i :9222` + `ps` 로 점유 프로세스 확인 → 전용 프로필 크롬(`.chrome-reverb-qa`)이 dev.globalreverb.com 로그인 상태로 떠 있음을 확인하고 진행(의심 4 보안 분리 충족).
- **CDP 엔드포인트 응답 검증:** `curl http://localhost:9222/json/version` → Chrome/149, `webSocketDebuggerUrl` 존재 확인. `curl .../json` → 열린 탭이 `dev.globalreverb.com/#home`(로그인 상태)임 확인.
- **JSON 유효성:** `python3 json.load` 로 `.mcp.json` 파싱 정상 확인.
- **ecc 플러그인 파일은 git 비추적**(`~/.claude/` = 레포 밖, 사용자 로컬 환경 전용). 커밋 대상 아님. 프로젝트 `.mcp.json` 원복만 dev 커밋.
- **전역 영향:** ecc playwright 변경은 REVERB뿐 아니라 **모든 프로젝트의 qa-tester**에 적용됨(사용자 단일 사용자라 전용 크롬 공유로 일관성은 오히려 양호).
- **휘발성(중요):** ecc 플러그인 업데이트/재설치 시 `marketplaces/ecc/.mcp.json` 이 git pull 로 `--extension` 으로 **덮어쓰여짐** → 그때 본 변경 재적용 필요. 메모리에 재적용 절차 기록.
- **남은 검증(세션 재시작 필요):** ecc 플러그인 `.mcp.json` 변경도 현재 세션의 이미 로드된 MCP 서버에 즉시 반영 안 됨 → **Claude Code 세션 재시작 후** `reverb-qa-tester` light 1회로 실제 연결·로그인 유지·평소 크롬 무영향 최종 확인. 이 세션에서는 ① 0.0.69 `--cdp-endpoint` 지원 ② CDP `:9222` 응답(Chrome149·dev 로그인 탭)까지만 검증.
