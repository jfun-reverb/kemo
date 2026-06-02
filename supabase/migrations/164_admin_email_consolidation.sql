-- ════════════════════════════════════════════════════════════════════
-- migration 164: 관리자 메일 수신 항목 통합
--   application_cancel + application_received → daily_digest 단일 항목
-- ════════════════════════════════════════════════════════════════════
--
-- 사양서: docs/specs/2026-06-02-admin-email-consolidation.md
--
-- 배경:
--   notify-admin-daily-digest 는 4섹션을 1통으로 묶어 발송한다.
--   그런데 수신 on/off 스위치가 application_cancel / application_received
--   두 항목으로 나뉘어 있어 관리자 메일 설정 화면에서 동일 메일을
--   두 곳에서 제어하는 혼란이 있었다.
--   (실제로 둘 중 하나만 ON 이어도 통합 메일 전체 4섹션이 발송됨)
--   → 단일 항목 'daily_digest'("일일 통합 메일")로 통합한다.
--
-- 변경 요약:
--   [1] lookup 'daily_digest' 신규 추가 (sort_order=20)
--   [2] 구독 이전: 기존 두 항목 중 하나라도 ON 이던 관리자 → daily_digest ON
--       (ON CONFLICT DO UPDATE — 기존 daily_digest=false 행도 켜짐 보장)
--   [3] 기존 두 mail_kind 구독 행 subscribed=false 정리 (칩 잔존 방지)
--   [4] 기존 두 lookup active=false (soft 비활성화, 행 보존)
--   [5] 죽은 로그 테이블 2개 COMMENT deprecated 표기 (보존)
--
-- 멱등: 재실행 안전 (ON CONFLICT DO UPDATE / UPDATE WHERE)
--
-- 롤백 방법 (롤백은 "누가 원래 어떤 항목을 ON 이었는가"를 정확히 복원 불가 — 비가역):
--   -- lookup 비활성화 원복
--   UPDATE public.lookup_values SET active=true
--    WHERE kind='admin_email_kind' AND code IN ('application_cancel','application_received');
--   UPDATE public.lookup_values SET active=false
--    WHERE kind='admin_email_kind' AND code='daily_digest';
--   -- (구독 행 원복 필요 시 마이그레이션 130 의 시드 INSERT 문을 재실행)
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── [1] 신규 lookup 'daily_digest' ────────────────────────────────
-- sort_order=20: 기존 brand_notify(10) 바로 다음, campaign_promo(40) 앞
INSERT INTO public.lookup_values (kind, code, name_ko, name_ja, sort_order, active)
VALUES (
  'admin_email_kind',
  'daily_digest',
  '일일 통합 메일',
  '日次まとめメール',
  20,
  true
)
ON CONFLICT (kind, code) DO UPDATE
  SET name_ko    = EXCLUDED.name_ko,
      name_ja    = EXCLUDED.name_ja,
      sort_order = EXCLUDED.sort_order,
      active     = true;

-- ── [2] 구독 이전: 하나라도 ON 이던 관리자 → daily_digest ON ───────
-- DISTINCT admin_id: 두 항목 모두 ON 이어도 1행만 삽입
-- ON CONFLICT DO UPDATE SET subscribed=true:
--   daily_digest 행이 이미 있어도(false 포함) 반드시 true 로 갱신
INSERT INTO public.admin_email_subscriptions (admin_id, mail_kind, subscribed)
SELECT DISTINCT s.admin_id, 'daily_digest', true
  FROM public.admin_email_subscriptions s
 WHERE s.mail_kind IN ('application_cancel', 'application_received')
   AND s.subscribed = true
ON CONFLICT (admin_id, mail_kind) DO UPDATE
  SET subscribed  = true,
      updated_at  = now();

-- ── [3] 기존 두 mail_kind 구독 행 정리 (칩 잔존 방지) ──────────────
-- DELETE 대신 UPDATE: 명시적 끄기 흔적 보존
UPDATE public.admin_email_subscriptions
   SET subscribed  = false,
       updated_at  = now()
 WHERE mail_kind IN ('application_cancel', 'application_received')
   AND subscribed  = true;

-- ── [4] 기존 두 lookup active=false (soft 비활성화) ─────────────────
-- 행 보존: 기존 참조·이력용으로 남겨둠
UPDATE public.lookup_values
   SET active = false
 WHERE kind = 'admin_email_kind'
   AND code IN ('application_cancel', 'application_received');

-- ── [5] 죽은 로그 테이블 deprecated 표기 (보존) ──────────────────────
-- 두 테이블을 사용하던 Edge Function 은 cron 이 해제된 상태이며
-- 이번 통합으로 더 이상 호출되지 않는다. 테이블 자체는 과거 이력 보존용.
COMMENT ON TABLE public.application_cancel_digest_runs IS
  'DEPRECATED (2026-06-02, migration 164). '
  'notify-application-cancelled-daily Edge Function 전용 발송 로그. '
  'cron 해제 및 기능 통합(notify-admin-daily-digest)으로 미사용. '
  '과거 이력 보존용으로 행 보존.';

COMMENT ON TABLE public.application_received_admin_digest_runs IS
  'DEPRECATED (2026-06-02, migration 164). '
  'notify-application-received-admin-daily Edge Function 전용 발송 로그. '
  'cron 미등록 및 기능 통합(notify-admin-daily-digest)으로 미사용. '
  '과거 이력 보존용으로 행 보존.';

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- 검증 쿼리 (개발/운영 SQL Editor에서 마이그레이션 직후 실행)
-- ════════════════════════════════════════════════════════════════════

-- [검증 1] daily_digest lookup 생성 + 기존 두 항목 비활성화 확인
-- 기대값: daily_digest active=true, application_cancel/received active=false
/*
SELECT code, name_ko, sort_order, active
  FROM public.lookup_values
 WHERE kind = 'admin_email_kind'
 ORDER BY sort_order;
*/

-- [검증 2] 구독 이전 결과 — daily_digest ON 인 관리자 수 확인
-- 기대값: 마이그레이션 전 application_cancel OR application_received 가 subscribed=true 이던 관리자 수와 일치
/*
SELECT mail_kind, COUNT(*) AS cnt
  FROM public.admin_email_subscriptions
 WHERE mail_kind IN ('application_cancel', 'application_received', 'daily_digest')
   AND subscribed = true
 GROUP BY mail_kind
 ORDER BY mail_kind;
-- 기대: daily_digest 행만 N건, 나머지 0건
*/

-- [검증 3] 로그 테이블 COMMENT 확인
/*
SELECT relname, obj_description(oid, 'pg_class') AS comment
  FROM pg_class
 WHERE relname IN ('application_cancel_digest_runs', 'application_received_admin_digest_runs')
 ORDER BY relname;
*/

-- ════════════════════════════════════════════════════════════════════
-- 스모크 호출 (검증 완료 후 실행 — notify-admin-daily-digest 수신자 확인)
-- ════════════════════════════════════════════════════════════════════
-- get_subscribed_admin_emails('daily_digest') 를 직접 호출해
-- 구독자 이메일 목록이 정상적으로 반환되는지 확인한다.
/*
SELECT email
  FROM public.get_subscribed_admin_emails('daily_digest');
-- 기대: 마이그레이션 전 두 항목 구독자의 합집합(DISTINCT)
*/
