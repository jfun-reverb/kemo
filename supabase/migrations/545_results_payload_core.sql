-- ============================================================
-- 545_results_payload_core.sql
-- 2026-10-19 — 결과물 판정 본체를 리포트 공유 함수에서 꺼낸다 + 사양서 §17 두 가지
--   작업표 docs/specs/2026-10-19-brand-campaign-results-breakdown.md 「조각 2」
--   사양서 docs/specs/2026-07-15-brand-portal.md §4 결과물 줄 ①(「같은 서버 판정 — 단 출시 전에 감사용 여부와
--   회원이 게시하지 않은 채널 계정을 걷어낸다」) · §17
--
-- 베이스: get_report_share_data 는 **491**(414 → 449 → 457 → 469 → 491 → 이 파일).
--   본문은 491 을 글자 그대로 옮기고 아래 다섯 자리만 바꿨다.
--     ① v_camp → p_campaign_ids · v_cols/r.share_columns → p_cols · r.include_audit → p_include_audit (내부 함수 인자로)
--     ② 회원 응답에서 'is_audit' 칸을 뺀다(§17 ①) — 공유 화면(report.html 160)의 감사용 거르기는 서버가 이미 뺀 뒤라 영향 없다
--     ③ 회원별 「관계있는 채널 집합」 (가) — 「또는」 캠페인(channel_match='or')은 요구 채널 전부를 넣지 않는다(§17 ②).
--        그 회원이 실제로 게시한 채널((나) post_channel)만 남는다. 「그리고」 캠페인은 지금과 같다.
--        ⚠️ 채널이 하나인 캠페인도 기본값이 'or' 라 같은 규칙을 탄다 — 아직 게시물 없이 영수증만 낸 회원은 그 채널 계정이 빈다(§17 「게시하지 않은 채널 계정을 걷어낸다」 그대로 — 의도).
--     ④ 외부 줄 조회를 별도 내부 함수로(브랜드용은 회원번호를 싣지 않는다 — 조각 4)
--     ⑤ get_report_share_data 는 「토큰 → 리포트 → 캠페인 배열」 + 리포트 머리 칸만 하고 본체를 부른다(539 _orient_*_core 선례)
--
-- 무엇을 하나
--   _results_payload_core(p_campaign_ids uuid[], p_cols jsonb, p_include_audit boolean) → {campaign_rows, deliverables, users}
--   _results_ext_rows(p_source_ids uuid[], p_cols jsonb, p_for_brand boolean)          → ext_rows 배열
--   get_report_share_data(uuid, text) — 🔴 CREATE OR REPLACE(인자·반환 그대로 — 413 이 비로그인에 준 권한 보존)
--   적용만으로 바뀌는 기존 동작: 공유 응답의 users 에서 is_audit 칸이 빠지고, 「또는」 캠페인에서 회원이 게시하지 않은 채널 계정이 비워진다.
--     운영 실측 2026-10-01 켜진 공유 0개 — 🔴 운영 반영 전에 다시 센다(작업표 조각 2 주의). 운영은 출시 날 ①.
--
-- 🔴 끈 열 비우기는 _report_share_col_off · _report_share_chan_col 을 그대로 부른다 — 새 사본을 만들지 않는다(화면 reportShareColOff 와 두 벌).
-- 🔴 줄 판정은 _report_share_row_included 한 곳(491) — 결과물·회원·채널 집합 셋이 같은 것을 부른다(셋 중 하나라도 빠지면 줄 없는 회원의 이름·계정이 남는다).
--
-- 롤백: 491 파일의 ② 함수 부분(get_report_share_data)을 그대로 다시 실행 — 내부 함수 둘은 남아도 무해. 되돌리면 users 의 is_audit 칸과 「또는」 캠페인의 요구 채널 계정이 다시 실린다.
-- 편집기 경고: 실행 구문에 DROP·DELETE 없음.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- [1] 결과물·회원·캠페인 본체
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._results_payload_core(p_campaign_ids uuid[], p_cols jsonb, p_include_audit boolean)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_camp uuid[]  := coalesce(p_campaign_ids, '{}');
  v_cols jsonb   := p_cols;
  v_aud  boolean := coalesce(p_include_audit, false);
  v_out  jsonb;
