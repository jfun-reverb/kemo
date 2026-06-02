# 관리자 메일 수신 항목 통합 (application_cancel + application_received → daily_digest)
**작성일:** 2026-06-02
**작성:** reverb-planner (기획)
**방향 확정:** 사용자 — "합치기 + 죽은 코드까지 제거"

## 현재 상태 (작성일 2026-06-02 기준, planning.md 규칙 A)

### 관련 코드·DB·UI 진입점
- **lookup `admin_email_kind` 현재 4항목**:
  | code | name_ko / name_ja | sort | 추가 | 발송 주체 | 처리 |
  |---|---|---|---|---|---|
  | `brand_notify` | 브랜드 서베이 접수 / ブランドサーベイ受付 | 10 | 마이그레이션 103 | `notify-brand-application` (INSERT 즉시) | **독립·유지** |
  | `application_cancel` | 응모 취소 알림 / 応募取消通知 | 20 | 마이그레이션 103 | (지금은) `notify-admin-daily-digest` 수신 스위치 | **흡수 대상** |
  | `application_received` | 캠페인 신청 접수 / キャンペーン応募受付 | 30 | 마이그레이션 130 | (지금은) `notify-admin-daily-digest` 수신 스위치 | **흡수 대상** |
  | `campaign_promo` | 캠페인 홍보 메일 / キャンペーン宣伝メール | 40 | 마이그레이션 152 | `notify-campaign-promo-digest` (주2회) | **독립·유지** |
- **실제 도는 일일 통합 함수**: `supabase/functions/notify-admin-daily-digest/index.ts`. 수신자 = `resolveAdminEmails()` (index.ts 263~291): `get_subscribed_admin_emails('application_cancel')` ∪ `get_subscribed_admin_emails('application_received')` ∪ env `NOTIFY_ADMIN_EMAILS`. **두 mail_kind가 같은 통합 메일 1통의 수신 스위치로 중복** → 둘 중 하나만 ON 이어도 통합 메일 전체(4섹션)가 발송됨.
- **헬퍼 함수**: `get_subscribed_admin_emails(p_mail_kind text)` (마이그레이션 103, SECURITY DEFINER, search_path 고정). `subscribed=true` 행만 조인.
- **구독 테이블**: `admin_email_subscriptions (admin_id, mail_kind)` UNIQUE, `subscribed boolean`. RLS SELECT 관리자 전체 / CUD 본인 또는 super_admin.
- **화면**: `dev/js/admin-accounts.js`
  - 모달 체크박스 목록은 `fetchAdminEmailKinds()`(storage.js 2363) → `lookup_values(kind='admin_email_kind', active=true)` order by sort_order 로 **완전 동적 렌더**. 하드코딩된 mail_kind 분기 **없음**.
  - 단 `_adminEmailKindDesc(code)` (admin-accounts.js 151~157)에 `brand_notify`·`application_cancel` 2개 code 의 **보조 설명 카피만 하드코딩**. (없으면 빈 문자열 — 동작엔 지장 없으나 신규 `daily_digest` 설명 추가 권장)
  - 목록 칩: `fetchAdminEmailSubscriptions()` (storage.js 2346) — **`subscribed=true` 인 모든 행을 lookup active 여부와 무관하게 가져옴**. ⚠️ 후술 충돌점.
  - 저장: `saveAdminEmailSubscriptions(adminId, subscribedKinds, allKinds)` (storage.js 2425) — `allKinds`(현재 active lookup 전체)에 대해서만 행을 UPSERT. **비활성 lookup 행은 건드리지 않음**.
- **죽은 Edge Function 2개** (cron 없음 = 호출 안 됨, 코드만 잔존):
  - `supabase/functions/notify-application-cancelled-daily/` — 로그 테이블 `application_cancel_digest_runs` (마이그레이션 113) 사용
  - `supabase/functions/notify-application-received-admin-daily/` — 로그 테이블 `application_received_admin_digest_runs` (마이그레이션 130) 사용
- **cron 상태** (2026-05-18 통합 사양서 §13·§14-3 확정):
  - `application-cancel-daily-digest` cron → **해제됨** (관리자 통합으로 흡수)
  - `notify-application-received-admin-daily` cron → **마이그레이션 130 시점부터 양 DB 모두 미등록**
  - 가동 중: `notify-admin-daily-digest` cron + `notify-influencer-daily-digest` cron
- **마이그레이션 최신 163**. 이번 작업은 **164** 사용. (에러 수집 마이그레이션은 다른 브랜치에서 165로 재배치 예정)

