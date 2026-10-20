-- ============================================================
-- 557_shipping_functions.sql   (번호는 dev 병합 직전 origin/dev·열린 병합 요청과 다시 대조 — 겹치면 파일 이름만 바꾼다)
-- 2026-10-20 · 개발서버만(운영은 브랜드 묶음 출시 날 L1 — 554 뒤)
--
-- 작업표 docs/specs/2026-10-19-brand-seeding-shipping-list-breakdown.md 「조각 S2」 · 결정 D1·D2·D4·D6·D9·D14·D16·D22·D25·D26 · 선결 Q2
-- 사양서 docs/specs/2026-10-19-brand-seeding-shipping-list.md §4-2~§4-6
--   선행: 552(_record_brand_provision) · 554(표 둘·_shipping_campaign_lock·_shipping_provision_columns·트리거)
--
-- 하는 일 (새 함수뿐 — 적용만으로 바뀌는 기존 동작은 트리거 함수의 이름 칸 하나[L8])
--   내부
--     _shipping_brand_campaign(p_campaign_id)        브랜드 판정(547 과 같은 식) — 통과하면 캠페인 행, 아니면 NULL
--     _shipping_list_open_for_brand(p_campaign_id)   목록 단위 판정 한 곳(위 + 시딩형 + 전달됨) — D9 정지가 생기면 여기 한 줄
--     _shipping_rows_payload(p_campaign_id, p_mask_pii, p_admin)  줄 단위 판정 한 곳 → {delivered_at, today, counts, rows}
--     _shipping_check_row(...)                       송장·택배사·발송일 검사와 정리 한 곳(브랜드·관리자 저장 공용 — D1·D6)
--     _brand_mailable_accounts(p_brand_id)           메일 받을 브랜드 계정 — 🔴 notify-orient-sheet resolveBrandAccountRecipients 의 사본
--     _shipping_carriers()                           택배사 목록(활성만, 순서대로)
--     _shipping_brand_rows_logged(p_campaign_id, p_action)  브랜드 열람·내려받기 공용 본체(판정 → 줄 → 제공 기록)
--   관리자 (has_permission('shipping.manage', …))
--     admin_get_campaign_shipping · admin_deliver_shipping_list · admin_save_shipping_rows
--   브랜드 (is_my_brand — 거부는 not_found 하나)
--     get_my_brand_shipping_summary · get_my_brand_shipping_list · get_my_brand_shipping_export · save_my_brand_shipping_rows
--   서비스 전용(S7 메일)
--     service_claim_shipping_mail · service_mark_shipping_mail_sent
--   트리거 함수 _application_shipping_sync 재정의(554 베이스 — 이름 칸만 [L8])
--
-- ============================================================
-- 확인한 것 (2026-10-20, 저장소 검색)
-- ============================================================
--   [이름 충돌 없음] 위 함수 이름 — migrations·dev/·supabase/functions 0건.
--   [브랜드 판정 = 547 get_my_brand_campaign] deleted_at IS NULL · status IN (scheduled,active,closed,ended) · brand_id 있음 · is_my_brand(brand_id).
--   [종료 판정 = 543 _brand_campaign_view_status] 저장값이 아니라 일본 날짜로 다시 판정한 값 'ended' (D2).
--   [메일 받는 사람 = notify-orient-sheet resolveBrandAccountRecipients] 활성 브랜드 · 활성 연결 · password_set_at 있음 · 대표 먼저(같으면 연결 순) ·
--     이메일 소문자 중복 제거. 🔴 그 식을 바꾸면 여기도(이 함수 머리 주석에도 적었다).
--   [회원 칸] influencers.name_kanji·name·name_kana·phone·ig·x·tiktok·youtube·email · applications.address·user_name·status·cancel_reason_code·cancel_reason.
--     관리자 화면의 이름 표기 = name_kanji → name(admin-core.js·admin-excel.js) — 여기도 같은 순서 + 응모 때 이름(user_name).
--   [탈퇴 확정 표시 = 520] 회원 email 을 'withdrawn+…@deleted.reverbjp.invalid' 로 바꾸고 이름 칸을 비운다(D25).
--   [이름 전파] 새 함수는 applications·influencers 를 정의자 권한 안에서만 읽는다 — 화면(storage.js·자립형 화면)의 조회는 바꾸지 않는다.
--
-- ============================================================
-- 설계 판단 (작업표가 비워 둔 곳 · 달라진 곳)
-- ============================================================
--   [L1] _shipping_rows_payload 에 세 번째 인자 p_admin 을 더했다(작업표는 둘). 관리자 줄만 응모 번호·SNS 계정·응모 상태·취소 사유·입력한 사람
--        이름을 싣는다 — 브랜드 응답에 회원 번호·SNS 가 섞이지 않게 같은 함수 안에서 가른다(판정 사본을 만들지 않으려고).
--   [L2] 줄 상태(전달 뒤): 응모가 승인 아님 → cancelled · 송장 있음 → shipped · 오늘 > 들어간 날 + 3일 → overdue · 그 밖 → pending(D14, 기한일 due_on 도 싣는다).
--        전달 전: pending / shipped 둘만. 「새로 추가」 is_new = 전달 뒤 + added_at > delivered_at + 오늘 < added_at 일본 날짜 + 7일(그날 포함 7일, D4).
--   [L3] 우편번호: 주소가 ^〒\s*([0-9０-９\-－]{7,8})\s+ 로 시작할 때만 떼어 postal_code 에, 나머지를 address 에. 아니면 postal_code NULL·주소 한 줄 그대로.
--        하이픈은 그대로 둔다(회원이 쓴 모양 — 사양서 「개발 판단」).
--   [L4] 「취소됨」 줄과 p_mask_pii 면 주소·우편번호·전화를 NULL. 「취소됨」 줄은 송장 칸도 그대로 보인다(보내지 말아야 할 분을 알아보는 용도).
--        탈퇴 확정(이메일 바꿔치기 또는 이름 칸 셋 다 비어 있음) → name NULL + withdrawn true(D25).
--   [L5] 저장 검사(D1·D6): 송장이 비면(NULL·공백) 「송장 지우기」 — 택배사·발송일도 비운다. 송장이 있으면 영문·숫자·하이픈·띄어쓰기 4~40자,
--        택배사 = 활성 목록 코드 하나 또는 「기타」 이름(1~50자) 하나(둘 다·둘 다 없음은 거부), 발송일이 비면 일본 날짜 오늘.
--        발송일은 2020-01-01 ~ 오늘+30일(엉뚱한 해 입력 방어 — 화면 날짜 선택기면 걸릴 일이 없다).
--   [L6] 저장은 한 거래에서 줄마다 판정하고 건너뛴 줄과 이유를 돌려준다(D22): not_found · cancelled · version_conflict · invalid_tracking ·
--        invalid_carrier · carrier_required · invalid_shipped_on · duplicate(같은 요청 안 같은 줄). 브랜드는 종료 캠페인이면 전체 거부 campaign_ended(D2).
--        관리자는 종료 뒤에도 저장되고, 전달 전에도 저장된다(그때 지금 승인인 응모에 한해 줄을 만든다 — 작업표). 관리자 expected_version 이 NULL 이면
--        「아직 줄이 없다고 본 것」 — 그새 줄이 생겼으면 version_conflict(덮어쓰지 않는다).
--   [L7] 전달(결정 9 — 되돌리지 않음): 잠금 → 이미 전달이면 {ok, delivered_now:false}(기록·메일 없음) → 지금 승인 아닌(또는 감사용) 줄 지움 →
--        승인인데 줄 없는 응모에 줄(승인 시각 순으로 번호) → 모든 줄 added_on = 오늘 → delivered_at → 제공 기록 shipping_deliver(사람 = 그 순간 줄 전부).
--        전달 순간의 줄은 added_at ≤ delivered_at 이라 「새로 추가」가 붙지 않는다(D4). 승인 0명이어도 전달된다(그 뒤 승인이 자동으로 들어온다).
--   [L8] 트리거 함수 _application_shipping_sync 를 다시 정의한다(554 베이스) — 제공 기록의 이름을 화면·전달 기록과 같은 순서(name_kanji → name →
--        user_name)로. 나머지 본문은 554 그대로. 🔴 트리거 함수의 현재 원본은 이 파일이다.
--   [L9] 열람·내려받기 기록(D16)의 사람 목록 = 그 응답에 실린 줄 전부(「취소됨」 줄도 이름은 보였으므로). 칸 목록 = _shipping_provision_columns().
--        기록이 실패하면 응답도 실패한다(같은 거래 — 「기록 없는 제공」 없음). 그래서 두 함수는 VOLATILE 이다.
--   [L10] 메일 선점(mail-webhooks.md 「선점 먼저」): 조건과 바꾸는 값이 같은 칸(mail_claimed_at). 15분 넘은 선점은 죽은 실행으로 보고 다시 잡는다.
--        실패 보고면 선점을 되돌린다. 성공 뒤 mail_sent_at — 다시는 안 잡힌다.
--   [L12] 응답 열쇠: 조회·브랜드 함수는 {success, reason?}(547 과 같은 모양), 관리자 전달·저장은 {ok, reason?}(작업표 그대로). 화면은 함수마다 맞춰 읽는다.
--   [L13] 저장 줄의 expected_version·shipped_on 이 숫자·날짜가 아니면 그 줄만 건너뛴다(version_conflict·invalid_shipped_on) — 한 줄 때문에 전체가 멈추지 않게(D22).
--   [L14] 후속(작은 틈): service_mark_shipping_mail_sent 는 선점한 실행인지 확인하지 않는다 — 15분 뒤 다시 잡힌 뒤 앞 실행이 늦게 「실패」를 보고하면
--         새 선점이 풀린다. 발생 가능성이 낮아 S7 메일 함수에서 선점 시각을 넘겨 비교하는 식으로 다룬다.
--   [L11] 관리자 provision_summary 의 열람·내려받기는 브랜드 줄만(actor_kind='brand') 센다 — 관리자가 브랜드 화면을 볼 일은 없지만 섞이지 않게.
--
-- ============================================================
-- 롤백 (화면 조각 S3·S5·S6·S7 부터 되돌린다) — 함수만 지우면 된다(표는 554)
-- ============================================================
--   DROP FUNCTION IF EXISTS public.service_mark_shipping_mail_sent(uuid, boolean);
--   DROP FUNCTION IF EXISTS public.service_claim_shipping_mail(uuid);
--   DROP FUNCTION IF EXISTS public.save_my_brand_shipping_rows(uuid, jsonb);
--   DROP FUNCTION IF EXISTS public.get_my_brand_shipping_export(uuid);
--   DROP FUNCTION IF EXISTS public.get_my_brand_shipping_list(uuid);
--   DROP FUNCTION IF EXISTS public.get_my_brand_shipping_summary(uuid);
--   DROP FUNCTION IF EXISTS public.admin_save_shipping_rows(uuid, jsonb);
--   DROP FUNCTION IF EXISTS public.admin_deliver_shipping_list(uuid);
--   DROP FUNCTION IF EXISTS public.admin_get_campaign_shipping(uuid);
--   DROP FUNCTION IF EXISTS public._shipping_brand_rows_logged(uuid, text);
--   DROP FUNCTION IF EXISTS public._shipping_carriers();
--   DROP FUNCTION IF EXISTS public._brand_mailable_accounts(uuid);
--   DROP FUNCTION IF EXISTS public._shipping_check_row(text, text, text, date);
--   DROP FUNCTION IF EXISTS public._shipping_rows_payload(uuid, boolean, boolean);
--   DROP FUNCTION IF EXISTS public._shipping_list_open_for_brand(uuid);
--   DROP FUNCTION IF EXISTS public._shipping_brand_campaign(uuid);
--   트리거 함수는 554 의 「6. 트리거 함수」 블록을 다시 실행한다(이름 칸만 되돌아간다).
-- ============================================================