BEGIN
  SELECT jsonb_build_object(
    -- 캠페인 실물(표 만들기가 쓰는 칸만) — 브랜드가 알아도 되는 값
    'campaign_rows', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'id', c.id, 'campaign_no', c.campaign_no, 'title', c.title, 'recruit_type', c.recruit_type, 'channel', c.channel,
        'proxy_purchase', c.proxy_purchase, 'purchase_start', c.purchase_start, 'purchase_end', c.purchase_end,
        'visit_start', c.visit_start, 'visit_end', c.visit_end))
        FROM public.campaigns c WHERE c.id = ANY(v_camp)), '[]'::jsonb),
    -- 결과물 — 임시저장 제외(관리자 화면과 같다). 감사용 계정은 인자대로.
    'deliverables', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'id', d.id, 'kind', d.kind, 'status', d.status, 'campaign_id', d.campaign_id, 'application_id', d.application_id, 'user_id', d.user_id,
        'order_number',    CASE WHEN public._report_share_col_off(v_cols, 'order_no')      THEN NULL ELSE d.order_number END,
        'purchase_date',   CASE WHEN public._report_share_col_off(v_cols, 'purchase_date') THEN NULL ELSE d.purchase_date END,
        'purchase_amount', CASE WHEN public._report_share_col_off(v_cols, 'amount')        THEN NULL ELSE d.purchase_amount END,
        'post_url', CASE WHEN public._report_share_col_off(v_cols, public._report_share_chan_col(d.post_channel)) THEN NULL ELSE d.post_url END, 'post_channel', d.post_channel, 'submitted_at', d.submitted_at,
        'has_receipt', d.receipt_url IS NOT NULL,
        'receipt_url', CASE
                         WHEN d.kind = 'receipt' AND public._report_share_col_off(v_cols, 'receipt_url') THEN NULL
                         WHEN d.kind = 'review_image' AND public._report_share_col_off(v_cols, public._report_share_chan_col(d.post_channel)) THEN NULL
                         ELSE d.receipt_url END,
        'review_image_url', CASE WHEN d.kind = 'review_image'
                                  AND NOT public._report_share_col_off(v_cols, public._report_share_chan_col(d.post_channel))
                                 THEN d.receipt_url END,
        'applications', jsonb_build_object('status', a.status),
        'campaigns', jsonb_build_object('id', c.id, 'campaign_no', c.campaign_no, 'title', c.title, 'recruit_type', c.recruit_type,
                                        'channel', c.channel, 'channel_match', c.channel_match, 'proxy_purchase', c.proxy_purchase,
                                        'purchase_start', c.purchase_start, 'purchase_end', c.purchase_end, 'visit_start', c.visit_start, 'visit_end', c.visit_end)))
        FROM public.deliverables d
        JOIN public.applications a ON a.id = d.application_id
        JOIN public.campaigns c ON c.id = d.campaign_id
        JOIN public.influencers i ON i.id = d.user_id
        WHERE d.campaign_id = ANY(v_camp) AND d.status <> 'draft' AND (v_aud OR NOT coalesce(i.is_audit, false))
          AND public._report_share_row_included(d.application_id, d.user_id)), '[]'::jsonb),
    -- 회원 — 🔴 이메일 없음. 이름은 가려서. 🔴 545: is_audit 칸을 싣지 않는다(§17 ①).
    --   ⚠️ v_cols 는 **jsonb 배열** — 원소 검사는 `?`(`= ANY` 는 Postgres 배열 전용이라 부르는 순간 오류).
    'users', coalesce((SELECT jsonb_object_agg(i.id, jsonb_build_object(
        'id', i.id,
        'name_kanji', CASE WHEN public._report_share_col_off(v_cols, 'name_kanji') THEN NULL
                           ELSE public._mask_report_name(coalesce(i.name_kanji, i.name), 2, '**') END,
        'name_kana',  CASE WHEN public._report_share_col_off(v_cols, 'name_kana') THEN NULL
                           ELSE public._mask_report_name(i.name_kana, 3, '***') END,
        'ig', CASE WHEN NOT (coalesce(v_cols, '[]'::jsonb) ? '-ch_instagram_acct')
                    AND (v_aud OR NOT coalesce(i.is_audit, false))
                    AND 'instagram' = ANY(ch.codes)
                   THEN nullif(btrim(i.ig), '') END,
        'tiktok', CASE WHEN NOT (coalesce(v_cols, '[]'::jsonb) ? '-ch_tiktok_acct')
                    AND (v_aud OR NOT coalesce(i.is_audit, false))
                    AND 'tiktok' = ANY(ch.codes)
                   THEN nullif(btrim(i.tiktok), '') END,
        'x', CASE WHEN NOT (coalesce(v_cols, '[]'::jsonb) ? '-ch_x_acct')
                    AND (v_aud OR NOT coalesce(i.is_audit, false))
                    AND 'x' = ANY(ch.codes)
                   THEN nullif(btrim(i.x), '') END,
        'youtube', CASE WHEN NOT (coalesce(v_cols, '[]'::jsonb) ? '-ch_youtube_acct')
                    AND (v_aud OR NOT coalesce(i.is_audit, false))
                    AND 'youtube' = ANY(ch.codes)
                   THEN nullif(btrim(i.youtube), '') END))
        FROM public.influencers i
        LEFT JOIN LATERAL (
          -- 이 회원이 v_camp 안에서 임시저장이 아닌 결과물로 「관계있는」 채널 코드 집합.
          -- (가) 결과물이 낸 캠페인이 요구하는 채널 전부 — 🔴 545: 「또는」 캠페인은 넣지 않는다(§17 ② — 게시하지 않은 채널 계정이 브랜드에게 가던 것)
          -- (나) 그 결과물 자신의 post_channel
          SELECT array_agg(DISTINCT code) AS codes
          FROM (
            SELECT btrim(x.val) AS code
              FROM public.deliverables d2
              JOIN public.campaigns c2 ON c2.id = d2.campaign_id
              CROSS JOIN LATERAL unnest(string_to_array(coalesce(c2.channel, ''), ',')) AS x(val)
             WHERE d2.user_id = i.id AND d2.campaign_id = ANY(v_camp) AND d2.status <> 'draft'
               AND coalesce(c2.channel_match, '') <> 'or'                                  -- 545 §17 ②
               AND public._report_share_row_included(d2.application_id, d2.user_id)
               AND btrim(x.val) <> ''
            UNION ALL
            SELECT d2.post_channel AS code
              FROM public.deliverables d2
             WHERE d2.user_id = i.id AND d2.campaign_id = ANY(v_camp) AND d2.status <> 'draft'
               AND public._report_share_row_included(d2.application_id, d2.user_id)
               AND d2.post_channel IS NOT NULL
          ) codes_raw
        ) ch ON true
        WHERE i.id IN (SELECT DISTINCT d.user_id FROM public.deliverables d WHERE d.campaign_id = ANY(v_camp) AND d.status <> 'draft'
                          AND public._report_share_row_included(d.application_id, d.user_id))), '{}'::jsonb)
  ) INTO v_out;
  RETURN v_out;
