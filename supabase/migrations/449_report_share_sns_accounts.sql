-- 449 — 브랜드 공유 응답의 회원 묶음에 SNS 계정 4종을 더한다
-- ------------------------------------------------------------
-- 사양서: docs/specs/2026-09-17-report-sns-channel-columns.md 「서버 — 마이그레이션 1개」
-- 작업표: docs/specs/2026-09-17-report-sns-channel-columns-breakdown.md 「작업 2」
--
-- 바뀌는 것: get_report_share_data 의 'users' 묶음(jsonb_object_agg)에 ig·tiktok·x·youtube
-- 네 열쇠를 더한다. 그 밖의 모든 절(campaigns/campaign_rows/deliverables/sources/ext_rows)은
-- 414 와 글자 그대로 같다.
--
-- 🔴 CREATE OR REPLACE 로만 — DROP 하면 413 이 anon 에 연 실행 권한이 풀려 공유 링크가
-- 전부 죽는다(387 선례와 같은 함정). GRANT/REVOKE 는 새로 넣지 않는다.
-- 베이스: 414(413 아님 — 413 을 베이스로 잡으면 영수증 사진 주소가 통째로 사라진다).
--
-- 「코드 ↔ 회원 표의 칸」 네 짝(화면 쪽 채널 대장 REPORT_CHANNELS 의 사본 — dev/js/report-rows.js):
--   instagram → ig / tiktok → tiktok / x → x / youtube → youtube
-- 🔴 계정 열이 있는 채널을 더하는 날은 이 함수와 REPORT_CHANNELS 두 곳을 함께 고친다.
--
-- 각 회원의 계정 값은 아래 조건이 맞을 때만 넣고, 아니면 NULL:
--   그 회원이 이 리포트가 가리키는 캠페인(v_camp)에 낸 임시저장이 아닌(status <> 'draft')
--   결과물 가운데, (가) 그 채널을 요구하는 모집 건(campaigns.channel 을 쉼표로 나눠
--   btrim 한 값에 코드가 글자 그대로 있음)의 것이 있거나, (나) 그 채널로 낸 것
--   (post_channel = 코드, 글자 그대로)이 있을 때.
--   share_columns 에 '-ch_{코드}_acct' 가 있으면 그 채널 계정은 전원 NULL.
--   리포트가 감사용 계정을 제외하는 설정(NOT r.include_audit)이면 감사용 회원의 계정도
--   전부 NULL(그 회원 줄 자체가 표에 안 나오므로 값을 실을 이유가 없다 — 메인 세션 결정).
--   빈 문자열은 NULL 로(nullif(btrim(...), '')).
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_report_share_data(p_token uuid, p_ticket text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r      public.campaign_reports%ROWTYPE;
  v_ok   boolean;
  v_camp uuid[];
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
    -- 캠페인 실물(표 만들기가 쓰는 칸만) — 브랜드가 알아도 되는 값
    'campaign_rows', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'id', c.id, 'campaign_no', c.campaign_no, 'title', c.title, 'recruit_type', c.recruit_type, 'channel', c.channel,
        'proxy_purchase', c.proxy_purchase, 'purchase_start', c.purchase_start, 'purchase_end', c.purchase_end,
        'visit_start', c.visit_start, 'visit_end', c.visit_end))
        FROM public.campaigns c WHERE c.id = ANY(v_camp)), '[]'::jsonb),
    -- 결과물 — 임시저장 제외(관리자 화면과 같다). 감사용 계정은 리포트 설정대로.
    --   ⚠️ 414 부터 receipt_url 을 **모든 종류**에 준다(영수증 사진 포함 — 사용자 결정 2026-09-04, 방침 §3.1 제공 항목에 추가).
    --   413 은 영수증(kind=receipt)만 빼고 리뷰 사진(review_image)의 주소를 review_image_url 로 따로 줬다.
    --   review_image_url 은 옛 화면이 아직 캐시돼 있을 때를 위해 남긴다.
    'deliverables', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'id', d.id, 'kind', d.kind, 'status', d.status, 'campaign_id', d.campaign_id, 'application_id', d.application_id, 'user_id', d.user_id,
        'order_number', d.order_number, 'purchase_date', d.purchase_date, 'purchase_amount', d.purchase_amount,
        'post_url', d.post_url, 'post_channel', d.post_channel, 'submitted_at', d.submitted_at,
        'has_receipt', d.receipt_url IS NOT NULL,
        'receipt_url', d.receipt_url,
        'review_image_url', CASE WHEN d.kind = 'review_image' THEN d.receipt_url END,
        'applications', jsonb_build_object('status', a.status),
        'campaigns', jsonb_build_object('id', c.id, 'campaign_no', c.campaign_no, 'title', c.title, 'recruit_type', c.recruit_type,
                                        'channel', c.channel, 'proxy_purchase', c.proxy_purchase,
                                        'purchase_start', c.purchase_start, 'purchase_end', c.purchase_end, 'visit_start', c.visit_start, 'visit_end', c.visit_end)))
        FROM public.deliverables d
        JOIN public.applications a ON a.id = d.application_id
        JOIN public.campaigns c ON c.id = d.campaign_id
        JOIN public.influencers i ON i.id = d.user_id
        WHERE d.campaign_id = ANY(v_camp) AND d.status <> 'draft' AND (r.include_audit OR NOT coalesce(i.is_audit, false))), '[]'::jsonb),
    -- 회원 — 🔴 이메일 없음. 이름은 가려서.
    --   449: SNS 계정 4종 추가. 회원별로 「관계있는 채널 집합」을 서브쿼리 하나로 구해
    --   그 안에 있는 채널만 계정을 싣는다(나머지는 NULL). 끈 채널(-ch_{코드}_acct)은
    --   관계와 무관하게 전원 NULL. 감사용 회원은 표에 안 나오므로 계정도 NULL.
    --   ⚠️ share_columns 는 **jsonb 배열**이다 — 원소 검사는 `?` 로 한다. `= ANY(...)` 는 Postgres 배열 전용이라
    --      jsonb 에 쓰면 함수를 만들 때는 통과하고 **부르는 순간** 오류가 난다(= 공유 링크가 전부 죽는다).
    'users', coalesce((SELECT jsonb_object_agg(i.id, jsonb_build_object(
        'id', i.id,
        'name_kanji', public._mask_report_name(coalesce(i.name_kanji, i.name), 2, '**'),
        'name_kana',  public._mask_report_name(i.name_kana, 3, '***'),
        'is_audit', coalesce(i.is_audit, false),
        'ig', CASE WHEN NOT (coalesce(r.share_columns, '[]'::jsonb) ? '-ch_instagram_acct')
                    AND (r.include_audit OR NOT coalesce(i.is_audit, false))
                    AND 'instagram' = ANY(ch.codes)
                   THEN nullif(btrim(i.ig), '') END,
        'tiktok', CASE WHEN NOT (coalesce(r.share_columns, '[]'::jsonb) ? '-ch_tiktok_acct')
                    AND (r.include_audit OR NOT coalesce(i.is_audit, false))
                    AND 'tiktok' = ANY(ch.codes)
                   THEN nullif(btrim(i.tiktok), '') END,
        'x', CASE WHEN NOT (coalesce(r.share_columns, '[]'::jsonb) ? '-ch_x_acct')
                    AND (r.include_audit OR NOT coalesce(i.is_audit, false))
                    AND 'x' = ANY(ch.codes)
                   THEN nullif(btrim(i.x), '') END,
        'youtube', CASE WHEN NOT (coalesce(r.share_columns, '[]'::jsonb) ? '-ch_youtube_acct')
                    AND (r.include_audit OR NOT coalesce(i.is_audit, false))
                    AND 'youtube' = ANY(ch.codes)
                   THEN nullif(btrim(i.youtube), '') END))
        FROM public.influencers i
        LEFT JOIN LATERAL (
          -- 이 회원이 v_camp 안에서 임시저장이 아닌 결과물로 「관계있는」 채널 코드 집합.
          -- (가) 결과물이 낸 캠페인이 요구하는 채널 전부(campaigns.channel 콤마 분해, btrim)
          -- (나) 그 결과물 자신의 post_channel
          SELECT array_agg(DISTINCT code) AS codes
          FROM (
            SELECT btrim(x.val) AS code
              FROM public.deliverables d2
              JOIN public.campaigns c2 ON c2.id = d2.campaign_id
              CROSS JOIN LATERAL unnest(string_to_array(coalesce(c2.channel, ''), ',')) AS x(val)
             WHERE d2.user_id = i.id AND d2.campaign_id = ANY(v_camp) AND d2.status <> 'draft'
               AND btrim(x.val) <> ''
            UNION ALL
            SELECT d2.post_channel AS code
              FROM public.deliverables d2
             WHERE d2.user_id = i.id AND d2.campaign_id = ANY(v_camp) AND d2.status <> 'draft'
               AND d2.post_channel IS NOT NULL
          ) codes_raw
        ) ch ON true
        WHERE i.id IN (SELECT DISTINCT d.user_id FROM public.deliverables d WHERE d.campaign_id = ANY(v_camp) AND d.status <> 'draft')), '{}'::jsonb),
    -- 외부 첨부 — 🔴 account_id 키 없음(414 에서 receipt_url 은 열었다)
    'sources', coalesce((SELECT jsonb_agg(jsonb_build_object('id', s.id, 'ext_campaign_no', s.ext_campaign_no, 'ext_campaign_name', s.ext_campaign_name,
        'attached_at', s.attached_at, 'row_count', s.row_count) ORDER BY s.attached_at)
        FROM public.campaign_report_sources s WHERE s.report_id = r.id), '[]'::jsonb),
    'ext_rows', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'source_id', x.source_id, 'member_no', x.member_no, 'mission_status', x.mission_status, 'order_no', x.order_no,
        'purchase_amount', x.purchase_amount, 'receipt_url', x.receipt_url, 'receipt_at', x.receipt_at, 'review_kind', x.review_kind,
        'qoo10_urls', x.qoo10_urls, 'qoo10_at', x.qoo10_at, 'cosme_urls', x.cosme_urls, 'cosme_at', x.cosme_at))
        FROM public.campaign_report_ext_rows x JOIN public.campaign_report_sources s ON s.id = x.source_id
        WHERE s.report_id = r.id), '[]'::jsonb)
  ) INTO v_out;
  RETURN v_out;
END; $$;

-- ------------------------------------------------------------
-- 검증
-- ------------------------------------------------------------
-- [V1] 414 의 권한 검증 조회 그대로 — anon true / PUBLIC 없음
-- SELECT has_function_privilege('anon', 'public.get_report_share_data(uuid, text)', 'EXECUTE'),
--        (p.proacl::text LIKE '{=X/%') AS public_remains
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--  WHERE n.nspname = 'public' AND p.proname = 'get_report_share_data';
-- 기대: true, false
--
-- [V2] 브랜드 공유 화면에서 인스타그램 모집 건이 포함된 리포트를 열고 응답을 보면
--   users[...] 에 ig·tiktok·x·youtube 네 열쇠가 있고, 그 모집 건에 낸 회원의 ig 에
--   값이 있으며, 큐텐·엣코스메 모집 건에만 낸 회원의 ig 는 null 인지
--
-- [V3] 그 리포트의 share_columns 배열에 '-ch_instagram_acct' 를 넣고 다시 열면
--   users 안 모든 회원의 ig 가 null 인지
--
-- 되돌리기: 414 파일(supabase/migrations/414_report_share_receipt_url.sql)을 그대로
--   다시 실행하면 이전 정의(SNS 계정 없음)로 돌아간다.
