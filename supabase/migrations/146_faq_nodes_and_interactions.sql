-- =============================================================================
-- 마이그레이션 146: faq_nodes + faq_interactions + record_faq_interaction RPC
-- + 초기 시드 (7카테고리 + 24질문항목(Q1-1 포함 5하위노드) = 총 31노드)
-- 의존: 144(application_messages), 145(application_messages_pr2)
-- 롤백: 파일 끝의 "롤백 방법" 주석 참조
-- =============================================================================

-- ─────────────────────────────────────────────
-- 1. faq_nodes: 자기참조 트리 (카테고리 / 질문항목)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.faq_nodes (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_id        uuid NULL REFERENCES public.faq_nodes(id) ON DELETE CASCADE,
  kind             text NOT NULL CHECK (kind IN ('category', 'item')),
  label_ko         text NOT NULL,
  label_ja         text NOT NULL,
  body_ko          text NULL,
  body_ja          text NULL,
  action_type      text NOT NULL DEFAULT 'none' CHECK (action_type IN ('none', 'navigate')),
  action_target    text NULL,
  action_label_ko  text NULL,
  action_label_ja  text NULL,
  is_human_handoff boolean NOT NULL DEFAULT false,
  relevant_stages  text[] NULL,
  sort_order       int NOT NULL DEFAULT 0,
  active           boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       uuid NULL REFERENCES auth.users(id) ON DELETE SET NULL
);

-- 인덱스
CREATE INDEX IF NOT EXISTS faq_nodes_parent_sort_idx  ON public.faq_nodes (parent_id, sort_order);
CREATE INDEX IF NOT EXISTS faq_nodes_kind_active_idx  ON public.faq_nodes (kind, active);

-- updated_at 자동 갱신 트리거
CREATE OR REPLACE FUNCTION public._set_faq_nodes_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_faq_nodes_updated_at ON public.faq_nodes;
CREATE TRIGGER trg_faq_nodes_updated_at
  BEFORE UPDATE ON public.faq_nodes
  FOR EACH ROW EXECUTE FUNCTION public._set_faq_nodes_updated_at();

-- 행 단위 보안 정책 (RLS)
ALTER TABLE public.faq_nodes ENABLE ROW LEVEL SECURITY;

-- 인증된 사용자는 전체 행 조회 가능 (인플루언서 포함)
CREATE POLICY "faq_nodes: authenticated can select"
  ON public.faq_nodes FOR SELECT
  TO authenticated
  USING (true);

-- 캠페인 관리자 이상만 INSERT/UPDATE/DELETE 가능
CREATE POLICY "faq_nodes: campaign_admin can insert"
  ON public.faq_nodes FOR INSERT
  TO authenticated
  WITH CHECK (public.is_campaign_admin());

CREATE POLICY "faq_nodes: campaign_admin can update"
  ON public.faq_nodes FOR UPDATE
  TO authenticated
  USING (public.is_campaign_admin())
  WITH CHECK (public.is_campaign_admin());

CREATE POLICY "faq_nodes: campaign_admin can delete"
  ON public.faq_nodes FOR DELETE
  TO authenticated
  USING (public.is_campaign_admin());

-- ─────────────────────────────────────────────
-- 2. faq_interactions: FAQ 열람·해결·직접문의 측정
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.faq_interactions (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  influencer_id   uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  application_id  uuid NULL REFERENCES public.applications(id) ON DELETE SET NULL,
  faq_node_id     uuid NULL REFERENCES public.faq_nodes(id) ON DELETE SET NULL,
  action          text NOT NULL CHECK (action IN ('viewed', 'resolved', 'handoff')),
  view_count      int NOT NULL DEFAULT 1,
  created_at      timestamptz NOT NULL DEFAULT now(),
  last_viewed_at  timestamptz NULL
);

-- 부분 유니크 제약: viewed는 (influencer_id, application_id, faq_node_id) 단위로 멱등
-- application_id가 NULL인 경우 NULL은 유니크 비교에서 제외되므로,
-- NULL 응모건 viewed도 아래 제약이 커버하지 않는다.
-- NULL 케이스는 record_faq_interaction RPC 내부에서 별도 멱등 처리.
CREATE UNIQUE INDEX IF NOT EXISTS faq_interactions_viewed_unique_idx
  ON public.faq_interactions (influencer_id, application_id, faq_node_id)
  WHERE action = 'viewed' AND application_id IS NOT NULL;

-- 조회 인덱스
CREATE INDEX IF NOT EXISTS faq_interactions_app_idx           ON public.faq_interactions (application_id);
CREATE INDEX IF NOT EXISTS faq_interactions_influencer_idx    ON public.faq_interactions (influencer_id);
CREATE INDEX IF NOT EXISTS faq_interactions_node_action_idx   ON public.faq_interactions (faq_node_id, action);

-- 행 단위 보안 정책 (RLS)
ALTER TABLE public.faq_interactions ENABLE ROW LEVEL SECURITY;

-- 인증된 사용자가 본인 행만 INSERT — RPC로 감싸므로 직접 INSERT는 보조 방어선
CREATE POLICY "faq_interactions: authenticated can insert own"
  ON public.faq_interactions FOR INSERT
  TO authenticated
  WITH CHECK (influencer_id = auth.uid());

-- SELECT는 관리자 전용 (§3-2 FAQ 열람 이력 패널에서 사용)
CREATE POLICY "faq_interactions: admin can select"
  ON public.faq_interactions FOR SELECT
  TO authenticated
  USING (public.is_admin());

