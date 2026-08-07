-- ============================================================
-- 237_link_orient_card_to_existing_campaign.sql
-- 2026-07-14
--
-- 목적:
--   오리엔시트 카드 1개를 "신규 캠페인 생성"이 아니라 관리자가 캠페인 관리에서
--   이미 직접 만들어둔 기존 캠페인에 연결(발행 상태로 전환)하는 관리자 전용 함수.
--
-- 배경:
--   196(mark_orient_card_consumed)은 "이 카드로 발행" 버튼이 add-campaign 폼을
--   거쳐 신규 캠페인을 INSERT 한 직후에만 호출된다(카드 데이터 → 새 캠페인 1:1).
--   이번 기능은 그 반대 경로 — 관리자가 이미 만든 기존 캠페인을 오리엔시트 카드와
--   사후 연결해 "이 카드는 이 캠페인으로 처리됐다"고 표시하고 싶은 경우다.
--   기록 대상 jsonb 키(campaign_id·published_at)는 196과 완전히 동일하게 유지해
--   기존 화면 로직(osCardsSummary·osStatusKey·delete_orient_sheet 등 카드 발행
--   판정 전부가 data.cards[].campaign_id 유무만 본다)을 그대로 재사용한다.
--
-- 함수 시그니처:
--   link_orient_card_to_campaign(
--     p_orient_id   uuid,   -- orient_sheets.id
--     p_card_idx    int,    -- data.cards 배열 인덱스 (0 기반)
--     p_campaign_id uuid    -- 연결할 기존 캠페인(campaigns.id) — 이 함수 호출 전에 이미 존재해야 함
--   ) RETURNS jsonb
--
-- 검증 순서 (196 계승 + 아래 2단계 추가):
--   1. is_admin() 권한 가드
--   2. orient_sheets 행 잠금(FOR UPDATE)
--   3. status = 'submitted' 인지 (draft/expired/consumed 차단 — 196과 동일)
--   4. 카드 인덱스 범위
--   5. 카드별 멱등(이미 이 카드에 campaign_id 기록됐으면 거부)
--   6. campaigns 행 잠금(FOR UPDATE) + 존재 확인
--      [신규] 7. 브랜드 일치 검증 — campaigns.brand_id = orient_sheets.brand_id 아니면 거부
--      [신규] 8. 캠페인 중복 참조 검증 — p_campaign_id가 이미 "어떤" 오리엔시트의
--                "어떤" 카드에도 기록돼 있으면 거부 (아래 「전역 중복 검사」 참조)
--   9. data.cards[idx]에 campaign_id·published_at 기록 + linked_existing:true 마커
--  10. version+1, 전 카드 발행 시 status=consumed 전이(196과 동일)
--
-- 전역 중복 검사 vs 같은 시트 내 중복 검사 (트레이드오프, 전역 채택):
--   - 같은 시트 내 중복만 본다면: 서로 다른 시트(다른 브랜드/다른 신청 맥락)의
--     카드 2개가 우연히 같은 캠페인을 가리키는 것은 걸러지지 않는다.
--     "카드 1개 = 캠페인 1개"라는 §15-11 설계 불변식이 시트 경계를 넘어 깨질 수 있고,
--     운영현황·비용 카드 등 캠페인→카드 역추적 로직이 다중 매칭을 가정하지 않는다.
--   - 전역 중복 검사(채택): orient_sheets 테이블 전체를 jsonb 순회해
--     이미 어느 카드든 이 campaign_id를 쓰고 있으면 차단. 쿼리 비용은
--     관리자 전용 소규모 테이블(수백~수천 행) 순회라 무시할 수준.
--   - 동시성: 6번에서 campaigns 행을 FOR UPDATE로 먼저 잠그므로, 두 관리자가
--     동시에 같은 캠페인을 서로 다른 카드에 연결 시도해도 첫 번째 트랜잭션이
--     커밋될 때까지 두 번째가 대기하고, 대기 후 재개된 시점에 전역 중복 검사가
--     그 사이 커밋된 첫 연결을 정확히 감지한다(잠금 획득 → 검사 순서 고정).
--
-- linked_existing 마커 (신규 카드 필드):
--   196 이 만든 카드는 "그 카드를 위해 새로 태어난 캠페인"이라 delete_orient_sheet(199)가
--   그 캠페인까지 함께 삭제해도 안전하다는 전제로 설계됐다.
--   이 함수로 연결한 카드는 그 전제가 깨진다 — 캠페인은 관리자가 별도로 이미
--   만들어둔 "독립적으로 존재하는" 캠페인이라, 오리엔시트 삭제 시 함께 지워지면
--   안 되는 데이터 손실 위험이 있다.
--   ⚠️ 이 마이그레이션은 199(delete_orient_sheet)를 수정하지 않는다(요청 범위 밖).
--      즉 **현재 상태로는 이 함수로 연결한 카드를 포함한 시트를 삭제하면
--      199가 여전히 그 기존 캠페인을 지우려 시도한다** — 후속 마이그레이션에서
--      199가 data.cards[].linked_existing=true 인 카드의 campaign_id는
--      삭제 대상에서 제외하도록 고쳐야 한다. 이 필드는 그 후속 작업을 위한
--      선행 표시(marker)로 지금 심어둔다.
--
-- source_application_id 보정 여부 — "건드리지 않음"으로 결정:
--   신규 발행 캠페인(196 경로)은 add-campaign 폼이 source_application_id를
--   채워서 INSERT 하지만, 관리자가 브랜드 서베이 화면 밖에서 직접 만든
--   "외부 캠페인"은 이 값이 NULL이다. 운영현황 비용 카드·get_brand_ops_detail
--   등이 이 값의 존재 여부로 조건 분기하므로, 시트의 application_id로
--   채워주면 유용해 보일 수 있다.
--   그러나 090(generate_campaign_no) 트리거는 BEFORE INSERT 전용이라 UPDATE로
--   source_application_id만 바꿔도 campaign_no 포맷(B{brand}-C{ext} vs
--   B{brand}-A{app}-C{camp})은 재채번되지 않는다 → "번호 포맷은 외부 캠페인인데
--   신청 연결은 돼 있는" 불일치 상태가 생긴다.
--   이 정합성은 이미 전용 RPC(121: link_campaign_to_application)가
--   pg_advisory_xact_lock 2단 잠금 + 채번 재발급까지 포함해 온전히 처리하고
--   있고, 관리자 화면(브랜드 운영 → 캠페인 「연결」 버튼)에도 이미 노출돼 있다.
--   이 함수가 절반만 흉내 낸 UPDATE로 source_application_id를 슬쩍 채우면
--   그 전용 경로와 어긋난 상태를 만들 위험이 더 크므로, 이 함수는
--   source_application_id를 전혀 건드리지 않는다. 신청 연결까지 원하면
--   관리자가 121번 기능을 이 함수와 별도로 수행하면 된다(양립 가능, 순서 무관).
--
-- 반환값:
--   성공: {success:true, status, all_published, published_count, total_count,
--          campaign_no, version, linked_existing:true}
--   실패: {success:false, reason}
--
--   reason 종류:
--     not_found              — orient_id 없음
--     permission_denied      — is_admin() 불통
--     invalid_status         — status가 submitted 아님
--     invalid_card           — p_card_idx 범위 밖
--     already_published      — 해당 카드에 이미 campaign_id 기록됨
--     campaign_not_found     — p_campaign_id 캠페인 미존재
--     brand_mismatch         — 캠페인의 brand_id가 시트의 brand_id와 다름
--     campaign_already_linked — p_campaign_id가 이미 어떤 오리엔시트의
--                                어떤 카드에 연결돼 있음(전역 검사)
--
-- 보안:
--   - SECURITY DEFINER + SET search_path = '' (security.md 필수 규칙)
--   - is_admin() 가드 — 196과 동일하게 campaign_manager 포함 전체 관리자 허용
--   - REVOKE PUBLIC → GRANT authenticated 명시
--
-- 운영 데이터 영향:
--   신규 함수. orient_sheets.data jsonb만 UPDATE. 기존 데이터 영향 없음.
--
-- 적용 순서:
--   … → 236 → 이 파일(237) → 238
--
-- 롤백:
--   DROP FUNCTION IF EXISTS public.link_orient_card_to_campaign(uuid, int, uuid);
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
  SELECT id, brand_id, campaign_no
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
GRANT  EXECUTE ON FUNCTION public.link_orient_card_to_campaign(uuid, int, uuid) TO authenticated;

