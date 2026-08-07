-- ============================================================
-- 290_deadline_reminder_review_image_kind.sql
-- 마감 안내 모집 형식 분기 수정 — 단계 2 (리뷰어형 인증샷 마감 안내 신설)
-- 사양서: docs/specs/2026-08-04-deadline-reminder-recruit-type-fix.md §설계 단계2
--
-- 배경: deadline_reminder_email_sent.kind 는 현재 ('receipt','post') 2종만
--   허용한다(마이그레이션 130). 리뷰어형(monitor)이 실제로 제출해야 하는
--   「채널별 리뷰 인증샷(review_image)」의 마감 임박 안내가 없어, 인플루언서
--   일일 다이제스트(notify-influencer-daily-digest Edge Function)에 이 종류를
--   추가한다. 값 추가만이며 기존 'receipt'·'post' 행은 영향 없음.
--
-- ⚠️ 확인 방법(재발 방지, 219 선례): supabase/migrations 전체에서
--   deadline_reminder_email_sent 의 kind CHECK 를 정의/확장한 최신 파일을
--   grep 해 현재 목록을 실측 확인한 뒤 작성함 — 130 이 최초 정의이고
--   이후 다른 마이그레이션이 이 CHECK 를 건드린 적 없음(2026-08-04 확인).
--
-- 롤백: 파일 하단 참고.
-- ============================================================

ALTER TABLE public.deadline_reminder_email_sent
  DROP CONSTRAINT IF EXISTS deadline_reminder_email_sent_kind_check;

ALTER TABLE public.deadline_reminder_email_sent
  ADD CONSTRAINT deadline_reminder_email_sent_kind_check CHECK (kind IN (
    'receipt',
    'post',
    'review_image'  -- 290 신규: 리뷰어형(monitor) 채널별 리뷰 인증샷 마감 임박 안내
  ));

COMMENT ON COLUMN public.deadline_reminder_email_sent.kind IS
  '마감 임박 안내 종류. receipt(영수증) | post(게시물, 시딩·방문형 전용) | '
  'review_image(리뷰 인증샷, 리뷰어형 전용·가구매 캠페인 제외) — 290';

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행)
-- ============================================================
/*

-- [V0] CHECK 제약 확장 확인 (3종 모두 포함돼야 함)
SELECT pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conrelid = 'public.deadline_reminder_email_sent'::regclass
  AND conname  = 'deadline_reminder_email_sent_kind_check';

-- [V1] 기존 행(receipt·post) 이 그대로 조회되는지 확인 — 값 변형 없어야 함
SELECT kind, count(*) FROM public.deadline_reminder_email_sent GROUP BY kind ORDER BY kind;

-- [V2] review_image 값으로 INSERT 가 통과하는지 스모크 테스트 (테스트 행이므로 직후 롤백)
BEGIN;
INSERT INTO public.deadline_reminder_email_sent
  (influencer_id, campaign_id, kind, d_minus, deadline_date)
VALUES
  ('00000000-0000-0000-0000-000000000000',
   (SELECT id FROM public.campaigns LIMIT 1),
   'review_image', 5, current_date);
ROLLBACK;

*/

-- ============================================================
-- 롤백 (130 버전 2종으로 복원)
-- ============================================================
-- ⚠️ 롤백 전 review_image 행이 이미 쌓였다면 먼저 삭제(또는 다른 kind로 이관)해야
--   ADD CONSTRAINT 시점에 기존 데이터가 CHECK 위반으로 막히지 않는다.
--   DELETE FROM public.deadline_reminder_email_sent WHERE kind = 'review_image';
--
-- ALTER TABLE public.deadline_reminder_email_sent
--   DROP CONSTRAINT IF EXISTS deadline_reminder_email_sent_kind_check;
-- ALTER TABLE public.deadline_reminder_email_sent
--   ADD CONSTRAINT deadline_reminder_email_sent_kind_check CHECK (kind IN ('receipt','post'));
-- COMMENT ON COLUMN public.deadline_reminder_email_sent.kind IS NULL;