-- ─────────────────────────────────────────────
-- 3. RPC: record_faq_interaction
--    SECURITY DEFINER + SET search_path = '' (보안 규칙 필수)
--    influencer_id = auth.uid() 강제 (변조 차단)
--    viewed: 멱등 UPSERT (view_count+1, last_viewed_at 갱신, created_at 보존)
--    resolved / handoff: 그냥 INSERT (이벤트성 append)
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.record_faq_interaction(
  p_application_id  uuid,
  p_faq_node_id     uuid,
  p_action          text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_influencer_id uuid;
BEGIN
  -- 1. 호출자 확인 (미인증이면 예외)
  v_influencer_id := auth.uid();
  IF v_influencer_id IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;

  -- 2. action 유효성 확인
  IF p_action NOT IN ('viewed', 'resolved', 'handoff') THEN
    RAISE EXCEPTION 'invalid action: %', p_action USING ERRCODE = '22023';
  END IF;

  -- 3. viewed: 멱등 UPSERT
  IF p_action = 'viewed' THEN

    IF p_application_id IS NOT NULL THEN
      -- application_id가 있는 경우 — 부분 유니크 인덱스 활용
      INSERT INTO public.faq_interactions
        (influencer_id, application_id, faq_node_id, action, view_count, created_at, last_viewed_at)
      VALUES
        (v_influencer_id, p_application_id, p_faq_node_id, 'viewed', 1, now(), now())
      ON CONFLICT (influencer_id, application_id, faq_node_id)
        WHERE action = 'viewed' AND application_id IS NOT NULL
      DO UPDATE SET
        view_count     = public.faq_interactions.view_count + 1,
        last_viewed_at = now();
        -- created_at은 갱신하지 않음 (최초 열람 시각 보존)

    ELSE
      -- application_id가 NULL인 경우 — 부분 유니크 인덱스가 커버하지 않으므로
      -- 기존 행을 수동으로 조회 후 UPSERT
      UPDATE public.faq_interactions
        SET view_count     = view_count + 1,
            last_viewed_at = now()
      WHERE influencer_id  = v_influencer_id
        AND application_id IS NULL
        AND faq_node_id    = p_faq_node_id
        AND action         = 'viewed';

      IF NOT FOUND THEN
        INSERT INTO public.faq_interactions
          (influencer_id, application_id, faq_node_id, action, view_count, created_at, last_viewed_at)
        VALUES
          (v_influencer_id, NULL, p_faq_node_id, 'viewed', 1, now(), now());
      END IF;
    END IF;

  ELSE
    -- 4. resolved / handoff: 이벤트성 append
    INSERT INTO public.faq_interactions
      (influencer_id, application_id, faq_node_id, action, view_count, created_at, last_viewed_at)
    VALUES
      (v_influencer_id, p_application_id, p_faq_node_id, p_action, 1, now(), NULL);
  END IF;
END;
$$;

-- 인증된 사용자에게 실행 권한 부여
GRANT EXECUTE ON FUNCTION public.record_faq_interaction(uuid, uuid, text) TO authenticated;

-- ─────────────────────────────────────────────
-- 4. 시드: 7카테고리 + 18질문(Q1-1은 분기 노드) + 5하위 = 총 30노드
--    재실행 안전: 고정 UUID + ON CONFLICT DO NOTHING
--    (운영자가 수정한 내용을 마이그레이션 재적용이 덮어쓰지 않음)
-- ─────────────────────────────────────────────

-- ──────────────────────────────
-- 카테고리 (kind='category', parent_id=NULL)
-- sort_order: 10, 20, 30 ... (사이에 추가 여지)
-- ──────────────────────────────
INSERT INTO public.faq_nodes
  (id, parent_id, kind, label_ko, label_ja, sort_order, active)
VALUES
  -- 카테고리 1: 신청·응모
  ('00000001-0000-0000-0000-000000000001'::uuid, NULL, 'category',
   '신청·응모', '申し込み・応募', 10, true),
  -- 카테고리 2: 심사·결과
  ('00000001-0000-0000-0000-000000000002'::uuid, NULL, 'category',
   '심사·결과', '審査・結果', 20, true),
  -- 카테고리 3: 결과물 제출
  ('00000001-0000-0000-0000-000000000003'::uuid, NULL, 'category',
   '결과물 제출', '成果物の提出', 30, true),
  -- 카테고리 4: 배송
  ('00000001-0000-0000-0000-000000000004'::uuid, NULL, 'category',
   '배송', '配送', 40, true),
  -- 카테고리 5: 보수·정산
  ('00000001-0000-0000-0000-000000000005'::uuid, NULL, 'category',
   '보수·정산', '報酬・精算', 50, true),
  -- 카테고리 6: 계정·프로필
  ('00000001-0000-0000-0000-000000000006'::uuid, NULL, 'category',
   '계정·프로필', 'アカウント・プロフィール', 60, true),
  -- 카테고리 7: 그 외
  ('00000001-0000-0000-0000-000000000007'::uuid, NULL, 'category',
   '그 외', 'その他', 70, true)
ON CONFLICT (id) DO NOTHING;

-- ──────────────────────────────
-- 카테고리 1 질문항목
-- ──────────────────────────────

-- Q1-1: 응모가 안 돼요 — 분기 노드 (body 없음, 하위 5개 자식 노드)
INSERT INTO public.faq_nodes
  (id, parent_id, kind, label_ko, label_ja, body_ko, body_ja,
   action_type, action_target, action_label_ko, action_label_ja,
   is_human_handoff, relevant_stages, sort_order, active)
VALUES
  ('00000002-0000-0000-0001-000000000001'::uuid,
   '00000001-0000-0000-0000-000000000001'::uuid,
   'item',
   '신청(응모)이 안 돼요',
   '応募ができません',
   '원인을 골라 주세요.',
   '原因を選んでください。',
   'none', NULL, NULL, NULL,
   false, NULL, 10, true)
ON CONFLICT (id) DO NOTHING;

-- Q1-1-a: 이메일 인증 필요
INSERT INTO public.faq_nodes
  (id, parent_id, kind, label_ko, label_ja, body_ko, body_ja,
   action_type, action_target, action_label_ko, action_label_ja,
   is_human_handoff, relevant_stages, sort_order, active)
VALUES
  ('00000002-0000-0000-0001-000000000011'::uuid,
   '00000002-0000-0000-0001-000000000001'::uuid,
   'item',
   '이메일 인증이 필요하다고 떠요',
   'メール認証が必要と表示されます',
   '응모 전에 이메일 주소 확인이 필요합니다. 1. 가입한 이메일로 온 REVERB 메일을 엽니다. 2. 메일 안의 링크를 한 번 누릅니다. 3. 확인 완료, 다시 응모해 보세요. 메일이 안 보이면 스팸함도 확인하시고, 그래도 없으면 직접 문의 바랍니다.',
   'ご応募の前に、メールアドレスの確認が必要です。つぎの順番でおこないます。
1. ご登録のメールアドレスに届いている、REVERBからのメールを開きます。
2. メールの中のリンクを1回押します。
3. これで確認は完了です。もう一度ご応募をお試しください。
メールが見つからないときは、迷惑メールのフォルダもご確認ください。それでも届いていないときは、下の「直接お問い合わせ」からご連絡ください。',
   'none', NULL, NULL, NULL,
   false, NULL, 10, true)
ON CONFLICT (id) DO NOTHING;

-- Q1-1-b: 필수 정보 입력 필요
INSERT INTO public.faq_nodes
  (id, parent_id, kind, label_ko, label_ja, body_ko, body_ja,
   action_type, action_target, action_label_ko, action_label_ja,
   is_human_handoff, relevant_stages, sort_order, active)
VALUES
  ('00000002-0000-0000-0001-000000000012'::uuid,
   '00000002-0000-0000-0001-000000000001'::uuid,
   'item',
   '필수 정보를 입력하라고 떠요',
   '必須情報を入力してくださいと表示されます',
   '응모 전에 마이페이지에서 3가지를 등록해야 합니다. 아래 버튼으로 마이페이지를 열어 1. SNS 계정(응모할 캠페인 대상) 2. 배송지(우편번호·도도부현·시·전화) 3. PayPal 이메일을 등록하세요. 미등록 항목은 「未登録」으로 표시되며, 모두 등록하면 응모할 수 있습니다.',
   'ご応募の前に、マイページで3つの情報を登録しておく必要があります。下のボタンからマイページを開いて、つぎを登録してください。
1. SNSアカウント（応募するキャンペーンの対象になっているもの）
2. お届け先（郵便番号・都道府県・市区町村・電話番号）
3. PayPalのメールアドレス
まだ登録していない項目には「未登録」と表示されます。すべて登録すると、ご応募いただけます。',
   'navigate', '#mypage-profile-basic', '기본정보 보기', '基本情報を見る',
   false, NULL, 20, true)
ON CONFLICT (id) DO NOTHING;

-- Q1-1-c: 팔로워 수 부족 (플레이스홀더 {required}/{current} 그대로 시드 — PR B에서 동적 치환)
INSERT INTO public.faq_nodes
  (id, parent_id, kind, label_ko, label_ja, body_ko, body_ja,
   action_type, action_target, action_label_ko, action_label_ja,
   is_human_handoff, relevant_stages, sort_order, active)
VALUES
  ('00000002-0000-0000-0001-000000000013'::uuid,
   '00000002-0000-0000-0001-000000000001'::uuid,
   'item',
   '팔로워 수가 부족하다고 떠요',
   'フォロワー数が足りないと表示されます',
   '이 캠페인은 최소 팔로워 수 조건이 있습니다.
・필요 팔로워: {required}명 이상
・현재 팔로워: {current}명
1. 아래 버튼으로 마이페이지 SNS 계정을 엽니다. 2. 팔로워 수를 지금 최신 인원으로 고칩니다. 3. 고친 뒤 다시 응모해 보세요. 조건은 대표로 설정한 SNS의 팔로워 수로 확인합니다.',
   'このキャンペーンには「最低フォロワー数」の条件があります。
・必要なフォロワー数：{required}人以上
・あなたの現在のフォロワー数：{current}人
つぎをご確認ください。
1. 下のボタンからマイページのSNSアカウントを開きます。
2. フォロワー数を、いまの最新の人数に直します。
3. 直したあと、もう一度ご応募をお試しください。
条件は、代表に設定したSNSのフォロワー数で確認します。',
   'navigate', '#mypage-profile-sns', 'SNS 계정 보기', 'SNSアカウントを見る',
   false, NULL, 30, true)
ON CONFLICT (id) DO NOTHING;

-- Q1-1-d: 이미 신청했다고 떠요
INSERT INTO public.faq_nodes
  (id, parent_id, kind, label_ko, label_ja, body_ko, body_ja,
   action_type, action_target, action_label_ko, action_label_ja,
   is_human_handoff, relevant_stages, sort_order, active)
VALUES
  ('00000002-0000-0000-0001-000000000014'::uuid,
   '00000002-0000-0000-0001-000000000001'::uuid,
   'item',
   '이미 신청했다고 떠요',
   'すでに応募済みと表示されます',
   '같은 캠페인에 중복 응모는 안 됩니다. 이미 응모하셨을 수 있습니다. 아래 버튼으로 응모이력을 열면 현재 응모 상태를 확인할 수 있습니다.',
   '同じキャンペーンには、重ねてご応募いただけません。すでにご応募されている可能性があります。下のボタンから応募履歴を開くと、いまの応募の状況をご確認いただけます。',
   'navigate', '#mypage-applications', '응모이력 보기', '応募履歴を見る',
   false, NULL, 40, true)
ON CONFLICT (id) DO NOTHING;

-- Q1-1-e: 모집이 마감됐다고 떠요
INSERT INTO public.faq_nodes
  (id, parent_id, kind, label_ko, label_ja, body_ko, body_ja,
   action_type, action_target, action_label_ko, action_label_ja,
   is_human_handoff, relevant_stages, sort_order, active)
VALUES
  ('00000002-0000-0000-0001-000000000015'::uuid,
   '00000002-0000-0000-0001-000000000001'::uuid,
   'item',
   '모집이 마감됐다고 떠요',
   '募集が締め切られたと表示されます',
   '이 캠페인은 모집이 끝났습니다. 모집 인원이 찼거나 마감일이 지나면 새로 응모할 수 없습니다. 다른 캠페인은 캠페인 목록에서 볼 수 있습니다.',
   'このキャンペーンは、募集が終わっています。募集人数がいっぱいになったか、募集の期限が過ぎた場合は、新しくご応募いただけません。ほかのキャンペーンは、キャンペーン一覧からご覧いただけます。',
   'none', NULL, NULL, NULL,
   false, NULL, 50, true)
ON CONFLICT (id) DO NOTHING;

-- Q1-2: 응모를 취소하고 싶어요
INSERT INTO public.faq_nodes
  (id, parent_id, kind, label_ko, label_ja, body_ko, body_ja,
   action_type, action_target, action_label_ko, action_label_ja,
   is_human_handoff, relevant_stages, sort_order, active)
VALUES
  ('00000002-0000-0000-0001-000000000002'::uuid,
   '00000001-0000-0000-0000-000000000001'::uuid,
   'item',
   '응모를 취소하고 싶어요',
   '応募を取り消したいです',
   '응모 취소는 다음 순서로 합니다. 1. 아래 버튼으로 응모이력을 엽니다. 2. 취소할 응모 카드의 메뉴(점 3개 표시)를 누릅니다. 3. 「취소」를 고릅니다. 단 결과물이 이미 승인된 경우 등은 취소가 안 될 수 있습니다. 도중에 에러가 나면 직접 문의 바랍니다.',
   'ご応募の取り消しは、つぎの順番でおこないます。
1. 下のボタンから応募履歴を開きます。
2. 取り消したい応募のカードにある、メニュー（点が3つのマーク）を押します。
3. 「取り消し」を選びます。
なお、成果物がすでに承認されている場合などは、取り消しができないことがあります。とちゅうでエラーが出るときは、下の「直接お問い合わせ」からご連絡ください。',
   'navigate', '#mypage-applications', '응모이력 보기', '応募履歴を見る',
   false, NULL, 20, true)
ON CONFLICT (id) DO NOTHING;

-- Q1-3: 다시 신청할 수 있나요
INSERT INTO public.faq_nodes
  (id, parent_id, kind, label_ko, label_ja, body_ko, body_ja,
   action_type, action_target, action_label_ko, action_label_ja,
   is_human_handoff, relevant_stages, sort_order, active)
VALUES
  ('00000002-0000-0000-0001-000000000003'::uuid,
   '00000001-0000-0000-0000-000000000001'::uuid,
   'item',
   '취소 후 다시 신청할 수 있나요',
   'もう一度応募できますか',
   '응모를 취소한 뒤, 그 캠페인 모집이 아직 진행 중이면 다시 응모할 수 있습니다. 모집이 이미 끝난 경우엔 새로 응모할 수 없습니다.',
   'ご応募を取り消したあと、そのキャンペーンの募集がまだ続いていれば、もう一度ご応募いただけます。募集がすでに終わっている場合は、新しくご応募いただけません。',
   'none', NULL, NULL, NULL,
   false, NULL, 30, true)
ON CONFLICT (id) DO NOTHING;

-- ──────────────────────────────
-- 카테고리 2 질문항목
-- ──────────────────────────────

-- Q2-1: 심사는 언제 끝나나요
INSERT INTO public.faq_nodes
  (id, parent_id, kind, label_ko, label_ja, body_ko, body_ja,
   action_type, action_target, action_label_ko, action_label_ja,
   is_human_handoff, relevant_stages, sort_order, active)
VALUES
  ('00000002-0000-0000-0002-000000000001'::uuid,
   '00000001-0000-0000-0000-000000000002'::uuid,
   'item',
   '심사는 언제 끝나나요',
   '審査はいつ終わりますか',
   '현재 심사 상태는 이 화면 맨 위, 또는 응모이력에서 확인할 수 있습니다. 심사에 며칠 걸릴 수 있고, 결과가 정해지면 앱 알림으로 안내하니 잠시 기다려 주세요.',
   'いまの審査の状況は、この画面のいちばん上、または応募履歴でご確認いただけます。審査には数日かかることがあります。結果が決まりましたら、アプリの通知でお知らせしますので、今しばらくお待ちください。',
   'navigate', '#mypage-applications', '응모이력 보기', '応募履歴を見る',
   false, ARRAY['pending'], 10, true)
ON CONFLICT (id) DO NOTHING;

-- Q2-2: 당첨됐는지 어떻게 아나요
INSERT INTO public.faq_nodes
  (id, parent_id, kind, label_ko, label_ja, body_ko, body_ja,
   action_type, action_target, action_label_ko, action_label_ja,
   is_human_handoff, relevant_stages, sort_order, active)
VALUES
  ('00000002-0000-0000-0002-000000000002'::uuid,
   '00000001-0000-0000-0000-000000000002'::uuid,
   'item',
   '당첨됐는지 어디서 알 수 있나요',
   '当選したかどうか、どこで分かりますか',
   '당첨 결과는 다음에서 확인합니다. 1. 아래 버튼으로 응모이력을 엽니다. 2. 각 응모에 표시되는 상태를 봅니다. 당첨 시 「当選」으로 표시되고 앱 알림으로도 안내합니다.',
   '当選の結果は、つぎの場所でご確認いただけます。
1. 下のボタンから応募履歴を開きます。
2. 各応募のところに表示される状態を見ます。
当選された場合は「当選」と表示され、アプリの通知でもお知らせします。',
   'navigate', '#mypage-applications', '응모이력 보기', '応募履歴を見る',
   false, ARRAY['pending'], 20, true)
ON CONFLICT (id) DO NOTHING;

-- Q2-3: 왜 비승인(선정 안 됨)됐는지 알고 싶어요
INSERT INTO public.faq_nodes
  (id, parent_id, kind, label_ko, label_ja, body_ko, body_ja,
   action_type, action_target, action_label_ko, action_label_ja,
   is_human_handoff, relevant_stages, sort_order, active)
VALUES
  ('00000002-0000-0000-0002-000000000003'::uuid,
   '00000001-0000-0000-0000-000000000002'::uuid,
   'item',
   '왜 비승인(선정 안 됨)됐는지 알고 싶어요',
   '選ばれなかった理由を知りたいです',
   '응모 감사합니다. 선정은 팔로워 수만이 아니라 게시물 내용·캠페인과의 적합도 등 여러 점을 종합 판단합니다. 그래서 개별 사유는 안내드리지 않습니다. 이번엔 인연이 없었지만, 꼭 다른 캠페인에 또 응모해 주세요. 기다리겠습니다.',
   'ご応募ありがとうございました。選考は、フォロワー数だけでなく、投稿の内容やキャンペーンとの相性など、いくつかの点をまとめて判断しております。そのため、おひとりずつの個別の理由はお伝えしておりません。ご縁がありませんでしたが、ぜひまた別のキャンペーンにご応募ください。お待ちしております。',
   'none', NULL, NULL, NULL,
   false, ARRAY['rejected'], 30, true)
ON CONFLICT (id) DO NOTHING;

-- ──────────────────────────────
-- 카테고리 3 질문항목
-- ──────────────────────────────

-- Q3-1: 영수증을 어떻게 올리나요
INSERT INTO public.faq_nodes
  (id, parent_id, kind, label_ko, label_ja, body_ko, body_ja,
   action_type, action_target, action_label_ko, action_label_ja,
   is_human_handoff, relevant_stages, sort_order, active)
VALUES
  ('00000002-0000-0000-0003-000000000001'::uuid,
   '00000001-0000-0000-0000-000000000003'::uuid,
   'item',
   '영수증을 어떻게 올리나요',
   'レシート（領収書）はどう提出しますか',
   '영수증 제출은 다음 순서로 합니다. 1. 상품을 구매합니다. 2. 아래 「成果物提出」 버튼을 눌러 제출 화면을 엽니다. 3. 주문번호·구매한 날짜·구매한 금액 3가지를 입력합니다. 4. 영수증 사진을 올립니다. 5. 「제출」을 누르면 완료. 모르겠으면 직접 문의 바랍니다.',
   'レシートのご提出は、つぎの順番でおこないます。
1. 商品を購入します。
2. 下の「成果物提出」ボタンを押して、提出の画面を開きます。
3. つぎの3つを入力します。
　・注文番号
　・購入した日
　・購入した金額
4. レシートの写真をアップロードします。
5. 「提出」を押したら完了です。
わからないときは、下の「直接お問い合わせ」からご連絡ください。',
   'navigate', '#activity', '결과물 제출 화면 보기', '成果物提出を開く',
   false, ARRAY['approved_purchase'], 10, true)
ON CONFLICT (id) DO NOTHING;

-- Q3-2: 게시물 주소(URL) 등록이 안 돼요
INSERT INTO public.faq_nodes
  (id, parent_id, kind, label_ko, label_ja, body_ko, body_ja,
   action_type, action_target, action_label_ko, action_label_ja,
   is_human_handoff, relevant_stages, sort_order, active)
VALUES
  ('00000002-0000-0000-0003-000000000002'::uuid,
   '00000001-0000-0000-0000-000000000003'::uuid,
   'item',
   '게시물 주소(URL) 등록이 안 돼요',
   '投稿リンク（URL）の登録ができません',
   '게시물 주소(URL) 등록은 다음 순서로 합니다. 1. 아래 「成果物提出」 버튼으로 제출 화면을 엽니다. 2. 게시물 공개 페이지 주소를 붙여넣습니다. 3. 주소로 인스타그램·틱톡 등 종류가 자동 선택됩니다. 4. 자동 선택이 안 되면 직접 종류를 고릅니다. 5. 「제출」을 누르면 완료. 주소는 게시물이 보이는 공개 페이지 것을 붙여넣으세요.',
   '投稿のリンク（URL）のご登録は、つぎの順番でおこないます。
1. 下の「成果物提出」ボタンを押して、提出の画面を開きます。
2. 投稿の公開ページのリンク（URL）を貼り付けます。
3. リンクから、InstagramやTikTokなどの種類が自動で選ばれます。
4. もし自動で選ばれないときは、ご自分で種類を選びます。
5. 「提出」を押したら完了です。
リンクは、投稿が見られる公開ページのものを貼り付けてください。',
   'navigate', '#activity', '결과물 제출 화면 보기', '成果物提出を開く',
   false, ARRAY['approved_post'], 20, true)
ON CONFLICT (id) DO NOTHING;

-- Q3-3: 게시물 규칙(해시태그)이 있나요
INSERT INTO public.faq_nodes
  (id, parent_id, kind, label_ko, label_ja, body_ko, body_ja,
   action_type, action_target, action_label_ko, action_label_ja,
   is_human_handoff, relevant_stages, sort_order, active)
VALUES
  ('00000002-0000-0000-0003-000000000003'::uuid,
   '00000001-0000-0000-0000-000000000003'::uuid,
   'item',
   '게시물 규칙(해시태그)이 있나요',
   '投稿の決まり（ハッシュタグ）はありますか',
   '게시 시 다음 규칙을 지켜주세요. 1. 「#PR」 또는 「#広告」 중 하나를 반드시 게시물에 적습니다(광고임을 알리는 일본 규칙). 2. 브랜드 지정 해시태그·계정이 있으면 함께 넣습니다. 3. 게시물은 정해진 기간 동안 그대로 둡니다. 자세한 조건은 각 캠페인 가이드라인 확인.',
   '投稿のときは、つぎの決まりを守ってください。
1. 「#PR」または「#広告」のどちらかを、必ず投稿に書きます。（広告であることを伝えるための、日本のルールです）
2. ブランドから指定されたハッシュタグやアカウントがある場合は、それも入れます。
3. 投稿は、決められた期間そのまま残しておきます。
くわしい条件は、各キャンペーンのガイドラインでご確認ください。',
   'none', NULL, NULL, NULL,
   false, ARRAY['approved_post'], 30, true)
ON CONFLICT (id) DO NOTHING;

-- Q3-4: 제출 기한이 지났어요 / 못 맞출 것 같아요 (handoff)
INSERT INTO public.faq_nodes
  (id, parent_id, kind, label_ko, label_ja, body_ko, body_ja,
   action_type, action_target, action_label_ko, action_label_ja,
   is_human_handoff, relevant_stages, sort_order, active)
VALUES
  ('00000002-0000-0000-0003-000000000004'::uuid,
   '00000001-0000-0000-0000-000000000003'::uuid,
   'item',
   '제출 기한이 지났어요 / 못 맞출 것 같아요',
   '提出期限が過ぎました / 間に合いそうにありません',
   '제출 기한이 지나면 제출 폼이 안 될 수 있습니다. 또 기한 내 미게시 시 원고료 지급이 안 될 수 있습니다. 못 맞출 사정이 있으면 가능한 빨리 직접 문의로 상담 바랍니다. 담당자가 확인합니다.',
   '提出の期限が過ぎると、提出のフォームが使えなくなることがあります。また、期限内に投稿されない場合、原稿料をお支払いできないことがあります。期限に間に合わないご事情があるときは、できるだけ早めに、下の「直接お問い合わせ」からご相談ください。担当者が確認します。',
   'none', NULL, NULL, NULL,
   true, ARRAY['approved_post'], 40, true)
ON CONFLICT (id) DO NOTHING;

-- Q3-5: 결과물이 반려됐어요, 재제출은?
INSERT INTO public.faq_nodes
  (id, parent_id, kind, label_ko, label_ja, body_ko, body_ja,
   action_type, action_target, action_label_ko, action_label_ja,
   is_human_handoff, relevant_stages, sort_order, active)
VALUES
  ('00000002-0000-0000-0003-000000000005'::uuid,
   '00000001-0000-0000-0000-000000000003'::uuid,
   'item',
   '결과물이 반려됐어요, 재제출은?',
   '成果物が差し戻されました。再提出は？',
   '결과물이 반려(다시 하기)됐을 때는 다음 순서로 합니다. 1. 아래 「成果物提出」 버튼으로 제출 화면을 엽니다. 2. 화면 맨 위에 반려 사유가 표시돼 있으니 먼저 읽습니다. 3. 사유에 맞게 내용을 고칩니다. 4. 다시 「제출」을 누릅니다. 재제출하면 다시 검수 상태로 돌아갑니다.',
   '成果物が差し戻された（やり直しになった）ときは、つぎの順番でおこないます。
1. 下の「成果物提出」ボタンを押して、提出の画面を開きます。
2. 画面のいちばん上に、差し戻しの理由が表示されています。まずそれを読みます。
3. 理由にそって、内容を直します。
4. もう一度「提出」を押します。
再提出すると、もう一度確認（審査）の状態にもどります。',
   'navigate', '#activity', '결과물 제출 화면 보기', '成果物提出を開く',
   false, ARRAY['approved_post'], 50, true)
ON CONFLICT (id) DO NOTHING;

-- ──────────────────────────────
-- 카테고리 4 질문항목
-- ──────────────────────────────

-- Q4-1: 제품은 언제 오나요
INSERT INTO public.faq_nodes
  (id, parent_id, kind, label_ko, label_ja, body_ko, body_ja,
   action_type, action_target, action_label_ko, action_label_ja,
   is_human_handoff, relevant_stages, sort_order, active)
VALUES
  ('00000002-0000-0000-0004-000000000001'::uuid,
   '00000001-0000-0000-0000-000000000004'::uuid,
   'item',
   '제품은 언제 오나요',
   '商品はいつ届きますか',
   '당첨 후 상품은 순서대로 발송됩니다. 상품은 한국에서 보내므로 도착까지 시간이 걸릴 수 있습니다. 발송 안내가 있으면 앱 알림·메시지로 연락합니다. 한참 기다려도 안 오면 직접 문의 바랍니다.',
   '当選されたあと、商品は順番に発送されます。商品は韓国から送られるため、お手元に届くまでお時間をいただくことがあります。発送についてのお知らせがある場合は、アプリの通知やメッセージでご連絡します。しばらく待っても届かないときは、下の「直接お問い合わせ」からご連絡ください。',
   'none', NULL, NULL, NULL,
   false, ARRAY['approved_purchase', 'approved_visit'], 10, true)
ON CONFLICT (id) DO NOTHING;

-- Q4-2: 상품이 잘못/누락되어 왔어요 (handoff=true)
INSERT INTO public.faq_nodes
  (id, parent_id, kind, label_ko, label_ja, body_ko, body_ja,
   action_type, action_target, action_label_ko, action_label_ja,
   is_human_handoff, relevant_stages, sort_order, active)
VALUES
  ('00000002-0000-0000-0004-000000000002'::uuid,
   '00000001-0000-0000-0000-000000000004'::uuid,
   'item',
   '상품이 잘못/누락/파손되어 왔어요',
   '商品が違う / 届いていません',
   '상품이 다르거나·파손·미착이면 한 분씩 확인이 필요합니다. 직접 문의로 1. 주문한 상품 이름 2. 현재 상황(다른 상품 도착/파손/미착 등)을 적어 연락 주세요. 담당자가 확인 후 대응합니다.',
   '商品がちがう・こわれている・届かない場合は、おひとりずつ確認が必要です。下の「直接お問い合わせ」から、つぎの内容を書いてご連絡ください。
1. 注文された商品の名前
2. いまどんな状況か（ちがう商品が届いた／こわれていた／届かない など）
担当者が確認して、ご対応します。',
   'none', NULL, NULL, NULL,
   true, NULL, 20, true)
ON CONFLICT (id) DO NOTHING;

-- ──────────────────────────────
-- 카테고리 5 질문항목
-- ──────────────────────────────

-- Q5-1: 리워드는 언제·어떻게 받나요
-- ⚠️ 운영 메모: 정산 시점·세부 조건은 운영 규칙 확정 후 문안 보강 필요
INSERT INTO public.faq_nodes
  (id, parent_id, kind, label_ko, label_ja, body_ko, body_ja,
   action_type, action_target, action_label_ko, action_label_ja,
   is_human_handoff, relevant_stages, sort_order, active)
VALUES
  ('00000002-0000-0000-0005-000000000001'::uuid,
   '00000001-0000-0000-0000-000000000005'::uuid,
   'item',
   '리워드는 언제·어떻게 받나요',
   '報酬はいつ・どのように受け取れますか',
   '리워드는 다음과 같이 받습니다. 1. 모든 결과물이 승인됩니다. 2. 그 후 등록한 PayPal 계정으로 지급합니다. 지급 시기·조건은 캠페인마다 다를 수 있습니다. PayPal 이메일이 미등록·오류면 지급이 안 되니 아래 버튼으로 마이페이지에서 한 번 확인하세요.',
   '報酬は、つぎのように受け取れます。
1. すべての成果物が承認されます。
2. そのあと、ご登録のPayPalのアカウントにお支払いします。
お支払いの時期や条件は、キャンペーンによって変わることがあります。なお、PayPalのメールアドレスが未登録だったり、まちがっていたりするとお支払いできません。下のボタンからマイページで一度ご確認ください。',
   'navigate', '#mypage-paypal', 'PayPal 설정 보기', 'PayPalを確認する',
   false, ARRAY['done'], 10, true)
ON CONFLICT (id) DO NOTHING;

-- Q5-2: PayPal 정보를 바꾸고 싶어요
INSERT INTO public.faq_nodes
  (id, parent_id, kind, label_ko, label_ja, body_ko, body_ja,
   action_type, action_target, action_label_ko, action_label_ja,
   is_human_handoff, relevant_stages, sort_order, active)
VALUES
  ('00000002-0000-0000-0005-000000000002'::uuid,
   '00000001-0000-0000-0000-000000000005'::uuid,
   'item',
   'PayPal 정보를 바꾸고 싶어요',
   'PayPal情報を変更したいです',
   'PayPal 이메일은 다음 순서로 변경합니다. 1. 아래 버튼으로 마이페이지 PayPal을 엽니다. 2. 새 이메일을 입력해 저장합니다. 지급 전에 올바른 이메일을 등록하세요.',
   'PayPalのメールアドレスは、つぎの順番で変更できます。
1. 下のボタンからマイページのPayPalを開きます。
2. 新しいメールアドレスを入力して保存します。
報酬のお支払いの前に、正しいメールアドレスをご登録ください。',
   'navigate', '#mypage-paypal', 'PayPal 설정 보기', 'PayPalを確認する',
   false, NULL, 20, true)
ON CONFLICT (id) DO NOTHING;

-- ──────────────────────────────
-- 카테고리 6 질문항목
-- ──────────────────────────────

-- Q6-1: SNS 계정을 등록/수정하려면
INSERT INTO public.faq_nodes
  (id, parent_id, kind, label_ko, label_ja, body_ko, body_ja,
   action_type, action_target, action_label_ko, action_label_ja,
   is_human_handoff, relevant_stages, sort_order, active)
VALUES
  ('00000002-0000-0000-0006-000000000001'::uuid,
   '00000001-0000-0000-0000-000000000006'::uuid,
   'item',
   'SNS 계정을 등록/수정하려면',
   'SNSアカウントを登録・修正したいです',
   'SNS 계정과 팔로워 수는 다음 순서로 등록·수정합니다. 1. 아래 버튼으로 마이페이지 SNS 계정을 엽니다. 2. 계정과 팔로워 수를 입력합니다. 3. 저장합니다. SNS는 여러 개 등록 가능하고 대표 SNS도 고를 수 있습니다.',
   'SNSアカウントとフォロワー数は、つぎの順番で登録・修正できます。
1. 下のボタンからマイページのSNSアカウントを開きます。
2. アカウントとフォロワー数を入力します。
3. 保存します。
SNSは複数登録でき、代表になるSNSを選ぶこともできます。',
   'navigate', '#mypage-profile-sns', 'SNS 계정 보기', 'SNSアカウントを見る',
   false, NULL, 10, true)
ON CONFLICT (id) DO NOTHING;

-- Q6-2: 비밀번호를 잊어버렸어요
INSERT INTO public.faq_nodes
  (id, parent_id, kind, label_ko, label_ja, body_ko, body_ja,
   action_type, action_target, action_label_ko, action_label_ja,
   is_human_handoff, relevant_stages, sort_order, active)
VALUES
  ('00000002-0000-0000-0006-000000000002'::uuid,
   '00000001-0000-0000-0000-000000000006'::uuid,
   'item',
   '비밀번호를 잊어버렸어요',
   'パスワードを忘れました',
   '비밀번호를 잊었을 때는 다음 순서로 재설정합니다. 1. 로그인 화면에서 「パスワードをお忘れですか？」를 누릅니다. 2. 가입 이메일을 입력합니다. 3. 온 메일의 링크에서 새 비밀번호를 정합니다. 로그인 상태면 아래 버튼으로 마이페이지 비밀번호 변경에서도 가능합니다.',
   'パスワードを忘れたときは、つぎの順番で再設定できます。
1. ログインの画面で「パスワードをお忘れですか？」を押します。
2. ご登録のメールアドレスを入力します。
3. 届いたメールのリンクから、新しいパスワードを決めます。
ログイン中の場合は、下のボタンからマイページのパスワード変更でも変えられます。',
   'navigate', '#mypage-password', '비밀번호 변경 보기', 'パスワード変更を開く',
   false, NULL, 20, true)
ON CONFLICT (id) DO NOTHING;

-- Q6-3: 메일을 그만 받고 싶어요
INSERT INTO public.faq_nodes
  (id, parent_id, kind, label_ko, label_ja, body_ko, body_ja,
   action_type, action_target, action_label_ko, action_label_ja,
   is_human_handoff, relevant_stages, sort_order, active)
VALUES
  ('00000002-0000-0000-0006-000000000003'::uuid,
   '00000001-0000-0000-0000-000000000006'::uuid,
   'item',
   '메일을 그만 받고 싶어요',
   'メールを受け取りたくありません',
   '메일 수신은 다음 순서로 전환합니다. 1. 아래 버튼으로 마이페이지 메일 수신 설정을 엽니다. 2. 캠페인 정보 알림 메일을 끕니다. 단 응모 상태·심사 결과·제출 기한 등 서비스 이용에 필요한 알림 메일은 계속 발송됩니다.',
   'メールの受け取りは、つぎの順番で切り替えられます。
1. 下のボタンからマイページのメール受信設定を開きます。
2. キャンペーン情報のお知らせメールを、オフにします。
なお、応募の状況・審査の結果・提出の期限など、サービスのご利用に必要なお知らせメールは、引き続きお送りします。',
   'navigate', '#mypage-email-settings', '메일 수신 설정 보기', 'メール受信設定を開く',
   false, NULL, 30, true)
ON CONFLICT (id) DO NOTHING;

-- ──────────────────────────────
-- 카테고리 7 질문항목
-- ──────────────────────────────

-- Q7-1: 그 외 문의 (handoff=true)
INSERT INTO public.faq_nodes
  (id, parent_id, kind, label_ko, label_ja, body_ko, body_ja,
   action_type, action_target, action_label_ko, action_label_ja,
   is_human_handoff, relevant_stages, sort_order, active)
VALUES
  ('00000002-0000-0000-0007-000000000001'::uuid,
   '00000001-0000-0000-0000-000000000007'::uuid,
   'item',
   '그 외 문의',
   'その他のお問い合わせ',
   '위 질문으로 해결되지 않으면 아래 입력란에서 직접 문의 바랍니다. 담당자가 확인 후 답변합니다.',
   '上のご質問で解決しないときは、下の入力らんから直接お問い合わせください。担当者が確認して、お返事します。',
   'none', NULL, NULL, NULL,
   true, NULL, 10, true)
ON CONFLICT (id) DO NOTHING;

-- =============================================================================
-- 롤백 방법 (필요 시 개발서버에서 먼저 실행 후 운영 적용)
-- =============================================================================
-- DROP FUNCTION IF EXISTS public.record_faq_interaction(uuid, uuid, text);
-- DROP TRIGGER IF EXISTS trg_faq_nodes_updated_at ON public.faq_nodes;
-- DROP FUNCTION IF EXISTS public._set_faq_nodes_updated_at();
-- DROP TABLE IF EXISTS public.faq_interactions;
-- DROP TABLE IF EXISTS public.faq_nodes;
-- (CASCADE 주의: faq_interactions.faq_node_id는 ON DELETE SET NULL이므로
--  faq_nodes 삭제 시 faq_interactions 행은 남고 faq_node_id가 NULL로 됨)
