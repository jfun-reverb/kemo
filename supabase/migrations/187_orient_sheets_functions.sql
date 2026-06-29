-- ============================================================
-- 187_orient_sheets_functions.sql
-- 2026-06-18
--
-- 목적:
--   브랜드 셀프 오리엔시트 익명(anon) 토큰 함수 3종 생성.
--   로그인 없는 브랜드 담당자가 토큰 링크로 오리엔시트를
--   조회·임시저장·제출할 수 있도록 한다.
--
-- 사양서:
--   docs/specs/2026-06-18-brand-self-orient-sheet.md §6, §7, §8(PR 1)
--
-- 전제:
--   186_orient_sheets_table.sql 이 먼저 적용되어 있어야 함.
--
-- 변경 내용:
--   [A] get_orient_sheet(p_token uuid) → jsonb
--       - anon, authenticated GRANT
--       - 미매칭 → {success:false, reason:'invalid_token'} (자원 열거 방지)
--       - 만료(token_expires_at 경과) → {success:false, reason:'expired', status:'expired'}
--       - consumed → {success:false, reason:'consumed', status:'consumed'}
--       - expired 상태(명시) → {success:false, reason:'expired', status:'expired'}
--       - 성공 → {success:true, data, status, version, initial_values?}
--         initial_values: application_id 연결 시 brand_applications의 모집 희망값 포함(잔여②)
--
--   [B] save_orient_draft(p_token uuid, p_data jsonb, p_version int) → jsonb
--       - anon GRANT
--       - 만료·consumed·expired 상태 차단
--       - 낙관적 락: version 불일치 시 {success:false, reason:'conflict', current_version}
--       - jsonb 크기 상한 가드 (100KB)
--       - status='draft' 유지, version+1, updated_at 갱신
--
--   [C] submit_orient_sheet(p_token uuid, p_data jsonb, p_version int) → jsonb
--       - anon GRANT
--       - 만료·consumed·expired 상태 차단(draft·submitted 모두 허용 — 재제출 가능)
--       - 낙관적 락
--       - 기본 입력 검증(data 비어있지 않아야 함)
--       - draft/submitted → submitted 전이, submitted_at 기록(첫 제출만), version+1
--
-- 보안:
--   - 모두 SECURITY DEFINER + SET search_path='' (security.md 필수 규칙)
--   - PostgreSQL 기본 PUBLIC EXECUTE 권한 REVOKE 후 명시 GRANT
--   - 자원 열거 방지: 토큰 미매칭은 HTTP 200 + {success:false} (에러 코드 없음)
--   - 선례: 140_influencer_unsubscribe_token.sql 패턴 그대로 따름
--
-- PR 1 범위에서 제외:
--   - create_orient_sheet(p_brand_id, p_application_id) — 관리자 발급 함수 (PR 3)
--   - mark_orient_consumed(p_orient_id, p_campaign_id)  — 발행 소비 함수 (PR 4)
--
-- 운영 데이터 영향:
--   신규 함수이므로 기존 데이터 영향 없음.
--
-- 적용 순서:
--   186_orient_sheets_table.sql → 이 파일(187)
--
-- 롤백:
--   DROP FUNCTION IF EXISTS public.submit_orient_sheet(uuid, jsonb, int);
--   DROP FUNCTION IF EXISTS public.save_orient_draft(uuid, jsonb, int);
--   DROP FUNCTION IF EXISTS public.get_orient_sheet(uuid);
-- ============================================================

BEGIN;