END; $$;

COMMENT ON FUNCTION public._results_payload_core(uuid[], jsonb, boolean) IS
  '[545] 결과물 판정 본체(491 에서 꺼냄) — {campaign_rows, deliverables, users}. 리포트 공유와 브랜드 결과물(조각 4)이 같이 쓴다. 정의자 권한 함수 안에서만 부른다.';

-- ------------------------------------------------------------
-- [2] 외부 첨부 줄
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._results_ext_rows(p_source_ids uuid[], p_cols jsonb, p_for_brand boolean)
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
           -- 🔴 브랜드용(p_for_brand)은 다른 서비스 회원번호를 싣지 않는다 — 리포트 공유(491)는 지금처럼 싣는다
           || CASE WHEN coalesce(p_for_brand, true) THEN '{}'::jsonb ELSE jsonb_build_object('member_no', x.member_no) END
         ), '[]'::jsonb)
    FROM public.campaign_report_ext_rows x
   WHERE x.source_id = ANY(coalesce(p_source_ids, '{}'));
$$;

COMMENT ON FUNCTION public._results_ext_rows(uuid[], jsonb, boolean) IS
  '[545] 외부 첨부 줄(끈 열은 비움). p_for_brand=true 면 member_no 를 싣지 않는다(기본 true — 빠뜨려도 새지 않게). 정의자 권한 함수 안에서만 부른다.';

