# 자동응답(FAQ) 시스템 — 개발 세션 인계서 (HANDOFF)

> **작성:** 기획/설계 세션 2026-05-21
> **대상:** 개발 세션
> **한 줄 요약:** 응모건 메시지 위에 **개인화 상태 한 줄 + 선택지 트리형 자주 묻는 질문(FAQ)**을 얹는다. 이 문서만 읽으면 착수 순서·함정·검증을 알 수 있다.

---

## 0. 먼저 읽을 문서 (순서대로)

1. **사양서(필독·source of truth):** [`docs/specs/2026-05-21-message-faq.md`](./2026-05-21-message-faq.md)
2. **답변 문안(시드 원본):** [`docs/research/2026-05-21-message-faq-answers.md`](../research/2026-05-21-message-faq-answers.md) — 7카테고리·18질문, 한/일 단계별 문안
3. **실측 근거(왜 만드는가):** [`docs/research/2026-05-21-message-faq-bot.md`](../research/2026-05-21-message-faq-bot.md)
4. **기존 메시지 기능(얹는 토대):** [`docs/specs/2026-05-15-application-messaging.md`](./2026-05-15-application-messaging.md), `dev/js/messaging.js`, `dev/js/admin-messaging.js`

---

## 1. 핵심 전제 (놓치면 방향이 어긋남)

- **FAQ는 독립 기능이 아니라 응모건 메시지 안에서 작동** — 진입점은 응모이력 카드의 메시지 버튼 하나. 메시지 0건이면 FAQ 먼저, 1건+면 기존 대화(상단 상태 한 줄은 항상)
- **핵심 가치는 "개인화 상태 한 줄"(§3)** — 가장 빈번한 "내 신청 지금 어떤 상태?"를 묻기 전에 해소. 고정 FAQ는 보조
- **답변 톤 = 초등학생 눈높이 + 번호 단계** (사양서 §7, `.claude/rules/ui.md`) — 신규/수정 문안 모두 준수
- **운영 배포는 메시지 본체(약관 D-7 통지)와 묶여 보류** — 이번 작업은 **개발서버 검증까지만**. 운영 자동 배포 금지

---

## 2. 착수 순서 (PR 분할 — 사양서 §9)

| 순서 | PR | 내용 | 마이그레이션 |
|---|---|---|---|
| 1 | **PR A** | 테이블 2개 + 기록 RPC + **시드 18문안** + 관리자 등록 페인 `#adminPane-faq` | **146** |
| 2 | **PR B** | 인플루언서 상태 한 줄 + FAQ 트리 + 동적 치환 + 사유 표시 + 측정 기록 | 없음 |
| 3 | **PR B2** | 관리자 메시지 화면에 응모건 상태 한 줄(§3-1) | 없음 |
| 4 | **PR C** | 관리자 FAQ 열람 이력 패널(§3-2) | 없음 |
| — | PR D | 운영 배포 (메시지 PR 5 약관 통지와 함께) — **지금은 안 함** | — |

각 PR은 앞 PR 머지 후 착수. 한 PR씩 dev 검증.

---

## 3. PR A 상세 체크리스트 (첫 PR)

**마이그레이션 146** (현재 최신 145 — 착수 직전 `ls supabase/migrations/ | tail -3`로 재확인):

- [ ] 테이블 `faq_nodes` (자기참조 트리, 사양서 §4-1) + 인덱스 `(parent_id, sort_order)`·`(kind, active)`
- [ ] 테이블 `faq_interactions` (측정, §4-2) + `viewed` 부분 유니크 `(influencer_id, application_id, faq_node_id) WHERE action='viewed'`
- [ ] 행 단위 보안 정책(RLS): `faq_nodes` SELECT=authenticated / 쓰기=`is_campaign_admin()`. `faq_interactions` INSERT=본인, SELECT=`is_admin()`
- [ ] 기록 함수 `record_faq_interaction(application_id, faq_node_id, action)` — `SECURITY DEFINER` + `SET search_path=''`, 내부 `influencer_id=auth.uid()` 강제, `viewed` 멱등 UPSERT(§4-2). **익명 폼 RPC 패턴과 동일 이유 — INSERT-only 정책으론 UPSERT 못 함**
- [ ] **시드 18문안** (§4-4): 카테고리 7 + 질문 18, 답변 문서 6칸 그대로. `ON CONFLICT DO NOTHING`(재실행 안전 — 운영자 수정분 보호)
- [ ] 관리자 페인 `#adminPane-faq` (§8): 좌우 2단(카테고리 | 질문+측정 배지), 편집 모달 한/일 2열 + 미리보기, 화면이동 드롭다운(§8-2), handoff·단계 다중선택, 저장 후 `refreshPane('faq')`
- [ ] **신규 함수 스모크 호출** — `record_faq_interaction` 1회 실제 호출해 동작 확인 (정적 리뷰만으론 불충분, 메모리 규칙)

