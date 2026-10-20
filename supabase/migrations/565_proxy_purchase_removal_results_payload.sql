-- ============================================================
-- 565: 가구매 철거 단계 B ② — 결과 공유 본체(_results_payload_core) 응답에서 proxy_purchase 키를 뺀다
-- ============================================================
-- 사양서 docs/specs/2026-10-20-proxy-purchase-removal.md 「설계 · 단계 B」
-- 베이스 545(CREATE OR REPLACE — 인자·반환 그대로, 실행 권한 postgres·service_role 보존. 🔴 DROP 금지).
-- 캠페인 줄(campaign_rows)과 결과물 안 캠페인(campaigns) 두 자리의 'proxy_purchase' 키만 지웠다.
-- ※ 545 의 같은 구간을 옮기며 그 함수 설명(COMMENT)과 _results_ext_rows 정의가 함께 들어왔다 — 545 와 글자 그대로 같아 동작 변화는 없다.
-- 화면(report-rows.js 등)은 단계 A 부터 이 키를 읽지 않는다(키가 없어도 실행 오류 없음).
--
-- 🔴 운영 적용 순서: 이 함수는 545 가 만든다 — 운영에는 아직 545 가 없다(2026-10-20 확인).
--    운영은 브랜드 페이지 출시 묶음에서 545 를 넣은 **뒤** 이 파일을 넣는다(먼저 넣으면 545 가 키를 되살린다).
--    운영의 지금 get_report_share_data(491 판) 응답에도 같은 키가 남아 있으나 화면이 안 읽어 해가 없고,
--    545 적용 때 본체가 이 함수로 바뀌며 함께 사라진다.
-- 실행 권한 확인: SELECT p.proacl::text FROM pg_proc p WHERE p.proname = '_results_payload_core';
--   기대값 {postgres=X/postgres,service_role=X/postgres}(2026-10-20 개발서버)
--
-- 되돌리기: 545 파일의 _results_payload_core 함수 블록을 다시 실행한다(권한 그대로).
-- ============================================================

BEGIN;

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
        'purchase_start', c.purchase_start, 'purchase_end', c.purchase_end,
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
                                        'channel', c.channel, 'channel_match', c.channel_match,
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
NOTIFY pgrst, 'reload schema';

COMMIT;