-- 안쪽 전용 — 회수 방향 셋 다(PUBLIC · anon · authenticated)
GRANT  EXECUTE ON FUNCTION public._results_payload_core(uuid[], jsonb, boolean) TO postgres, service_role;
GRANT  EXECUTE ON FUNCTION public._results_ext_rows(uuid[], jsonb, boolean)     TO postgres, service_role;
REVOKE ALL ON FUNCTION public._results_payload_core(uuid[], jsonb, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._results_payload_core(uuid[], jsonb, boolean) FROM anon, authenticated;
REVOKE ALL ON FUNCTION public._results_ext_rows(uuid[], jsonb, boolean)     FROM PUBLIC;
REVOKE ALL ON FUNCTION public._results_ext_rows(uuid[], jsonb, boolean)     FROM anon, authenticated;

-- ------------------------------------------------------------
-- [3] 공유 데이터 — 491 의 바깥(토큰·열람표·리포트 머리) + 본체 호출
--   🔴 CREATE OR REPLACE 로만(인자·반환 그대로)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_report_share_data(p_token uuid, p_ticket text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r      public.campaign_reports%ROWTYPE;
  v_ok   boolean;
  v_camp uuid[];
  v_core jsonb;
  v_out  jsonb;
BEGIN
  IF p_token IS NULL OR p_ticket IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO r FROM public.campaign_reports WHERE share_token = p_token;
  IF r.id IS NULL OR NOT r.share_enabled OR (r.share_expires_at IS NOT NULL AND r.share_expires_at < now()) THEN RETURN NULL; END IF;
  SELECT EXISTS (SELECT 1 FROM public.campaign_report_view_tickets t
                  WHERE t.report_id = r.id AND t.token_hash = encode(extensions.digest(p_ticket, 'sha256'), 'hex') AND t.expires_at > now())
    INTO v_ok;
  IF NOT v_ok THEN RETURN NULL; END IF;

  -- 🔴 토큰이 가리키는 캠페인만
  SELECT coalesce(array_agg(campaign_id) FILTER (WHERE campaign_id IS NOT NULL), '{}') INTO v_camp
    FROM public.campaign_report_campaigns WHERE report_id = r.id;

  UPDATE public.campaign_reports SET share_last_viewed_at = now() WHERE id = r.id;

  v_core := public._results_payload_core(v_camp, r.share_columns, r.include_audit);

  SELECT jsonb_build_object(
    'title',         r.title,
    'created_at',    r.created_at,
    'updated_at',    r.updated_at,
    'include_audit', r.include_audit,
    'columns',       r.share_columns,
    'campaigns', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'campaign_id', rc.campaign_id, 'campaign_no', rc.campaign_no, 'campaign_title', rc.campaign_title, 'sort_order', rc.sort_order,
        'campaign_exists', rc.campaign_id IS NOT NULL) ORDER BY rc.sort_order)
        FROM public.campaign_report_campaigns rc WHERE rc.report_id = r.id), '[]'::jsonb),
    'campaign_rows', v_core -> 'campaign_rows',
    'deliverables',  v_core -> 'deliverables',
    'users',         v_core -> 'users',
    -- 외부 첨부 — 🔴 account_id 키 없음 · 리포트 공유는 member_no 를 지금처럼 싣는다(p_for_brand=false)
    'sources', coalesce((SELECT jsonb_agg(jsonb_build_object('id', s.id, 'ext_campaign_no', s.ext_campaign_no, 'ext_campaign_name', s.ext_campaign_name,
        'attached_at', s.attached_at, 'row_count', s.row_count) ORDER BY s.attached_at)
        FROM public.campaign_report_sources s WHERE s.report_id = r.id), '[]'::jsonb),
    'ext_rows', public._results_ext_rows(
        coalesce((SELECT array_agg(s.id) FROM public.campaign_report_sources s WHERE s.report_id = r.id), '{}'),
        r.share_columns, false)
  ) INTO v_out;
  RETURN v_out;
END; $$;

COMMIT;

-- ============================================================
-- 검증
--   [V1] 권한 — 공유 함수 anon true · PUBLIC 없음 / 내부 둘 anon·authenticated false
--     SELECT has_function_privilege('anon', 'public.get_report_share_data(uuid, text)', 'EXECUTE') AS share_anon,
--            (SELECT p.proacl::text LIKE '{=X/%' FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--              WHERE n.nspname='public' AND p.proname='get_report_share_data') AS share_public_remains,
--            has_function_privilege('authenticated', 'public._results_payload_core(uuid[], jsonb, boolean)', 'EXECUTE') AS core_auth,
--            has_function_privilege('anon', 'public._results_ext_rows(uuid[], jsonb, boolean)', 'EXECUTE') AS ext_anon;
--     기대: true, false, false, false
--   [V2] 같은 결과 — 적용 전 491 응답과 적용 뒤 응답을 같은 리포트로 비교(차이는 users 의 is_audit 와 「또는」 캠페인 계정뿐)
--   [V3] 공유 화면을 실제로 열어 표가 전과 같은지 눈으로
-- ============================================================