-- ============================================================
-- A. get_orient_sheet(p_token uuid) — 토큰으로 오리엔시트 조회
--   anon + authenticated 양쪽 GRANT (sales 폼: 비로그인 브랜드 담당자 호출)
--   미매칭 시 success=false 반환 (HTTP 에러 없이 정상 200 — 자원 열거 방지)
--   연결된 신청(application_id)이 있으면 모집 희망값을 initial_values로 함께 반환 (잔여②)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_orient_sheet(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sheet          record;
  v_initial_values jsonb := NULL;
BEGIN
  -- 토큰으로 오리엔시트 행 조회
  SELECT id, brand_id, application_id, form_type, data, status, version,
         token_expires_at, submitted_at, consumed_at, campaign_id
    INTO v_sheet
    FROM public.orient_sheets
   WHERE token = p_token;

  -- 미매칭: UUID v4 엔트로피(122 bit)로 무차별 대입 사실상 불가.
  -- 잘못된 토큰은 success=false 반환 (자원 열거 공격 방지 — 140 패턴 동일)
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;

  -- consumed 상태: 캠페인 발행 완료, 더 이상 수정 불가
  IF v_sheet.status = 'consumed' THEN
    RETURN jsonb_build_object(
      'success', false,
      'reason',  'consumed',
      'status',  'consumed'
    );
  END IF;

  -- 만료 판정(P1-1): 조회 함수는 읽기 전용. 실제 status='expired' 전환은
  --   쓰기 함수(save_orient_draft·submit_orient_sheet)가 FOR UPDATE 잠금 하에 수행한다.
  --   여기서는 만료를 반환값으로만 알린다(조회 함수의 쓰기 부작용·동시 조회 race 제거).
  IF v_sheet.status = 'expired'
     OR (v_sheet.token_expires_at IS NOT NULL AND v_sheet.token_expires_at < now())
  THEN
    RETURN jsonb_build_object(
      'success', false,
      'reason',  'expired',
      'status',  'expired'
    );
  END IF;

  -- 연결된 신청이 있으면 모집 희망값을 initial_values로 반환 (잔여②)
  -- brand_applications의 관련 필드: products(모집 수량/종류), total_qty, total_jpy
  -- 추가로 form_type도 승계 참고로 포함
  IF v_sheet.application_id IS NOT NULL THEN
    SELECT jsonb_build_object(
             'form_type',   ba.form_type,
             'total_qty',   ba.total_qty,
             'total_jpy',   ba.total_jpy,
             'products',    ba.products
           )
      INTO v_initial_values
      FROM public.brand_applications ba
     WHERE ba.id = v_sheet.application_id;
    -- 신청 행이 삭제됐거나 못 찾으면 NULL 유지 (오류 없이 진행)
  END IF;

  -- 정상 반환: data, status, version + 초기값(있는 경우)
  RETURN jsonb_build_object(
    'success',        true,
    'id',             v_sheet.id,
    'form_type',      v_sheet.form_type,
    'data',           v_sheet.data,
    'status',         v_sheet.status,
    'version',        v_sheet.version,
    'submitted_at',   v_sheet.submitted_at,
    'initial_values', v_initial_values   -- NULL이면 JSON null로 직렬화됨
  );
END;
$$;

-- PostgreSQL 기본은 PUBLIC EXECUTE 권한 부여 → REVOKE 후 명시 GRANT 로 표면적 최소화
REVOKE EXECUTE ON FUNCTION public.get_orient_sheet(uuid) FROM PUBLIC;
-- 익명(anon) GRANT 필수: sales 폼은 비로그인 브랜드 담당자가 호출
GRANT EXECUTE ON FUNCTION public.get_orient_sheet(uuid) TO anon, authenticated;

COMMENT ON FUNCTION public.get_orient_sheet(uuid) IS
  '[187] 오리엔시트 토큰 조회. anon GRANT — 로그인 없이 토큰만으로 현재 내용·상태 반환. '
  '미매칭·만료·소비 상태는 success=false. '
  '연결 신청이 있으면 initial_values에 모집 희망값 포함. '
  'SECURITY DEFINER + search_path 고정.';


-- ============================================================
-- B. save_orient_draft(p_token uuid, p_data jsonb, p_version int) — 임시저장
--   anon GRANT (비로그인 브랜드 담당자가 폼 중간에 저장)
--   만료·consumed·expired 상태는 저장 차단.
--   낙관적 락: version 불일치 시 충돌 반환.
--   jsonb 크기 상한 100KB.
-- ============================================================
CREATE OR REPLACE FUNCTION public.save_orient_draft(
  p_token   uuid,
  p_data    jsonb,
  p_version int
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sheet       record;
  v_data_size   int;
  v_rows_updated int;
BEGIN
  -- 토큰으로 오리엔시트 행 조회 (FOR UPDATE 행 잠금 — 동시 저장 충돌 대비)
  SELECT id, status, version, token_expires_at
    INTO v_sheet
    FROM public.orient_sheets
   WHERE token = p_token
     FOR UPDATE;

  -- 미매칭
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

  -- 저장 불가 상태 차단
  IF v_sheet.status = 'consumed' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'consumed');
  END IF;
  IF v_sheet.status = 'expired' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;

  -- jsonb 크기 상한 가드 (100KB = 102400 바이트)
  v_data_size := octet_length(p_data::text);
  IF v_data_size > 102400 THEN
    RETURN jsonb_build_object(
      'success', false,
      'reason',  'data_too_large',
      'limit_bytes', 102400,
      'actual_bytes', v_data_size
    );
  END IF;

  -- 낙관적 락: 클라이언트가 보낸 version이 현재 DB version과 다르면 충돌
  IF p_version <> v_sheet.version THEN
    RETURN jsonb_build_object(
      'success',         false,
      'reason',          'conflict',
      'current_version', v_sheet.version
    );
  END IF;

  -- 임시저장: data·version만 갱신. status는 변경하지 않음(submitted→draft 역전환 없음, P0-1).
  --   updated_at은 BEFORE UPDATE 트리거(trg_orient_sheets_updated_at)가 자동 갱신.
  UPDATE public.orient_sheets
     SET data    = p_data,
         version = v_sheet.version + 1
   WHERE id      = v_sheet.id
     AND version = p_version;           -- 이중 낙관적 락 (FOR UPDATE + WHERE version)

  GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

  -- UPDATE가 0행이면 version 충돌(FOR UPDATE 이후 다른 트랜잭션이 먼저 커밋)
  IF v_rows_updated = 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'reason',  'conflict'
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'version', v_sheet.version + 1
  );
END;
$$;

