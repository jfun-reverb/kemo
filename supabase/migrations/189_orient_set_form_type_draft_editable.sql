-- ============================================================
-- 189_orient_set_form_type_draft_editable.sql
-- 2026-06-18
--
-- 목적:
--   188_orient_set_form_type.sql의 잠금 정책을 완화.
--   "form_type NULL인 경우만 SET 가능"
--     → "draft 상태에서는 자유 변경, submitted 이후 잠금"으로 변경.
--
--   브랜드 담당자가 0단계에서 타입을 잘못 고르더라도
--   작성 중(draft)이면 다시 바꿀 수 있어야 한다는 UX 요구 반영.
--   제출(submit_orient_sheet) 후에는 form_type 변경 불가(type_locked).
--
-- 사양서:
--   docs/specs/2026-06-18-brand-self-orient-sheet.md
--   (PR 2 — 타입 선택 0단계 잠금 정책 완화)
--
-- 전제:
--   186_orient_sheets_table.sql  — orient_sheets 테이블 존재
--   187_orient_sheets_functions.sql — 기존 익명 함수 3종 존재
--   188_orient_set_form_type.sql — set_orient_form_type 최초 구현 존재
--
-- 변경 요약 (188 대비):
--   잠금 조건 변경:
--     [이전 188] form_type IS NOT NULL AND form_type != p_form_type → type_locked
--     [이번 189] status='submitted' AND form_type IS NOT NULL AND form_type != p_form_type → type_locked
--   즉 status='draft' 이면 form_type이 이미 있어도 자유 변경 허용.
--   status='submitted'이고 같은 값이면 멱등 성공(변경 없이 통과).
--   locked 반환 플래그 제거(불필요해짐 — 성공이면 항상 success:true, form_type).
--
-- 정합 확인:
--   - get_orient_sheet: form_type 반환 — 클라이언트가 현재 타입 확인 가능
--   - save_orient_draft: version(낙관적 락) 변경 — form_type과 독립
--   - submit_orient_sheet: status를 'submitted'로 전환 →
--     이후 set_orient_form_type 호출 시 type_locked로 거부되는 흐름 정합
--
-- 보안:
--   188과 동일 — SECURITY DEFINER + SET search_path=''
--   anon GRANT 유지 (비로그인 브랜드 담당자 호출)
--   FOR UPDATE 행 잠금 유지 (동시 호출 race condition 방지)
--
-- 운영 데이터 영향:
--   CREATE OR REPLACE FUNCTION으로 기존 함수 덮어쓰기.
--   테이블/컬럼 변경 없음.
--   기존 orient_sheets 행 데이터에 영향 없음.
--
-- 적용 순서:
--   186 → 187 → 188 → 이 파일(189)
--
-- 롤백:
--   아래 188 원본 로직으로 CREATE OR REPLACE FUNCTION 재실행하면
--   이전 잠금 정책(form_type NULL일 때만 SET)으로 되돌릴 수 있음.
--   빠른 롤백 SQL은 이 파일 맨 아래 주석 참조.
-- ============================================================

BEGIN;


-- ============================================================
-- A. set_orient_form_type(p_token uuid, p_form_type text) — 폼 타입 변경
--   [189 변경점] 잠금 조건: "form_type != p_form_type이면 무조건 잠금"
--                            → "status='submitted'이고 다른 값이면 잠금"
--   draft 상태에서는 기존 form_type 무관하게 자유 변경 허용.
--   제출(submitted) 후에만 변경 차단.
--   version은 건드리지 않음 — data 낙관적 락과 독립.
-- ============================================================
CREATE OR REPLACE FUNCTION public.set_orient_form_type(
  p_token     uuid,
  p_form_type text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sheet record;
BEGIN
  -- 토큰으로 오리엔시트 행 조회 (FOR UPDATE 행 잠금 — 동시 호출 race condition 방지)
  SELECT id, status, form_type, token_expires_at
    INTO v_sheet
    FROM public.orient_sheets
   WHERE token = p_token
     FOR UPDATE;

  -- 미매칭: UUID v4 엔트로피(122 bit)로 무차별 대입 사실상 불가.
  -- 잘못된 토큰은 success=false 반환 (자원 열거 공격 방지 — 140/187/188 패턴 동일)
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;

  -- 만료 시각 경과 확인 (쓰기 함수이므로 FOR UPDATE 잠금 하에 status='expired' 전환)
  IF v_sheet.token_expires_at IS NOT NULL AND v_sheet.token_expires_at < now() THEN
    IF v_sheet.status NOT IN ('expired', 'consumed') THEN
      UPDATE public.orient_sheets
         SET status = 'expired'   -- updated_at은 트리거가 자동 갱신
       WHERE id = v_sheet.id;
    END IF;
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;

  -- 쓰기 불가 상태 차단
  IF v_sheet.status = 'consumed' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'consumed');
  END IF;
  IF v_sheet.status = 'expired' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;

  -- p_form_type 입력값 검증: reviewer/seeding 외 거부
  IF p_form_type NOT IN ('reviewer', 'seeding') THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_type');
  END IF;

  -- [189 변경] 잠금 판정: status='submitted'이고 다른 값일 때만 거부
  --   188: form_type IS NOT NULL AND form_type != p_form_type → type_locked (draft도 포함)
  --   189: status='submitted' AND form_type IS NOT NULL AND form_type != p_form_type → type_locked
  --        status='draft'이면 form_type이 이미 있어도 자유 변경 허용
  IF v_sheet.status = 'submitted'
     AND v_sheet.form_type IS NOT NULL
     AND v_sheet.form_type <> p_form_type
  THEN
    -- 제출 후 다른 타입으로 변경 시도 → 거부
    RETURN jsonb_build_object(
      'success',            false,
      'reason',             'type_locked',
      'current_form_type',  v_sheet.form_type
    );
  END IF;

  -- UPDATE: draft 자유 변경 또는 최초 확정 또는 submitted 동일값 멱등
  -- version은 건드리지 않음 (data 낙관적 락과 독립)
  -- updated_at은 BEFORE UPDATE 트리거(trg_orient_sheets_updated_at)가 자동 갱신
  UPDATE public.orient_sheets
     SET form_type = p_form_type
   WHERE id = v_sheet.id;

  RETURN jsonb_build_object(
    'success',   true,
    'form_type', p_form_type
  );