### 이 제안과 충돌 가능성 있는 기존 동작
1. **칩 표시 잔존 (가장 중요)** — `fetchAdminEmailSubscriptions()`는 lookup active 무관하게 `subscribed=true` 행을 칩으로 노출한다. lookup 만 비활성화하고 구독 행을 안 치우면 관리자 계정 목록 칩에 라벨 매핑 안 되는 code(또는 깨진 칩)가 계속 보인다. → **마이그레이션 164에서 기존 두 mail_kind 구독 행을 반드시 정리(subscribed=false)** 해야 화면이 깨끗해진다.
2. **저장 시 stale 행 미정리** — `saveAdminEmailSubscriptions`는 active lookup(`allKinds`)만 UPSERT 하므로, 비활성 lookup 의 기존 행은 영원히 `subscribed=true` 로 남는다. 위 1번과 동일 뿌리.
3. **env NOTIFY_ADMIN_EMAILS** — `resolveAdminEmails()`는 lookup·구독과 무관하게 env 관리자를 **항상** 합집합에 포함. 통합 후에도 동일하게 유지되어야 한다(수신 누락 0 보장).

### 미해결 백로그·관련 작업
- `docs/specs/2026-05-18-mail-pipeline-consolidation.md` §6-1 — "deprecated Edge Function 2종 정리는 운영 2주 안정화 후 별도 PR". **본 작업이 그 미처리 백로그를 닫는다.** (통합 가동 2026-05-18~19, 2주 안정화 충족)

## 의심·경우의 수 (planning.md 규칙 B — 반대론자)

### 1. 깨질 수 있는 경우의 수

**[데이터] ① 한쪽만 구독한 관리자 이전 누락/중복**
관리자별로 두 항목을 각각 ON/OFF 가능. 통합 규칙 "둘 중 하나라도 ON → daily_digest ON". 이전 쿼리는 `OR`(distinct admin_id) + `(admin_id, daily_digest)` UNIQUE 충돌을 `ON CONFLICT DO UPDATE SET subscribed=true` 로 흡수해야 함. `DO NOTHING` 이면 기존 daily_digest=false 행이 우연히 있을 때 안 켜짐 → **DO UPDATE 필수**.

**[데이터] ② 기존 구독 행 미정리로 칩 깨짐 (충돌점 1번)**
이전 후 두 mail_kind 구독 행을 **반드시 정리**(권장: subscribed=false UPDATE — DELETE 보다 명시적 끄기 흔적 보존).

**[기술] ③ 죽은 함수 운영 잔존**
Edge Function 은 repo 삭제만으론 운영에서 안 사라짐. 배포본이 Dashboard 에 남아 URL 직접 호출 시 실행 가능. → repo 삭제 + **양 서버 `supabase functions delete` 수동 절차 필요**. (cron 없어 자동 호출 위험 0)

**[기술] ④ resolveAdminEmails 부분 실패 폴백 회귀**
2 RPC → 1 RPC 로 줄일 때, 단일 RPC error 시에도 빈 배열 + env 폴백 처리 유지 확인.

**[UX] ⑤ (필수) 관리자 의도 손실 — "취소만 받고 접수는 끄기"가 원래 불가능했음**
통합 메일은 1통에 4섹션. **현재도 섹션별 수신 선택 불가**(둘 중 하나만 켜도 통합 메일 전체). 즉 "응모취소만 받기"는 이미 작동 안 하던 환상 옵션. 통합은 UI 를 정직하게 만드는 개선. 단 daily_digest 보조 설명에 **"신청 접수·응모 취소·결과물 제출·재처리를 하루 1통으로 묶어 보냅니다"** 명시. 둘 다 OFF 였던 관리자는 통합 후 daily_digest OFF 유지(이전 쿼리 "하나라도 ON" 조건이라 제외) → 의도 보존.

**[권한] ⑥ campaign_manager** — 통합 후 권한 변화 없음(본인 daily_digest 토글 가능). 충돌 없음.

### 2. 현재 구현 충돌점
- **충돌 있음 (2건, 같은 뿌리)**: `fetchAdminEmailSubscriptions`가 active 무관 칩 렌더 + `saveAdminEmailSubscriptions`가 active lookup 만 UPSERT. → **마이그레이션 164에서 기존 구독 행 subscribed=false 정리하면 화면 자동 정상화**(코드 수정 불필요).
- 그 외 영역(brand_notify·campaign_promo 발송, RLS, env 폴백): **확인 완료, 충돌 없음**.

### 3. 의도 모호점
- "죽은 코드 제거" 범위 = ① repo 디렉토리 2개 삭제 ② 양 서버 functions delete ③ 로그 테이블 2개 DROP vs 보존 ④ 카탈로그 카드 정리. → ②③④ 사용자 확인.
- lookup 비활성화 vs 완전 삭제 → 권고: soft(active=false).
- 로그 테이블 보존 여부 → 권고: 보존(COMMENT deprecated 표기).

## 제안 / 설계

### 변경 요지
1. 신규 lookup `daily_digest` 1건 추가 ("일일 통합 메일").
2. 기존 `application_cancel`·`application_received` lookup 을 active=false (soft, 행 보존).
3. `admin_email_subscriptions`: 둘 중 하나라도 ON 이던 관리자를 daily_digest ON 으로 이전(멱등) → 그 후 두 mail_kind 구독 행 subscribed=false 정리.
4. `notify-admin-daily-digest`: resolveAdminEmails() 의 2 RPC → daily_digest 단일 RPC.
5. 죽은 Edge Function 2개 repo 삭제 + 양 서버 functions delete (수동).
6. 카탈로그·CLAUDE.md·문서 갱신.

