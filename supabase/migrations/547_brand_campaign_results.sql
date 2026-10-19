-- ============================================================
-- 547_brand_campaign_results.sql
-- 2026-10-19 — 브랜드 페이지 캠페인 결과물 조회 + 1단계 함수(543)에 공개 여부·결과물 게시·외부 참가자 합산
--   작업표 docs/specs/2026-10-19-brand-campaign-results-breakdown.md 「조각 4」 · 결정 D5(세 숫자 = 최신 건만)·D6(업데이트 = 마지막 변경 시각)·
--   D7(공개 스위치만 따름)·D9(외부 줄 캠페인 값은 화면이 채움) · S10·S11
--   사양서 docs/specs/2026-07-15-brand-portal.md §4 결과물 줄 ①~⑦ · 16-5 15번 ③·⑦
--
-- 무엇을 하나
--   get_my_brand_campaign_results(p_campaign_id)   브랜드 결과물 — 공개 꺼짐이면 {ready:false}(숫자도 없음), 켜짐이면 줄·세 숫자·외부 줄
--   _brand_campaign_result_counts(p_campaign_id)   내부 — 세 숫자 {submitted, approved, pending}(REVERB 최신 건 + 외부 증빙 있는 줄)
--   _brand_campaign_summary(p_campaign_id)         내부 — 목록·상세에 붙는 칸(응모·선정 + 외부 참가자 · results_public · result_posted)
--   _results_ext_rows(uuid[], jsonb, boolean, boolean)  내부 — 넷째 인자 p_submitted_only(증빙 있는 줄만). 545 의 3인자 판은 4인자를 false 로 부른다(동작 그대로)
--   get_my_brand_campaigns · get_my_brand_campaign — 543 본문 그대로 + `_brand_campaign_counts` 자리를 `_brand_campaign_summary` 로(CREATE OR REPLACE — 반환 jsonb 라 권한 보존)
--   적용만으로 바뀌는 기존 동작: 브랜드 목록·상세에 칸 셋이 더 실리고, 외부 파일이 붙은 캠페인의 응모·선정 수가 외부 참가자만큼 커진다(지금 캠페인 첨부 0건).
--
-- 🔴 운영 반영 — 출시 날 ①(브랜드 묶음). 1(544)·2(545)·3(546)에 기댄다.
--
-- 계약
--   · 공개 하나(get_my_brand_campaign_results)는 SECURITY DEFINER SET search_path=''. 권한 authenticated 만(PUBLIC·anon 회수). 내부 넷은 셋 다 회수.
--   · 거부는 {success:false, reason:'not_found'} 하나(543 계약 — 캠페인의 brand_id 로 is_my_brand, 보일 상태 넷, 보관 삭제 제외).
--   · 🔴 결과물·회원은 _results_payload_core(ARRAY[캠페인], 캠페인 열 목록, false) 로만 받는다 — 감사용 늘 제외, 포털이 따로 조회하지 않는다(§4 ①).
--   · 외부 줄은 그 캠페인에 붙은 파일만 · 회원번호 없음(p_for_brand) · 증빙 있는 줄만(p_submitted_only — 16-5 15번 ③).
--   · 🔴 STABLE — 아무것도 쓰지 않는다(열람 기록 없음 — §4 ③). 세 숫자는 이 함수에만(공유 함수에 더하지 않는다 — 법률 절 「집계 숫자」 예외).
--   · 🔴 임시 주소(영수증 사진 서명)는 이 함수가 하지 않는다 — 조각 5 서버 함수가 이 응답 안의 경로만 서명한다.
--
-- 설계 판단
--   [A] 세 숫자의 「건」(D5): REVERB 결과물을 화면 buildDeliverableGroups 와 같은 묶음으로 — 영수증은 응모당 하나, 리뷰 인증샷·게시물은 (응모·채널)마다 하나 —
--       그 묶음의 최신 1건(submitted_at → created_at → id)만 센다. 채널 없는 옛 인증샷(legacy)은 화면처럼 뺀다.
--       🔴 임시저장을 **먼저 빼고** 남은 것 중 최신 1건을 고른다(화면 결과물 표와 같다 — 반려 뒤 새 임시저장이 있어도 그 반려 건이 최신으로 잡힌다).
--       제출 = 그 최신 건이 있음(반려 포함) · 검수 완료 = 최신 건 승인 · 검수 대기 = 최신 건 검수 중.
--       ⚠️ 채널이 빈 게시물은 「post:」 한 묶음으로 따로 센다 — 한 응모에 채널 있는 게시물과 섞이면 한 건 더 잡힌다(채널 없는 게시물은 거의 없다).
--       범위·제외는 결과물 줄과 같다 — 임시저장 제외 · 감사용 제외 · _report_share_row_included(반려·취소 신청·탈퇴 확정 제외).
--       외부 줄 하나 = 한 건 — 증빙(영수증·큐텐·엣코스메 주소) 있음 = 제출, 그중 「완료」 = 검수 완료, 「미완료」 = 검수 대기.
--   [B] 업데이트 시각(D6) = 결과물 제출·검수(submitted_at·reviewed_at), 외부 파일 붙인 시각, 공개 설정 저장 시각 중 가장 늦은 것.
--   [C] 목록·상세 「결과물 게시」(S11) = 공개 켜짐일 때만 세 숫자의 「제출」. 꺼짐이면 키를 싣지 않는다 — 화면은 「-」.
--   [D] 응모·선정 수의 외부 합산(16-5 15번 ⑦)은 공개와 무관하다. 🔴 _brand_campaign_counts(543)는 바꾸지 않고 바깥에서 더한다 — 관리자 쪽 숫자는 REVERB 만.
--
-- 🔴 반환 칸을 바꾸려면 DROP 후 CREATE 라 실행 권한 회수를 다시 걸어야 한다. 다음 재정의의 베이스: 결과물 조회·요약은 이 파일(547),
--    get_my_brand_campaigns·get_my_brand_campaign 도 이 파일(547 — 543 베이스), _results_ext_rows 3인자·4인자 모두 이 파일.
-- 편집기 경고: 실행 구문에 DROP·DELETE 없음.
--
-- 롤백: 543 파일의 [3]·[4] 함수 부분 다시 실행(목록·상세 원상) → 545 파일의 [2] 부분 다시 실행(3인자 외부 줄 원상)
--   → DROP FUNCTION public.get_my_brand_campaign_results(uuid), public._brand_campaign_summary(uuid), public._brand_campaign_result_counts(uuid),
--      public._results_ext_rows(uuid[], jsonb, boolean, boolean);
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- [1] 외부 줄 — 4인자(증빙 있는 줄만 거르기) + 3인자는 4인자를 false 로
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._results_ext_rows(p_source_ids uuid[], p_cols jsonb, p_for_brand boolean, p_submitted_only boolean)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(
           jsonb_build_object(
             'source_id', x.source_id, 'mission_status', x.mission_status,
             'order_no',        CASE WHEN public._report_share_col_off(p_cols, 'order_no')     THEN NULL ELSE x.order_no END,
             'purchase_amount', CASE WHEN public._report_share_col_off(p_cols, 'amount')       THEN NULL ELSE x.purchase_amount END,
             'receipt_url',     CASE WHEN public._report_share_col_off(p_cols, 'receipt_url')  THEN NULL ELSE x.receipt_url END,
             'receipt_at', x.receipt_at, 'review_kind', x.review_kind,
             'qoo10_urls', CASE WHEN public._report_share_col_off(p_cols, 'ch_qoo10_url') THEN NULL ELSE x.qoo10_urls END,
             'qoo10_at', x.qoo10_at,
             'cosme_urls', CASE WHEN public._report_share_col_off(p_cols, 'ch_cosme_url') THEN NULL ELSE x.cosme_urls END,
             'cosme_at', x.cosme_at)
           || CASE WHEN coalesce(p_for_brand, true) THEN '{}'::jsonb ELSE jsonb_build_object('member_no', x.member_no) END
         ), '[]'::jsonb)
    FROM public.campaign_report_ext_rows x
   WHERE x.source_id = ANY(coalesce(p_source_ids, '{}'))
     -- 🔴 거르기는 가리기 **전** 원본 칸으로 — 끈 열 때문에 제출한 줄이 빠지지 않게
     AND (NOT coalesce(p_submitted_only, false)
          OR nullif(btrim(x.receipt_url), '') IS NOT NULL
          OR nullif(btrim(x.qoo10_urls), '')  IS NOT NULL
          OR nullif(btrim(x.cosme_urls), '')  IS NOT NULL);
