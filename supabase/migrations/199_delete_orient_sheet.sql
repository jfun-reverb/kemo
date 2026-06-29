-- ============================================================
-- 199_delete_orient_sheet.sql
-- 2026-06-25
--
-- 목적:
--   오리엔시트 발급 목록에서 시트를 삭제하는 함수.
--   orient_sheets DELETE 행 단위 보안 정책(RLS)이 super_admin 한정(186)이라,
--   전체 관리자 삭제를 위해 SECURITY DEFINER 함수로 우회한다(RLS 완화는 안 함).
--
-- 사용자 확정 규칙 (2026-06-25):
--   ① 발행 캠페인이 연결 안 된 시트(작성중·제출됨·만료·미발행) = 시트 행만 삭제
--   ② 발행 캠페인이 연결된 시트(consumed 또는 일부 카드 발행) =
--        - 연결 캠페인 중 신청(applications)이 1건이라도 있으면 삭제 거부(차단)
--          → delete_brand(174) "연결 0건만 삭제"와 동일 정신
--        - 모든 연결 캠페인이 신청 0건이면 캠페인들 + 시트 함께 삭제(트랜잭션)
--   ③ 권한: 미발행 = is_admin() / 발행 캠페인 포함 = is_campaign_admin() 이상
--          (캠페인 삭제는 admin.js 에서 campaign_manager 차단 — 정합)
--   ④ 브랜드명 재입력 확인은 UI(캠페인 삭제 패턴) — 함수는 검증 안 함
--
-- 설계 메모 (reverb-supabase-expert + 경우의 수 8 반영):
--   - 분기 기준은 status 가 아니라 "발행 캠페인 연결 여부".
--     일부 카드만 발행된 submitted 시트도 그 캠페인을 보호 대상으로 본다.
--   - 발행 캠페인 수집: data.cards[].campaign_id 순회(DISTINCT).
--     orient_sheets.campaign_id 단일 컬럼은 "마지막 발행분"이라 cards 순회로 대체.
--   - 경쟁 상태 방어: 캠페인 행 FOR UPDATE 잠금 후 신청 수 체크
--     (체크~삭제 사이 신규 신청 INSERT 직렬화).
--   - 신청 수는 감사용(is_audit) 포함 전건 — 1건이라도 있으면 보호(실삭제 안전 우선).
--   - 캠페인 삭제 cascade(신청 0건 전제라 실질 0행): deliverables·캠페인 이력·홍보 로그 자동 삭제.
--     orient_sheets.campaign_id 는 ON DELETE SET NULL — 캠페인 먼저 지워도 시트 삭제 무해.
--
-- 반환 jsonb:
--   성공: {success:true, deleted_campaign_ids:[...]}
--   실패: {success:false, reason:'not_found'|'permission_denied'|'blocked_has_applications', ...}
--         blocked_has_applications 시 campaign_ids:[신청 있는 캠페인...] 동반
--
-- 전제: 186(orient_sheets) · 196(cards[].campaign_id) · is_admin()/is_campaign_admin()
-- 적용 순서: … → 198 → 이 파일(199)
-- 롤백: DROP FUNCTION IF EXISTS public.delete_orient_sheet(uuid);
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
  v_exists        boolean;
  v_data          jsonb;
  v_campaign_ids  uuid[];
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

  -- ── 연결 발행 캠페인 수집 (data.cards[].campaign_id, DISTINCT, 방어적) ──
  SELECT COALESCE(array_agg(DISTINCT cid), ARRAY[]::uuid[])
    INTO v_campaign_ids
    FROM (
      SELECT (card->>'campaign_id')::uuid AS cid
        FROM jsonb_array_elements(COALESCE(v_data->'cards', '[]'::jsonb)) AS card
       WHERE COALESCE(card->>'campaign_id', '') <> ''
    ) t;

  -- ── 권한 가드: 발행 캠페인 포함 여부로 분기 ──────────────────────────
  IF array_length(v_campaign_ids, 1) IS NOT NULL THEN
    -- 캠페인까지 삭제하는 파괴적 동작 — campaign_admin 이상
    IF NOT public.is_campaign_admin() THEN
      RETURN jsonb_build_object('success', false, 'reason', 'permission_denied');
    END IF;

    -- 캠페인 행 잠금(경쟁 상태 방어: 체크~삭제 사이 신규 신청 직렬화)
    PERFORM 1
       FROM public.campaigns
      WHERE id = ANY(v_campaign_ids)
      FOR UPDATE;

    -- 신청(applications) 1건이라도 있는 캠페인 수집 → 있으면 차단
    SELECT COALESCE(array_agg(DISTINCT a.campaign_id), ARRAY[]::uuid[])
      INTO v_blocked
      FROM public.applications a
     WHERE a.campaign_id = ANY(v_campaign_ids);

    IF array_length(v_blocked, 1) IS NOT NULL THEN
      RETURN jsonb_build_object(
        'success', false,
        'reason',  'blocked_has_applications',
        'campaign_ids', to_jsonb(v_blocked)
      );
    END IF;

    -- 신청 0건 확인 완료 → 캠페인 일괄 삭제(cascade: deliverables 등 자동)
    DELETE FROM public.campaigns WHERE id = ANY(v_campaign_ids);

  ELSE
    -- 발행 캠페인 없음(미발행) — 오리엔시트 행만 삭제, 전체 관리자 허용
    IF NOT public.is_admin() THEN
      RETURN jsonb_build_object('success', false, 'reason', 'permission_denied');
    END IF;
  END IF;

  -- ── 오리엔시트 행 삭제 ────────────────────────────────────────────────
  DELETE FROM public.orient_sheets WHERE id = p_orient_id;

  RETURN jsonb_build_object(
    'success', true,
    'deleted_campaign_ids', to_jsonb(v_campaign_ids)
  );
END;
$$;

-- 기본 PUBLIC 실행 권한 회수 후 authenticated(관리자)에게만 부여.
-- 실제 권한 분기(is_admin / is_campaign_admin)는 함수 내부에서 수행.
REVOKE EXECUTE ON FUNCTION public.delete_orient_sheet(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.delete_orient_sheet(uuid) TO authenticated;

COMMENT ON FUNCTION public.delete_orient_sheet(uuid) IS
  '[199] 오리엔시트 삭제. 발행 캠페인 연결 없으면 시트만 삭제(is_admin). '
  '연결 있으면 신청 0건 캠페인만 함께 삭제(is_campaign_admin), 신청 1건+ 있으면 '
  'blocked_has_applications 차단. FOR UPDATE 잠금·트랜잭션. SECURITY DEFINER + search_path 고정.';

NOTIFY pgrst, 'reload schema';

COMMIT;