### 마이그레이션 164 SQL 초안

```sql
-- 164_admin_email_consolidation.sql  (2026-06-02)
-- application_cancel + application_received → daily_digest 단일 항목
-- 멱등: 재실행 안전
BEGIN;

-- [1] 신규 lookup 'daily_digest' (sort 20)
INSERT INTO public.lookup_values (kind, code, name_ko, name_ja, sort_order, active)
VALUES ('admin_email_kind', 'daily_digest', '일일 통합 메일', '日次まとめメール', 20, true)
ON CONFLICT (kind, code) DO UPDATE
  SET name_ko=EXCLUDED.name_ko, name_ja=EXCLUDED.name_ja,
      sort_order=EXCLUDED.sort_order, active=true;

-- [2] 구독 이전: 둘 중 하나라도 ON 이던 관리자 → daily_digest ON
INSERT INTO public.admin_email_subscriptions (admin_id, mail_kind, subscribed)
SELECT DISTINCT s.admin_id, 'daily_digest', true
FROM public.admin_email_subscriptions s
WHERE s.mail_kind IN ('application_cancel','application_received') AND s.subscribed = true
ON CONFLICT (admin_id, mail_kind) DO UPDATE SET subscribed=true, updated_at=now();

-- [3] 기존 두 mail_kind 구독 행 정리 (칩 잔존 방지)
UPDATE public.admin_email_subscriptions
   SET subscribed=false, updated_at=now()
 WHERE mail_kind IN ('application_cancel','application_received') AND subscribed=true;

-- [4] 기존 두 lookup 비활성화 (soft)
UPDATE public.lookup_values SET active=false
 WHERE kind='admin_email_kind' AND code IN ('application_cancel','application_received');

-- [5] 로그 테이블 deprecated 표기 (보존 — 선택지 확정 후 확정)
COMMENT ON TABLE public.application_cancel_digest_runs IS
  'DEPRECATED (2026-06-02, migration 164). 함수 통합으로 미사용. 과거 이력 보존용.';
COMMENT ON TABLE public.application_received_admin_digest_runs IS
  'DEPRECATED (2026-06-02, migration 164). 함수 통합으로 미사용. 과거 이력 보존용.';

COMMIT;
```

검증 쿼리 / 롤백 SQL 은 기획 보고 본문 참조(롤백은 어느 쪽이 원래 ON 이었는지 정보 손실 → 사실상 비가역, 단 발송 동작은 동일하므로 실질 위험 낮음).

### Edge Function 변경
| 파일 | 변경 |
|---|---|
| `notify-admin-daily-digest/index.ts` (resolveAdminEmails 263~291) | 2 RPC → 1 RPC(`daily_digest`). 주석 갱신. env·single-RPC error 폴백 유지 |
| `notify-application-cancelled-daily/` | 디렉토리 삭제 |
| `notify-application-received-admin-daily/` | 디렉토리 삭제 |
수동 절차: 양 서버 `supabase functions delete <fn>` (운영 twofagomeizrtkwlhsuv / 개발 qysmxtipobomefudyixw) + `notify-admin-daily-digest` 양 서버 재배포.

### 화면 확인 결과
- 모달 체크박스: lookup 동적 → 자동 반영. 코드 수정 불필요.
- `_adminEmailKindDesc(code)`: daily_digest 보조 설명 한 줄 추가 권장.
- 칩: 마이그레이션 [3]으로 자동 정상화.
- **화면 코드 변경은 `_adminEmailKindDesc` 한 줄(권장)뿐.**

### 약관 판정
- **PRIVACY/TERMS 무영향** — 관리자 내부 수신 설정 명칭 변경, 개인정보 수집·처리 변화 없음.

## PR 분할
| PR | 내용 | 의존 |
|---|---|---|
| **PR 1 — 메일 항목 통합** | 마이그레이션 164 + notify-admin-daily-digest 1 RPC 화 + _adminEmailKindDesc 설명 | 없음 |
| **PR 2 — 죽은 함수 정리** | repo 디렉토리 2개 삭제 + 카탈로그 카드 제거 + 문서 정리. 양 서버 functions delete 는 수동 | PR 1 안정화 후 권장(또는 동시) |

## 사용자 확인 필요 (4가지)
- Q1 항목 처리: 비활성화(행 보존, 추천) vs 완전 삭제
- Q2 로그 테이블: 보존+deprecated 표기(추천) vs DROP
- Q3 PR 분할: 분리(추천) vs 한 PR
- Q4 명칭: "일일 통합 메일"(추천) vs 직접 입력

## 구현 결과 (개발 세션이 채울 것)
**구현일:** (미정)
**관련 커밋/PR:** (미정)
### 초안 대비 변경 사항
- 추가된 것:
- 빠진 것:
- 달라진 것:
### 구현 중 기술 결정 사항
-
