-- ============================================================
-- 188_orient_set_form_type.sql
-- 2026-06-18
--
-- 목적:
--   브랜드 셀프 오리엔시트 폼 0단계(타입 선택)에서 리뷰어/시딩을
--   1회 확정하는 익명(anon) 함수 신규 생성.
--   form_type은 한 번 정하면 잠금 — 다른 값으로 재호출 시 거부.
--
-- 사양서:
--   docs/specs/2026-06-18-brand-self-orient-sheet.md (PR 2 — 타입 선택 0단계)
--
-- 전제:
--   186_orient_sheets_table.sql  — orient_sheets 테이블 존재
--   187_orient_sheets_functions.sql — 기존 익명 함수 3종 존재
--
-- 변경 내용:
--   [A] set_orient_form_type(p_token uuid, p_form_type text) → jsonb
--       - anon GRANT (비로그인 브랜드 담당자가 폼 0단계에서 호출)
--       - 토큰 미매칭      → {success:false, reason:'invalid_token'}
--       - 만료(시각 경과)  → status='expired' 전환 + {success:false, reason:'expired'}
--       - status consumed  → {success:false, reason:'consumed'}
--       - status expired   → {success:false, reason:'expired'}
--       - p_form_type 검증 → reviewer/seeding 외 {success:false, reason:'invalid_type'}
--       - 이미 설정된 form_type과 다른 값 → {success:false, reason:'type_locked', current_form_type}
--       - 이미 설정된 form_type과 같은 값 → 멱등 성공 {success:true, form_type, locked:true}
--       - form_type IS NULL → UPDATE 성공 {success:true, form_type}
--
-- 보안:
--   - SECURITY DEFINER + SET search_path='' (security.md 필수 규칙)
--   - PostgreSQL 기본 PUBLIC EXECUTE 권한 REVOKE 후 명시 GRANT
--   - 자원 열거 방지: 토큰 미매칭은 HTTP 200 + {success:false} (에러 코드 없음)
--   - FOR UPDATE 행 잠금으로 동시 호출 race condition 방지
--   - 선례: 187_orient_sheets_functions.sql 패턴 동일
--
-- 기존 함수(187)와의 정합:
--   - get_orient_sheet: form_type을 이미 반환 — 클라이언트는 폼 0단계 진입 시
--     form_type NULL인지 확인 후 set_orient_form_type 호출 여부 결정
--   - save_orient_draft / submit_orient_sheet: version(낙관적 락)을 변경하지 않음
--     (set_orient_form_type은 form_type 컬럼만 변경 — data/version과 독립)
--   - 충돌 없음: form_type 컬럼은 data/version 낙관적 락과 무관한 독립 필드
--
-- 운영 데이터 영향:
--   신규 함수이므로 기존 데이터 및 기존 함수 동작 영향 없음.
--
-- 적용 순서:
--   186 → 187 → 이 파일(188)
--
-- 롤백:
--   DROP FUNCTION IF EXISTS public.set_orient_form_type(uuid, text);
-- ============================================================

BEGIN;


-- ============================================================
-- A. set_orient_form_type(p_token uuid, p_form_type text) — 폼 타입 1회 확정
--   anon GRANT (비로그인 브랜드 담당자가 폼 0단계에서 호출)
--   form_type이 NULL인 경우만 SET 허용.
--   이미 설정된 경우:
--     - 같은 값 → 멱등 성공(locked:true)
--     - 다른 값 → 거부(type_locked)
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
  -- 잘못된 토큰은 success=false 반환 (자원 열거 공격 방지 — 140/187 패턴 동일)
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

  -- form_type 잠금 판정
  IF v_sheet.form_type IS NOT NULL THEN
    -- 이미 설정됨 — 같은 값이면 멱등 성공, 다른 값이면 거부
    IF v_sheet.form_type = p_form_type THEN
      -- 멱등 성공: 클라이언트가 같은 타입으로 재호출한 경우
      RETURN jsonb_build_object(
        'success',   true,
        'form_type', v_sheet.form_type,
        'locked',    true
      );
    ELSE
      -- 잠금 위반: 이미 다른 타입으로 확정된 토큰
      RETURN jsonb_build_object(
        'success',            false,
        'reason',             'type_locked',
        'current_form_type',  v_sheet.form_type
      );
    END IF;
  END IF;

  -- form_type IS NULL → 최초 확정 UPDATE
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
REVOKE EXECUTE ON FUNCTION public.set_orient_form_type(uuid, text) FROM PUBLIC;
-- 익명(anon) GRANT 필수: sales 폼은 비로그인 브랜드 담당자가 호출
GRANT EXECUTE ON FUNCTION public.set_orient_form_type(uuid, text) TO anon;

COMMENT ON FUNCTION public.set_orient_form_type(uuid, text) IS
  '[188] 오리엔시트 폼 타입 1회 확정. anon GRANT — 로그인 없이 토큰+form_type으로 호출. '
  'form_type NULL인 경우만 SET 허용(reviewer/seeding). '
  '이미 설정된 경우: 같은 값=멱등 성공(locked:true) / 다른 값=type_locked 거부. '
  'version 미변경(data 낙관적 락과 독립). '
  'SECURITY DEFINER + search_path 고정.';


-- PostgREST 스키마 캐시 재로드 (신규 함수 즉시 인식)
NOTIFY pgrst, 'reload schema';


COMMIT;