BEGIN;

-- ── 1. 내부 — 판정 ────────────────────────────────────────────

-- 브랜드 판정(547 get_my_brand_campaign 과 같은 식) — 통과하면 캠페인 행
CREATE OR REPLACE FUNCTION public._shipping_brand_campaign(p_campaign_id uuid)
RETURNS public.campaigns
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  c public.campaigns%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR p_campaign_id IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT * INTO c FROM public.campaigns WHERE id = p_campaign_id;
  IF NOT FOUND
     OR c.deleted_at IS NOT NULL
     OR c.status NOT IN ('scheduled', 'active', 'closed', 'ended')
     OR c.brand_id IS NULL
     OR NOT public.is_my_brand(c.brand_id) THEN
    RETURN NULL;
  END IF;
  RETURN c;
END;
$$;

COMMENT ON FUNCTION public._shipping_brand_campaign(uuid) IS
  '[557·S2] 배송 리스트 — 로그인 브랜드가 볼 수 있는 캠페인이면 그 행, 아니면 NULL(547 과 같은 판정). 내부 전용.';

-- 목록 단위 판정 한 곳 — 결과물 열람 정지(4c)가 생기면 여기에 한 줄(D9)
CREATE OR REPLACE FUNCTION public._shipping_list_open_for_brand(p_campaign_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  c public.campaigns%ROWTYPE;
BEGIN
  c := public._shipping_brand_campaign(p_campaign_id);
  IF c.id IS NULL OR c.recruit_type IS DISTINCT FROM 'gifting' THEN
    RETURN false;
  END IF;
  RETURN EXISTS (SELECT 1 FROM public.campaign_shipping_lists s
                  WHERE s.campaign_id = p_campaign_id AND s.delivered_at IS NOT NULL);
END;
$$;

COMMENT ON FUNCTION public._shipping_list_open_for_brand(uuid) IS
  '[557·S2] 배송 리스트 목록 단위 판정 한 곳 — 브랜드 판정 + 시딩형 + 전달됨. 정지 판정이 생기면 여기에(D9). 내부 전용.';

-- ── 2. 내부 — 줄 단위 판정 한 곳 ───────────────────────────────

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
           a.cancel_reason_code, a.cancel_reason, a.reviewed_at, a.created_at AS applied_at,
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
             'postal_code',     CASE WHEN c.st = 'cancelled' OR p_mask_pii THEN NULL ELSE c.zip_part END,
             'address',         CASE WHEN c.st = 'cancelled' OR p_mask_pii THEN NULL
                                     WHEN c.zip_part IS NOT NULL THEN btrim(regexp_replace(c.app_address, '^〒\s*[0-9０-９\-－]{7,8}\s+', ''))
                                     ELSE NULLIF(btrim(c.app_address), '') END,
             'phone',           CASE WHEN c.st = 'cancelled' OR p_mask_pii THEN NULL ELSE NULLIF(btrim(c.phone), '') END,
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
  '[557·S2] 배송 리스트 줄 단위 판정 한 곳 — 전달 뒤 = 줄 있는 응모(승인 아님은 cancelled, 주소·전화 NULL) / 전달 전 = 지금 승인인 응모. '
  '상태·기한·「새로 추가」·우편번호 떼기·탈퇴 표시를 서버가 정한다. p_admin 이면 응모 번호·SNS·취소 사유·입력한 사람을 더한다. 내부 전용.';

-- ── 3. 내부 — 저장 검사 한 곳 [L5] ─────────────────────────────

-- 반환 {ok, reason?, carrier_code, carrier_other, tracking_no, shipped_on} — 정리된 값
CREATE OR REPLACE FUNCTION public._shipping_check_row(p_carrier_code text, p_carrier_other text, p_tracking_no text, p_shipped_on date)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_today   date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  v_track   text := NULLIF(btrim(COALESCE(p_tracking_no, '')), '');
  v_code    text := NULLIF(btrim(COALESCE(p_carrier_code, '')), '');
  v_other   text := NULLIF(btrim(COALESCE(p_carrier_other, '')), '');
BEGIN
  -- 송장 지우기(D1) — 택배사·발송일도 비운다
  IF v_track IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'cleared', true,
             'carrier_code', NULL, 'carrier_other', NULL, 'tracking_no', NULL, 'shipped_on', NULL);
  END IF;
  -- 형식(D6): 영문·숫자·하이픈·띄어쓰기 4~40자
  IF v_track !~ '^[A-Za-z0-9 -]{4,40}$' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_tracking');
  END IF;
  -- 택배사 = 목록 코드 하나 또는 「기타」 이름 하나
  IF v_code IS NULL AND v_other IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'carrier_required');
  END IF;
  IF v_code IS NOT NULL AND v_other IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_carrier');
  END IF;
  IF v_code IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.lookup_values lv WHERE lv.kind = 'shipping_carrier' AND lv.code = v_code AND lv.active) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_carrier');
  END IF;
  IF v_other IS NOT NULL AND length(v_other) > 50 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_carrier');
  END IF;
  -- 발송일 — 비면 오늘(일본 날짜)
  IF p_shipped_on IS NOT NULL AND (p_shipped_on < DATE '2020-01-01' OR p_shipped_on > v_today + 30) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_shipped_on');
  END IF;
  RETURN jsonb_build_object('ok', true, 'cleared', false,
           'carrier_code', v_code, 'carrier_other', v_other, 'tracking_no', v_track,
           'shipped_on', COALESCE(p_shipped_on, v_today));
