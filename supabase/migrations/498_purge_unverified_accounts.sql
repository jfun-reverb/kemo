-- ============================================================
-- 498_purge_unverified_accounts.sql
-- 회원가입 이메일 인증번호 — 조각 D6 「미인증 계정 정기 삭제 함수(예약 없음)」
--   선행: 493(설정 표) · 494(실행 기록 표) · 495(다른 기록 판정 도우미)
--   사양서 설계 ⑤
--
-- 대상
--   auth.users 중 email_confirmed_at 이 비어 있고,
--   COALESCE(confirmation_sent_at, created_at) 이 unverified_purge_days(493, 시작 7일)보다 오래된 계정.
--   🔴 created_at 만 보면 안 된다 — 다시 가입하면 생성 시각은 그대로이고 확인 메일만 새로 가서
--      방금 링크를 받은 사람이 그날 밤 지워진다(경우의 수 11·12).
--   제외: 관리자 계정(public.admins.auth_id) · 감사용 계정(influencers.is_audit).
--   건너뜀: _signup_unverified_has_records(495)가 참이면(응모·결과물·정산 등) 지우지 않고 고유번호를 남긴다.
--   ⚠️ policy_notice_log 는 「다른 기록」이 아니다 — 연쇄로 함께 지워진다(사용자 결정 2026-10-01).
--   🔴 「인증」은 이메일 인증만 — 관리자 인플루언서 관리의 인증/위반/블랙리스트와 무관하다.
--
-- 삭제 순서(253:139~141): 회원 행 → 신원(auth.identities) → 인증 계정.
--   인증 계정을 지워도 회원 행은 연쇄로 안 지워진다(2026-10-01 개발서버 실측) — 반드시 둘 다.
--   한 계정에서 오류가 나도 그 계정만 하위 블록으로 되돌리고 건너뛴 목록에 넣은 뒤 계속한다.
--
-- 실행 기록: 한 실행 = unverified_account_purge_runs 1행(지운 건수·건너뛴 건수·건너뛴 고유번호·오류).
--
-- 🔴 이 파일은 예약을 등록하지 않는다 — 사양서 단계 3(운영 전환, 첫 실행을 사람이 지켜본 뒤)에서
--    별도 마이그레이션으로 'unverified-accounts-purge-daily'(제안 UTC 20:45 = 도쿄 05:45 — 작업표 선결 9)를 건다.
--    그 전까지는 SQL 편집기로 수동 실행만 가능.
-- 🔴 첫 실행 전에 대상을 조회로 먼저 본다(아래 [V1]).
--
-- 롤백
--   DROP FUNCTION IF EXISTS public.purge_unverified_accounts();
-- ============================================================

CREATE OR REPLACE FUNCTION public.purge_unverified_accounts()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_days      integer;
  v_cutoff    timestamptz;
  v_id        uuid;
  v_deleted   integer := 0;
  v_skipped   uuid[]  := '{}';
  v_first_err text;
