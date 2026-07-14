-- ============================================================
-- 238_unlink_orient_card.sql
-- 2026-07-14
--
-- 목적:
--   237(link_orient_card_to_campaign)로 연결한(또는 196으로 발행한) 오리엔시트
--   카드 1개의 캠페인 연결을 되돌리는(해제) 관리자 전용 함수.
--   "카드는 제출된 채로 남기고, 이 카드에 붙어있던 campaign_id 만 뗀다."
--
-- 함수 시그니처:
--   unlink_orient_card(
--     p_orient_id uuid,   -- orient_sheets.id
--     p_card_idx  int     -- data.cards 배열 인덱스 (0 기반)
--   ) RETURNS jsonb
--
-- 검증 순서:
--   1. is_admin() 권한 가드
--   2. orient_sheets 행 잠금(FOR UPDATE)
--   3. 카드 인덱스 범위
--   4. 대상 카드에 campaign_id 가 없으면 not_linked (뗄 게 없음)
--   5. 카드에서 campaign_id·published_at·linked_existing 키 제거
--   6. version+1, status·consumed_at·레거시 campaign_id 컬럼 재계산(아래 참조)
--
-- 상태(status) 전이 규칙:
--   - 해제 전 status='consumed' (전 카드 발행 완료 상태)였다면, 이 해제로
--     최소 1장은 다시 미발행 상태가 되므로 all_published 는 항상 false가 된다
--     → status 를 'submitted' 로 되돌리고 consumed_at 을 NULL 로 지운다.
--   - 해제 전 status='submitted'(일부만 발행된 부분 발행 상태)였다면 그대로
--     'submitted' 유지 — 애초에 consumed 로 전이한 적이 없으므로 되돌릴 것도 없음.
--   - status 가 draft/expired 인 채로 카드에 campaign_id 가 박혀있는 경우는
--     정상 흐름에서 발생하지 않는다(196·237 둘 다 submitted 상태만 연결을
--     허용하므로). 방어적으로 이 함수는 그런 상태를 만나도 status 자체는
--     건드리지 않고 카드 데이터만 정리한다(상태를 임의로 되살리지 않음).
--
-- 레거시 단일 역참조 컬럼(orient_sheets.campaign_id) 재계산:
--   186 설계상 이 컬럼은 "카드 전부가 발행 완료된 순간의 마지막 발행 캠페인"만
--   의미를 가진다(부분 발행 상태에서는 계속 NULL). 그래서:
--   - 해제 전 status 가 'consumed' 였을 때만 이 컬럼을 재계산한다.
--     재계산 값 = 남은(campaign_id 가 아직 있는) 카드 중 published_at 이
--     가장 최근인 카드의 campaign_id, 남은 카드가 하나도 없으면 NULL.
--   - 해제 전 status 가 'submitted'(부분 발행) 였다면 이 컬럼은 원래도 NULL이므로
--     건드리지 않는다(196 관행과 일치 — 부분 발행 중엔 이 컬럼을 쓰지 않음).
--
-- linked_existing 마커:
--   196 경로로 만든 카드든 237 경로로 만든 카드든 구분 없이 동일하게
--   campaign_id·published_at·linked_existing 3개 키를 모두 제거한다.
--   해제는 어느 경로로 연결됐든 대칭적으로 동작해야 하고, 캠페인 자체를
--   삭제하지 않는다(연결 표시만 지운다 — 캠페인 행은 그대로 존재).
--
-- 반환값:
--   성공: {success:true, status, all_published, published_count, total_count,
--          unlinked_campaign_id, version}
--   실패: {success:false, reason}
--
--   reason 종류:
--     not_found          — orient_id 없음
--     permission_denied  — is_admin() 불통
--     invalid_card       — p_card_idx 범위 밖
--     not_linked         — 해당 카드에 애초에 campaign_id 가 없음(뗄 게 없음)
--
-- 보안:
--   - SECURITY DEFINER + SET search_path = '' (security.md 필수 규칙)
--   - is_admin() 가드 — 196·237과 동일하게 campaign_manager 포함 전체 관리자 허용
--   - REVOKE PUBLIC → GRANT authenticated 명시
--
-- 운영 데이터 영향:
--   신규 함수. orient_sheets.data jsonb만 UPDATE. 캠페인(campaigns) 행은
--   전혀 건드리지 않는다(삭제·수정 없음 — 연결 표시만 해제).
--
-- 적용 순서:
--   … → 237 → 이 파일(238)
--
-- 롤백:
--   DROP FUNCTION IF EXISTS public.unlink_orient_card(uuid, int);
-- ============================================================

BEGIN;