END;
$$;

COMMENT ON FUNCTION public._shipping_check_row(text, text, text, date) IS
  '[557·S2] 송장 저장 검사·정리 한 곳(브랜드·관리자 공용) — 빈 송장 = 지우기(D1), 형식 4~40자(D6), 택배사 목록/기타 하나, 발송일 비면 오늘. 내부 전용.';

-- ── 4. 내부 — 메일 받을 브랜드 계정 · 택배사 목록 ─────────────────

-- 🔴 supabase/functions/notify-orient-sheet/index.ts resolveBrandAccountRecipients 와 같은 규칙의 사본 — 한쪽을 바꾸면 함께
CREATE OR REPLACE FUNCTION public._brand_mailable_accounts(p_brand_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('auth_id', t.auth_id, 'email', t.email, 'name', t.name, 'role', t.role)
                            ORDER BY t.ord), '[]'::jsonb)
    FROM (
      SELECT DISTINCT ON (lower(btrim(ba.email)))
             ba.auth_id, lower(btrim(ba.email)) AS email, NULLIF(btrim(ba.name), '') AS name, l.role,
             row_number() OVER (ORDER BY (l.role <> 'owner'), l.created_at) AS ord
        FROM public.brand_account_links l
        JOIN public.brands b          ON b.id = l.brand_id AND b.status = 'active'
        JOIN public.brand_accounts ba ON ba.auth_id = l.auth_id
       WHERE l.brand_id = p_brand_id
         AND l.status = 'active'
         AND ba.password_set_at IS NOT NULL
         AND NULLIF(btrim(ba.email), '') IS NOT NULL
       ORDER BY lower(btrim(ba.email)), (l.role <> 'owner'), l.created_at
    ) t;
$$;

COMMENT ON FUNCTION public._brand_mailable_accounts(uuid) IS
  '[557·S2] 메일 받을 브랜드 계정 [{auth_id,email,name,role}] — 활성 브랜드·활성 연결·비밀번호 정함·대표 먼저·이메일 중복 제거. '
  '🔴 notify-orient-sheet resolveBrandAccountRecipients 의 사본. 내부 전용.';

CREATE OR REPLACE FUNCTION public._shipping_carriers()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('code', lv.code, 'name', lv.name_ko) ORDER BY lv.sort_order, lv.code), '[]'::jsonb)
    FROM public.lookup_values lv
   WHERE lv.kind = 'shipping_carrier' AND lv.active;
$$;

COMMENT ON FUNCTION public._shipping_carriers() IS
  '[557·S2] 택배사 목록(활성, 순서대로) [{code,name}] — 「기타」는 목록에 없다(화면이 덧붙인다). 내부 전용.';