BEGIN
  SELECT unverified_purge_days INTO v_days FROM public.signup_code_settings WHERE id = 1;
  IF v_days IS NULL THEN
    -- 설정 표를 못 읽으면 아무것도 지우지 않는다(지우는 작업이라 기본값으로 진행하지 않는다).
    INSERT INTO public.unverified_account_purge_runs (deleted_count, skipped_count, skipped_ids, error_message)
    VALUES (0, 0, '{}', 'settings_missing');
    RETURN jsonb_build_object('deleted_count', 0, 'skipped_count', 0, 'skipped_ids', '[]'::jsonb,
                              'error', 'settings_missing');
  END IF;

  v_cutoff := now() - make_interval(days => v_days);

  FOR v_id IN
    SELECT u.id
      FROM auth.users u
     WHERE u.email_confirmed_at IS NULL
       AND coalesce(u.confirmation_sent_at, u.created_at) < v_cutoff
       AND NOT EXISTS (SELECT 1 FROM public.admins a WHERE a.auth_id = u.id)
       AND NOT EXISTS (SELECT 1 FROM public.influencers i WHERE i.id = u.id AND i.is_audit)
     ORDER BY u.created_at
  LOOP
    BEGIN
      IF public._signup_unverified_has_records(v_id) THEN
        v_skipped := v_skipped || v_id;
      ELSE
        DELETE FROM public.influencers WHERE id = v_id;
        DELETE FROM auth.identities    WHERE user_id = v_id;
        DELETE FROM auth.users         WHERE id = v_id;
        v_deleted := v_deleted + 1;
      END IF;
    EXCEPTION WHEN others THEN
      -- 이 계정만 되돌리고 건너뛴 목록에 넣는다(다른 계정은 계속)
      v_skipped := v_skipped || v_id;
      IF v_first_err IS NULL THEN
        v_first_err := left(SQLERRM, 300);
      END IF;
    END;
  END LOOP;

  INSERT INTO public.unverified_account_purge_runs (deleted_count, skipped_count, skipped_ids, error_message)
  VALUES (v_deleted, coalesce(array_length(v_skipped, 1), 0), v_skipped, v_first_err);

  RETURN jsonb_build_object(
    'deleted_count', v_deleted,
    'skipped_count', coalesce(array_length(v_skipped, 1), 0),
    'skipped_ids',   to_jsonb(v_skipped)
  );
END;
$$;

COMMENT ON FUNCTION public.purge_unverified_accounts() IS
  '[498] 미인증(이메일 인증 전) 계정 정기 삭제 — COALESCE(confirmation_sent_at, created_at)가 unverified_purge_days(시작 7일) 이전인 계정. '
  '관리자·감사용 제외, 다른 기록이 있으면 건너뛰고 고유번호 기록. 회원 행→신원→계정 순 삭제. 실행마다 unverified_account_purge_runs 1행. '
  'postgres 전용. 예약은 사양서 단계 3 에서 별도 마이그레이션으로 등록(이 파일은 안 건다).';

GRANT  EXECUTE ON FUNCTION public.purge_unverified_accounts() TO postgres;
REVOKE EXECUTE ON FUNCTION public.purge_unverified_accounts() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.purge_unverified_accounts() FROM anon, authenticated, service_role;

-- ------------------------------------------------------------
-- 검증 (개발서버, 1단계씩)
-- ------------------------------------------------------------
-- [V1] 🔴 첫 실행 전 대상 조회 — 지워질 후보(응모 등 다른 기록이 있으면 건너뛴다)
-- SELECT u.id, u.email, u.created_at, u.confirmation_sent_at,
--        public._signup_unverified_has_records(u.id) AS has_records
--   FROM auth.users u
--  WHERE u.email_confirmed_at IS NULL
--    AND coalesce(u.confirmation_sent_at, u.created_at)
--        < now() - make_interval(days => (SELECT unverified_purge_days FROM public.signup_code_settings WHERE id = 1))
--    AND NOT EXISTS (SELECT 1 FROM public.admins a WHERE a.auth_id = u.id)
--    AND NOT EXISTS (SELECT 1 FROM public.influencers i WHERE i.id = u.id AND i.is_audit)
--  ORDER BY u.created_at;
-- [V2] 시험 — 미인증 시험 계정 2개(하나는 응모 붙임, 가입·확인 메일 시각을 과거로) 만든 뒤 실행:
--      기대 = deleted 1 · skipped 1 · 실행 기록 1행
-- SELECT public.purge_unverified_accounts();
-- SELECT * FROM public.unverified_account_purge_runs ORDER BY run_at DESC LIMIT 3;
-- [V3] 예약이 없는지(이 파일은 안 건다)
-- SELECT jobname FROM cron.job WHERE jobname = 'unverified-accounts-purge-daily';   -- 0행