END;
$$;

-- PostgreSQL 기본은 PUBLIC EXECUTE 권한 부여 → REVOKE 후 명시 GRANT 로 최소화
-- (CREATE OR REPLACE는 기존 권한을 초기화하므로 재선언 필요)
REVOKE EXECUTE ON FUNCTION public.set_orient_form_type(uuid, text) FROM PUBLIC;
-- 익명(anon) GRANT 필수: sales 폼은 비로그인 브랜드 담당자가 호출
GRANT EXECUTE ON FUNCTION public.set_orient_form_type(uuid, text) TO anon;

COMMENT ON FUNCTION public.set_orient_form_type(uuid, text) IS
  '[189] 오리엔시트 폼 타입 변경(188 잠금 정책 완화). anon GRANT — 로그인 없이 토큰+form_type으로 호출. '
  'draft 상태에서는 form_type 자유 변경 허용. '
  'submitted 후에는 다른 값으로 변경 시 type_locked 거부. '
  'version 미변경(data 낙관적 락과 독립). '
  'SECURITY DEFINER + search_path 고정.';


-- PostgREST 스키마 캐시 재로드 (함수 변경 즉시 인식)
NOTIFY pgrst, 'reload schema';


COMMIT;


-- ============================================================
-- 롤백 SQL (188 원본 잠금 로직으로 되돌리기)
-- 아래를 SQL Editor에서 실행하면 "form_type NULL일 때만 SET" 정책으로 복귀.
-- ============================================================
/*
CREATE OR REPLACE FUNCTION public.set_orient_form_type(
  p_token     uuid,
  p_form_type text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sheet record;
BEGIN
  SELECT id, status, form_type, token_expires_at
    INTO v_sheet
    FROM public.orient_sheets
   WHERE token = p_token
     FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;

  IF v_sheet.token_expires_at IS NOT NULL AND v_sheet.token_expires_at < now() THEN
    IF v_sheet.status NOT IN ('expired', 'consumed') THEN
      UPDATE public.orient_sheets SET status = 'expired' WHERE id = v_sheet.id;
    END IF;
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;

  IF v_sheet.status = 'consumed' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'consumed');
  END IF;
  IF v_sheet.status = 'expired' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;

  IF p_form_type NOT IN ('reviewer', 'seeding') THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_type');
  END IF;

  IF v_sheet.form_type IS NOT NULL THEN
    IF v_sheet.form_type = p_form_type THEN
      RETURN jsonb_build_object('success', true, 'form_type', v_sheet.form_type, 'locked', true);
    ELSE
      RETURN jsonb_build_object('success', false, 'reason', 'type_locked', 'current_form_type', v_sheet.form_type);
    END IF;
  END IF;

  UPDATE public.orient_sheets SET form_type = p_form_type WHERE id = v_sheet.id;
  RETURN jsonb_build_object('success', true, 'form_type', p_form_type);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.set_orient_form_type(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_orient_form_type(uuid, text) TO anon;

COMMENT ON FUNCTION public.set_orient_form_type(uuid, text) IS
  '[188] 오리엔시트 폼 타입 1회 확정(롤백 복원). form_type NULL인 경우만 SET 허용.';
NOTIFY pgrst, 'reload schema';
*/