COMMENT ON FUNCTION public.link_orient_card_to_campaign(uuid, int, uuid) IS
  '[237] 오리엔시트 카드 1개를 관리자가 이미 만들어둔 기존 캠페인과 연결(발행 처리). '
  '196(mark_orient_card_consumed)의 신규발행 흐름과 반대로, 기존 campaigns 행을 대상으로 한다. '
  'is_admin() 가드. 검증 순서: 권한→시트잠금→status=submitted→카드범위→멱등→'
  '캠페인잠금·존재→브랜드일치→전역중복(어떤 시트든 이미 이 캠페인 참조 여부). '
  'data.cards[idx].campaign_id·published_at·linked_existing=true 기록. version+1. '
  'source_application_id 는 의도적으로 건드리지 않음(121번 link_campaign_to_application 이 '
  '채번 재발급까지 포함해 전담 — 이 함수가 절반만 UPDATE 하면 campaign_no 포맷과 불일치 생김). '
  '⚠️ delete_orient_sheet(199) 는 아직 linked_existing 마커를 모른다 — 후속 마이그레이션 필요. '
  'SECURITY DEFINER + search_path 고정.';


-- ============================================================
-- 스모크 테스트용 SELECT 예시 (주석 — SQL Editor에서 확인 용도)
-- ============================================================
--
-- [1] 함수 존재 확인
--   SELECT routine_name, routine_type, security_type
--   FROM information_schema.routines
--   WHERE routine_schema = 'public'
--     AND routine_name = 'link_orient_card_to_campaign';
--
-- [2] 정상 연결 (관리자 로그인 후)
--   SELECT public.link_orient_card_to_campaign(
--     '<orient_id>'::uuid, 0, '<campaign_id>'::uuid
--   );
--   -- 기대: {success:true, status:"submitted" or "consumed", linked_existing:true, ...}
--
-- [3] 브랜드 불일치 재현
--   -- 다른 브랜드 소유 캠페인 id 를 넣으면
--   -- {success:false, reason:"brand_mismatch", ...}
--
-- [4] 전역 중복 재현
--   -- [2]에서 이미 연결한 campaign_id 를 다른 카드에 다시 연결 시도하면
--   -- {success:false, reason:"campaign_already_linked"}
--
-- [5] 기록 확인
--   SELECT id, status, version, data -> 'cards' AS cards
--   FROM public.orient_sheets WHERE id = '<orient_id>';
--   -- cards[0].campaign_id · published_at · linked_existing=true 확인


-- PostgREST 스키마 캐시 재로드
NOTIFY pgrst, 'reload schema';


COMMIT;