-- ── 5. 관리자 ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_get_campaign_shipping(p_campaign_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  c        public.campaigns%ROWTYPE;
  v_list   public.campaign_shipping_lists%ROWTYPE;
  v_mask   boolean;
  v_pay    jsonb;
BEGIN
  IF NOT public.has_permission('shipping.manage', 'read') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO c FROM public.campaigns WHERE id = p_campaign_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;
  IF c.recruit_type IS DISTINCT FROM 'gifting' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_gifting');
  END IF;

  -- 선결 Q2 — 민감정보 권한이 없는 등급에는 주소·전화를 비운다
  v_mask := NOT public.has_permission('influencer.sensitive_pii', 'read');
  v_pay  := public._shipping_rows_payload(p_campaign_id, v_mask, true);
  SELECT * INTO v_list FROM public.campaign_shipping_lists WHERE campaign_id = p_campaign_id;

  RETURN jsonb_build_object(
    'success',           true,
    'campaign_id',       c.id,
    'campaign_no',       c.campaign_no,
    'brand_id',          c.brand_id,
    'deleted',           c.deleted_at IS NOT NULL,
    'pii_masked',        v_mask,
    'can_write',         public.has_permission('shipping.manage', 'write'),
    'delivered_at',      v_list.delivered_at,
    'delivered_by_name', (SELECT COALESCE(NULLIF(btrim(ad.name), ''), ad.email) FROM public.admins ad WHERE ad.auth_id = v_list.delivered_by LIMIT 1),
    'account_count',     CASE WHEN c.brand_id IS NULL THEN 0 ELSE jsonb_array_length(public._brand_mailable_accounts(c.brand_id)) END,
    'provision_summary', (
      SELECT jsonb_build_object(
               'view_count',     count(*) FILTER (WHERE l.action = 'shipping_view'),
               'last_viewed_at', max(l.at) FILTER (WHERE l.action = 'shipping_view'),
               'excel_count',    count(*) FILTER (WHERE l.action = 'shipping_excel'),
               'last_excel_at',  max(l.at) FILTER (WHERE l.action = 'shipping_excel'),
               'last_excel_by',  (SELECT l2.actor_name FROM public.brand_provision_logs l2
                                   WHERE l2.campaign_id = p_campaign_id AND l2.action = 'shipping_excel' AND l2.actor_kind = 'brand'
                                   ORDER BY l2.at DESC LIMIT 1))
        FROM public.brand_provision_logs l
       WHERE l.campaign_id = p_campaign_id AND l.actor_kind = 'brand'),
    'counts',            v_pay->'counts',
    'today',             v_pay->'today',
    'carriers',          public._shipping_carriers(),
    'rows',              v_pay->'rows'
  );
END;
$$;

COMMENT ON FUNCTION public.admin_get_campaign_shipping(uuid) IS
  '[557·S2] 관리자 배송 탭 조회(shipping.manage 읽기). 민감정보 권한이 없으면 주소·전화 NULL(선결 Q2). 전달 전에는 지금 승인인 응모를 줄이 없어도 싣는다.';

CREATE OR REPLACE FUNCTION public.admin_deliver_shipping_list(p_campaign_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_today    date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  c          public.campaigns%ROWTYPE;
  v_accounts jsonb;
  v_list     public.campaign_shipping_lists%ROWTYPE;
  v_next     integer;
  v_added    integer;
  v_persons  jsonb;
  v_rows     integer;
BEGIN
  IF v_uid IS NULL OR NOT public.has_permission('shipping.manage', 'write') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  -- 🔴 잠금 먼저, 읽기는 그 뒤(554 [K1])
  PERFORM public._shipping_campaign_lock(p_campaign_id);

  SELECT * INTO c FROM public.campaigns WHERE id = p_campaign_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF c.deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'campaign_deleted');
  END IF;
  IF c.recruit_type IS DISTINCT FROM 'gifting' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_gifting');
  END IF;

  v_accounts := CASE WHEN c.brand_id IS NULL THEN '[]'::jsonb ELSE public._brand_mailable_accounts(c.brand_id) END;

  INSERT INTO public.campaign_shipping_lists (campaign_id) VALUES (p_campaign_id)
  ON CONFLICT (campaign_id) DO NOTHING;
  SELECT * INTO v_list FROM public.campaign_shipping_lists WHERE campaign_id = p_campaign_id;

  -- 이미 전달됨 — 오류가 아니다(기록·메일 없음, 두 관리자가 동시에 눌러도 true 는 한 번)
  IF v_list.delivered_at IS NOT NULL THEN
    SELECT count(*) INTO v_rows FROM public.campaign_shipments WHERE campaign_id = p_campaign_id;
    RETURN jsonb_build_object('ok', true, 'delivered_now', false, 'delivered_at', v_list.delivered_at,
                              'row_count', v_rows, 'account_count', jsonb_array_length(v_accounts));
  END IF;

  IF jsonb_array_length(v_accounts) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_account');
  END IF;

  -- ③ 지금 승인이 아닌(또는 감사용) 응모의 줄은 지운다 — 전달 전에 빠진 분은 넣지 않는다(§4-2)
  DELETE FROM public.campaign_shipments sh
   USING public.applications a
   LEFT JOIN public.influencers i ON i.id = a.user_id
   WHERE sh.application_id = a.id
     AND sh.campaign_id = p_campaign_id
     AND (a.status IS DISTINCT FROM 'approved' OR COALESCE(i.is_audit, true));

  -- ① 승인인데 줄이 없는 응모에 줄(승인 시각 순으로 번호)
  v_next := v_list.next_row_no;
  WITH todo AS (
    SELECT a.id, row_number() OVER (ORDER BY a.reviewed_at NULLS LAST, a.created_at, a.id) AS rn
      FROM public.applications a
      JOIN public.influencers i ON i.id = a.user_id AND i.is_audit = false
     WHERE a.campaign_id = p_campaign_id
       AND a.status = 'approved'
       AND NOT EXISTS (SELECT 1 FROM public.campaign_shipments sh WHERE sh.application_id = a.id)
  ), ins AS (
    INSERT INTO public.campaign_shipments (campaign_id, application_id, row_no, added_on, added_at)
    SELECT p_campaign_id, t.id, v_next + t.rn - 1, v_today, now() FROM todo t
    RETURNING 1
  )
  SELECT count(*) INTO v_added FROM ins;

  -- ② 모든 줄의 기한 기준일 = 전달한 날(D14)
  UPDATE public.campaign_shipments SET added_on = v_today WHERE campaign_id = p_campaign_id;

  UPDATE public.campaign_shipping_lists
     SET delivered_at = now(),
         delivered_by = v_uid,
         next_row_no  = v_next + v_added,
         version      = version + 1
   WHERE campaign_id = p_campaign_id;

  -- 제공 기록 — 그 순간 리스트에 든 사람 전부 [L7]
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'influencer_id', a.user_id,
           'name', COALESCE(NULLIF(btrim(i.name_kanji), ''), NULLIF(btrim(i.name), ''), NULLIF(btrim(a.user_name), '')))
           ORDER BY sh.row_no), '[]'::jsonb), count(*)
    INTO v_persons, v_rows
    FROM public.campaign_shipments sh
    JOIN public.applications a ON a.id = sh.application_id
    JOIN public.influencers i  ON i.id = a.user_id
   WHERE sh.campaign_id = p_campaign_id;

  PERFORM public._record_brand_provision(c.brand_id, p_campaign_id, 'shipping_deliver',
                                         public._shipping_provision_columns(), v_persons, v_uid, 'admin');

  RETURN jsonb_build_object('ok', true, 'delivered_now', true, 'delivered_at', now(),
                            'row_count', v_rows, 'account_count', jsonb_array_length(v_accounts));
