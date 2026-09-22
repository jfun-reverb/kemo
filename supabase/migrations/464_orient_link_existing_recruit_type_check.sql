-- ============================================================
-- 464 — 오리엔시트 「기존 캠페인 연결」 모집 형식 일치 검사
--
-- link_orient_card_to_campaign 재정의 (베이스 237 — 그 뒤 재정의 없음, 2026-09-22 확인).
-- 브랜드 일치 검사 직후·전역 중복 검사 전에 카드 form_type ↔ 캠페인 recruit_type·proxy_purchase
-- 일치를 본다. 불일치면 reason='recruit_type_mismatch'.
-- 인자 불변 → CREATE OR REPLACE(권한 보존). 237 과 같은 REVOKE/GRANT 를 다시 건다.
-- 사양서: docs/specs/2026-09-22-orient-link-existing-recruit-type-check.md
-- 오리엔시트 개편(424~463)과 무관 — 운영에 단독 적용 가능.
--
-- 되돌리기: 237 파일의 함수 정의를 그대로 다시 실행.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.link_orient_card_to_campaign(
  p_orient_id   uuid,
  p_card_idx    int,
  p_campaign_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sheet          record;
  v_campaign       record;
  v_now            timestamptz := now();

  v_cards          jsonb;
  v_total_count    int;
  v_card_entry     jsonb;
  v_existing_cid   text;

  v_already_linked boolean;

  v_updated_cards  jsonb;
  v_updated_data   jsonb;
  v_published_count int := 0;
  v_all_published  boolean;

  -- [464] 모집 형식 일치 검사
  v_card_ft        text;      -- 카드의 form_type
  v_exp_rt         text;      -- 기대하는 recruit_type
  v_exp_proxy      boolean;   -- 기대하는 proxy_purchase
BEGIN
  -- ── 권한 가드 ─────────────────────────────────────────────────────────
  IF NOT public.is_admin() THEN
    RETURN jsonb_build_object('success', false, 'reason', 'permission_denied');
  END IF;

  -- ── orient_sheets 행 잠금 ─────────────────────────────────────────────
  SELECT id, brand_id, application_id, status, data, version, campaign_id
    INTO v_sheet
    FROM public.orient_sheets
   WHERE id = p_orient_id
     FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;

  -- ── 상태 검증: submitted 인 경우만 연결 가능 (196과 동일) ────────────
  IF v_sheet.status <> 'submitted' THEN
    RETURN jsonb_build_object(
      'success', false,
      'reason',  'invalid_status',
      'current_status', v_sheet.status
    );
  END IF;

  -- ── cards 배열 추출 + 인덱스 범위 검증 ────────────────────────────────
  v_cards       := COALESCE(v_sheet.data -> 'cards', '[]'::jsonb);
  v_total_count := jsonb_array_length(v_cards);

  IF p_card_idx < 0 OR p_card_idx >= v_total_count THEN
    RETURN jsonb_build_object(
      'success',     false,
      'reason',      'invalid_card',
      'card_idx',    p_card_idx,
      'total_count', v_total_count
    );
  END IF;

  -- ── 멱등 검사: 해당 카드에 이미 campaign_id 기록 여부 ────────────────
  v_card_entry   := v_cards -> p_card_idx;
  v_existing_cid := v_card_entry ->> 'campaign_id';

  IF v_existing_cid IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success',              false,
      'reason',               'already_published',
      'card_idx',             p_card_idx,
      'existing_campaign_id', v_existing_cid
    );
  END IF;

  -- ── 캠페인 행 잠금 + 존재 확인 ────────────────────────────────────────
  -- FOR UPDATE 로 이 캠페인을 대상으로 하는 동시 연결 시도를 직렬화한다
  -- (아래 전역 중복 검사가 정확히 동작하려면 이 잠금이 검사보다 먼저 있어야 함).
  SELECT id, brand_id, campaign_no, recruit_type, proxy_purchase
    INTO v_campaign
    FROM public.campaigns
   WHERE id = p_campaign_id
     FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'campaign_not_found');
  END IF;

  -- ── 브랜드 일치 검증 ──────────────────────────────────────────────────
  IF v_campaign.brand_id IS DISTINCT FROM v_sheet.brand_id THEN
    RETURN jsonb_build_object(
      'success',           false,
      'reason',            'brand_mismatch',
      'sheet_brand_id',    v_sheet.brand_id,
      'campaign_brand_id', v_campaign.brand_id
    );
  END IF;

  -- ── [464] 모집 형식 일치 검증 ────────────────────────────────────────
  -- 카드 형식 → 캠페인 형식: reviewer→monitor+가구매 아님 / proxy_purchase→monitor+가구매 /
  --   seeding→gifting. 🔴 reviewer 와 proxy_purchase 는 recruit_type 이 같아(monitor)
  --   proxy_purchase 비교로만 가른다. 방문형(visit)은 대응하는 카드 형식이 없어 어느 카드로도 안 붙는다.
  -- 캠페인 행 잠금(위 FOR UPDATE) 뒤라 최신 값을 본다.
  -- 카드 형식이 셋 중 하나가 아니면(옛 데이터·예외) 판단 근거가 없어 막지 않는다.
  v_card_ft := v_card_entry ->> 'form_type';
  IF v_card_ft IN ('reviewer', 'seeding', 'proxy_purchase') THEN
    v_exp_rt    := CASE WHEN v_card_ft = 'seeding' THEN 'gifting' ELSE 'monitor' END;
    v_exp_proxy := (v_card_ft = 'proxy_purchase');
    IF v_campaign.recruit_type IS DISTINCT FROM v_exp_rt
       OR (v_exp_rt = 'monitor' AND v_campaign.proxy_purchase IS DISTINCT FROM v_exp_proxy) THEN
      RETURN jsonb_build_object(
        'success',                 false,
        'reason',                  'recruit_type_mismatch',
        'card_form_type',          v_card_ft,
        'campaign_recruit_type',   v_campaign.recruit_type,
        'campaign_proxy_purchase', v_campaign.proxy_purchase
      );
    END IF;
  END IF;

  -- ── 전역 중복 검사: 이 캠페인이 이미 "어떤" 시트의 "어떤" 카드에 연결됐는지 ──
  -- (campaigns 행 잠금 뒤에 수행 — 동시 연결 시도 직렬화 보장)
  SELECT EXISTS (
    SELECT 1
      FROM public.orient_sheets os2,
           LATERAL jsonb_array_elements(COALESCE(os2.data -> 'cards', '[]'::jsonb)) AS card2
     WHERE (card2 ->> 'campaign_id') = p_campaign_id::text
  ) INTO v_already_linked;

  IF v_already_linked THEN
    RETURN jsonb_build_object(
      'success', false,
      'reason',  'campaign_already_linked'
    );
  END IF;

  -- ── cards[p_card_idx]에 campaign_id·published_at·linked_existing 기록 ──
  v_updated_cards := jsonb_set(
    jsonb_set(
      jsonb_set(
        v_cards,
        ARRAY[p_card_idx::text, 'campaign_id'],
        to_jsonb(p_campaign_id::text),
        true
      ),
      ARRAY[p_card_idx::text, 'published_at'],
      to_jsonb(v_now::text),
      true
    ),
    ARRAY[p_card_idx::text, 'linked_existing'],
    to_jsonb(true),
    true
  );

  v_updated_data := jsonb_set(v_sheet.data, '{cards}', v_updated_cards, false);

  -- ── all_published 판정 (196과 동일 로직) ─────────────────────────────
  SELECT COUNT(*)
    INTO v_published_count
    FROM jsonb_array_elements(v_updated_cards) AS card
   WHERE (card ->> 'campaign_id') IS NOT NULL;

  v_all_published := (v_published_count = v_total_count AND v_total_count > 0);

  -- ── UPDATE ────────────────────────────────────────────────────────────
  IF v_all_published THEN
    UPDATE public.orient_sheets
       SET data        = v_updated_data,
           version     = v_sheet.version + 1,
           status      = 'consumed',
           consumed_at = v_now,
           campaign_id = p_campaign_id
     WHERE id = v_sheet.id;
  ELSE
    UPDATE public.orient_sheets
       SET data    = v_updated_data,
           version = v_sheet.version + 1
     WHERE id = v_sheet.id;
  END IF;

  -- ── 반환 ─────────────────────────────────────────────────────────────
  RETURN jsonb_build_object(
    'success',         true,
    'status',          CASE WHEN v_all_published THEN 'consumed' ELSE 'submitted' END,
    'all_published',   v_all_published,
    'published_count', v_published_count,
    'total_count',     v_total_count,
    'campaign_no',     v_campaign.campaign_no,
    'linked_existing', true,
    'version',         v_sheet.version + 1
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.link_orient_card_to_campaign(uuid, int, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.link_orient_card_to_campaign(uuid, int, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.link_orient_card_to_campaign(uuid, int, uuid) TO authenticated;

COMMENT ON FUNCTION public.link_orient_card_to_campaign(uuid, int, uuid) IS
  '[237→464] 오리엔시트 카드 1개를 관리자가 이미 만들어둔 기존 캠페인과 연결(발행 처리). '
  'is_admin() 가드. 검증 순서: 권한→시트잠금→status=submitted→카드범위→멱등→'
  '캠페인잠금·존재→브랜드일치→[464]모집형식일치(recruit_type_mismatch)→전역중복. '
  'data.cards[idx].campaign_id·published_at·linked_existing=true 기록. version+1. '
  'source_application_id 는 의도적으로 건드리지 않음. SECURITY DEFINER + search_path 고정.';

COMMIT;

-- ============================================================
-- 확인 (SQL Editor — 서비스 키라 is_admin() 이 거짓이므로 거부 경로는 관리자 브라우저에서 본다)
-- [V0] 정의에 새 검사가 들어갔는지
--   SELECT position('recruit_type_mismatch' in pg_get_functiondef(
--     'public.link_orient_card_to_campaign(uuid,int,uuid)'::regprocedure)) > 0 AS has_check;
-- [V1] 권한 — 비로그인 실행 불가, 로그인만
--   SELECT has_function_privilege('anon','public.link_orient_card_to_campaign(uuid,int,uuid)','EXECUTE') AS anon_exec,
--          has_function_privilege('authenticated','public.link_orient_card_to_campaign(uuid,int,uuid)','EXECUTE') AS auth_exec;
-- ============================================================
