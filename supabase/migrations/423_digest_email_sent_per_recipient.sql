-- ============================================================
-- 423. 다이제스트 3종 — 수신자 단위 발송 기록 (전수조사 D-8)
--   사양서: docs/specs/2026-09-07-digest-per-recipient-send-record.md
--
-- 무엇을 고치나
--   인플루언서 일일·관리자 일일·브랜드 일일 다이제스트는 실행 단위 기록
--   (digest_date UNIQUE 자물쇠)만 있고 「누구에게 보냈는지」가 없다. 그래서
--   ①반복문 도중 죽으면 재시도가 전원에게 다시 보내고 ②일부만 실패해도
--   실행이 'sent' 로 닫혀 그 사람은 영영 못 받는다.
--
-- 이 파일이 하는 일 (4가지)
--   [1] 공용 표 public.digest_email_sent — (종류·날짜·수신자 열쇠) 유일.
--       선점 순서는 D-9(방침 통지, policy_notice_sent)와 같다:
--         INSERT status='failed' + skip_reason='in_flight@<ISO>' → 발송 → 성공 뒤에만 sent.
--       🔴 선점 「조건」과 「바꾸는 값」이 skip_reason 한 칸 — 다른 칸이면 두 실행이
--       같은 사람을 동시에 잡는다(D-9 첫 판 사고).
--   [2] 실행 표 3종의 status CHECK 에 'partial' 추가 — 일부 실패·진행 중·발송 뒤 기록
--       실패가 남은 실행은 'sent' 가 아니라 'partial' 로 닫히고, 당일 재호출의 재진입
--       대상이 된다(함수 쪽 조건 failed → failed 또는 partial).
--   [3] 90일 정리 함수 purge_old_digest_email_sent() + pg_cron (한국·일본 03:45).
--       ⚠️ 메일을 보내지 않는 정리 예약이라 **개발·운영 양쪽에 등록**한다(364·365 와 같고,
--       메일 예약 351 과는 다르다).
--   [4] 권한 — 표는 SELECT is_admin() 만(쓰기 정책 없음 = 서비스 키 전용). 정리 함수는
--       postgres·service_role 만. **부여 먼저, 회수 나중**(375 의 순서).
--
-- 배포 순서 🔴 데이터베이스 먼저 → Edge Function 3개 배포.
--   반대로 하면 표가 없어 첫 사람부터 record_error → 그날 다이제스트가 통째로 failed.
--   ⚠️ 적용 시각은 **오전 09:00(한국·일본) 앞뒤 10분을 피할 것** — [2]의 CHECK 재생성이 실행 표 3종에
--   짧은 배타 잠금을 걸어, 그 순간 돌고 있는 다이제스트 함수의 실행 표 쓰기와 잠깐 서로 기다린다.
--
-- 되돌리기 (필요 시, 순서대로)
--   SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'digest-email-sent-retention-daily';
--   DROP FUNCTION IF EXISTS public.purge_old_digest_email_sent();
--   DROP TABLE IF EXISTS public.digest_email_sent;          -- 트리거·함수는 아래 DROP 으로
--   DROP FUNCTION IF EXISTS public.touch_digest_email_sent_updated_at();
--   -- 실행 표 CHECK 는 'partial' 행이 없을 때만 되돌릴 수 있다:
--   -- ALTER TABLE public.<runs> DROP CONSTRAINT <runs>_status_check;
--   -- ALTER TABLE public.<runs> ADD CONSTRAINT <runs>_status_check CHECK (status IN ('sent','skipped_no_data','failed'));
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- [1] 수신자 단위 발송 기록 표
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.digest_email_sent (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  -- 네 번째 값은 예약(홍보 메일의 관리자 요약 — 같은 결함의 네 번째 자리. 코드는 이번에 안 건드린다)
  digest_kind    text        NOT NULL CHECK (digest_kind IN ('influencer_daily', 'admin_daily', 'brand_daily', 'promo_admin_summary')),
  digest_date    date        NOT NULL,
  -- 인플루언서 = 회원 id 문자열 / 관리자·브랜드 = 소문자 정규화 이메일
  recipient_key  text        NOT NULL,
  -- 인플루언서 종류만 채운다. 회원 이메일은 이 표에 남기지 않는다.
  influencer_id  uuid        NULL REFERENCES public.influencers(id) ON DELETE CASCADE,
  status         text        NOT NULL CHECK (status IN ('sent', 'skipped', 'failed')),
  -- no_email / send_failed / in_flight@<ISO 시각(UTC, 자릿수 고정)> — 선점 조건과 바꾸는 값이 이 한 칸
  skip_reason    text        NULL,
  error_message  text        NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT digest_email_sent_kind_date_key_uniq UNIQUE (digest_kind, digest_date, recipient_key)
);

