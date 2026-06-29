-- ============================================================
-- 196_mark_orient_card_consumed.sql
-- 2026-06-23
--
-- 목적:
--   오리엔시트의 카드 1개를 발행 처리하는 관리자 전용 함수 신규 생성.
--   §15-11 "1 링크 N개 카드 → 캠페인 N개" 재설계에 따른 카드별 발행 추적.
--
-- 배경:
--   186 테이블 + 187 함수 주석에 mark_orient_consumed(orient_id, campaign_id) 를
--   PR 4에서 만든다고 명시했으나, 당시 전제는 "1 시트 = 1 캠페인" 1:1이었다.
--   §15-11 재설계(195)에서 1 시트 = 카드 N개 = 캠페인 N개로 변경되어
--   기존 함수 설계를 폐기하고, 카드 인덱스를 받는 이 함수로 대체한다.
--
-- 함수 시그니처:
--   mark_orient_card_consumed(
--     p_orient_id  uuid,    -- orient_sheets.id
--     p_card_idx   int,     -- data.cards 배열 인덱스 (0 기반)
--     p_campaign_id uuid    -- 이 카드로 발행한 캠페인(campaigns.id)
--   ) RETURNS jsonb
--
-- 반환값:
--   성공: {success:true, status, all_published:bool, published_count:int, total_count:int, version:int}
--   실패: {success:false, reason}
--
--   reason 종류:
--     not_found          — orient_id 없음
--     permission_denied  — is_admin() 불통 (관리자 미로그인)
--     invalid_status     — status가 submitted 아님 (draft/expired/consumed 차단)
--     invalid_card       — p_card_idx 범위 밖
--     already_published  — 해당 카드에 이미 campaign_id 기록됨 (카드별 멱등)
--     campaign_not_found — p_campaign_id 캠페인 미존재
--
-- 보안:
--   - SECURITY DEFINER + SET search_path = '' (security.md 필수 규칙)
--   - is_admin() 가드: campaign_manager 포함 전체 관리자 허용
--     (사용자 확정: 매니저도 발행 가능. 일본어 미보완 긴급 발행은 클라 게이트로 campaign_admin 제한)
--   - REVOKE PUBLIC → GRANT authenticated 명시
--   - FOR UPDATE 행 잠금으로 동시 발행 경쟁(race condition) 방지
--
-- 낙관적 락 및 동시성:
--   SELECT ... FOR UPDATE 로 이 함수가 진행하는 동안 같은 행을 잠근다.
--   두 관리자가 같은 카드를 동시에 발행 시도해도 첫 번째가 성공하고
--   두 번째는 already_published 로 거부된다. (version+1 로 낙관적 락 버전 추적도 병행)
--
-- all_published 판정:
--   data.cards 배열의 모든 원소에 campaign_id 키가 존재하고 NOT NULL 이면 전부 발행 완료.
--   모든 카드 발행 완료 시: status='consumed', consumed_at=now(),
--   단일 역참조 컬럼(campaign_id)=마지막 발행 캠페인(레거시 1:1 컬럼 존속 대응).
--
-- 운영 데이터 영향:
--   신규 함수이므로 기존 데이터 영향 없음.
--   orient_sheets 테이블의 data jsonb 컬럼만 UPDATE (cards[idx].campaign_id·published_at 추가).
--
-- 적용 순서:
--   186 → 187 → ... → 195 → 이 파일(196) → 197
--
-- 롤백:
--   DROP FUNCTION IF EXISTS public.mark_orient_card_consumed(uuid, int, uuid);
-- ============================================================

BEGIN;


