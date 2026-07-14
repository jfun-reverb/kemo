# 정산 과거분 컷오프 + 관리자 수동 처리

**작성일:** 2026-07-09
**작성 주체:** 개발 세션(방향은 사용자 확정 2026-07-09)
**관련 기능:** 인플루언서 정산 관리(사양서 `2026-06-22-influencer-settlement.md`, PR1~3 dev 완결·운영 배포 대기 PR #695)
**성격:** 정산 운영 배포 **전 필수 보완**

---

## 배경 (문제)

정산 운영 배포 직전 발견. `backfill_settlements()`(마이그레이션 218)에 **시간 컷오프가 없다**:
- 운영 배포 후 관리자가 정산 화면을 처음 열면 `backfillSettlements()`가 호출되어, **과거에 인증 성공한 모든 승인 응모가 한꺼번에 `pending` 정산으로 생성**된다.
- 그 중 이미 외부 PayPal로 지급 완료한 건도 시스템에 지급 기록이 없어 `pending`으로 잡힌다 → 관리자가 과거 이력을 일일이 찾아 상태를 고쳐야 함(비현실적).
- 부작용: PayPal 미등록인 **과거 인플에게 `settlement_paypal_required` 알림이 대량 발송**(활동 종료 인플 포함).

---

## 현재 상태 (규칙 A — 검증)

### 관련 코드·DB
- `supabase/migrations/218_backfill_settlements_fn.sql` — 백필 함수. 대상 = `applications.status='approved' AND campaigns.reward>0 AND influencers.is_audit=false AND settlements 행 없음`. **시간 조건 없음.** 인증 성공 판정(computeCertStatus SQL 재현) → `settlements` INSERT(기본 `status='pending'`) + `settlement_events(action='create')` + PayPal 미등록 시 `notifications('settlement_paypal_required')`.
- `supabase/migrations/217_settlements_schema.sql` — `settlements`(status CHECK pending/paid/on_hold/cancelled, `application_id` UNIQUE 멱등, `created_at`, `amount_jpy`, `paypal_email`, `version`) + `settlement_events`(ON DELETE RESTRICT, append-only).
- 상태 변경 RPC(222~225): `mark_settlement_paid/hold/cancel/revert`, `get_settlement_events`. 전부 `has_permission('settlement.pay','write')` 게이트 + 낙관적 락 + 이력.
- `dev/js/admin-settlements.js` — 정산 페인. 진입 시 `backfillSettlements()` 호출, 상태 탭(전체/정산대기/송금완료/보류/취소), 캠페인 다중필터, 처리 모달, `refreshPane('settlements')`.
- `dev/js/mypage.js` `renderMySettlements` — 인플 본인 정산행만(RLS `influencer_id=auth.uid()`). cancelled 숨김, on_hold=「確認中」.
- **인증 성공일 판정 근거**: `deliverables.reviewed_at`(승인 시각) 존재 → 인증에 필요한 마지막 결과물의 승인 시각을 "인증 성공일"로 사용 가능(서버 판정).

### 이 제안과 충돌 가능성 있는 기존 동작
- `backfill_settlements()` 시그니처·호출부(`admin-settlements.js`)는 유지하되 **내부에 컷오프 조건만 추가** → 기존 흐름과 충돌 없음(확인).
- `application_id` UNIQUE 라 자동 백필과 과거 수동 처리가 같은 응모를 동시에 만들어도 중복 불가(멱등) — 상태 결정 주체만 정리하면 됨.

### 미해결 백로그·관련 작업
- 정산 PR1~3(마이그레이션 217~225) 운영 배포 대기(PR #695). 본 보완은 그 배포에 **합류**(배포 전 필수).
- 마이그레이션 번호: 인플루언서 추천 도구가 226~229 점유(dev 미머지). **본 작업은 230번대부터**(충돌 회피, 개발 생성 시 확정).

---

## 의심·경우의 수 (규칙 B — 반대론자)

1. **컷오프 기준일 판정**(기술): "인증 성공일"을 응모 승인일이 아니라 **마지막 필요 결과물 승인 시각(reviewed_at)** 으로 잡아야 실제 지급 대상 확정 시점과 일치. 백필 CTE에서 리뷰어=영수증+채널별 인증샷 중 최종 승인 시각, 시딩·방문=게시물 승인 시각. 클라 시각 신뢰 금지·서버 판정(`now()` 비교).
2. **경계 건**(데이터): 컷오프 직전 인증 성공했지만 아직 안 준 건 → 과거 목록에 떠서 관리자가 「정산대기 추가」로 처리. 컷오프 직후는 자동 백필. 겹침 없음(UNIQUE).
3. **도입일 저장 위치**(운영): 코드 하드코딩 금지(재배포·환경차). **설정 싱글톤 테이블**(연령정책 `age_policy_settings` 패턴) — 배포 시 도입일 세팅, 이후 조정 가능. NULL이면 "컷오프 미설정 = 과거 전체가 자동 대상"이 되어 위험하므로 **NULL 처리 정책 명시**(NULL이면 백필 0건=안전측, 또는 배포와 동시에 값 세팅 필수).
4. **알림 폭주 vs 과거 처리 알림**(UX·사용자 강조): 컷오프로 과거 자동 백필을 막으면 알림 폭주 해소. **추가로 과거 수동 처리(지급완료 기록/정산대기 추가)는 어떤 알림도 발송하지 않음**(사용자 명시 2026-07-09). `settlement_paid`·`settlement_paypal_required` 둘 다 미발송.
5. **권한·감사**(권한): 과거 처리도 `has_permission('settlement.pay','write')` 게이트 + `settlement_events` 이력(action은 신규 값 또는 create/pay 재사용). 되돌릴 수 없는 「지급완료 기록」은 확인 모달.
6. **대량 처리 부담**(UX): 과거 미등록 인증성공이 수백 건이면 관리자가 일괄 처리 필요 — 목록 + 다중선택 일괄 「지급완료 기록」/「정산대기 추가」.
7. **인플 빈 상태**(UX): 컷오프+수동처리로 과거는 관리자가 넣은 것만 인플에 노출. 인플 화면 0건 안내 유지.

---

## 확정 설계 결정 (사용자 2026-07-09)

| # | 항목 | 결정 |
|---|---|---|
| ① | 자동 백필 범위 | **인증 성공일이 도입일(컷오프) 이후**인 것만 `pending` 생성 |
| ② | 도입일 저장 | **설정 싱글톤 테이블** — 배포 시 세팅, 조정 가능. 코드 하드코딩 금지 |
| ③ | 과거 건 처리 | 정산 화면 **별도 목록**(과거 미등록 인증성공) → 관리자가 **건별/일괄** 처리 |
| ④ | 과거 처리 상태 | 건별로 **「지급완료 기록」**(이미 외부 지급) 또는 **「정산대기 추가」**(아직 안 줌) 선택 |
| ⑤ | 알림 | **과거 처리·과거분은 어떤 알림도 발송 안 함**(사용자 강조). 컷오프로 자동 알림 폭주도 해소 |
| ⑥ | 인플 노출 | 관리자가 처리해 `settlements` 행이 생긴 것만(기존 RLS로 자연 성립) |
| ⑦ | 권한·감사 | `has_permission('settlement.pay','write')` + `settlement_events` 이력. 지급완료 기록은 확인 모달 |
| ⑧ | 배포 | 정산 운영 배포 **전 필수** — dev 반영 후 정산과 함께 운영 배포 |

---

## 설계

### 마이그레이션 (2개 — 상대 순서, 번호는 개발 생성 시 확정·230번대)

**①(먼저) 도입일 설정 싱글톤 + 백필 컷오프**
- 신규 설정 테이블(싱글톤, `age_policy_settings` 패턴): 정산 도입일(`cutoff`) `timestamptz NULL` + `updated_at`/`updated_by`. RLS SELECT `has_permission('settlement.view','read')` / UPDATE `is_super_admin()`(또는 settlement.pay write).
- `backfill_settlements()` 수정: candidates에 **"인증 성공일 ≥ cutoff"** 조건 추가. cutoff NULL이면 **백필 0건**(안전측 — 값 세팅 전 폭주 방지). 인증 성공일 = 판정에 쓰인 마지막 필요 deliverable의 `reviewed_at` 최댓값을 CTE로 계산.

**②(나중) 과거 미등록 인증성공 조회 + 처리 RPC**
- 조회 RPC: `cutoff 이전 인증 성공 AND settlements 행 없음`인 응모 목록(인플·캠페인·금액·인증성공일·PayPal 유무) 반환. `has_permission('settlement.view','read')`.
- 처리 RPC: 응모 id(들) + 목표 상태(`paid` | `pending`) + 메모 → `settlements` INSERT(멱등 `application_id` UNIQUE) + `settlement_events(action='create'`, memo에 「과거 이관」 표시). **알림 INSERT 없음**(⑤). paid면 `paid_at`/`paid_by` 채움. `has_permission('settlement.pay','write')`.

### 화면 (`dev/js/admin-settlements.js`)
- 정산 페인에 **「과거 미등록」** 진입점(상태 탭 옆 별도 버튼 또는 탭). 클릭 시 조회 RPC → 목록(다중선택 체크박스).
- 일괄 처리 버튼 2종: 「선택 지급완료 기록」/「선택 정산대기 추가」. 지급완료는 확인 모달(되돌릴 수 없음). 처리 후 `refreshPane('settlements')`.
- 자동 백필(`backfillSettlements`)은 그대로 진입 시 호출되나 컷오프로 과거 제외.

### 인플 화면
- 변경 없음(`settlements` 행 있는 것만 노출 — 기존 RLS). 과거 처리분이 자동 포함.

---

## PR 분할

- **PR 1 — 백필 컷오프**: 설정 싱글톤 + `backfill_settlements` 컷오프 조건(마이그레이션 ①). 화면은 도입일 설정 UI 최소(super_admin). **이것만으로 폭주·알림은 막힘**.
- **PR 2 — 과거 수동 처리**: 조회·처리 RPC(마이그레이션 ②) + 정산 페인 「과거 미등록」 목록·일괄 처리 UI.
- 정산 운영 배포와의 순서: PR1·2를 정산 217~225와 함께(또는 직후) 운영 배포. 최소 **PR1은 정산 배포와 동시 필수**.

---

## 사용자 확인 필요

- 컷오프 도입일 값: 운영 배포일로 세팅 vs 특정일 지정 (구현은 설정 테이블로 열어둠 → 배포 시점에 확정).

---

## 구현 결과

**구현일:** 2026-07-09 (dev, `feature/settlement-cutoff`)

### PR 1 — 백필 컷오프 (마이그레이션 230·231)
- **230** `settlement_settings` 싱글톤(id=1, `cutoff_at timestamptz NULL`) + touch 트리거. RLS SELECT `has_permission('settlement.view','read')` / **UPDATE `is_super_admin()`**(도입일은 과거분 전체 좌우 스위치 — 사용자 확정으로 supabase-expert 초안 `settlement.pay`에서 최고 관리자 전용으로 강화, 연령정책 선례 일관).
- **231** `backfill_settlements()` CREATE OR REPLACE + 컷오프 조건. 인증성공일 `cert_at` = 판정에 쓰인 마지막 결과물 `reviewed_at`(가구매=영수증 / 리뷰어=영수증·채널 GREATEST, 단 any_null이면 NULL 강제 / 시딩·방문=post). `cert_at >= cutoff_at`만 자동 생성. `cutoff_at` NULL이면 0건, `cert_at` NULL(레거시)이면 제외.
- 개발 DB 적용 완료(`cutoff_at` NULL = 백필 0건 안전상태 확인).

### PR 2 — 과거 미등록 조회·처리 + 화면 (마이그레이션 232·233 + 프론트)
- **232** private 헬퍼 `_settlement_cert_candidates()`로 231 판정 로직 추출(3곳 공유 — 드리프트 차단), `backfill_settlements()` 헬퍼 위임 재정의, 조회 RPC `get_past_unregistered_settlements()`(PayPal은 `has_paypal` 불리언만). **reviewer 지적 반영**: 조회에 명시적 컷오프 필터(`cert_at < cutoff OR cert_at NULL OR cutoff NULL`) 추가 — 호출 순서 비의존(컷오프 이후 신규건이 과거 목록에 섞여 무알림 처리되는 알림 스킵 사고 차단).
- **233** `register_past_settlements(uuid[], 'paid'|'pending', memo)` — 서버 재검증(헬퍼)·멱등(ON CONFLICT)·컷오프 필터·paid면 paid_at/paid_by 세팅·`settlement_events(create)` 이력. **알림 INSERT 없음**(사용자 강조 — settlement_paid·settlement_paypal_required 둘 다 미발송).
- **화면**(`dev/js/admin-settlements.js` + `dev/admin/index.html` + `storage.js`): 정산 페인 「과거 미등록」 별도 뷰 토글(모달 아님 — 대량 대비 lazy-load 목록). 다중선택(Set)·전체선택·일괄 「선택 송금완료 기록」(확인 모달·되돌릴 수 없음)/「선택 정산대기 추가」. 상단 앰버 안내박스(처리분만 인플 노출·**알림 안 감**). 빈 상태 안내. 처리 후 `refreshPane('settlements')`. `paid` 라벨은 메인 목록과 통일해 **「송금완료」**(reviewer 지적 반영).
- 개발 DB 적용 완료(232·233).

### 초안 대비 변경 사항
- **추가**: 판정 로직 공통 헬퍼(`_settlement_cert_candidates`) — 사양서엔 "231 재사용"만 있었으나 물리적 함수 공유로 구현. 조회·처리 양쪽에 명시적 컷오프 필터(reviewer 지적).
- **달라진 것**: 도입일 UPDATE 권한을 `is_super_admin()`으로(초안 "is_super_admin 또는 settlement.pay" 중 전자). 과거 「지급완료」 → 「송금완료」로 라벨 통일.
- **미결(배포 시)**: `cutoff_at` 실제 값은 정산 운영 배포 시점에 SQL로 세팅(배포일 or 특정일).

### 배포 관계
- 마이그레이션 번호 230~233(인플루언서 추천 도구 226~229 회피). **정산 운영 배포와 함께 필수** — 정산(217~225) + 컷오프(230~233)를 함께 운영 적용하고, 그때 `settlement_settings.cutoff_at`를 세팅해야 과거 폭주가 안 난다.