END;
$$;

COMMENT ON FUNCTION public.admin_deliver_shipping_list(uuid) IS
  '[557·S2] 배송 리스트 전달(shipping.manage 쓰기, 되돌리지 않음 — 결정 9). 이미 전달이면 {ok, delivered_now:false}. '
  '거부 not_found·campaign_deleted·not_gifting·no_account. 같은 거래에서 제공 기록 shipping_deliver.';

CREATE OR REPLACE FUNCTION public.admin_save_shipping_rows(p_campaign_id uuid, p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_today   date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  c         public.campaigns%ROWTYPE;
  v_saved   jsonb := '[]'::jsonb;
  v_skipped jsonb := '[]'::jsonb;
  v_seen    uuid[] := '{}';
  r         jsonb;
  v_app_id  uuid;
  v_app     public.applications%ROWTYPE;
  v_audit   boolean;
  v_ship    public.campaign_shipments%ROWTYPE;
  v_exp     integer;
  v_chk     jsonb;
  v_row_no  integer;
  v_on      date;
BEGIN
  IF v_uid IS NULL OR NOT public.has_permission('shipping.manage', 'write') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) > 2000 THEN
    RAISE EXCEPTION 'invalid_payload' USING ERRCODE = '22023';
  END IF;

  PERFORM public._shipping_campaign_lock(p_campaign_id);

  SELECT * INTO c FROM public.campaigns WHERE id = p_campaign_id;
  IF NOT FOUND OR c.deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF c.recruit_type IS DISTINCT FROM 'gifting' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_gifting');
  END IF;

  INSERT INTO public.campaign_shipping_lists (campaign_id) VALUES (p_campaign_id)
  ON CONFLICT (campaign_id) DO NOTHING;

  FOR r IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    BEGIN
      v_app_id := NULLIF(r->>'application_id', '')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      v_app_id := NULL;
    END;
    IF v_app_id IS NULL THEN
      v_skipped := v_skipped || jsonb_build_object('application_id', r->>'application_id', 'reason', 'not_found');
      CONTINUE;
    END IF;
    IF v_app_id = ANY (v_seen) THEN
      v_skipped := v_skipped || jsonb_build_object('application_id', v_app_id, 'reason', 'duplicate');
      CONTINUE;
    END IF;
    v_seen := v_seen || v_app_id;

    SELECT * INTO v_app FROM public.applications WHERE id = v_app_id AND campaign_id = p_campaign_id;
    SELECT i.is_audit INTO v_audit FROM public.influencers i WHERE i.id = v_app.user_id;
    IF v_app.id IS NULL OR COALESCE(v_audit, true) THEN
      v_skipped := v_skipped || jsonb_build_object('application_id', v_app_id, 'reason', 'not_found');
      CONTINUE;
    END IF;
    IF v_app.status IS DISTINCT FROM 'approved' THEN
      v_skipped := v_skipped || jsonb_build_object('application_id', v_app_id, 'reason', 'cancelled');
      CONTINUE;
    END IF;

    SELECT * INTO v_ship FROM public.campaign_shipments WHERE application_id = v_app_id FOR UPDATE;
    BEGIN
      v_exp := NULLIF(r->>'expected_version', '')::integer;
    EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
      v_skipped := v_skipped || jsonb_build_object('application_id', v_app_id, 'reason', 'version_conflict');
      CONTINUE;
    END;
    -- 버전 확인 — NULL 이면 「줄이 없다고 본 것」 [L6]
    IF (v_ship.id IS NULL AND v_exp IS NOT NULL)
       OR (v_ship.id IS NOT NULL AND v_exp IS DISTINCT FROM v_ship.version) THEN
      v_skipped := v_skipped || jsonb_build_object('application_id', v_app_id, 'reason', 'version_conflict');
      CONTINUE;
    END IF;

    BEGIN
      v_on := NULLIF(r->>'shipped_on', '')::date;
    EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow OR invalid_text_representation THEN
      v_skipped := v_skipped || jsonb_build_object('application_id', v_app_id, 'reason', 'invalid_shipped_on');
      CONTINUE;
    END;
    v_chk := public._shipping_check_row(r->>'carrier_code', r->>'carrier_other', r->>'tracking_no', v_on);
    IF NOT (v_chk->>'ok')::boolean THEN
      v_skipped := v_skipped || jsonb_build_object('application_id', v_app_id, 'reason', v_chk->>'reason');
      CONTINUE;
    END IF;

    IF v_ship.id IS NULL THEN
      -- 줄이 없다(전달 전) — 지금 승인인 응모에 한해 그 자리에서 만들고 번호를 매긴다
      UPDATE public.campaign_shipping_lists s SET next_row_no = s.next_row_no + 1
       WHERE s.campaign_id = p_campaign_id
      RETURNING s.next_row_no - 1 INTO v_row_no;
      INSERT INTO public.campaign_shipments
        (campaign_id, application_id, row_no, added_on, added_at,
         carrier_code, carrier_other, tracking_no, shipped_on, updated_by, updated_by_kind, updated_at)
      VALUES
        (p_campaign_id, v_app_id, v_row_no, v_today, now(),
         v_chk->>'carrier_code', v_chk->>'carrier_other', v_chk->>'tracking_no', (v_chk->>'shipped_on')::date,
         v_uid, 'admin', now())
      RETURNING * INTO v_ship;
    ELSE
      UPDATE public.campaign_shipments sh
         SET carrier_code    = v_chk->>'carrier_code',
             carrier_other   = v_chk->>'carrier_other',
             tracking_no     = v_chk->>'tracking_no',
             shipped_on      = (v_chk->>'shipped_on')::date,
             updated_by      = v_uid,
             updated_by_kind = 'admin',
             updated_at      = now(),
             version         = sh.version + 1
       WHERE sh.id = v_ship.id
      RETURNING * INTO v_ship;
    END IF;

    v_saved := v_saved || jsonb_build_object('application_id', v_app_id, 'row_no', v_ship.row_no, 'version', v_ship.version,
                                             'cleared', (v_chk->>'cleared')::boolean);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'saved', v_saved, 'skipped', v_skipped);
END;
$$;

COMMENT ON FUNCTION public.admin_save_shipping_rows(uuid, jsonb) IS
  '[557·S2] 관리자 송장 저장(shipping.manage 쓰기) — 줄 = 응모 번호. 전달 전·종료 뒤에도 된다. 줄마다 판정 {ok, saved, skipped:[{application_id, reason}]}(D22). '
  '빈 송장 = 지우기(D1), 형식 D6. 전달 전이면 지금 승인인 응모에 그 자리에서 줄을 만든다.';

