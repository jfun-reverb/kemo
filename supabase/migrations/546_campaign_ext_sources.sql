-- ============================================================
-- 546_campaign_ext_sources.sql
-- 2026-10-19 — 외부 결과 파일(다른 서비스 — 포인테일)을 캠페인에 붙인다
--   작업표 docs/specs/2026-10-19-brand-campaign-results-breakdown.md 「조각 3」 · 결정 D9·D10 · S20
--   사양서 docs/specs/2026-07-15-brand-portal.md 16-5 15번 ①(외부 파일을 캠페인에 첨부) · ⑦(모집 현황에 외부 참가자 수)
--
-- 무엇을 하나
--   표   campaign_report_sources: campaign_id 칸 추가 · report_id NULL 허용 · 「둘 중 정확히 하나」 검사 · 캠페인용 유일 색인
--   함수 attach_campaign_ext_source(campaign, ext_no, ext_name, file_name, rows)  붙이기·업데이트(같은 외부 번호면 줄 전부 교체 — 410 과 같다)
--   함수 detach_campaign_ext_source(source)                                       떼기(캠페인 첨부만)
--   함수 get_campaign_ext_sources(campaign)                                       관리자 조회 {sources, ext_rows}
--   함수 _campaign_ext_participant_count(campaign)                               내부 — 외부 참가자 수(조각 4 의 모집 현황 합산용)
--   410 replace_report_source_rows · remove_report_source — 리포트 첨부만 받도록 한 줄씩 막는다(첨부 번호만 받아 캠페인 첨부도 건드릴 수 있었다)
--   적용만으로 바뀌는 기존 동작: 없음(기존 줄은 모두 report_id 가 있어 검사를 통과한다).
--
-- 🔴 운영 반영 — 작업표 「사전」 단계(출시 전에 먼저 — 16-5 15번 ② 「배포 순서 1번」). 브랜드 묶음(526~)과 545 에 기대지 않는다.
-- 🔴 리포트 공유(get_report_share_data 545)·리포트 화면(410 get_campaign_report)은 report_id 로만 찾는다 —
--    캠페인에 붙인 파일은 공유 링크로 새지 않는다(배포 순서 1번의 조건).
--
-- 계약
--   · 권한: 쓰기 has_permission('menu.reports','write') · 읽기 has_permission('menu.reports','read') — 410 리포트 첨부와 같은 등급(결정 D10 「지금대로」 —
--     404 시드상 매니저 숨김). 공개 셋 authenticated 만 · 내부 하나는 셋 다 회수.
--   · 행 단위 보안: 409 정책(SELECT has_permission('menu.reports','read'))이 캠페인 첨부 줄에도 그대로 걸린다 — 화면이 표를 직접 읽어도 같은 등급.
--   · 줄 넣기는 410 의 _insert_report_ext_rows 를 그대로 쓴다(칸 이름·형 변환 한 벌).
--   · 보관 삭제된 캠페인(deleted_at)에는 붙이지 않는다. 캠페인 완전 삭제 때 첨부·줄이 함께 지워진다(ON DELETE CASCADE).
--   · ⚠️ 보관 삭제(soft_delete_campaign) 때는 첨부·줄이 **남는다**(30일 뒤 완전 삭제까지) — 신청·결과물은 즉시 파기되는데 외부 참가자의
--     주문번호·영수증 주소는 남는다. 브랜드 화면은 보관 삭제 캠페인을 안 보여 주지만(543 [A]) 데이터는 그대로 — 작업표 후속 과제(보관 삭제 때 함께 지우기).
--
-- 🔴 반환 칸을 바꾸려면 DROP 후 CREATE 라 실행 권한 회수를 다시 걸어야 한다. 다음 재정의의 베이스는 이 파일(546).
--    410 의 두 함수(replace_report_source_rows · remove_report_source)의 현재 원본도 이 파일이다.
-- 편집기 경고: 실행 구문에 DELETE 가 있다 — attach(교체 때 옛 줄 지우기)·detach(첨부 지우기)·410 두 함수 본문. DROP 없음.
--
-- 롤백(화면 조각 12 를 먼저 되돌리고, 캠페인 첨부 줄을 먼저 지운 뒤):
--   DELETE FROM public.campaign_report_sources WHERE campaign_id IS NOT NULL;
--   DROP FUNCTION IF EXISTS public._campaign_ext_participant_count(uuid);
--   DROP FUNCTION IF EXISTS public.get_campaign_ext_sources(uuid);
--   DROP FUNCTION IF EXISTS public.detach_campaign_ext_source(uuid);
--   DROP FUNCTION IF EXISTS public.attach_campaign_ext_source(uuid, text, text, text, jsonb);
--   DROP INDEX IF EXISTS public.campaign_report_sources_campaign_ext_uidx;
--   ALTER TABLE public.campaign_report_sources DROP CONSTRAINT IF EXISTS campaign_report_sources_owner_chk;
--   ALTER TABLE public.campaign_report_sources DROP COLUMN IF EXISTS campaign_id;
--   ALTER TABLE public.campaign_report_sources ALTER COLUMN report_id SET NOT NULL;
--   410 파일의 replace_report_source_rows · remove_report_source 부분 다시 실행
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- [1] 표 — 리포트 또는 캠페인, 정확히 하나
-- ------------------------------------------------------------
ALTER TABLE public.campaign_report_sources
  ADD COLUMN IF NOT EXISTS campaign_id uuid NULL REFERENCES public.campaigns(id) ON DELETE CASCADE;
