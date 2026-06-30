-- ============================================================
-- 202_orient_submit_notification.sql
-- 2026-06-30
--
-- 목적:
--   오리엔시트 제출 알림 PR 1 — 데이터 + 개별 즉시 메일 기반 구축.
--
--   1) orient_sheets.last_submitted_at 컬럼 추가
--      - 재제출마다 now()로 갱신 (submitted_at은 최초 불변 유지)
--      - PR 2 브랜드 일일 보고에서 재제출 판정 기준 컬럼
--
--   2) submit_orient_sheet 함수 수정
--      - last_submitted_at = now() 추가 (매 제출 갱신)
--      - 반환값에 is_first_submission 플래그 추가 (신규/재제출 구분)
--      - 반환값에 orient_sheet_id, brand_id, form_type, application_id 추가
--        (Edge Function 메일 분기 참고용)
--
-- 사양서:
--   docs/specs/2026-06-30-orient-submit-notification.md §3·§4·§6
--
-- 트리거 방식:
--   Database Webhook (orient_sheets UPDATE + status='submitted' 필터)
--   → Edge Function notify-orient-submitted
--   (notify-brand-application Webhook 패턴 미러링 — §6 권고)
--
--   [Dashboard 수동 설정 필요 — 마이그레이션으로 자동화 불가]
--   Supabase Dashboard → Database → Webhooks → Create new Webhook
--     Name    : notify-orient-submitted
--     Table   : public.orient_sheets
--     Events  : UPDATE
--     Row filter : status = 'submitted'
--     Type    : Supabase Edge Functions
--     Function: notify-orient-submitted
--     HTTP Headers: (기본)
--   ⚠ 양 서버(개발/운영) 모두 설정 필요
--   ⚠ 재제출 시 status 불변이지만 last_submitted_at 변경으로 UPDATE 발생 → Webhook 트리거 됨
--   ⚠ draft 저장 시 NEW.status='draft' → Row filter에서 자동 차단 됨
--
-- 기존 기능 영향:
--   - submitted_at 의미(최초 불변) 보존 → admin-orient.js:203 회귀 없음
--   - submit_orient_sheet 인자 시그니처(token, data, version) 불변
--     → 기존 익명(anon) 호출(sales/orient.html) 호환 유지
--   - last_submitted_at 컬럼: NULL 허용 신규 컬럼
--     → 기존 행 NULL 시작, 영향 없음
--
-- 롤백:
--   ALTER TABLE public.orient_sheets DROP COLUMN IF EXISTS last_submitted_at;
--   -- submit_orient_sheet 롤백: 187_orient_sheets_functions.sql 의 정의로
--   --   CREATE OR REPLACE 로 되돌리기 (인자 시그니처 동일)
-- ============================================================

BEGIN;

-- ──────────────────────────────────────────────────────────────
-- 1. orient_sheets.last_submitted_at 컬럼 추가
-- ──────────────────────────────────────────────────────────────
ALTER TABLE public.orient_sheets
  ADD COLUMN IF NOT EXISTS last_submitted_at timestamptz;

COMMENT ON COLUMN public.orient_sheets.last_submitted_at IS
  '[202] 마지막 제출 시각. 신규·재제출 모두 now()로 갱신. '
  'submitted_at(최초 불변)과 분리해 재제출 이력 추적. '
  'PR 2 브랜드 일일 보고 재제출 판정 기준.';


-- ──────────────────────────────────────────────────────────────
-- 2. submit_orient_sheet 함수 수정
--    인자 시그니처: (p_token uuid, p_data jsonb, p_version int) — 불변 유지
--    변경 요약:
--      · last_submitted_at = now() 추가 (매 제출 갱신)
--      · 반환값에 is_first_submission, orient_sheet_id, brand_id,
--        form_type, application_id 추가
-- ──────────────────────────────────────────────────────────────
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
  v_is_first     boolean;
BEGIN
  -- 토큰으로 오리엔시트 행 조회 (FOR UPDATE 행 잠금 — 동시 제출 충돌 대비)
  SELECT id, brand_id, application_id, form_type,
         status, version, token_expires_at, submitted_at
    INTO v_sheet
    FROM public.orient_sheets
   WHERE token = p_token
     FOR UPDATE;

  -- 미매칭 (자원 열거 방지 — 187 패턴 유지)
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;

  -- 만료 시각 경과 확인 (쓰기 함수이므로 FOR UPDATE 잠금 하에 expired 전환)
  IF v_sheet.token_expires_at IS NOT NULL AND v_sheet.token_expires_at < v_now THEN
    IF v_sheet.status NOT IN ('expired', 'consumed') THEN
      UPDATE public.orient_sheets
         SET status = 'expired'
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

  -- 기본 입력 검증: data가 NULL 이거나 빈 객체이면 제출 거부
  IF p_data IS NULL OR p_data = '{}'::jsonb THEN
    RETURN jsonb_build_object('success', false, 'reason', 'data_required');
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

  -- 신규/재제출 판정 (갱신 전 submitted_at 기준 — 반환값·Edge Function 메일 분기용)
  v_is_first := (v_sheet.submitted_at IS NULL);

  -- 제출 전이: draft | submitted → submitted
  --   submitted_at : COALESCE — 첫 제출 시각만 기록 (재제출 시 불변)
  --   last_submitted_at : now() — 매 제출마다 갱신 (신규 컬럼, PR 2 일일 보고용)
  UPDATE public.orient_sheets
     SET data              = p_data,
         status            = 'submitted',
         submitted_at      = COALESCE(v_sheet.submitted_at, v_now),
         last_submitted_at = v_now,
         version           = v_sheet.version + 1
         -- updated_at 은 BEFORE UPDATE 트리거가 자동 갱신
   WHERE id      = v_sheet.id
     AND version = p_version;     -- 이중 낙관적 락 (FOR UPDATE + WHERE version)

  GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

  -- UPDATE 0행 = version 충돌 (FOR UPDATE 이후 다른 트랜잭션이 먼저 커밋)
  IF v_rows_updated = 0 THEN
    RETURN jsonb_build_object('success', false, 'reason', 'conflict');
  END IF;

  RETURN jsonb_build_object(
    -- 기존 반환 키 유지 (클라이언트 하위호환)
    'success',             true,
    'version',             v_sheet.version + 1,
    'submitted_at',        COALESCE(v_sheet.submitted_at, v_now),
    -- 신규 반환 키 (PR 1 — Edge Function 및 클라이언트 신규/재제출 분기용)
    'last_submitted_at',   v_now,
    'is_first_submission', v_is_first,
    'orient_sheet_id',     v_sheet.id,
    'brand_id',            v_sheet.brand_id,
    'form_type',           v_sheet.form_type,
    'application_id',      v_sheet.application_id
  );
END;
$$;

-- GRANT 재부여 (CREATE OR REPLACE 는 기존 GRANT 를 리셋하므로 187 과 동일하게 재적용)
REVOKE EXECUTE ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) TO anon;

COMMENT ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) IS
  '[202] 오리엔시트 제출. anon GRANT — 로그인 없이 토큰·data·version 으로 최종 제출. '
  'draft·submitted 양쪽 허용(발행 전 재제출 가능). 만료·consumed 차단. '
  '낙관적 락. submitted_at 은 최초 불변(COALESCE). last_submitted_at 은 매 제출 갱신. '
  '반환값에 is_first_submission·orient_sheet_id·brand_id·form_type·application_id 포함. '
  'SECURITY DEFINER + search_path 고정.';

-- PostgREST 스키마 캐시 재로드 (수정된 함수 즉시 인식)
NOTIFY pgrst, 'reload schema';

COMMIT;