COMMENT ON TABLE public.digest_email_sent IS
  '[423] 다이제스트 3종 수신자 단위 발송 기록(전수조사 D-8). (종류·날짜·수신자 열쇠) 유일 = 멱등. '
  '선점: status=failed + skip_reason=in_flight@<ISO> → 발송 → 성공 뒤에만 sent(skip_reason NULL). '
  '실패: failed + send_failed(재진입 대상). 이메일 없음: skipped + no_email(재시도 안 함). '
  '쓰기는 service_role 만(정책 없음). 90일 뒤 purge_old_digest_email_sent() 가 지운다.';
COMMENT ON COLUMN public.digest_email_sent.recipient_key IS
  '인플루언서 종류 = influencers.id 문자열 / 관리자·브랜드 종류 = trim+lower 정규화 이메일(함수 normalizeRecipientKey 한 곳에서만).';
COMMENT ON COLUMN public.digest_email_sent.skip_reason IS
  '선점 조건과 바꾸는 값이 이 한 칸. in_flight@<ISO UTC> 는 문자열 비교로 오래됨을 판정하므로 자릿수 고정 ISO 8601 이어야 한다.';

CREATE INDEX IF NOT EXISTS idx_digest_email_sent_kind_date_status
  ON public.digest_email_sent (digest_kind, digest_date, status);
CREATE INDEX IF NOT EXISTS idx_digest_email_sent_created_at
  ON public.digest_email_sent (created_at);

-- updated_at 갱신 트리거 — 표마다 전용 함수(touch_<표>_updated_at)를 두는 이 저장소 관례(345 등)
CREATE OR REPLACE FUNCTION public.touch_digest_email_sent_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.touch_digest_email_sent_updated_at() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.touch_digest_email_sent_updated_at() TO PUBLIC;

DROP TRIGGER IF EXISTS trg_digest_email_sent_updated_at ON public.digest_email_sent;
CREATE TRIGGER trg_digest_email_sent_updated_at
  BEFORE UPDATE ON public.digest_email_sent
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_digest_email_sent_updated_at();

-- 행 단위 보안 정책 — 읽기는 관리자, 쓰기 정책 없음(service_role 만 우회). policy_notice_sent(153)·campaign_promo_digest_sent(139) 와 같다.
ALTER TABLE public.digest_email_sent ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS digest_email_sent_select_admin ON public.digest_email_sent;
CREATE POLICY digest_email_sent_select_admin ON public.digest_email_sent
  FOR SELECT
  USING ((SELECT public.is_admin()));

-- ------------------------------------------------------------
-- [2] 실행 표 3종 status CHECK 에 'partial' 추가
--   130(influencer·admin 원형)·132·203 이 인라인 CHECK 라 이름을 안 줬다 → 자동 이름은
--   <표>_status_check 이지만, 이름을 가정하지 않고 pg_constraint 에서 찾아 갈아끼운다.
-- ------------------------------------------------------------
DO $$
DECLARE
  v_table  text;
  v_name   text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY['influencer_daily_digest_runs', 'admin_daily_digest_runs', 'brand_daily_digest_runs']
  LOOP
    -- status 칸에 걸린 CHECK 제약(들)을 전부 찾아 제거
    FOR v_name IN
      SELECT c.conname
      FROM   pg_constraint c
      JOIN   pg_class t ON t.oid = c.conrelid
      JOIN   pg_namespace n ON n.oid = t.relnamespace
      WHERE  n.nspname = 'public'
        AND  t.relname = v_table
        AND  c.contype = 'c'
        AND  pg_get_constraintdef(c.oid) ILIKE '%status%'
    LOOP
      EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I', v_table, v_name);
    END LOOP;

    EXECUTE format(
      'ALTER TABLE public.%I ADD CONSTRAINT %I CHECK (status IN (''sent'', ''skipped_no_data'', ''failed'', ''partial''))',
      v_table, v_table || '_status_check'
    );
  END LOOP;