-- ── 6. 브랜드 ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.get_my_brand_shipping_summary(p_campaign_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  c     public.campaigns%ROWTYPE;
  v_pay jsonb;
BEGIN
  c := public._shipping_brand_campaign(p_campaign_id);
  IF c.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;
  IF NOT public._shipping_list_open_for_brand(p_campaign_id) THEN
    RETURN jsonb_build_object('success', true, 'ready', false);
  END IF;
  -- 개인정보 없음 · 기록 없음 — 숫자만
  v_pay := public._shipping_rows_payload(p_campaign_id, true, false);
  RETURN jsonb_build_object('success', true, 'ready', true,
                            'delivered_at', v_pay->'delivered_at', 'today', v_pay->'today', 'counts', v_pay->'counts');
END;
$$;

COMMENT ON FUNCTION public.get_my_brand_shipping_summary(uuid) IS
  '[557·S2] 브랜드 캠페인 상세 배송 카드 — {success, ready, delivered_at, counts}. 개인정보·기록 없음. 남의·없는 캠페인은 not_found.';

-- 열람·내려받기 공용 본체(기록 종류만 다르다) [L9]
CREATE OR REPLACE FUNCTION public._shipping_brand_rows_logged(p_campaign_id uuid, p_action text)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  c        public.campaigns%ROWTYPE;
  v_pay    jsonb;
  v_today  date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  v_persons jsonb;
BEGIN
  IF NOT public._shipping_list_open_for_brand(p_campaign_id) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;
  c := public._shipping_brand_campaign(p_campaign_id);
  v_pay := public._shipping_rows_payload(p_campaign_id, false, false);

  -- 사람 목록 = 응답에 실린 줄의 회원(이름은 브랜드가 받은 모양 그대로) — 회원 번호는 응답에 없지만 기록에는 남긴다
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'influencer_id', a.user_id,
           'name', COALESCE(NULLIF(btrim(i.name_kanji), ''), NULLIF(btrim(i.name), ''), NULLIF(btrim(a.user_name), '')))
           ORDER BY sh.row_no), '[]'::jsonb)
    INTO v_persons
    FROM public.campaign_shipments sh
    JOIN public.applications a ON a.id = sh.application_id
    JOIN public.influencers i  ON i.id = a.user_id AND i.is_audit = false
   WHERE sh.campaign_id = p_campaign_id;

  PERFORM public._record_brand_provision(c.brand_id, p_campaign_id, p_action,
                                         public._shipping_provision_columns(), v_persons, NULL, 'brand');

  RETURN jsonb_build_object(
    'success',      true,
    'campaign_no',  c.campaign_no,
    'product',      COALESCE(NULLIF(btrim(c.product_ko), ''), NULLIF(btrim(c.product), ''), c.title),
    'editable',     public._brand_campaign_view_status(c, v_today) <> 'ended',   -- D2
    'delivered_at', v_pay->'delivered_at',
    'today',        v_pay->'today',
    'counts',       v_pay->'counts',
    'carriers',     public._shipping_carriers(),
    'rows',         v_pay->'rows'
  );
END;
$$;

COMMENT ON FUNCTION public._shipping_brand_rows_logged(uuid, text) IS
  '[557·S2] 브랜드 배송 리스트 열람·내려받기 공용 본체 — 목록 단위 판정 → 줄 → 같은 거래에서 제공 기록. 내부 전용.';

CREATE OR REPLACE FUNCTION public.get_my_brand_shipping_list(p_campaign_id uuid)
RETURNS jsonb
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT public._shipping_brand_rows_logged(p_campaign_id, 'shipping_view');
$$;

COMMENT ON FUNCTION public.get_my_brand_shipping_list(uuid) IS
  '[557·S2] 브랜드 배송 리스트 화면 — 줄 + 택배사 목록 + editable(종료면 false — D2). 제공 기록 shipping_view(30분 합치기 D16).';

CREATE OR REPLACE FUNCTION public.get_my_brand_shipping_export(p_campaign_id uuid)
RETURNS jsonb
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT public._shipping_brand_rows_logged(p_campaign_id, 'shipping_excel');
$$;

COMMENT ON FUNCTION public.get_my_brand_shipping_export(uuid) IS
  '[557·S2] 브랜드 배송 리스트 엑셀 내려받기용 — 화면과 같은 줄. 제공 기록 shipping_excel(매번 새 줄).';

CREATE OR REPLACE FUNCTION public.save_my_brand_shipping_rows(p_campaign_id uuid, p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_today   date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  c         public.campaigns%ROWTYPE;
  v_saved   jsonb := '[]'::jsonb;
  v_skipped jsonb := '[]'::jsonb;
  v_seen    integer[] := '{}';
  r         jsonb;
  v_no      integer;
  v_ship    public.campaign_shipments%ROWTYPE;
  v_status  text;
  v_chk     jsonb;
  v_exp     integer;
  v_on      date;
BEGIN
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) > 2000 THEN
    RAISE EXCEPTION 'invalid_payload' USING ERRCODE = '22023';
  END IF;

  -- 판정을 잠금 앞에 — 남의 캠페인 번호로 잠금을 쥐지 못하게(전달은 되돌아가지 않으니 앞에서 봐도 안전하다)
  IF NOT public._shipping_list_open_for_brand(p_campaign_id) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;
  PERFORM public._shipping_campaign_lock(p_campaign_id);
  c := public._shipping_brand_campaign(p_campaign_id);
  IF public._brand_campaign_view_status(c, v_today) = 'ended' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'campaign_ended');   -- D2
  END IF;

  FOR r IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    BEGIN
      v_no := NULLIF(r->>'row_no', '')::integer;
    EXCEPTION WHEN invalid_text_representation THEN
      v_no := NULL;
    END;
    IF v_no IS NULL THEN
      v_skipped := v_skipped || jsonb_build_object('row_no', r->'row_no', 'reason', 'not_found');
      CONTINUE;
    END IF;
    IF v_no = ANY (v_seen) THEN
      v_skipped := v_skipped || jsonb_build_object('row_no', v_no, 'reason', 'duplicate');
      CONTINUE;
    END IF;
    v_seen := v_seen || v_no;

    SELECT sh.* INTO v_ship
      FROM public.campaign_shipments sh
      JOIN public.applications a ON a.id = sh.application_id
      JOIN public.influencers i  ON i.id = a.user_id AND i.is_audit = false
     WHERE sh.campaign_id = p_campaign_id AND sh.row_no = v_no
     FOR UPDATE OF sh;
    IF NOT FOUND THEN
      v_skipped := v_skipped || jsonb_build_object('row_no', v_no, 'reason', 'not_found');
      CONTINUE;
    END IF;
    -- 🔴 지금 승인인 줄만 받는다(§4-2)
    SELECT a.status INTO v_status FROM public.applications a WHERE a.id = v_ship.application_id;
    IF v_status IS DISTINCT FROM 'approved' THEN
      v_skipped := v_skipped || jsonb_build_object('row_no', v_no, 'reason', 'cancelled');
      CONTINUE;
    END IF;
    BEGIN
      v_exp := NULLIF(r->>'expected_version', '')::integer;
    EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
      v_exp := NULL;
    END;
    IF v_exp IS DISTINCT FROM v_ship.version THEN
      v_skipped := v_skipped || jsonb_build_object('row_no', v_no, 'reason', 'version_conflict');
      CONTINUE;
    END IF;
    BEGIN
      v_on := NULLIF(r->>'shipped_on', '')::date;
    EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow OR invalid_text_representation THEN
      v_skipped := v_skipped || jsonb_build_object('row_no', v_no, 'reason', 'invalid_shipped_on');
      CONTINUE;
    END;

    v_chk := public._shipping_check_row(r->>'carrier_code', r->>'carrier_other', r->>'tracking_no', v_on);
    IF NOT (v_chk->>'ok')::boolean THEN
      v_skipped := v_skipped || jsonb_build_object('row_no', v_no, 'reason', v_chk->>'reason');
      CONTINUE;
    END IF;

    UPDATE public.campaign_shipments sh
       SET carrier_code    = v_chk->>'carrier_code',
           carrier_other   = v_chk->>'carrier_other',
           tracking_no     = v_chk->>'tracking_no',
           shipped_on      = (v_chk->>'shipped_on')::date,
           updated_by      = v_uid,
           updated_by_kind = 'brand',
           updated_at      = now(),
           version         = sh.version + 1
     WHERE sh.id = v_ship.id
    RETURNING * INTO v_ship;

    v_saved := v_saved || jsonb_build_object('row_no', v_no, 'version', v_ship.version, 'cleared', (v_chk->>'cleared')::boolean);
  END LOOP;

  RETURN jsonb_build_object('success', true, 'saved', v_saved, 'skipped', v_skipped);