ALTER TABLE public.campaign_report_sources ALTER COLUMN report_id DROP NOT NULL;

ALTER TABLE public.campaign_report_sources DROP CONSTRAINT IF EXISTS campaign_report_sources_owner_chk;
ALTER TABLE public.campaign_report_sources
  ADD CONSTRAINT campaign_report_sources_owner_chk CHECK (num_nonnulls(report_id, campaign_id) = 1);

CREATE UNIQUE INDEX IF NOT EXISTS campaign_report_sources_campaign_ext_uidx
  ON public.campaign_report_sources (campaign_id, service_code, ext_campaign_no)
  WHERE campaign_id IS NOT NULL;

COMMENT ON COLUMN public.campaign_report_sources.campaign_id IS
  '[546] 캠페인에 붙인 외부 결과 파일이면 그 캠페인(report_id 는 NULL). 리포트 첨부와 정확히 하나만(campaign_report_sources_owner_chk).';

-- ------------------------------------------------------------
-- [2] 붙이기·업데이트
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.attach_campaign_ext_source(
  p_campaign_id uuid,
  p_ext_no      text,
  p_ext_name    text,
  p_file_name   text,
  p_rows        jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_source_id uuid;
  v_name      text;
  v_n         integer;
BEGIN
  IF NOT public.has_permission('menu.reports', 'write') THEN
    RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501';
  END IF;
  PERFORM 1 FROM public.campaigns WHERE id = p_campaign_id AND deleted_at IS NULL FOR KEY SHARE;   -- 삭제만 막는다(캠페인 편집 저장은 막지 않는다)
  IF NOT FOUND THEN RAISE EXCEPTION '없는 캠페인입니다' USING ERRCODE = '22023'; END IF;
  IF coalesce(btrim(p_ext_no), '') = '' OR coalesce(btrim(p_ext_name), '') = '' THEN
    RAISE EXCEPTION '외부 캠페인 번호와 이름이 필요합니다' USING ERRCODE = '22023';
  END IF;

  SELECT a.name INTO v_name FROM public.admins a WHERE a.auth_id = auth.uid();

  -- 이미 있으면 갱신(줄 전부 교체), 없으면 새로 — 410 add_report_source 와 같은 방식
  SELECT id INTO v_source_id
    FROM public.campaign_report_sources
   WHERE campaign_id = p_campaign_id AND service_code = 'pointail' AND ext_campaign_no = btrim(p_ext_no)
   FOR UPDATE;

  IF v_source_id IS NULL THEN
    INSERT INTO public.campaign_report_sources
      (report_id, campaign_id, service_code, ext_campaign_no, ext_campaign_name, file_name, attached_by, attached_by_name)
    VALUES (NULL, p_campaign_id, 'pointail', btrim(p_ext_no), btrim(p_ext_name), p_file_name, auth.uid(), v_name)
    RETURNING id INTO v_source_id;
  ELSE
    DELETE FROM public.campaign_report_ext_rows WHERE source_id = v_source_id;
    UPDATE public.campaign_report_sources
       SET ext_campaign_name = btrim(p_ext_name), file_name = p_file_name,
           attached_by = auth.uid(), attached_by_name = v_name, attached_at = now()
     WHERE id = v_source_id;
  END IF;

  v_n := public._insert_report_ext_rows(v_source_id, p_rows);
  UPDATE public.campaign_report_sources SET row_count = v_n WHERE id = v_source_id;
  RETURN v_source_id;
END;
$$;

COMMENT ON FUNCTION public.attach_campaign_ext_source(uuid, text, text, text, jsonb) IS
  '[546] 캠페인에 외부 결과 파일 붙이기(서비스 pointail). 같은 (캠페인·외부번호)가 있으면 줄을 전부 교체해 갱신한다.';

-- ------------------------------------------------------------
-- [3] 떼기 — 캠페인 첨부만
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.detach_campaign_ext_source(p_source_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_n integer;
BEGIN
  IF NOT public.has_permission('menu.reports', 'write') THEN
    RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501';
  END IF;
  DELETE FROM public.campaign_report_sources WHERE id = p_source_id AND campaign_id IS NOT NULL;   -- 줄은 CASCADE
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n > 0;
END;
$$;

-- ------------------------------------------------------------
-- [4] 관리자 조회 — 첨부 목록 + 줄(회원번호 포함 — 관리자 화면 「외부 · 회원번호」)
--   🔴 account_id(채널 계정 ID)는 싣지 않는다 — 리포트 공유와 같다(계정 ID 는 늘 빼는 열)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_campaign_ext_sources(p_campaign_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_out jsonb;
BEGIN
  IF NOT public.has_permission('menu.reports', 'read') THEN
    RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501';
  END IF;
  SELECT jsonb_build_object(
    'sources', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'id', s.id, 'service_code', s.service_code, 'ext_campaign_no', s.ext_campaign_no, 'ext_campaign_name', s.ext_campaign_name,
        'file_name', s.file_name, 'attached_at', s.attached_at, 'attached_by_name', s.attached_by_name, 'row_count', s.row_count)
        ORDER BY s.attached_at)
        FROM public.campaign_report_sources s WHERE s.campaign_id = p_campaign_id), '[]'::jsonb),
    'ext_rows', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'id', x.id, 'source_id', x.source_id, 'member_no', x.member_no, 'mission_status', x.mission_status,
        'order_no', x.order_no, 'purchase_amount', x.purchase_amount, 'receipt_url', x.receipt_url, 'receipt_at', x.receipt_at,
        'review_kind', x.review_kind, 'qoo10_urls', x.qoo10_urls, 'qoo10_at', x.qoo10_at,
        'cosme_urls', x.cosme_urls, 'cosme_at', x.cosme_at)
        ORDER BY x.member_no, x.id)
        FROM public.campaign_report_ext_rows x
        JOIN public.campaign_report_sources s ON s.id = x.source_id
       WHERE s.campaign_id = p_campaign_id), '[]'::jsonb)
  ) INTO v_out;
  RETURN v_out;
