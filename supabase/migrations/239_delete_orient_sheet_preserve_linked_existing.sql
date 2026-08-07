-- ============================================================
-- 239_delete_orient_sheet_preserve_linked_existing.sql
-- 2026-07-14
--
-- 목적:
--   199(delete_orient_sheet)를 수정해, 시트 삭제 시 "함께 삭제하는 캠페인"
--   집합에서 linked_existing:true 카드의 campaign_id를 제외한다.
--
-- 배경 (237 주석에서 예고한 후속 작업):
--   199는 "발행 캠페인은 이 시트를 위해 새로 태어난 캠페인이라 함께 지워도
--   안전하다"는 전제로, data.cards[].campaign_id 를 전부 삭제 대상으로 모았다.
--   그런데 237(link_orient_card_to_campaign)이 도입한 "기존 캠페인 연결" 경로는
--   그 전제를 깬다 — 관리자가 캠페인 관리에서 이미 독립적으로 만들어둔 캠페인을
--   오리엔시트 카드와 사후 연결(발행 표시)한 것뿐이라, 이 시트를 지운다고
--   그 기존 캠페인까지 사라지면 부주의한 데이터 손실이다.
--   237은 이 위험을 예견해 카드에 linked_existing:true 마커를 심어두고
--   "199를 아직 고치지 않았다"고 명시적으로 경고했다. 이 마이그레이션이 그 후속.
--
-- 199 대비 변경점 (그 외 전부 199 원본 로직 그대로 계승):
--   1. 삭제 대상 캠페인 수집 쿼리에 필터 추가:
--        AND COALESCE(card->>'linked_existing', 'false') <> 'true'
--      → 196(신규 발행) 경로로 만들어진 카드만 삭제 대상에 남는다.
--        237(기존 연결) 경로로 만들어진 카드는 제외된다.
--   2. 제외된(보존되는) 캠페인 id도 별도로 수집해 응답에
--        preserved_campaign_ids
--      로 포함한다 — 관리자가 "왜 이 캠페인은 안 지워졌지"를 화면에서
--      알 수 있도록 투명하게 반환(추가 키라 기존 클라이언트 코드와 호환).
--   3. 권한 분기 3단계로 세분화(199는 2단계):
--        ① 삭제 대상(v_delete_ids)이 1개 이상 → is_campaign_admin() 이상
--           (199와 동일 — 캠페인을 실제로 지우는 파괴적 동작이므로)
--        ② 삭제 대상은 0개지만 보존 대상(linked_existing)만 있는 시트
--           → is_admin() 이면 충분(캠페인을 전혀 건드리지 않으므로).
--           238(unlink_orient_card, 연결 해제)과 동일한 권한 등급으로 정합.
--        ③ 발행 캠페인 자체가 없음(미발행) → is_admin() (199와 동일)
--   4. 신청(applications) 차단 검사(blocked_has_applications)는
--      "삭제 대상(v_delete_ids)"에 대해서만 수행한다. 보존 대상 캠페인은
--      애초에 지우지 않으므로 신청이 있어도 차단 사유가 아니다.
--   5. FOR UPDATE 잠금도 삭제 대상 캠페인에만 건다. 보존 대상 캠페인은
--      전혀 수정하지 않으므로 잠글 이유가 없다.
--
-- 반환 jsonb (199 대비 preserved_campaign_ids 추가, 그 외 동일):
--   성공: {success:true, deleted_campaign_ids:[...], preserved_campaign_ids:[...]}
--   실패: {success:false, reason:'not_found'|'permission_denied'|'blocked_has_applications', ...}
--         blocked_has_applications 시 campaign_ids:[신청 있는 삭제대상 캠페인...] 동반
--
-- 전제: 186(orient_sheets) · 196(cards[].campaign_id) · 199(delete_orient_sheet 원본) ·
--       237(link_orient_card_to_campaign, linked_existing 마커 도입) ·
--       is_admin()/is_campaign_admin()
--
-- 적용 순서:
--   237·238과는 서로 독립(함수 정의 교체라 실행 순서 무관 — 237이 만드는
--   linked_existing 마커는 "값"일 뿐, 239는 그 값을 읽는 조회 필터만 바꾼다).
--   단 데이터 정합성 관점에서는 237이 먼저 배포돼 있어야 linked_existing:true
--   카드가 실제로 존재할 수 있다(239 자체는 마커가 없어도 안전하게 동작 —
--   전부 COALESCE(..., 'false') 로 기본값 처리).
--   … → 199 → 236 → 237 → 238 → 이 파일(239)
--
-- 롤백:
--   199 원본 CREATE OR REPLACE 재실행으로 되돌린다
--   (즉 199_delete_orient_sheet.sql 파일의 CREATE OR REPLACE FUNCTION 블록을
--    다시 실행 — 함수 OID가 유지되므로 GRANT 재부여 불필요).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.delete_orient_sheet(
  p_orient_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_data          jsonb;
  v_delete_ids    uuid[];  -- 함께 삭제할 캠페인(linked_existing 아닌 발행 카드)
  v_preserved_ids uuid[];  -- 보존할 캠페인(linked_existing=true 발행 카드)
  v_blocked       uuid[];
BEGIN
  -- ── 시트 행 잠금 + 존재 확인 ──────────────────────────────────────────
  SELECT data
    INTO v_data
    FROM public.orient_sheets
   WHERE id = p_orient_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;

  -- ── 함께 삭제할 발행 캠페인 수집 (linked_existing=true 카드는 제외, 239) ──
  -- linked_existing 마커가 있는 카드는 관리자가 독립적으로 만든 기존 캠페인을
  -- 237(link_orient_card_to_campaign)로 사후 연결한 것이라, 이 시트를 위해
  -- 새로 태어난 캠페인이 아니다 — 삭제 대상에서 제외해 보존한다.
  SELECT COALESCE(array_agg(DISTINCT cid), ARRAY[]::uuid[])
    INTO v_delete_ids
    FROM (
      SELECT (card->>'campaign_id')::uuid AS cid
        FROM jsonb_array_elements(COALESCE(v_data->'cards', '[]'::jsonb)) AS card
       WHERE COALESCE(card->>'campaign_id', '') <> ''
         AND COALESCE(card->>'linked_existing', 'false') <> 'true'
    ) t;

  -- ── 보존 대상(linked_existing=true) 캠페인 수집 — 응답 투명성 + 권한 분기용 ──
  SELECT COALESCE(array_agg(DISTINCT cid), ARRAY[]::uuid[])
    INTO v_preserved_ids
    FROM (
      SELECT (card->>'campaign_id')::uuid AS cid
        FROM jsonb_array_elements(COALESCE(v_data->'cards', '[]'::jsonb)) AS card
       WHERE COALESCE(card->>'campaign_id', '') <> ''
         AND COALESCE(card->>'linked_existing', 'false') = 'true'
    ) t;

  -- ── 권한 가드: 3단계 분기 ─────────────────────────────────────────────
  IF array_length(v_delete_ids, 1) IS NOT NULL THEN
    -- ① 실제로 삭제할 캠페인이 있음 — 파괴적 동작이므로 campaign_admin 이상
    IF NOT public.is_campaign_admin() THEN
      RETURN jsonb_build_object('success', false, 'reason', 'permission_denied');
    END IF;

    -- 삭제 대상 캠페인 행만 잠금(경쟁 상태 방어: 체크~삭제 사이 신규 신청 직렬화)
    -- 보존 대상(linked_existing) 캠페인은 건드리지 않으므로 잠그지 않는다.
    PERFORM 1
       FROM public.campaigns
      WHERE id = ANY(v_delete_ids)
      FOR UPDATE;

    -- 신청(applications) 1건이라도 있는 삭제 대상 캠페인 수집 → 있으면 차단
    SELECT COALESCE(array_agg(DISTINCT a.campaign_id), ARRAY[]::uuid[])
      INTO v_blocked
      FROM public.applications a
     WHERE a.campaign_id = ANY(v_delete_ids);

    IF array_length(v_blocked, 1) IS NOT NULL THEN
      RETURN jsonb_build_object(
        'success', false,
        'reason',  'blocked_has_applications',
        'campaign_ids', to_jsonb(v_blocked)
      );
    END IF;

    -- 신청 0건 확인 완료 → 삭제 대상 캠페인만 일괄 삭제(cascade: deliverables 등 자동)
    -- (linked_existing 캠페인은 v_delete_ids 에 없으므로 여기서 삭제되지 않음)
    DELETE FROM public.campaigns WHERE id = ANY(v_delete_ids);

  ELSIF array_length(v_preserved_ids, 1) IS NOT NULL THEN
    -- ② 삭제할 캠페인은 없지만(전부 linked_existing) 발행 표시는 있는 시트.
    --    캠페인을 전혀 건드리지 않으므로 파괴 등급이 아님 — is_admin() 이면 충분
    --    (238 unlink_orient_card 와 동일한 권한 등급으로 정합).
    IF NOT public.is_admin() THEN
      RETURN jsonb_build_object('success', false, 'reason', 'permission_denied');
    END IF;

  ELSE
    -- ③ 발행 캠페인 없음(미발행) — 오리엔시트 행만 삭제, 전체 관리자 허용
    IF NOT public.is_admin() THEN
      RETURN jsonb_build_object('success', false, 'reason', 'permission_denied');
    END IF;
  END IF;

  -- ── 오리엔시트 행 삭제 ────────────────────────────────────────────────
  DELETE FROM public.orient_sheets WHERE id = p_orient_id;

  RETURN jsonb_build_object(
    'success', true,
    'deleted_campaign_ids', to_jsonb(v_delete_ids),
    'preserved_campaign_ids', to_jsonb(v_preserved_ids)
  );
END;
$$;

-- 기본 PUBLIC 실행 권한 회수 후 authenticated(관리자)에게만 부여.
-- 실제 권한 분기(is_admin / is_campaign_admin)는 함수 내부에서 수행.
-- (CREATE OR REPLACE 는 함수 OID를 유지해 기존 GRANT를 보존하지만,
--  하우스 스타일대로 방어적으로 재선언한다.)
REVOKE EXECUTE ON FUNCTION public.delete_orient_sheet(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.delete_orient_sheet(uuid) TO authenticated;

COMMENT ON FUNCTION public.delete_orient_sheet(uuid) IS
  '[239] 오리엔시트 삭제(199 대체). 발행 캠페인 연결 없으면 시트만 삭제(is_admin). '
  '연결 있으면 linked_existing=true(237로 연결한 기존 캠페인) 카드는 삭제 대상에서 '
  '제외해 보존하고, 그 외(196 신규발행) 신청 0건 캠페인만 함께 삭제(is_campaign_admin). '
  '보존만 있는 시트는 is_admin(). 신청 1건+ 삭제대상 캠페인 있으면 '
  'blocked_has_applications 차단. FOR UPDATE 잠금·트랜잭션. SECURITY DEFINER + search_path 고정.';

NOTIFY pgrst, 'reload schema';

COMMIT;