END $$;

COMMENT ON COLUMN public.influencer_daily_digest_runs.status IS
  'sent=전원 성공 · skipped_no_data=대상 0건 · failed=선점 중(in-flight) 또는 전원 실패 · partial=일부 실패/진행 중/발송 뒤 기록 실패(423, 당일 재호출 재진입 대상).';
COMMENT ON COLUMN public.admin_daily_digest_runs.status IS
  'sent=전원 성공 · skipped_no_data=대상 0건 · failed=선점 중(in-flight) 또는 전원 실패 · partial=일부 실패/진행 중/발송 뒤 기록 실패(423, 당일 재호출 재진입 대상).';
COMMENT ON COLUMN public.brand_daily_digest_runs.status IS
  'sent=전원 성공 · skipped_no_data=대상 0건 · failed=선점 중(in-flight) 또는 전원 실패 · partial=일부 실패/진행 중/발송 뒤 기록 실패(423, 당일 재호출 재진입 대상).';

-- ------------------------------------------------------------
-- [3] 90일 정리 함수
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.purge_old_digest_email_sent()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_cutoff  timestamptz;
  v_deleted integer;
BEGIN
  -- 90일 — 사용자 결정(2026-09-07). 실행 표(하루 1행)는 종전대로 영구 보존.
  v_cutoff := now() - interval '90 days';

  DELETE FROM public.digest_email_sent
  WHERE created_at < v_cutoff;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RAISE NOTICE '[purge_old_digest_email_sent] cutoff=% deleted=% rows', v_cutoff, v_deleted;

  RETURN v_deleted;
END;
$$;

COMMENT ON FUNCTION public.purge_old_digest_email_sent() IS
  '[423] digest_email_sent 90일 보존 정리. created_at 기준 90일 경과 행 삭제, 삭제 건수 반환. '
  'SECURITY DEFINER, postgres·service_role 전용. pg_cron job: digest-email-sent-retention-daily '
  '(매일 한국·일본 03:45 = UTC 18:45). 개발·운영 양쪽 등록.';

-- [4] 실행 권한 — 🔴 부여 먼저, 회수 나중(375). 회수는 두 방향 모두(369·370 — 서로를 대신하지 못한다).
GRANT EXECUTE ON FUNCTION public.purge_old_digest_email_sent() TO postgres, service_role;
REVOKE ALL ON FUNCTION public.purge_old_digest_email_sent() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.purge_old_digest_email_sent() FROM anon, authenticated;

COMMIT;

-- ------------------------------------------------------------
-- pg_cron 등록 (트랜잭션 밖 — cron.schedule 은 자체 커밋. 166·243·258·286 과 같은 패턴)
--   시각: 한국·일본 03:45 = UTC 18:45. 04:00~05:30 은 예약 아홉 개가 몰려 있어(사양서 확인)
--   실패 원인을 가리기 어렵고, 03:30~03:59 는 비어 있다.
-- ------------------------------------------------------------
SELECT cron.unschedule(jobid)
FROM   cron.job
WHERE  jobname = 'digest-email-sent-retention-daily';

SELECT cron.schedule(
  'digest-email-sent-retention-daily',
  '45 18 * * *',                       -- 매일 UTC 18:45 (= 한국·일본 03:45)
  $$
  SELECT public.purge_old_digest_email_sent();
  $$
);