END;
$$;

-- ------------------------------------------------------------
-- [5] 내부 — 외부 참가자 수(모집 현황 합산용, 16-5 15번 ⑦)
--   🔴 조각 4 의 브랜드 목록·상세가 응모·선정 수에 바깥에서 더한다(관리자 숫자는 REVERB 만 그대로).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._campaign_ext_participant_count(p_campaign_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT count(*)::integer
    FROM public.campaign_report_ext_rows x
    JOIN public.campaign_report_sources s ON s.id = x.source_id
   WHERE s.campaign_id = p_campaign_id;
$$;

-- ------------------------------------------------------------
-- [6] 410 두 함수 — 리포트 첨부만 받는다(본문은 410 그대로 + 한 줄)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.replace_report_source_rows(p_source_id uuid, p_rows jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_report uuid; v_n integer;
BEGIN
  IF NOT public.has_permission('menu.reports', 'write') THEN
    RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501';
  END IF;
  SELECT report_id INTO v_report FROM public.campaign_report_sources WHERE id = p_source_id AND report_id IS NOT NULL FOR UPDATE;   -- 546: 캠페인 첨부 제외
  IF v_report IS NULL THEN
    RAISE EXCEPTION '없는 첨부입니다' USING ERRCODE = '22023';
  END IF;

  DELETE FROM public.campaign_report_ext_rows WHERE source_id = p_source_id;
  v_n := public._insert_report_ext_rows(p_source_id, p_rows);
  UPDATE public.campaign_report_sources
     SET row_count = v_n, attached_at = now(), attached_by = auth.uid()
   WHERE id = p_source_id;
  UPDATE public.campaign_reports SET version = version + 1 WHERE id = v_report;
  RETURN v_n;
END;
$$;

CREATE OR REPLACE FUNCTION public.remove_report_source(p_source_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_report uuid; v_n integer;
BEGIN
  IF NOT public.has_permission('menu.reports', 'write') THEN
    RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501';
  END IF;
  SELECT report_id INTO v_report FROM public.campaign_report_sources WHERE id = p_source_id;
  DELETE FROM public.campaign_report_sources WHERE id = p_source_id AND report_id IS NOT NULL;   -- 546: 캠페인 첨부 제외
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n > 0 THEN
    UPDATE public.campaign_reports SET version = version + 1 WHERE id = v_report;
  END IF;
  RETURN v_n > 0;
END;
$$;

-- ------------------------------------------------------------
-- [7] 실행 권한
-- ------------------------------------------------------------
GRANT  EXECUTE ON FUNCTION public.attach_campaign_ext_source(uuid, text, text, text, jsonb) TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.detach_campaign_ext_source(uuid)                          TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.get_campaign_ext_sources(uuid)                            TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public._campaign_ext_participant_count(uuid)                     TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public.attach_campaign_ext_source(uuid, text, text, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.detach_campaign_ext_source(uuid)                          FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_campaign_ext_sources(uuid)                            FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._campaign_ext_participant_count(uuid)                     FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.attach_campaign_ext_source(uuid, text, text, text, jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION public.detach_campaign_ext_source(uuid)                          FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_campaign_ext_sources(uuid)                            FROM anon;
REVOKE EXECUTE ON FUNCTION public._campaign_ext_participant_count(uuid)                     FROM anon, authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증
--   [V1] 기존 줄이 모두 검사를 통과했는가(적용 성공 자체가 증거) + 캠페인 첨부 0
--     SELECT count(*) FILTER (WHERE report_id IS NOT NULL) AS report_sources, count(*) FILTER (WHERE campaign_id IS NOT NULL) AS campaign_sources
--       FROM public.campaign_report_sources;
--   [V2] 🔴 실제 로그인 브라우저(관리자 판정은 편집기로 재현 안 됨): 시험 캠페인에 붙이기 → 같은 번호로 다시 → 줄 교체 → 떼기
--   [V3] 그 캠페인이 든 리포트의 공유 응답 ext_rows 에 그 줄이 없는지
-- ============================================================