-- PostgreSQL 기본 PUBLIC EXECUTE 권한 → REVOKE 후 익명(anon)만 명시 GRANT
--   ※ 관리자 대리 저장(authenticated GRANT)은 PR 3 관리자 흐름에서 필요 시 추가 예정.
REVOKE EXECUTE ON FUNCTION public.save_orient_draft(uuid, jsonb, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_orient_draft(uuid, jsonb, int) TO anon;

COMMENT ON FUNCTION public.save_orient_draft(uuid, jsonb, int) IS
  '[187] 오리엔시트 임시저장. anon GRANT — 로그인 없이 토큰·data·version으로 저장. '
  '만료·consumed 상태 차단. 낙관적 락(version 불일치=충돌 반환). jsonb 100KB 상한. '
  'status 미변경(submitted→draft 역전환 없음 — data·version만 갱신). '
  'SECURITY DEFINER + search_path 고정.';


-- ============================================================
-- C. submit_orient_sheet(p_token uuid, p_data jsonb, p_version int) — 제출
--   anon GRANT (비로그인 브랜드 담당자가 최종 제출)
--   draft, submitted 양쪽에서 전이 허용 (사양서 결정⑨: 발행 전 재편집·재제출 가능)
--   만료·consumed 차단.
--   낙관적 락.
--   기본 입력 검증: data가 비어있지 않아야 함.
-- ============================================================
CREATE OR REPLACE FUNCTION public.submit_orient_sheet(
  p_token   uuid,
  p_data    jsonb,
  p_version int
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sheet        record;
  v_data_size    int;
  v_rows_updated int;
  v_now          timestamptz := now();
BEGIN
  -- 토큰으로 오리엔시트 행 조회 (FOR UPDATE 행 잠금)
  SELECT id, status, version, token_expires_at, submitted_at
    INTO v_sheet
    FROM public.orient_sheets
   WHERE token = p_token
     FOR UPDATE;

  -- 미매칭
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;

  -- 만료 시각 경과 확인
  IF v_sheet.token_expires_at IS NOT NULL AND v_sheet.token_expires_at < v_now THEN
    IF v_sheet.status NOT IN ('expired', 'consumed') THEN
      UPDATE public.orient_sheets
         SET status = 'expired'   -- updated_at은 트리거가 자동 갱신
       WHERE id = v_sheet.id;
    END IF;
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;

  -- 제출 불가 상태 차단
  IF v_sheet.status = 'consumed' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'consumed');
  END IF;
  IF v_sheet.status = 'expired' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;

  -- 기본 입력 검증: data가 NULL이거나 빈 객체이면 제출 거부
  IF p_data IS NULL OR p_data = '{}'::jsonb THEN
    RETURN jsonb_build_object(
      'success', false,
      'reason',  'data_required'
    );
  END IF;

  -- jsonb 크기 상한 가드 (100KB = 102400 바이트)
  v_data_size := octet_length(p_data::text);
  IF v_data_size > 102400 THEN
    RETURN jsonb_build_object(
      'success',      false,
      'reason',       'data_too_large',
      'limit_bytes',  102400,
      'actual_bytes', v_data_size
    );
  END IF;

  -- 낙관적 락: version 불일치 시 충돌 반환
  IF p_version <> v_sheet.version THEN
    RETURN jsonb_build_object(
      'success',         false,
      'reason',          'conflict',
      'current_version', v_sheet.version
    );
  END IF;

  -- 제출 전이: draft | submitted → submitted
  -- submitted_at: 첫 제출 시각만 기록 (재제출 시 덮어쓰지 않음 — COALESCE)
  UPDATE public.orient_sheets
     SET data         = p_data,
         status       = 'submitted',
         submitted_at = COALESCE(v_sheet.submitted_at, v_now),
         version      = v_sheet.version + 1
         -- updated_at은 트리거가 자동 갱신
   WHERE id      = v_sheet.id
     AND version = p_version;

  GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

  IF v_rows_updated = 0 THEN
    RETURN jsonb_build_object('success', false, 'reason', 'conflict');
  END IF;

  RETURN jsonb_build_object(
    'success',      true,
    'version',      v_sheet.version + 1,
    'submitted_at', COALESCE(v_sheet.submitted_at, v_now)
  );
END;
$$;

-- PostgreSQL 기본 PUBLIC EXECUTE 권한 → REVOKE 후 익명(anon)만 명시 GRANT
--   ※ 관리자 대리 제출(authenticated GRANT)은 PR 3 관리자 흐름에서 필요 시 추가 예정.
REVOKE EXECUTE ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) TO anon;

COMMENT ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) IS
  '[187] 오리엔시트 제출. anon GRANT — 로그인 없이 토큰·data·version으로 최종 제출. '
  'draft·submitted 양쪽 허용(발행 전 재제출 가능). 만료·consumed 차단. '
  '낙관적 락. submitted_at은 첫 제출 시각만 기록. '
  'SECURITY DEFINER + search_path 고정.';


-- PostgREST 스키마 캐시 재로드 (신규 함수 즉시 인식)
NOTIFY pgrst, 'reload schema';


COMMIT;
