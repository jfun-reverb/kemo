# 세션 역할·인수인계 규칙 (영구) — REVERB 세부

> **원칙 정의처는 전역 `~/.claude/rules/common-session-roles.md`** (세 세션 요약·같은 턴 커밋·인수인계 트리거·세션 지시 우선·고문 반대론자 모드·규칙 적용 범위 게이트). 여기는 이 저장소의 **실제 폴더·브랜치·파일 경계**만 적는다.

---

## 1. 세 세션 — 이 저장소의 자리

| 세션 | 본업 | 위치·브랜치 |
|---|---|---|
| **고문** | 규칙·방향 결정, 검증, 거버넌스 문서, **에이전트 팀 점검**(호출 빈도·중복·과부하 — 옛 reverb-team-manager 역할 흡수) | 메인 폴더 · `dev` |
| **기획/설계** | 사양서 — *무엇을* | worktree · **`feature` 브랜치** (사양서는 PR 로) |
| **개발 1~2** | 코딩·빌드·DB·배포 — *어떻게* | worktree · `feature` 브랜치 |

혼자 시퀀셜이면 메인 폴더 그대로([`multi-session.md`](multi-session.md)). 고문이 떠 있거나 동시 작업이면 기획·개발은 worktree — 원칙은 전역 §1.

---

## 2. 파일·작업 종류별 경계

| 작업·파일 종류 | 고문 | 기획 | 개발 |
|---|---|---|---|
| 규칙 파일 `.claude/rules/*` | ✅ 직접 + **같은 턴 커밋** | ✅ 직접 | — |
| 후크 `.claude/hooks/*` | ✅ 직접 + **같은 턴 커밋** | — | (필요 시 위임받아) |
| 메모리 `~/.claude/.../memory/*` (git 비추적) | ✅ 직접 | ✅ 직접 | △ 구현 사후기록 |
| 사양서 `docs/specs/*` 신규 | ✅ 직접 | ✅ 주작성 | — |
| 사양서 `docs/specs/*` 기존 | (보조) | ✅ **본문** | ✅ **「구현 결과」 섹션만** |
| HANDOFF 문서 (신규) | ✅ 직접 | ✅ 직접 | (받는 쪽) |
| 코드 `dev/*.js·css·html` | ❌ → 개발 | ❌ → 개발 | ✅ |
| 빌드 산출물 `index.html`·`admin/index.html` | ❌ | ❌ | ✅ (`build.sh`) |
| 마이그레이션 SQL `supabase/migrations/*` | ❌ → 개발 | ❌ (번호 안 박고 넘김) | ✅ (**번호 확정**) |
| `CLAUDE.md` (레퍼런스+거버넌스 혼합) | ❌ → 개발 | ❌ → 개발 | ✅ |
| 커밋·`dev` 머지 | **거버넌스 문서만** `dev` 직접 커밋 | `feature` 브랜치 | ✅ `feature`→`dev` PR |
| 운영(`main`) 배포 | ❌ | ❌ | ❌ → **사용자 확인** ([`git.md`](git.md)) |

**거버넌스 문서** = `.claude/rules/*` · `.claude/agents/*` · `.claude/commands/*` · **`.claude/hooks/*`** · 메모리 · HANDOFF · `docs/specs/*` 신규. 고문/기획이 직접 수정하고 **같은 턴에 커밋**(이유는 전역 §2). 그 외(코드·빌드·마이그레이션·`CLAUDE.md`·운영 배포)는 개발/사용자로. `dev` 직접 push 금지([`git.md`](git.md))의 **명시적 예외**가 거버넌스 문서인데, 🔴 **그 예외는 고문에게만** 해당한다 — 기획은 `feature` 브랜치에서 PR([`git.md`](git.md) 「기획 세션은 이 예외가 아니다」). 고문은 push 직전 원격 `dev` 를 먼저 받아 합친다(SessionStart 후크가 뒤처짐을 감지).

⚠️ **`.claude/hooks/*`**(2026-08-20 사용자 승인) — 후크는 코드지만 **규칙 준수를 검사하는 장치**라 규칙과 한 몸이다(규칙만 고치면 검사가 옛 규칙을 계속 강제한다). 셋을 지킨다:
1. **검사·경고·차단만** 한다. 제품 동작을 바꾸거나 파일을 고치지 않는다
2. **차단(exit 2)을 새로 거는 것은 사용자 확인** — 잘못 걸면 모든 커밋이 막힌다
3. 만든 뒤 **걸려야 할 것과 안 걸려야 할 것 양쪽을 시험**한다. 후크는 조용히 통과하는 실패가 가장 흔하다

⚠️ **여기에 없는 곳(`.claude/scripts/` 같은 새 폴더)을 고문이 임의로 만들지 않는다**(2026-08-20 실제로 만들었다 되돌림, `3616217f`). 새 카테고리는 **먼저 사용자 확인**.

---

## 3. 인수인계 — 이 저장소 이름

원칙(「설계 결정이 아직 남아 있나?」·정량 트리거 넷)은 전역 §3. 여기서 기획 = **`reverb-planner`**, 새 기능·동작 변경은 기획 / 버그·미세 조정은 개발(메모리 `feedback_change_request_routing` — PR 본문에 라우팅 흔적). 개발은 「구현 결과」 + 실제 마이그레이션 번호를 사후 기록([`docs-tracking.md`](docs-tracking.md)).

## 3-B. 세션 지시가 이긴다 — 이 저장소 사례

원칙·커밋 꼬리 한 줄(`Reviewer not run — session instruction, see PR body`)·「협의는 멈추게도 움직이게도 못 한다」는 전역 §3-B. 실제 사례: 어느 세션이 「요청 없이 Agent 도구 금지」 지시를 받았는데 [`interaction.md`](interaction.md)·[`git.md`](git.md) 는 「모든 커밋 직전 `reverb-reviewer`, 예외 없음」이었다. 세션 지시를 택하고 병합 요청 본문에 적은 처리가 **맞다**.

## 4. 고문 반대론자 모드

전역 §4 그대로. 판단성 대화 정의는 [`planning.md`](planning.md) 규칙 B.

---

## 관련 규칙·메모리
- [`planning.md`](planning.md) · [`request-validation.md`](request-validation.md) · [`multi-session.md`](multi-session.md) · [`git.md`](git.md) · [`docs-tracking.md`](docs-tracking.md)
- 메모리: `feedback_main_session_advisor_role` · `feedback_advisor_no_tracked_file_edits` · `feedback_session_role_split` · `feedback_change_request_routing` · `feedback_migration_number_no_preassign`
