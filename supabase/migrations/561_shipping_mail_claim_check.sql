-- ============================================================
-- 561_shipping_mail_claim_check.sql   (번호는 dev 병합 직전 origin/dev·열린 병합 요청과 다시 대조 — 겹치면 파일 이름만 바꾼다)
-- 2026-10-20 · 개발서버만(운영은 브랜드 묶음 출시 날 L1 — 557 뒤)
--
-- 작업표 docs/specs/2026-10-19-brand-seeding-shipping-list-breakdown.md 「조각 S7」 · 557 머리말 [L14](알려진 작은 틈)
--   선행: 557(service_claim_shipping_mail · service_mark_shipping_mail_sent)
--
-- 하는 일
--   ① service_claim_shipping_mail — 557 베이스 CREATE OR REPLACE(인자·반환 그대로 — 권한 보존). 응답에 칸 넷을 더한다:
--      claimed_at(선점 시각 — 결과 보고 때 그대로 돌려준다) · delivered_on·deadline(일본 날짜 — 전달한 날, 그 + 3일 D14) ·
--      row_count(그 순간 받는 사람 수 = 지금 승인인 줄, 감사용 제외)
--   ② service_mark_shipping_mail_sent — 인자를 하나 늘린다(p_claimed_at). 선점 시각이 같을 때만 결과를 적는다.
--      🔴 이유: 15분 넘은 선점은 다른 실행이 다시 잡는다(557 [L10]). 앞 실행이 늦게 「실패」를 보고하면 새 실행의 선점까지 풀려
--         같은 메일이 또 나갈 수 있었다(557 [L14]). 시각을 대조하면 남의 선점은 건드리지 못한다.
--      옛 2인자 판은 지운다(부르는 곳이 아직 없다 — 서버 함수 notify-brand-shipping-list 가 이 파일과 같은 병합 요청에서 처음 부른다).
--      두 판을 남기면 서버 함수가 인자 둘로 부를 때 옛 판이 조용히 불린다.
--
-- 롤백: DROP FUNCTION IF EXISTS public.service_mark_shipping_mail_sent(uuid, boolean, timestamptz);
--       그다음 557 의 「7. 서비스 전용」 블록 둘과 그 권한 줄(부여·회수)을 다시 실행한다. 서버 함수부터 되돌린다.
-- 편집기 경고: DROP 이 있다(옛 2인자 판 — 위 ②).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.service_claim_shipping_mail(p_campaign_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  c            public.campaigns%ROWTYPE;
  v_claimed    timestamptz;
  v_delivered  timestamptz;
  v_on         date;
BEGIN
  UPDATE public.campaign_shipping_lists s
     SET mail_claimed_at = clock_timestamp()
   WHERE s.campaign_id = p_campaign_id
     AND s.delivered_at IS NOT NULL
     AND s.mail_sent_at IS NULL
     AND (s.mail_claimed_at IS NULL OR s.mail_claimed_at < now() - interval '15 minutes')
  RETURNING s.mail_claimed_at, s.delivered_at INTO v_claimed, v_delivered;
  IF v_claimed IS NULL THEN
    RETURN NULL;   -- 이미 선점·이미 보냄·전달 전
  END IF;

  v_on := (v_delivered AT TIME ZONE 'Asia/Tokyo')::date;
  SELECT * INTO c FROM public.campaigns WHERE id = p_campaign_id;
  RETURN jsonb_build_object(
    'campaign_id',  c.id,
    'campaign_no',  c.campaign_no,
    'product',      COALESCE(NULLIF(btrim(c.product_ko), ''), NULLIF(btrim(c.product), ''), c.title),
    'brand_id',     c.brand_id,
    'brand_name',   (SELECT b.name FROM public.brands b WHERE b.id = c.brand_id),
    'recipients',   CASE WHEN c.brand_id IS NULL THEN '[]'::jsonb ELSE public._brand_mailable_accounts(c.brand_id) END,
    'claimed_at',   v_claimed,
    'delivered_on', to_char(v_on, 'YYYY/MM/DD'),
    'deadline',     to_char(v_on + 3, 'YYYY/MM/DD'),
    'row_count',    (SELECT count(*) FROM public.campaign_shipments sh
                       JOIN public.applications a ON a.id = sh.application_id AND a.status = 'approved'
                       JOIN public.influencers i  ON i.id = a.user_id AND i.is_audit = false
                      WHERE sh.campaign_id = p_campaign_id)
  );
END;
$$;

COMMENT ON FUNCTION public.service_claim_shipping_mail(uuid) IS
  '[557 → 561] 전달 알림 메일 선점(service_role 전용) — 성공이면 {받는 사람·제품·claimed_at·delivered_on·deadline·row_count}, '
  '이미 선점·보냄·전달 전이면 NULL. 15분 넘은 선점은 다시 잡는다. 결과 보고 때 claimed_at 을 그대로 돌려준다.';

-- ② 결과 보고 — 선점 시각 대조
DROP FUNCTION IF EXISTS public.service_mark_shipping_mail_sent(uuid, boolean);

CREATE OR REPLACE FUNCTION public.service_mark_shipping_mail_sent(p_campaign_id uuid, p_ok boolean, p_claimed_at timestamptz)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_n integer;
BEGIN
  IF COALESCE(p_ok, false) THEN
    UPDATE public.campaign_shipping_lists SET mail_sent_at = now()
     WHERE campaign_id = p_campaign_id AND mail_sent_at IS NULL AND mail_claimed_at = p_claimed_at;
  ELSE
    UPDATE public.campaign_shipping_lists SET mail_claimed_at = NULL   -- 실패면 내 선점만 되돌린다
     WHERE campaign_id = p_campaign_id AND mail_sent_at IS NULL AND mail_claimed_at = p_claimed_at;
  END IF;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n > 0;   -- false = 내 선점이 아니다(다른 실행이 다시 잡았거나 이미 보냄)
END;
$$;

COMMENT ON FUNCTION public.service_mark_shipping_mail_sent(uuid, boolean, timestamptz) IS
  '[561] 전달 알림 메일 결과(service_role 전용) — 선점 시각이 같을 때만: 성공이면 mail_sent_at, 실패면 선점 되돌림. 적었으면 true.';

GRANT  EXECUTE ON FUNCTION public.service_mark_shipping_mail_sent(uuid, boolean, timestamptz) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public.service_mark_shipping_mail_sent(uuid, boolean, timestamptz) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.service_mark_shipping_mail_sent(uuid, boolean, timestamptz) FROM anon, authenticated;

COMMIT;

-- ============================================================
-- 적용 뒤 확인 (개발서버)
-- ============================================================
-- [1] 권한 — 기대: 둘 다 anon/authenticated false · service_role true · 옛 2인자 판 없음
--   SELECT p.proname, pg_get_function_identity_arguments(p.oid), has_function_privilege('anon',p.oid,'EXECUTE'),
--          has_function_privilege('authenticated',p.oid,'EXECUTE'), has_function_privilege('service_role',p.oid,'EXECUTE')
--     FROM pg_proc p WHERE p.proname IN ('service_claim_shipping_mail','service_mark_shipping_mail_sent');
-- [2] 되돌리는 블록: 전달 표시 → 선점(claimed_at) → 남의 시각으로 실패 보고 = false·선점 그대로 → 내 시각으로 실패 = true·풀림
--     → 다시 선점 → 성공 보고 = true → 다시 선점 = NULL