-- ============================================================
-- mark_orient_card_consumed(p_orient_id, p_card_idx, p_campaign_id)
--
-- 카드 1개 발행 처리:
--   1. SELECT FOR UPDATE 행 잠금
--   2. 권한·상태·카드범위·멱등·캠페인 존재 검증 (순서대로)
--   3. data.cards[idx]에 campaign_id·published_at 기록 (jsonb_set 중첩)
--   4. version+1
--   5. 모든 카드 발행 완료 여부 집계 → all_published 판정
--   6. all_published 시 status='consumed', consumed_at, campaign_id(단일 역참조) 갱신
-- ============================================================
CREATE OR REPLACE FUNCTION public.mark_orient_card_consumed(
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
  v_now            timestamptz := now();

  -- cards 배열 처리용
  v_cards          jsonb;        -- 현재 cards 배열
  v_total_count    int;          -- 배열 전체 길이
  v_card_entry     jsonb;        -- 대상 카드 원소
  v_existing_cid   text;         -- 이미 기록된 campaign_id (멱등 검사)

  -- 갱신 후 집계용
  v_updated_cards  jsonb;        -- campaign_id 기록 후 cards 배열
  v_updated_data   jsonb;        -- data 전체 (cards 교체 후)
  v_published_count int := 0;   -- campaign_id 가 기록된 카드 수
  v_all_published  boolean;
  v_campaign_exists boolean;
BEGIN
  -- ── 권한 가드 ─────────────────────────────────────────────────────────
  -- campaign_manager 포함 전체 관리자 허용 (사용자 확정)
  IF NOT public.is_admin() THEN
    RETURN jsonb_build_object('success', false, 'reason', 'permission_denied');
  END IF;

  -- ── 행 잠금: SELECT FOR UPDATE ────────────────────────────────────────
  -- 같은 시트를 두 관리자가 동시에 다른 카드 발행 시 직렬화 보장
  SELECT id, status, data, version, campaign_id
    INTO v_sheet
    FROM public.orient_sheets
   WHERE id = p_orient_id
     FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;

  -- ── 상태 검증: submitted 인 경우만 발행 가능 ─────────────────────────
  -- draft  : 브랜드가 아직 제출 안 함 → 발행 불가
  -- expired: 토큰 만료 → 발행 불가
  -- consumed: 이미 전부 발행 완료 → 발행 불가
  IF v_sheet.status <> 'submitted' THEN
    RETURN jsonb_build_object(
      'success', false,
      'reason',  'invalid_status',
      'current_status', v_sheet.status
    );
  END IF;

  -- ── cards 배열 추출 ───────────────────────────────────────────────────
  v_cards       := COALESCE(v_sheet.data -> 'cards', '[]'::jsonb);
  v_total_count := jsonb_array_length(v_cards);

  -- ── 카드 인덱스 범위 검증 ─────────────────────────────────────────────
  -- 0 기반 인덱스: 유효 범위 [0, v_total_count - 1]
  -- 빈 cards 배열(total_count=0)이면 무조건 invalid_card
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
      'success',             false,
      'reason',              'already_published',
      'card_idx',            p_card_idx,
      'existing_campaign_id', v_existing_cid
    );
  END IF;

  -- ── 캠페인 존재 검증 ──────────────────────────────────────────────────
  SELECT EXISTS(
    SELECT 1 FROM public.campaigns WHERE id = p_campaign_id
  ) INTO v_campaign_exists;

  IF NOT v_campaign_exists THEN
    RETURN jsonb_build_object('success', false, 'reason', 'campaign_not_found');
  END IF;

  -- ── cards[p_card_idx]에 campaign_id·published_at 기록 ────────────────
  -- jsonb_set 2회 중첩:
  --   1차: cards 배열에서 idx 원소 교체 → cards[idx]에 campaign_id 추가
  --   2차: 1차 결과에 published_at 추가
  --
  -- '{인덱스}'는 jsonb_set의 path 표기 — 정수 인덱스는 TEXT로 캐스팅 필요
  v_updated_cards := jsonb_set(
    jsonb_set(
      v_cards,
      ARRAY[p_card_idx::text, 'campaign_id'],
      to_jsonb(p_campaign_id::text),
      true   -- create_missing: 키 없으면 추가
    ),
    ARRAY[p_card_idx::text, 'published_at'],
    to_jsonb(v_now::text),
    true
  );

  -- ── data 전체 재구성 (brand 등 나머지 필드 보존) ─────────────────────
  v_updated_data := jsonb_set(
    v_sheet.data,
    '{cards}',
    v_updated_cards,
    false  -- cards 키는 항상 존재 → create_missing 불필요
  );

  -- ── all_published 판정 ───────────────────────────────────────────────
  -- 갱신 후 cards 배열을 순회해 campaign_id 가 NOT NULL 인 카드 수 집계
  -- 전체 카드(v_total_count)와 같으면 모두 발행 완료
  SELECT COUNT(*)
    INTO v_published_count
    FROM jsonb_array_elements(v_updated_cards) AS card
   WHERE (card ->> 'campaign_id') IS NOT NULL;

  v_all_published := (v_published_count = v_total_count AND v_total_count > 0);

  -- ── UPDATE ────────────────────────────────────────────────────────────
  IF v_all_published THEN
    -- 모든 카드 발행 완료: consumed 전이
    -- campaign_id 단일 역참조 컬럼 = 마지막 발행분(레거시 1:1 컬럼 존속 대응)
    UPDATE public.orient_sheets
       SET data        = v_updated_data,
           version     = v_sheet.version + 1,
           status      = 'consumed',
           consumed_at = v_now,
           campaign_id = p_campaign_id   -- 마지막 발행 캠페인 (레거시 단일 역참조)
     WHERE id = v_sheet.id;
  ELSE
    -- 일부 카드 발행: status=submitted 유지
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
    'version',         v_sheet.version + 1
  );