-- ============================================================
-- 검증 (적용 후 SQL 편집기에서)
-- ============================================================
-- [V1] 표·유일 제약·색인
--   SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
--   WHERE conrelid = 'public.digest_email_sent'::regclass ORDER BY conname;
--   -- 기대: PK · digest_email_sent_kind_date_key_uniq · CHECK(digest_kind) · CHECK(status) · FK(influencer_id, ON DELETE CASCADE)
--
-- [V2] 실행 표 3종 CHECK 에 partial 포함
--   SELECT t.relname, pg_get_constraintdef(c.oid) FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid
--   WHERE t.relname IN ('influencer_daily_digest_runs','admin_daily_digest_runs','brand_daily_digest_runs') AND c.contype='c';
--   -- 기대: 3행, 각각 'partial' 포함
--
-- [V3] 정책 — SELECT 하나만, 쓰기 정책 없음
--   SELECT policyname, cmd FROM pg_policies WHERE tablename = 'digest_email_sent';
--   -- 기대: digest_email_sent_select_admin / SELECT 1행
--
-- [V4] 정리 함수 권한 — proacl 맨 앞에 =X/ 가 없어야 한다(PUBLIC 회수 확인)
--   SELECT proname, proacl::text FROM pg_proc WHERE proname = 'purge_old_digest_email_sent';
--
-- [V5] 예약
--   SELECT jobname, schedule, active FROM cron.job WHERE jobname = 'digest-email-sent-retention-daily';
--   -- 기대: '45 18 * * *' / active=true
--
-- [V6] 선점 동작 재현(사양서 검증 2) — 되돌리기 트랜잭션 안에서
--   BEGIN;
--   INSERT INTO public.digest_email_sent (digest_kind, digest_date, recipient_key, status, skip_reason)
--     VALUES ('admin_daily', '2000-01-01', 'a@x', 'failed', 'in_flight@' || to_char(now() at time zone 'UTC' - interval '11 minutes', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'));
--   INSERT INTO public.digest_email_sent (digest_kind, digest_date, recipient_key, status, skip_reason)
--     VALUES ('admin_daily', '2000-01-01', 'b@x', 'failed', 'in_flight@' || to_char(now() at time zone 'UTC' - interval '9 minutes', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'));
--   INSERT INTO public.digest_email_sent (digest_kind, digest_date, recipient_key, status, skip_reason) VALUES ('admin_daily', '2000-01-01', 'c@x', 'sent', NULL);
--   INSERT INTO public.digest_email_sent (digest_kind, digest_date, recipient_key, status, skip_reason) VALUES ('admin_daily', '2000-01-01', 'd@x', 'failed', 'send_failed');
--   -- 함수의 넘겨받기 조건 그대로:
--   UPDATE public.digest_email_sent SET skip_reason = 'in_flight@' || to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
--   WHERE digest_kind='admin_daily' AND digest_date='2000-01-01' AND status='failed'
--     AND (skip_reason = 'send_failed' OR skip_reason < 'in_flight@' || to_char(now() at time zone 'UTC' - interval '10 minutes', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'))
--   RETURNING recipient_key;
--   -- 기대: a@x(11분 전) · d@x(send_failed) 두 행. b@x(9분 전)·c@x(sent) 는 안 걸린다.
--   ROLLBACK;
--
-- [V7] 정리 함수(사양서 검증 4) — 되돌리기 트랜잭션 안에서
--   BEGIN;
--   INSERT INTO public.digest_email_sent (digest_kind, digest_date, recipient_key, status, created_at)
--     VALUES ('admin_daily','2000-01-02','old@x','sent', now() - interval '91 days'), ('admin_daily','2000-01-02','new@x','sent', now() - interval '89 days');
--   SELECT public.purge_old_digest_email_sent();   -- 기대: 1 (운영에 다른 90일 초과 행이 없을 때)
--   SELECT recipient_key FROM public.digest_email_sent WHERE digest_date='2000-01-02';   -- 기대: new@x 만
--   ROLLBACK;