CREATE OR REPLACE FUNCTION public.unlink_orient_card(
  p_orient_id uuid,
  p_card_idx  int
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sheet             record;

  v_cards             jsonb;
  v_total_count       int;
  v_card_entry        jsonb;
  v_existing_cid      text;

  v_updated_cards     jsonb;
  v_updated_data      jsonb;
  v_published_count   int := 0;
  v_all_published     boolean;

  v_new_status        text;
  v_new_consumed_at   timestamptz;
  v_new_legacy_cid    uuid;
BEGIN
  -- ── 권한 가드 ─────────────────────────────────────────────────────────
  IF NOT public.is_admin() THEN
    RETURN jsonb_build_object('success', false, 'reason', 'permission_denied');
  END IF;

  -- ── orient_sheets 행 잠금 ─────────────────────────────────────────────
  SELECT id, status, data, version, campaign_id, consumed_at
    INTO v_sheet
    FROM public.orient_sheets
   WHERE id = p_orient_id
     FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
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

  -- ── 대상 카드에 campaign_id 가 있는지 확인 ────────────────────────────
  v_card_entry   := v_cards -> p_card_idx;
  v_existing_cid := v_card_entry ->> 'campaign_id';

  IF v_existing_cid IS NULL THEN
    RETURN jsonb_build_object(
      'success',  false,
      'reason',   'not_linked',
      'card_idx', p_card_idx
    );
  END IF;

  -- ── 카드에서 campaign_id·published_at·linked_existing 키 제거 ────────
  v_updated_cards := jsonb_set(
    v_cards,
    ARRAY[p_card_idx::text],
    (v_card_entry - 'campaign_id' - 'published_at' - 'linked_existing'),
    false
  );

  v_updated_data := jsonb_set(v_sheet.data, '{cards}', v_updated_cards, false);

  -- ── all_published 재판정 (해제 후 기준) ──────────────────────────────
  SELECT COUNT(*)
    INTO v_published_count
    FROM jsonb_array_elements(v_updated_cards) AS card
   WHERE (card ->> 'campaign_id') IS NOT NULL;

  v_all_published := (v_published_count = v_total_count AND v_total_count > 0);
  -- (참고) 방금 카드 1개를 해제했으므로 v_all_published 는 이론상 항상 false.

  -- ── status·consumed_at·레거시 campaign_id 재계산 ─────────────────────
  IF v_sheet.status = 'consumed' THEN
    -- 전 카드 발행 완료 상태였다가 이번 해제로 깨짐 → submitted 로 되돌림
    v_new_status      := 'submitted';
    v_new_consumed_at := NULL;

    -- 레거시 단일 역참조: 남은 카드 중 가장 최근 발행분으로 재계산 (없으면 NULL)
    SELECT (card ->> 'campaign_id')::uuid
      INTO v_new_legacy_cid
      FROM jsonb_array_elements(v_updated_cards) AS card
     WHERE (card ->> 'campaign_id') IS NOT NULL
     ORDER BY (card ->> 'published_at') DESC NULLS LAST
     LIMIT 1;
  ELSE
    -- 부분 발행(submitted) 상태였다면 상태·레거시 컬럼 모두 그대로 유지
    -- (186 관행: 레거시 campaign_id 는 consumed 전이 시점에만 의미를 가짐)
    v_new_status      := v_sheet.status;
    v_new_consumed_at := v_sheet.consumed_at;
    v_new_legacy_cid  := v_sheet.campaign_id;
  END IF;

  -- ── UPDATE ────────────────────────────────────────────────────────────
  UPDATE public.orient_sheets
     SET data        = v_updated_data,
         version     = v_sheet.version + 1,
         status      = v_new_status,
         consumed_at = v_new_consumed_at,
         campaign_id = v_new_legacy_cid
   WHERE id = v_sheet.id;

  -- ── 반환 ─────────────────────────────────────────────────────────────
  RETURN jsonb_build_object(
    'success',              true,
    'status',               v_new_status,
    'all_published',        v_all_published,
    'published_count',      v_published_count,
    'total_count',          v_total_count,
    'unlinked_campaign_id', v_existing_cid,
    'version',              v_sheet.version + 1
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.unlink_orient_card(uuid, int) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.unlink_orient_card(uuid, int) TO authenticated;

COMMENT ON FUNCTION public.unlink_orient_card(uuid, int) IS
  '[238] 오리엔시트 카드 1개의 캠페인 연결 해제(되돌리기). 196·237 어느 경로로 '
  '연결됐든 대칭 동작. is_admin() 가드. data.cards[idx]에서 campaign_id·'
  'published_at·linked_existing 키 제거. version+1. '
  '해제 전 status=consumed 였으면 submitted 로 되돌리고 consumed_at=NULL, '
  '레거시 단일 역참조 컬럼(campaign_id)은 남은 카드 중 최근 발행분으로 재계산(없으면 NULL). '
  '부분 발행(submitted) 상태였다면 상태·레거시 컬럼 모두 유지. '
  '캠페인(campaigns) 행 자체는 삭제·수정하지 않음 — 연결 표시만 해제. '
  'SECURITY DEFINER + search_path 고정.';


-- ============================================================
-- 스모크 테스트용 SELECT 예시 (주석 — SQL Editor에서 확인 용도)
-- ============================================================
--
-- [1] 함수 존재 확인
--   SELECT routine_name, routine_type, security_type
--   FROM information_schema.routines
--   WHERE routine_schema = 'public'
--     AND routine_name = 'unlink_orient_card';
--
-- [2] 해제 호출 (237 또는 196으로 이미 연결된 카드 대상)
--   SELECT public.unlink_orient_card('<orient_id>'::uuid, 0);
--   -- 기대: {success:true, status:"submitted", all_published:false, ...}
--
-- [3] 이미 해제된 카드 재호출 (not_linked 검증)
--   SELECT public.unlink_orient_card('<orient_id>'::uuid, 0);
--   -- 기대: {success:false, reason:"not_linked", ...}
--
-- [4] 기록 확인
--   SELECT id, status, version, campaign_id AS legacy_campaign_id,
--          data -> 'cards' AS cards
--   FROM public.orient_sheets WHERE id = '<orient_id>';
--   -- cards[0]에 campaign_id·published_at·linked_existing 키가 사라졌는지 확인


-- PostgREST 스키마 캐시 재로드
NOTIFY pgrst, 'reload schema';


COMMIT;