$$;

CREATE OR REPLACE FUNCTION public._results_ext_rows(p_source_ids uuid[], p_cols jsonb, p_for_brand boolean)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT public._results_ext_rows(p_source_ids, p_cols, p_for_brand, false);
$$;

-- ------------------------------------------------------------
-- [2] 세 숫자(설계 판단 [A])
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._brand_campaign_result_counts(p_campaign_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH d AS (
    SELECT d.application_id, d.status, d.submitted_at, d.created_at, d.id,
           CASE WHEN d.kind = 'receipt' THEN 'receipt' ELSE d.kind || ':' || coalesce(d.post_channel, '') END AS gk
      FROM public.deliverables d
      JOIN public.influencers i ON i.id = d.user_id AND NOT coalesce(i.is_audit, false)
     WHERE d.campaign_id = p_campaign_id
       AND d.status <> 'draft'
       AND NOT (d.kind = 'review_image' AND d.post_channel IS NULL)          -- 채널 없는 옛 인증샷은 화면처럼 뺀다
       AND public._report_share_row_included(d.application_id, d.user_id)
  ), latest AS (
    SELECT DISTINCT ON (application_id, gk) status
      FROM d
     ORDER BY application_id, gk, submitted_at DESC NULLS LAST, created_at DESC, id DESC
  ), ext AS (
    SELECT x.mission_status
      FROM public.campaign_report_ext_rows x
      JOIN public.campaign_report_sources s ON s.id = x.source_id
     WHERE s.campaign_id = p_campaign_id
       AND (nullif(btrim(x.receipt_url), '') IS NOT NULL
            OR nullif(btrim(x.qoo10_urls), '') IS NOT NULL
            OR nullif(btrim(x.cosme_urls), '') IS NOT NULL)
  )
  SELECT jsonb_build_object(
    'submitted', (SELECT count(*) FROM latest) + (SELECT count(*) FROM ext),
    'approved',  (SELECT count(*) FROM latest WHERE status = 'approved') + (SELECT count(*) FROM ext WHERE btrim(coalesce(mission_status, '')) = '완료'),
    'pending',   (SELECT count(*) FROM latest WHERE status = 'pending')  + (SELECT count(*) FROM ext WHERE btrim(coalesce(mission_status, '')) = '미완료')
  );
$$;

-- ------------------------------------------------------------
-- [3] 목록·상세에 붙는 요약(설계 판단 [C]·[D])
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._brand_campaign_summary(p_campaign_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_counts jsonb   := public._brand_campaign_counts(p_campaign_id);
  v_ext    integer := public._campaign_ext_participant_count(p_campaign_id);
  v_pub    boolean;
  v_out    jsonb;
BEGIN
  SELECT p.enabled INTO v_pub FROM public.campaign_brand_publish p WHERE p.campaign_id = p_campaign_id;
  v_pub := coalesce(v_pub, false);
  v_out := jsonb_build_object(
    'applied_count',  coalesce((v_counts ->> 'applied_count')::integer, 0)  + coalesce(v_ext, 0),
    'approved_count', coalesce((v_counts ->> 'approved_count')::integer, 0) + coalesce(v_ext, 0),
    'results_public', v_pub
  );
  IF v_pub THEN
    v_out := v_out || jsonb_build_object('result_posted', (public._brand_campaign_result_counts(p_campaign_id) ->> 'submitted')::integer);
  END IF;
  RETURN v_out;
END;
$$;

-- ------------------------------------------------------------
-- [4] 브랜드 결과물 조회
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_my_brand_campaign_results(p_campaign_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_uid  uuid := auth.uid();
  c      public.campaigns%ROWTYPE;
  pub    public.campaign_brand_publish%ROWTYPE;
  v_src  uuid[];
  v_core jsonb;
  v_upd  timestamptz;
BEGIN
  IF v_uid IS NULL OR p_campaign_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;
  SELECT * INTO c FROM public.campaigns WHERE id = p_campaign_id;
  IF NOT FOUND
     OR c.deleted_at IS NOT NULL
     OR c.status NOT IN ('scheduled', 'active', 'closed', 'ended')
     OR c.brand_id IS NULL
     OR NOT public.is_my_brand(c.brand_id) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;

  SELECT * INTO pub FROM public.campaign_brand_publish WHERE campaign_id = c.id;
  IF NOT FOUND OR NOT pub.enabled THEN
    RETURN jsonb_build_object('success', true, 'ready', false);   -- 🔴 세 숫자도 싣지 않는다(§4 ④)
  END IF;

  SELECT coalesce(array_agg(s.id), '{}') INTO v_src FROM public.campaign_report_sources s WHERE s.campaign_id = c.id;
  v_core := public._results_payload_core(ARRAY[c.id], pub.columns, false);

  SELECT greatest(
           (SELECT max(greatest(d.submitted_at, d.reviewed_at)) FROM public.deliverables d
             WHERE d.campaign_id = c.id AND d.status <> 'draft'),
           (SELECT max(s.attached_at) FROM public.campaign_report_sources s WHERE s.campaign_id = c.id),
           pub.updated_at)
    INTO v_upd;

  RETURN jsonb_build_object(
    'success',       true,
    'ready',         true,
    'campaign_id',   c.id,
    'columns',       pub.columns,
    'campaign_rows', v_core -> 'campaign_rows',
    'deliverables',  v_core -> 'deliverables',
    'users',         v_core -> 'users',
    'ext_rows',      public._results_ext_rows(v_src, pub.columns, true, true),
    'counts',        public._brand_campaign_result_counts(c.id),
    'updated_at',    v_upd
  );
END;
$$;

COMMENT ON FUNCTION public.get_my_brand_campaign_results(uuid) IS
  '[547] 브랜드 페이지 결과물 — 캠페인의 brand_id 로 is_my_brand. 공개 꺼짐 {ready:false} / 켜짐 줄·세 숫자·외부 줄(회원번호 없음·증빙 있는 줄만). 쓰기 없음.';

-- ------------------------------------------------------------
-- [5] get_my_brand_campaigns — 목록 (543 본문 그대로 + 요약 함수 한 줄)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_my_brand_campaigns(p_brand_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_today date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  v_rows  jsonb;
BEGIN
  IF v_uid IS NULL OR p_brand_id IS NULL OR NOT public.is_my_brand(p_brand_id) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;

  SELECT COALESCE(jsonb_agg(row_json ORDER BY created_at DESC, id), '[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT c.id, c.created_at,
             jsonb_build_object(
               'id',            c.id,
               'campaign_no',   c.campaign_no,
               'product',       COALESCE(NULLIF(btrim(c.product_ko), ''), NULLIF(btrim(c.product), ''), c.title),
               'recruit_type',  c.recruit_type,
               'channel_names', public._brand_campaign_channel_names(c.channel),
               'status',        public._brand_campaign_view_status(c, v_today),
               'recruit_start', c.recruit_start,
               'deadline',      c.deadline,
               'slots',         c.slots
             ) || public._brand_campaign_summary(c.id) AS row_json
        FROM public.campaigns c
       WHERE c.brand_id = p_brand_id
         AND c.deleted_at IS NULL
         AND c.status IN ('scheduled', 'active', 'closed', 'ended')
    ) t;

  RETURN jsonb_build_object(
    'success',   true,
    'today',     to_char(v_today, 'YYYY-MM-DD'),
    'campaigns', v_rows
  );
END;
$$;

COMMENT ON FUNCTION public.get_my_brand_campaigns(uuid) IS
  '[547] 브랜드 페이지 캠페인 목록 — 543 + results_public·result_posted·외부 참가자 합산(_brand_campaign_summary). 거부는 not_found 하나.';

GRANT  EXECUTE ON FUNCTION public.get_my_brand_campaigns(uuid) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.get_my_brand_campaigns(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_my_brand_campaigns(uuid) FROM anon;

-- ------------------------------------------------------------
-- [6] get_my_brand_campaign — 상세 (543 본문 그대로 + 요약 함수 한 줄)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_my_brand_campaign(p_campaign_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_today date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  c       public.campaigns%ROWTYPE;
BEGIN
  IF v_uid IS NULL OR p_campaign_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;

  SELECT * INTO c FROM public.campaigns WHERE id = p_campaign_id;
  IF NOT FOUND
     OR c.deleted_at IS NOT NULL
     OR c.status NOT IN ('scheduled', 'active', 'closed', 'ended')
     OR c.brand_id IS NULL
     OR NOT public.is_my_brand(c.brand_id) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;

  RETURN jsonb_build_object(
    'success',  true,
    'today',    to_char(v_today, 'YYYY-MM-DD'),
    'campaign', jsonb_build_object(
      'id',                   c.id,
      'brand_id',             c.brand_id,
      'campaign_no',          c.campaign_no,
      'product',              COALESCE(NULLIF(btrim(c.product_ko), ''), NULLIF(btrim(c.product), ''), c.title),
      'recruit_type',         c.recruit_type,
      'channel',              c.channel,
      'channel_names',        public._brand_campaign_channel_names(c.channel),
      'status',               public._brand_campaign_view_status(c, v_today),
      'slots',                c.slots,
      'recruit_start',        c.recruit_start,
      'deadline',             c.deadline,
      'selection_start',      c.selection_start,
      'selection_end',        c.selection_end,
      'purchase_start',       c.purchase_start,
      'purchase_end',         c.purchase_end,
      'visit_start',          c.visit_start,
      'visit_end',            c.visit_end,
      'submission_end',       c.submission_end,
      'event_mode',           c.event_mode,
      'event_selection_mode', c.event_selection_mode
    ) || public._brand_campaign_summary(c.id)
  );
END;
$$;

COMMENT ON FUNCTION public.get_my_brand_campaign(uuid) IS
  '[547] 브랜드 페이지 캠페인 상세 — 543 + results_public·result_posted·외부 참가자 합산. 없는·남의·안 보이는 캠페인은 모두 not_found.';

GRANT  EXECUTE ON FUNCTION public.get_my_brand_campaign(uuid) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.get_my_brand_campaign(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_my_brand_campaign(uuid) FROM anon;

-- ------------------------------------------------------------
-- [7] 실행 권한 — 공개 하나 authenticated 만 · 내부 넷 셋 다 회수
-- ------------------------------------------------------------
GRANT  EXECUTE ON FUNCTION public.get_my_brand_campaign_results(uuid) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.get_my_brand_campaign_results(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_my_brand_campaign_results(uuid) FROM anon;

GRANT  EXECUTE ON FUNCTION public._brand_campaign_result_counts(uuid)                    TO postgres, service_role;
GRANT  EXECUTE ON FUNCTION public._brand_campaign_summary(uuid)                          TO postgres, service_role;
GRANT  EXECUTE ON FUNCTION public._results_ext_rows(uuid[], jsonb, boolean, boolean)     TO postgres, service_role;
REVOKE ALL ON FUNCTION public._brand_campaign_result_counts(uuid)                        FROM PUBLIC;
REVOKE ALL ON FUNCTION public._brand_campaign_result_counts(uuid)                        FROM anon, authenticated;
REVOKE ALL ON FUNCTION public._brand_campaign_summary(uuid)                              FROM PUBLIC;
REVOKE ALL ON FUNCTION public._brand_campaign_summary(uuid)                              FROM anon, authenticated;
REVOKE ALL ON FUNCTION public._results_ext_rows(uuid[], jsonb, boolean, boolean)         FROM PUBLIC;
REVOKE ALL ON FUNCTION public._results_ext_rows(uuid[], jsonb, boolean, boolean)         FROM anon, authenticated;

COMMIT;

-- ============================================================
-- 검증
--   [V1] 권한 — 결과물 조회 authenticated=X · 맨 앞 =X/ 없음 · anon 없음 / 내부 넷 authenticated·anon 없음
--   [V2] 🔴 실제 로그인 브라우저(브랜드 계정): 꺼짐 → ready:false · 켜짐 → 줄이 진행현황 결과물 탭(반려·취소·탈퇴·감사용 제외)과 같은 사람 수 ·
--        영수증 열을 끄면 receipt_url null · 외부 줄에 member_no 없음 · 남의 캠페인 not_found · 외부 파일 붙은 캠페인 목록 응모·선정이 외부 수만큼 크다
-- ============================================================
