-- ============================================================
-- 191_delete_brand_orient_count.sql
-- 2026-06-19
--
-- 목적:
--   delete_brand(174) 함수에 orient_sheets 카운트 체크 추가.
--   브랜드에 연결된 오리엔시트가 있으면 삭제 거부.
--
-- 배경:
--   174_delete_brand_rpc.sql: campaigns·brand_applications 카운트만 검사.
--   186_orient_sheets_table.sql: brand_id ON DELETE RESTRICT 외래 키로 테이블 생성.
--   PR 3(create_orient_sheet)으로 발급이 가능해지면 orient_sheets 연결 행이
--   생길 수 있으므로, delete_brand의 가드에도 orient_sheets를 포함해야 함.
--   RESTRICT 외래 키가 있어 DB 레벨에서도 차단되지만,
--   사용자에게 친절한 한국어 오류 메시지를 내려주기 위해 함수 레벨 카운트 추가.
--
-- 변경 내용:
--   - delete_brand(p_brand_id uuid) CREATE OR REPLACE
--   - 기존 v_camps(캠페인 수)·v_apps(신청 수)에 v_sheets(오리엔시트 수) 추가
--   - 거부 조건: v_camps > 0 OR v_apps > 0 OR v_sheets > 0
--   - 거부 메시지에 오리엔시트 건수 포함
--   - 나머지 로직(권한·brand 존재 검증·DELETE·반환) 보존
--
-- 사양서:
--   docs/specs/2026-06-18-brand-self-orient-sheet.md §8(PR 3) — delete_brand 갱신
--
-- 전제:
--   174_delete_brand_rpc.sql     — 원본 함수 존재
--   186_orient_sheets_table.sql  — orient_sheets 테이블 존재 (brand_id FK RESTRICT)
--
-- 운영 데이터 영향:
--   CREATE OR REPLACE FUNCTION으로 기존 함수 덮어쓰기.
--   테이블/컬럼 변경 없음.
--   기존 delete_brand 호출 동작에 영향 없음
--   (기존에 orient_sheets 행이 없으면 v_sheets = 0, 거부 조건 미충족).
--
-- 롤백:
--   174_delete_brand_rpc.sql 내용을 SQL Editor에서 재실행하면
--   orient_sheets 카운트 없는 원본으로 복귀.
-- ============================================================

BEGIN;


-- ============================================================
-- A. delete_brand(p_brand_id uuid) — 브랜드 삭제 RPC 갱신
--    174 원본에서 v_sheets(orient_sheets 카운트) 추가.
--    나머지 권한·존재 검증·DELETE·반환 로직은 174 그대로 보존.
-- ============================================================
CREATE OR REPLACE FUNCTION public.delete_brand(p_brand_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_camps  bigint;
  v_apps   bigint;
  v_sheets bigint;   -- [191 추가] 연결된 오리엔시트 수
  v_exists boolean;
BEGIN
  -- 권한: campaign_admin 이상 (174 원본과 동일)
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (campaign_admin 이상 필요)' USING ERRCODE = '42501';
  END IF;

  SELECT EXISTS(SELECT 1 FROM public.brands WHERE id = p_brand_id) INTO v_exists;
  IF NOT v_exists THEN
    RAISE EXCEPTION '브랜드를 찾을 수 없습니다' USING ERRCODE = '22023';
  END IF;

  SELECT count(*) INTO v_camps  FROM public.campaigns          WHERE brand_id = p_brand_id;
  SELECT count(*) INTO v_apps   FROM public.brand_applications WHERE brand_id = p_brand_id;
  -- [191 추가] orient_sheets 연결 건수 조회
  SELECT count(*) INTO v_sheets FROM public.orient_sheets      WHERE brand_id = p_brand_id;

  -- [191 변경] 거부 조건에 v_sheets 추가
  IF v_camps > 0 OR v_apps > 0 OR v_sheets > 0 THEN
    RAISE EXCEPTION
      '연결된 캠페인 %건, 신청 %건, 오리엔시트 %건이 있어 삭제할 수 없습니다. 병합 기능을 사용하세요.',
      v_camps, v_apps, v_sheets
      USING ERRCODE = '22023';
  END IF;

  DELETE FROM public.brands WHERE id = p_brand_id;

  RETURN jsonb_build_object('ok', true, 'deleted', p_brand_id);
END;
$$;

COMMENT ON FUNCTION public.delete_brand(uuid) IS
  '[174+191] 브랜드 hard delete (연결 0건 한정). campaign_admin 가드. '
  '연결된 캠페인·신청·오리엔시트가 있으면 22023 + 병합 안내. '
  '[191] orient_sheets 카운트 체크 추가(174 대비 변경점).';

-- GRANT: 174와 동일. CREATE OR REPLACE는 기존 권한을 초기화하지 않지만 명시 재선언.
GRANT EXECUTE ON FUNCTION public.delete_brand(uuid) TO authenticated;


-- PostgREST 스키마 캐시 재로드
NOTIFY pgrst, 'reload schema';


COMMIT;
