# 거버넌스 규칙 다이어트 — 분석·계획

**작성일:** 2026-06-15
**작성 세션:** 개발 세션 (읽기 전용 분석 — 실제 규칙 파일 수정은 고문 세션 영역)
**성격:** 분석/계획 자료. 본 문서는 규칙을 바꾸지 않음. 다이어트 실행 시 고문 세션이 이 계획을 참고.

---

## 배경
`.claude/rules/*` 규칙 문서가 비대·상호참조 과다해 정리(다이어트) 필요. 메모리 `project_governance_diet_backlog`의 미착수 항목. 단 규칙 변경은 위험이 커서 과거에도 연기됨(메모리 `project_global_governance_extraction`: "실익(토큰) < 위험"으로 통째 제거 연기).

## 측정 결과 (2026-06-15 기준)

규칙 15개 = 총 1,286줄. 글로벌 공통 규칙(`~/.claude/rules/common-*.md`, 총 393줄)과 2층 구조.

### 글로벌과 주제가 겹치는 6개 (= 674줄, 다이어트 후보)

| 레포 규칙 | 레포 줄 | 글로벌 짝 | 글로벌 줄 | 중복도 |
|---|---|---|---|---|
| session-roles | 90 | common-session-roles | 89 | 거의 동일 |
| request-validation | 40 | common-request-validation | 35 | 거의 동일 |
| planning | 166 | common-planning | 79 | 절반 |
| interaction | 176 | common-interaction | 79 | 절반 |
| docs-tracking | 97 | common-doc-tracking | 66 | 절반 |
| multi-session | 105 | common-multi-session | 45 | 절반 |

### REVERB 전용 (612줄, 다이어트 대상 아님)
supabase(130)·git(116)·release-timing(102)·ui(68)·security(54)·notion-sync(50)·policy(36)·build(30)·quality(26). 글로벌 중복 없음.

### 상호참조
`session-roles.md`가 다른 파일을 21회 참조하는 허브. planning(13)·release-timing(11)·interaction(10) 순. 파일 제거 시 참조 끊김 위험.

---

## 다이어트 후보 3등급

### 🔴 고위험 — "통째 제거 후 글로벌 위임" (권장: 하지 말 것)
session-roles·request-validation은 글로벌과 거의 동일해 통째 삭제가 매력적이지만:
- **상호참조 허브 붕괴**: session-roles를 다른 13개 파일이 21회 참조 → 제거 시 전부 끊김.
- **도메인 세부 손실**: 레포판에만 있는 REVERB 세부(reverb-planner 정량 트리거, dev/feature 브랜치, build.sh, CLAUDE.md 등).
- **우선순위 함정**: 같은 이름 규칙/커맨드는 글로벌(Personal)이 프로젝트(Project)를 덮음(2026-06-11 실측). 레포 파일 제거는 위험.
- **과거 결정**: 이미 "실익 < 위험"으로 연기. → **연기 유지.**

### 🟡 중위험 — 의도적 이중 안전망 (권장: 보존)
reviewer 등 에이전트 호출 의무가 `interaction.md` + `git.md` 양쪽 중복. "반복 위반 방지용 일부러 두 곳 명시(이중 안전망)"라고 문서에 적혀 있음. 줄이면 누락 재발. → **보존.**

### 🟢 저위험 — 안전한 축약 (권장: 여기만 진행)
글로벌과 100% 겹치는 **원칙 문단**을 레포에서 "정의처: 글로벌 common-X 참조" 한 줄로 줄이고, **REVERB 고유 세부만 본문 유지**.
- 효과 큰 대상: planning(166→~90), interaction(176→~110).
- session-roles·request-validation: 파일·제목은 유지(참조 허브 보존), 본문 원칙만 축약.
- **보존 필수**: 오탈자 목록·UX 체크리스트·reverb-* 에이전트 이름·약어 풀이 예시 (REVERB 전용).
- 예상 절감: 약 200~250줄(전체 15~20%), 참조·도메인 손실 없이.

---

## 실행 가이드 (고문 세션용)
1. 고위험(통째 제거)은 하지 않음 — 과거 결정 유지.
2. 저위험 축약만 진행. 원칙 3종 엄수:
   - ① 파일·제목 유지(상호참조 보존)
   - ② REVERB 도메인 세부 보존(오탈자·UX 체크리스트·에이전트명·약어 예시)
   - ③ **한 파일씩** 고치고 같은 턴에 dev 커밋(미커밋 방치 금지)
3. 한 파일 축약 후 `grep -rE "그 파일명.md|\[\[그_slug\]\]"`로 참조 끊김 점검.
4. 글로벌과 겹치는 문단을 줄일 때 글로벌 common-* 내용이 실제 그 원칙을 담는지 먼저 대조(글로벌이 더 얕으면 레포 본문 유지).

## 미결정 / 사용자 확인 사항
- 저위험 축약을 실제로 진행할지 여부 (현재는 분석·계획만 — 실행 미승인)
- 진행 시 우선순위(planning·interaction부터 권장)

## 관련
- 메모리 `project_governance_diet_backlog`, `project_global_governance_extraction`
- 규칙 `.claude/rules/session-roles.md`(§2 거버넌스 문서 경계 — 규칙 파일은 고문/기획 영역)