END;
$$;

-- 기본 PUBLIC EXECUTE 권한 회수 → authenticated(관리자)에게만 명시 부여
-- anon 은 발행 불가 (is_admin() 가드가 이중 차단하지만 GRANT 레벨서도 제외)
REVOKE EXECUTE ON FUNCTION public.mark_orient_card_consumed(uuid, int, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.mark_orient_card_consumed(uuid, int, uuid) TO authenticated;

COMMENT ON FUNCTION public.mark_orient_card_consumed(uuid, int, uuid) IS
  '[196] 오리엔시트 카드 1개 발행 처리. §15-11 "1 링크 N카드 → N캠페인" 재설계. '
  'is_admin() 가드 — campaign_manager 포함 전체 관리자. '
  'p_orient_id: orient_sheets.id / p_card_idx: 0기반 카드 인덱스 / p_campaign_id: 발행 캠페인. '
  '검증 순서: 권한→행잠금→status=submitted→카드범위→멱등→캠페인존재. '
  'data.cards[idx].campaign_id·published_at 기록. version+1. '
  '모든 카드 발행 완료 시 status=consumed·consumed_at·campaign_id(레거시 단일). '
  'SECURITY DEFINER + search_path 고정.';


-- ============================================================
-- 스모크 테스트용 SELECT 예시 (주석 — SQL Editor에서 확인 용도)
-- ============================================================
--
-- [1] 함수 존재 확인
--   SELECT routine_name, routine_type, security_type
--   FROM information_schema.routines
--   WHERE routine_schema = 'public'
--     AND routine_name = 'mark_orient_card_consumed';
--
-- [2] 테스트 시트 제출 상태로 전환 (테스트용 — 실 운영 시 실행 금지)
--   UPDATE public.orient_sheets SET status = 'submitted' WHERE id = '<uuid>';
--
-- [3] 카드 1개 발행 호출 (관리자 로그인 후 SQL Editor 또는 JS rpc)
--   SELECT public.mark_orient_card_consumed(
--     '<orient_id>'::uuid,
--     0,                           -- 첫 번째 카드 (0기반)
--     '<campaign_id>'::uuid
--   );
--   -- 기대 결과: {success:true, status:"submitted" or "consumed", all_published:..., ...}
--
-- [4] data.cards 발행 결과 확인
--   SELECT id, status, version,
--          data -> 'cards' AS cards
--   FROM public.orient_sheets WHERE id = '<orient_id>';
--   -- cards[0].campaign_id 가 채워져 있어야 함
--
-- [5] 이미 발행된 카드 재호출 (멱등 검증)
--   SELECT public.mark_orient_card_consumed('<orient_id>'::uuid, 0, '<campaign_id>'::uuid);
--   -- 기대 결과: {success:false, reason:"already_published", ...}


-- PostgREST 스키마 캐시 재로드
NOTIFY pgrst, 'reload schema';


COMMIT;
