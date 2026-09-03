-- 414 — 브랜드 공유 응답에 영수증 사진 주소를 연다
-- ------------------------------------------------------------
-- 사용자 결정(2026-09-04): 브랜드에게 영수증 사진을 보여준다. 이미 낸 영수증도 포함.
-- 개인정보처리방침 §3.1 제공 항목에 「구매 영수증 이미지, 주문번호·구매일·구매금액」을 같은 날 추가했다
-- (사전 공고 없이 기능 제공일 시행 — 사용자 결정. 부칙의 30일 조항과 어긋난 채 나간다는 것을 사양서에 적어 뒀다).
--
-- 바뀌는 것: get_report_share_data 가 deliverables 의 receipt_url(모든 종류)과 ext_rows 의 receipt_url 을 돌려준다.
-- 🔴 계정 ID(account_id)·이메일은 여전히 안 준다. 이름 가림도 그대로.
-- 🔴 CREATE OR REPLACE 로만 — DROP 하면 413 이 anon 에 연 실행 권한이 풀린다(387 선례).
-- 베이스: 413.
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
    'users', coalesce((SELECT jsonb_object_agg(i.id, jsonb_build_object(
        'id', i.id,
        'name_kanji', public._mask_report_name(coalesce(i.name_kanji, i.name), 2, '**'),
        'name_kana',  public._mask_report_name(i.name_kana, 3, '***'),
        'is_audit', coalesce(i.is_audit, false)))
        FROM public.influencers i
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
-- [V1] 권한이 그대로인가 — anon true / PUBLIC 없음
-- SELECT has_function_privilege('anon', 'public.get_report_share_data(uuid, text)', 'EXECUTE'),
--        (p.proacl::text LIKE '{=X/%') AS public_remains
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--  WHERE n.nspname = 'public' AND p.proname = 'get_report_share_data';
-- 기대: true, false
--
-- [V2] 브랜드 화면에서 비밀번호로 열고 응답을 보면 deliverables[].receipt_url 이 있고 account_id·email 키는 0개