END;
$$;

COMMENT ON FUNCTION public.save_my_brand_shipping_rows(uuid, jsonb) IS
  '[557·S2] 브랜드 송장 저장 — 줄 = row_no, 지금 승인인 줄만, 버전 확인, 종료 캠페인은 campaign_ended(D2). '
  '{success, saved, skipped:[{row_no, reason}]}(D22). 파일·엑셀 원문은 받지 않는다(결정 3).';

-- ── 7. 서비스 전용 — 전달 알림 메일 선점(S7) [L10] ─────────────────

CREATE OR REPLACE FUNCTION public.service_claim_shipping_mail(p_campaign_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  c        public.campaigns%ROWTYPE;
  v_ok     boolean;
BEGIN
  UPDATE public.campaign_shipping_lists s
     SET mail_claimed_at = now()
   WHERE s.campaign_id = p_campaign_id
     AND s.delivered_at IS NOT NULL
     AND s.mail_sent_at IS NULL
     AND (s.mail_claimed_at IS NULL OR s.mail_claimed_at < now() - interval '15 minutes')
  RETURNING true INTO v_ok;
  IF v_ok IS NULL THEN
    RETURN NULL;   -- 이미 선점·이미 보냄·전달 전
  END IF;

  SELECT * INTO c FROM public.campaigns WHERE id = p_campaign_id;
  RETURN jsonb_build_object(
    'campaign_id', c.id,
    'campaign_no', c.campaign_no,
    'product',     COALESCE(NULLIF(btrim(c.product_ko), ''), NULLIF(btrim(c.product), ''), c.title),
    'brand_id',    c.brand_id,
    'brand_name',  (SELECT b.name FROM public.brands b WHERE b.id = c.brand_id),
    'recipients',  CASE WHEN c.brand_id IS NULL THEN '[]'::jsonb ELSE public._brand_mailable_accounts(c.brand_id) END
  );
END;
$$;

COMMENT ON FUNCTION public.service_claim_shipping_mail(uuid) IS
  '[557·S2] 전달 알림 메일 선점(service_role 전용) — 성공이면 받는 사람 목록, 이미 선점·보냄이면 NULL. 15분 넘은 선점은 다시 잡는다.';

CREATE OR REPLACE FUNCTION public.service_mark_shipping_mail_sent(p_campaign_id uuid, p_ok boolean)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF COALESCE(p_ok, false) THEN
    UPDATE public.campaign_shipping_lists SET mail_sent_at = now()
     WHERE campaign_id = p_campaign_id AND mail_sent_at IS NULL;
  ELSE
    UPDATE public.campaign_shipping_lists SET mail_claimed_at = NULL   -- 실패면 선점을 되돌린다
     WHERE campaign_id = p_campaign_id AND mail_sent_at IS NULL;
  END IF;
END;
$$;

COMMENT ON FUNCTION public.service_mark_shipping_mail_sent(uuid, boolean) IS
  '[557·S2] 전달 알림 메일 결과(service_role 전용) — 성공이면 mail_sent_at, 실패면 선점 되돌림.';

-- ── 8. 트리거 함수 재정의 — 이름 칸만 [L8] (554 베이스) ───────────────

CREATE OR REPLACE FUNCTION public._application_shipping_sync()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_brand_id  uuid;
  v_name      text;
  v_today     date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  v_ship_id   uuid;
  v_row_no    integer;
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NULL;
  END IF;

  SELECT c.brand_id INTO v_brand_id
    FROM public.campaigns c
   WHERE c.id = NEW.campaign_id
     AND c.recruit_type = 'gifting'
     AND c.deleted_at IS NULL;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- 감사용 아님 — 이름은 화면·전달 기록과 같은 순서(557 [L8])
  SELECT COALESCE(NULLIF(btrim(i.name_kanji), ''), NULLIF(btrim(i.name), ''), NULLIF(btrim(NEW.user_name), ''))
    INTO v_name
    FROM public.influencers i
   WHERE i.id = NEW.user_id
     AND i.is_audit = false;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  PERFORM public._shipping_campaign_lock(NEW.campaign_id);

  IF NOT EXISTS (
    SELECT 1 FROM public.campaign_shipping_lists s
     WHERE s.campaign_id = NEW.campaign_id
       AND s.delivered_at IS NOT NULL
  ) THEN
    RETURN NULL;
  END IF;

  SELECT sh.id INTO v_ship_id
    FROM public.campaign_shipments sh
   WHERE sh.application_id = NEW.id
   FOR UPDATE;

  IF FOUND THEN
    UPDATE public.campaign_shipments sh
       SET added_at = now(),
           added_on = CASE WHEN sh.tracking_no IS NULL THEN v_today ELSE sh.added_on END,
           version  = sh.version + 1
     WHERE sh.id = v_ship_id;
  ELSE
    UPDATE public.campaign_shipping_lists s
       SET next_row_no = s.next_row_no + 1
     WHERE s.campaign_id = NEW.campaign_id
    RETURNING s.next_row_no - 1 INTO v_row_no;

    INSERT INTO public.campaign_shipments (campaign_id, application_id, row_no, added_on, added_at)
    VALUES (NEW.campaign_id, NEW.id, v_row_no, v_today, now());
  END IF;

  PERFORM public._record_brand_provision(
    v_brand_id,
    NEW.campaign_id,
    'shipping_auto_add',
    public._shipping_provision_columns(),
    jsonb_build_array(jsonb_build_object('influencer_id', NEW.user_id, 'name', v_name)),
    NULL,
    'system'
  );

  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION public._application_shipping_sync() IS
  '[554·S1 → 557] 응모가 승인으로 바뀌면 — 전달된 시딩형 캠페인 + 감사용 아님일 때 배송 줄을 넣거나 되살리고(D15) 제공 기록 shipping_auto_add. '
  '현재 원본 557(이름 = name_kanji → name → user_name).';

-- ── 9. 실행 권한 ─────────────────────────────────────────────
-- 🔴 두 방향 회수(369). 부여 먼저, 회수 나중(375). 트리거 함수는 554 의 권한 그대로(CREATE OR REPLACE 는 권한을 보존한다).

-- 부여
GRANT EXECUTE ON FUNCTION public._shipping_brand_campaign(uuid)                     TO postgres;
GRANT EXECUTE ON FUNCTION public._shipping_list_open_for_brand(uuid)                TO postgres;
GRANT EXECUTE ON FUNCTION public._shipping_rows_payload(uuid, boolean, boolean)     TO postgres;
GRANT EXECUTE ON FUNCTION public._shipping_check_row(text, text, text, date)        TO postgres;
GRANT EXECUTE ON FUNCTION public._brand_mailable_accounts(uuid)                     TO postgres;
GRANT EXECUTE ON FUNCTION public._shipping_carriers()                               TO postgres;
GRANT EXECUTE ON FUNCTION public._shipping_brand_rows_logged(uuid, text)            TO postgres;
GRANT EXECUTE ON FUNCTION public.admin_get_campaign_shipping(uuid)                  TO postgres, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_deliver_shipping_list(uuid)                  TO postgres, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_save_shipping_rows(uuid, jsonb)              TO postgres, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_brand_shipping_summary(uuid)                TO postgres, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_brand_shipping_list(uuid)                   TO postgres, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_brand_shipping_export(uuid)                 TO postgres, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.save_my_brand_shipping_rows(uuid, jsonb)           TO postgres, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.service_claim_shipping_mail(uuid)                  TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.service_mark_shipping_mail_sent(uuid, boolean)     TO postgres, service_role;

-- 내부 일곱 — 모두 회수(정의자 권한 함수 안에서만 불린다)
REVOKE EXECUTE ON FUNCTION public._shipping_brand_campaign(uuid)                 FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._shipping_brand_campaign(uuid)                 FROM anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public._shipping_list_open_for_brand(uuid)            FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._shipping_list_open_for_brand(uuid)            FROM anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public._shipping_rows_payload(uuid, boolean, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._shipping_rows_payload(uuid, boolean, boolean) FROM anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public._shipping_check_row(text, text, text, date)    FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._shipping_check_row(text, text, text, date)    FROM anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public._brand_mailable_accounts(uuid)                 FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_mailable_accounts(uuid)                 FROM anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public._shipping_carriers()                           FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._shipping_carriers()                           FROM anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public._shipping_brand_rows_logged(uuid, text)        FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._shipping_brand_rows_logged(uuid, text)        FROM anon, authenticated, service_role;

-- 공개 일곱 — authenticated 만(안쪽 가드가 최종), 비로그인 막음
REVOKE EXECUTE ON FUNCTION public.admin_get_campaign_shipping(uuid)        FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_get_campaign_shipping(uuid)        FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_deliver_shipping_list(uuid)        FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_deliver_shipping_list(uuid)        FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_save_shipping_rows(uuid, jsonb)    FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_save_shipping_rows(uuid, jsonb)    FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_my_brand_shipping_summary(uuid)      FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_my_brand_shipping_summary(uuid)      FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_my_brand_shipping_list(uuid)         FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_my_brand_shipping_list(uuid)         FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_my_brand_shipping_export(uuid)       FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_my_brand_shipping_export(uuid)       FROM anon;
REVOKE EXECUTE ON FUNCTION public.save_my_brand_shipping_rows(uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.save_my_brand_shipping_rows(uuid, jsonb) FROM anon;

-- 서비스 전용 둘 — service_role 만
REVOKE EXECUTE ON FUNCTION public.service_claim_shipping_mail(uuid)              FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.service_claim_shipping_mail(uuid)              FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.service_mark_shipping_mail_sent(uuid, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.service_mark_shipping_mail_sent(uuid, boolean) FROM anon, authenticated;

COMMIT;

-- ============================================================
-- 적용 뒤 확인 (한 단계씩 — 개발서버에서 먼저)
-- ============================================================
-- ※ 관리자·브랜드 판정은 SQL 편집기로 재현되지 않는다(서비스 권한이라 auth.uid() 가 비어 있다) — 로그인 브라우저 콘솔에서.
--   SQL 편집기 시험은 「회원 권한 흉내」(set_config('request.jwt.claims', {sub, role}) + set_config('role','authenticated'))를
--   끝에서 예외로 되돌리는 블록 안에서 한다(554 시험과 같은 방식).
--
-- [1] 권한 — 기대: 내부 일곱 anon/auth/svc 모두 false · 공개 일곱 auth=true·anon=false · 서비스 둘 svc=true·auth=false · acl 맨 앞 `=X/` 없음
--   SELECT p.proname, has_function_privilege('anon',p.oid,'EXECUTE') a, has_function_privilege('authenticated',p.oid,'EXECUTE') u,
--          has_function_privilege('service_role',p.oid,'EXECUTE') s, p.proacl::text
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname='public' AND (p.proname LIKE '%shipping%' OR p.proname = '_brand_mailable_accounts') ORDER BY 1;
--
-- [2] 동작 — 시험 대표 계정(zz-b2-owner)의 시딩 캠페인 · 다른 브랜드 캠페인 · 관리자(최고·매니저) 흉내로:
--   요약 전달 전 ready=false → 관리자 전달(no_account/첫 전달 true/둘째 false·기록 1줄) → 목록(줄·기록 shipping_view) → 내려받기(기록 shipping_excel)
--   → 브랜드 저장(정상·취소 줄 cancelled·버전 충돌 version_conflict·형식 오류) → 매니저 조회 주소·전화 NULL → 남의 캠페인 not_found
--   (실제 블록은 적용 세션에서 개발 데이터로 짠다)
