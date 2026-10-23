-- ============================================================
-- 592_shipping_admin_cancelled_rows.sql
-- 2026-10-23 — 관리자 배송 리스트의 「취소됨」 줄에 우편번호·주소·전화와 선정이 풀린 날을 보인다(피그마 a05-09a)
--   사용자 결정(2026-10-23, 기획 세션 전달): 「Figma대로 보이기」 — 관리자에게만. 브랜드 응답은 그대로 비운다
--   사양서 docs/specs/2026-10-19-brand-seeding-shipping-list.md 결정 7(문장 갱신은 기획) · 작업표 …-breakdown.md
--
-- 고치는 것(베이스 = 557 — 유일한 정의. 583 은 이 함수를 부르기만 한다)
--   _shipping_rows_payload(uuid, boolean, boolean) — 두 군데만, 그 밖은 557 과 글자 그대로
--     1) 우편번호·주소·전화 비우기 조건
--          557: c.st = 'cancelled' OR p_mask_pii
--          592: p_mask_pii OR (c.st = 'cancelled' AND (NOT p_admin OR c.withdrawn))
--        · p_admin = false(브랜드 요약·목록·내려받기 — 583 _shipping_brand_rows_logged·557 요약)는 557 과 같다 — 취소 줄은 계속 비움
--        · 탈퇴 표시 줄(withdrawn)은 관리자에게도 비운다(파기 대상 — 다시 보이지 않게)
--        · 민감정보 권한이 없는 등급(p_mask_pii)은 그대로 비운다
--     2) 관리자 칸(p_admin)에 'cancelled_on'(YYYY-MM-DD, 일본 날짜) 추가 — 본인 취소 = applications.cancelled_at,
--        반려·대기로 되돌림 = application_events 에서 승인(from_status=approved)에서 바뀐 마지막 시각. 둘 다 없으면 NULL
--   · CREATE OR REPLACE — 실행 권한(557 끝: postgres 만 · PUBLIC 회수) 그대로. 인자·반환 형 같음
--   · 부르는 곳: 557 admin_get_campaign_shipping(p_admin=true — 유일) · 557 get_my_brand_shipping_summary · 583 _shipping_brand_rows_logged(둘 다 false)
--   · 화면: dev/js/admin-shipping.js(같은 PR) — 칸이 없는 서버(592 전)에서는 날짜 없이 그린다
--
-- 되돌리기: 557 의 _shipping_rows_payload 정의(CREATE OR REPLACE)를 다시 실행 — 인자가 같아 권한 유지
-- 🔴 운영 순서: 557 뒤에만(배송 묶음 L1 과 함께). 화면보다 먼저 넣어도 해는 없다(새 칸을 안 읽을 뿐)
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._shipping_rows_payload(p_campaign_id uuid, p_mask_pii boolean, p_admin boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_today     date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  v_delivered timestamptz;
  v_rows      jsonb;
BEGIN
  SELECT s.delivered_at INTO v_delivered
    FROM public.campaign_shipping_lists s WHERE s.campaign_id = p_campaign_id;

  WITH base AS (
    -- 전달 뒤: 줄이 있는 응모 전부 / 전달 전: 지금 승인인 응모(줄이 없어도)
    SELECT a.id AS application_id, a.user_id, a.status AS app_status, a.address AS app_address, a.user_name,
           a.cancel_reason_code, a.cancel_reason, a.cancelled_at, a.reviewed_at, a.created_at AS applied_at,
           i.name_kanji, i.name AS inf_name, i.name_kana, i.phone, i.email, i.ig, i.x, i.tiktok, i.youtube,
           sh.id AS ship_id, sh.row_no, sh.added_on, sh.added_at, sh.carrier_code, sh.carrier_other, sh.tracking_no,
           sh.shipped_on, sh.updated_by, sh.updated_by_kind, sh.updated_at, sh.version
      FROM public.applications a
      JOIN public.influencers i ON i.id = a.user_id AND i.is_audit = false
      LEFT JOIN public.campaign_shipments sh ON sh.application_id = a.id
     WHERE a.campaign_id = p_campaign_id
       AND ( (v_delivered IS NOT NULL AND sh.id IS NOT NULL)
          OR (v_delivered IS NULL AND a.status = 'approved') )
  ), calc AS (
    SELECT b.*,
           (b.email LIKE '%@deleted.reverbjp.invalid'
             OR (NULLIF(btrim(b.name_kanji), '') IS NULL AND NULLIF(btrim(b.inf_name), '') IS NULL AND NULLIF(btrim(b.user_name), '') IS NULL)) AS withdrawn,
           COALESCE(NULLIF(btrim(b.name_kanji), ''), NULLIF(btrim(b.inf_name), ''), NULLIF(btrim(b.user_name), '')) AS disp_name,
           substring(b.app_address FROM '^〒\s*([0-9０-９\-－]{7,8})\s+') AS zip_part,
           CASE
             WHEN v_delivered IS NOT NULL AND b.app_status IS DISTINCT FROM 'approved' THEN 'cancelled'
             WHEN b.tracking_no IS NOT NULL THEN 'shipped'
             WHEN v_delivered IS NOT NULL AND b.added_on IS NOT NULL AND v_today > b.added_on + 3 THEN 'overdue'
             ELSE 'pending'
           END AS st
      FROM base b
  )
  SELECT COALESCE(jsonb_agg(
           jsonb_build_object(
             'row_no',          c.row_no,
             'name',            CASE WHEN c.withdrawn THEN NULL ELSE c.disp_name END,
             'name_kana',       CASE WHEN c.withdrawn THEN NULL ELSE NULLIF(btrim(c.name_kana), '') END,
             'withdrawn',       c.withdrawn,
             'postal_code',     CASE WHEN p_mask_pii OR (c.st = 'cancelled' AND (NOT p_admin OR c.withdrawn)) THEN NULL ELSE c.zip_part END,
             'address',         CASE WHEN p_mask_pii OR (c.st = 'cancelled' AND (NOT p_admin OR c.withdrawn)) THEN NULL
                                     WHEN c.zip_part IS NOT NULL THEN btrim(regexp_replace(c.app_address, '^〒\s*[0-9０-９\-－]{7,8}\s+', ''))
                                     ELSE NULLIF(btrim(c.app_address), '') END,
             'phone',           CASE WHEN p_mask_pii OR (c.st = 'cancelled' AND (NOT p_admin OR c.withdrawn)) THEN NULL ELSE NULLIF(btrim(c.phone), '') END,
             'carrier_code',    c.carrier_code,
             'carrier_name',    COALESCE((SELECT lv.name_ko FROM public.lookup_values lv
                                           WHERE lv.kind = 'shipping_carrier' AND lv.code = c.carrier_code), c.carrier_other),
             'carrier_active',  CASE WHEN c.carrier_code IS NULL THEN NULL
                                     ELSE EXISTS (SELECT 1 FROM public.lookup_values lv
                                                   WHERE lv.kind = 'shipping_carrier' AND lv.code = c.carrier_code AND lv.active) END,
             'carrier_other',   c.carrier_other,
             'tracking_no',     c.tracking_no,
             'shipped_on',      c.shipped_on,
             'status',          c.st,
             'added_on',        c.added_on,
             'due_on',          CASE WHEN v_delivered IS NOT NULL AND c.added_on IS NOT NULL THEN c.added_on + 3 END,
             'is_new',          (v_delivered IS NOT NULL AND c.added_at IS NOT NULL AND c.added_at > v_delivered
                                 AND v_today < ((c.added_at AT TIME ZONE 'Asia/Tokyo')::date + 7)),
             'updated_by_kind', c.updated_by_kind,
             'version',         c.version
           )
           || CASE WHEN p_admin THEN jsonb_build_object(
                'application_id',     c.application_id,
                'influencer_id',      c.user_id,
                'app_status',         c.app_status,
                'cancel_reason_code', c.cancel_reason_code,
                'cancel_reason',      c.cancel_reason,
                -- 592 — 선정이 풀린 날(일본 날짜): 본인 취소 = cancelled_at / 반려·대기로 되돌림 = 승인에서 바뀐 마지막 기록
                'cancelled_on',       CASE WHEN c.st = 'cancelled' THEN to_char((COALESCE(
                                          CASE WHEN c.app_status = 'cancelled' THEN c.cancelled_at END,
                                          (SELECT max(e.created_at) FROM public.application_events e
                                            WHERE e.application_id = c.application_id AND e.from_status = 'approved'))
                                        AT TIME ZONE 'Asia/Tokyo')::date, 'YYYY-MM-DD') END,
                'sns',                jsonb_build_object('ig', c.ig, 'x', c.x, 'tiktok', c.tiktok, 'youtube', c.youtube),
                'updated_at',         c.updated_at,
                'updated_by_name',    CASE c.updated_by_kind
                                        WHEN 'admin' THEN (SELECT COALESCE(NULLIF(btrim(ad.name), ''), ad.email) FROM public.admins ad WHERE ad.auth_id = c.updated_by LIMIT 1)
                                        WHEN 'brand' THEN (SELECT COALESCE(NULLIF(btrim(ba.name), ''), ba.email) FROM public.brand_accounts ba WHERE ba.auth_id = c.updated_by)
                                      END
              ) ELSE '{}'::jsonb END
           ORDER BY c.row_no NULLS LAST, c.reviewed_at NULLS LAST, c.applied_at, c.application_id), '[]'::jsonb)
    INTO v_rows
    FROM calc c;

  RETURN jsonb_build_object(
    'delivered_at', v_delivered,
    'today',        to_char(v_today, 'YYYY-MM-DD'),
    'counts',       jsonb_build_object(
                      'total',     jsonb_array_length(v_rows),
                      'shipped',   (SELECT count(*) FROM jsonb_array_elements(v_rows) r WHERE r->>'status' = 'shipped'),
                      'pending',   (SELECT count(*) FROM jsonb_array_elements(v_rows) r WHERE r->>'status' = 'pending'),
                      'overdue',   (SELECT count(*) FROM jsonb_array_elements(v_rows) r WHERE r->>'status' = 'overdue'),
                      'cancelled', (SELECT count(*) FROM jsonb_array_elements(v_rows) r WHERE r->>'status' = 'cancelled')),
    'rows',         v_rows
  );
END;
$$;

COMMENT ON FUNCTION public._shipping_rows_payload(uuid, boolean, boolean) IS
  '[557·S2 → 592] 배송 리스트 줄 단위 판정 한 곳 — 전달 뒤 = 줄 있는 응모(승인 아님은 cancelled) / 전달 전 = 지금 승인인 응모. '
  '취소 줄 주소·전화: 브랜드(p_admin=false)·탈퇴 표시 줄은 NULL, 관리자는 보인다(592). '
  '상태·기한·「새로 추가」·우편번호 떼기·탈퇴 표시를 서버가 정한다. p_admin 이면 응모 번호·SNS·취소 사유·풀린 날·입력한 사람을 더한다. 내부 전용.';

INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '592', '592_shipping_admin_cancelled_rows.sql');
COMMIT;