---

## 4. 구현 함정 (1·2차 검토 + 인계 점검에서 나온 것 — 꼭 확인)

1. **상태 한 줄 판정 순서(§3-0)** — 결과물 상태를 캠페인 일정보다 **먼저** 본다. "이미 영수증 냈는데 영수증 내라고 안내"하는 모순 방지. monitor 부분 반려 케이스 포함
2. **동적 치환(§5-1)** — Q1-1-c 본문의 `{required}`/`{current}`를 렌더 시 실제 값으로 치환. **안 하면 「{required}人以上」 토큰이 그대로 노출**. 값 없으면 그 줄 통째 생략. 화이트리스트 토큰만, `esc()` 적용
3. **사유 표시 3구분(§3-4)** — ① 응모 비승인=구체 사유 미공개(완곡), ② 결과물 반려=`reject_reason` 동적 표시(코드→일본어 라벨 변환 + `esc()`), ③ 응모 차단=미달 수치 구체 안내
4. **관리자 상태 한 줄(§3-1)** — 인플루언서 측과 같은 결과가 나오려면 admin-messaging 응모건 로딩에 **캠페인 일정·타입 + 결과물 상태 집계**를 함께 가져와야 함
5. **측정 무한 증가(§4-2)** — `viewed`는 멱등(질문당 1행 + `view_count`), `resolved`/`handoff`만 append
6. **화면이동 해시(§8-2)** — 표의 `action_target` 값은 추정. PR A 전 `dev/js/app.js` 라우팅과 1:1 대조해 확정
7. **`admin.js` 핫스팟** — 이 파일 동시 수정 작업과 병렬 금지, 시퀀셜만

---

## 5. 에이전트 호출 (개발 세션 의무)

- **reverb-planner:** 본 사양서가 기획을 갈음. PR별 큰 분기 생기면 추가 호출
- **reverb-supabase-expert:** PR A의 테이블·RLS·RPC·마이그레이션 — **반드시 호출**
- **reverb-reviewer:** 모든 commit 직전
- **reverb-qa-tester:** 각 PR dev 검증 (PR A=관리자 페인 Light, PR B=인플루언서 플로우 Full 성격). 운영 배포는 보류이므로 main merge 직전 Full은 PR D 시점

---

## 6. 검증 요약 (사양서 §10)

- **PR A:** 시드 18문안이 페인에 보이는지 + 마이그레이션 재실행 시 수정분 안 덮이는지 + 신규 등록·순서변경·활성토글·측정 보기 + `record_faq_interaction` 스모크
- **PR B:** 상태 한 줄 케이스별 정확성(심사/구매/반려/일부반려/완료) + 동적 치환(`{required}` 실제값) + 맞춤 정렬 + 직접문의 전환 + KO/JA 토글 + 측정 멱등
- **PR B2:** 관리자 상태 한 줄이 인플루언서 측과 동일 결과인지 대조
- **PR C:** 열람 이력 패널 순서·"직전 열람" 칩·답변 수정 후 「현재 답변 기준」 안내

---

## 7. 작업 환경

- 별도 작업 폴더(git worktree) + `feature/message-faq` 브랜치에서 진행 (기획 세션이 생성)
- dev/ 수정 후 `cd dev && bash build.sh` 필수
- DB 변경은 개발 데이터베이스 먼저 적용 후 검증 (운영은 PR D까지 보류)
- 구현 완료 후 사양서 하단 "## 구현 결과" 섹션 채우기 (문서 추적 규칙)
