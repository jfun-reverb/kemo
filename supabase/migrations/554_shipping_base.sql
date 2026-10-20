-- ============================================================
-- 554_shipping_base.sql   (번호는 dev 병합 직전 origin/dev·열린 병합 요청과 다시 대조 — 겹치면 파일 이름만 바꾼다)
-- 2026-10-20 · 개발서버만(운영은 브랜드 묶음 출시 날 L1 — 552·553 뒤)
--
-- 작업표 docs/specs/2026-10-19-brand-seeding-shipping-list-breakdown.md 「조각 S1」 · 결정 D15·D21 · 선결 Q3(남긴다)
-- 사양서 docs/specs/2026-10-19-brand-seeding-shipping-list.md §3 결정 8·10·13 · §4-6
--   선행: 552(_record_brand_provision)
--
-- 하는 일
--   ① lookup_values.kind 검사 제약 — 346 의 16종 + shipping_carrier(택배사) = 17종, 처음 값 7개
--   ② 권한 항목 shipping.manage(배송 리스트 보기·전달·송장 수정) — 세 등급 모두 쓰기(menu.applications 와 같게, 결정 10)
--   ③ 표 campaign_shipping_lists(캠페인당 1줄 — 전달 여부·시각·줄 번호 카운터·메일 선점)
--   ④ 표 campaign_shipments(응모 1건 = 1줄 — 택배사·송장·발송일·입력한 사람·버전)
--   ⑤ 내부 함수 _shipping_campaign_lock(캠페인 단위 잠금 — S2 의 전달·저장 함수와 같은 열쇠) ·
--      _shipping_provision_columns(브랜드에 열리는 칸 목록 — 제공 기록의 columns, S2 전달 기록도 이것을 쓴다)
--   ⑥ 트리거 trg_application_shipping_sync(응모 삽입·상태 변경 뒤) — 전달된 시딩형 캠페인에서 승인되면 줄을 넣거나 되살리고
--      같은 거래에서 제공 기록 shipping_auto_add 한 줄(선결 Q3)
--   적용만으로 바뀌는 기존 동작: 없다 — 아직 전달된 캠페인이 없으므로 트리거는 늘 바로 빠진다.
--
-- ============================================================
-- 확인한 것 (2026-10-20, 저장소 검색)
-- ============================================================
--   [이름 충돌 없음] campaign_shipping_lists · campaign_shipments · shipping_carrier · shipping.manage ·
--     _shipping_campaign_lock · _shipping_provision_columns · _application_shipping_sync · trg_application_shipping_sync — migrations·dev/ 0건.
--   [kind 제약 현재 원본 = 346] lookup_values_kind_check 를 정의한 파일은 160·227·346 — 346 이 마지막(16종).
--   [권한 시드 방식 = 441·530] role_permissions(role, feature_key, access_level, default_level), super_admin 행 포함.
--     update_role_permissions(271)는 시드된 키만 저장을 받으므로 세 등급 행을 여기서 넣는다. 화면 카탈로그(shared.js) 등록은 S3.
--   [응모 상태가 바뀌는 길] 관리자 표 직접 수정(승인·반려·대기) · cancel_application(394 — 취소) · restore_cancelled_application(525 —
--     previous_status 로 같은 응모 줄이 돌아온다 → 승인으로 돌아오면 이 트리거가 줄을 되살린다) · 재응모 = 새 응모 줄(새 배송 줄).
--     시딩형 응모는 늘 심사중으로 들어오지만(537) INSERT 도 함께 건다(작업표 그대로 — 다른 삽입 경로가 생겨도 빠지지 않게).
--   [보관 삭제] soft_delete_campaign 이 신청을 즉시 지운다 → campaign_shipments.application_id 는 「함께 지움」.
--     campaign_shipping_lists 는 캠페인 행이 남아 있는 동안(보관 30일) 남고, 258 의 영구 삭제 때 함께 지워진다.
--   [감사용 계정] 543 _brand_campaign_counts 와 같은 판정 — influencers.is_audit = false 인 회원만.
--   [개인정보 복사 없음] 두 표에 주소·전화·이름을 두지 않는다(읽을 때 applications.address·influencers 에서 — 520 탈퇴 파기에 새 절 불필요).
--
-- ============================================================
-- 설계 판단
-- ============================================================
--   [K1] 잠금 순서: 트리거는 「시딩형·보관 아님·감사용 아님」만 잠금 없이 거르고, 「전달됐나」는 **잠금을 잡은 뒤** 읽는다.
--        잠금 전에 읽으면 — 전달 함수가 거래를 끝내기 직전에 승인된 응모가 「아직 전달 전」으로 보여 빠지고, 전달 함수도 아직 커밋 안 된
--        그 승인을 못 봐서 **아무 쪽도 줄을 안 넣는다.** 🔴 S2 의 전달·저장 함수도 첫 줄에서 _shipping_campaign_lock 을 잡고 그 뒤에 읽는다.
--   [K2] 되살림(D15): 줄이 이미 있으면 added_at 은 늘 지금으로(「새로 추가」 표시 D4), added_on(기한 기준 D14)은 송장이 없을 때만 오늘(일본 날짜).
--        version 은 +1 — 화면이 되살아나기 전 판으로 저장하면 버전 확인에서 거부된다. 송장·입력한 사람 칸은 건드리지 않는다.
--   [K3] 줄 번호(D21): campaign_shipping_lists.next_row_no 를 +1 하고 앞 값을 쓴다(잠금 안이라 겹치지 않는다). 지운 번호는 다시 쓰지 않는다.
--   [K4] 제공 기록의 사람 이름 = influencers.name(비면 applications.user_name) — 브랜드가 실제로 받는 전체 이름(결과물과 달리 가리지 않는다).
--        칸 목록 = _shipping_provision_columns() 한 곳(이름·가나·우편번호·주소·전화).
--   [K5] 기록이 실패하면 승인도 실패한다(같은 거래 — 「기록 없는 제공」을 만들지 않는다, 사양서 ② 결정). 552 _record_brand_provision 은
--        system 갈래에서 계정을 읽지 않으므로 실패할 길은 사실상 CHECK 위반뿐이다.
--   [K6] 상태가 승인이 아닌 쪽으로 바뀔 때(취소·반려·대기)는 줄을 건드리지 않는다 — 상태는 읽을 때 응모에서 판정한다(S2).
--   [K7] 두 표 모두 행 단위 보안을 켜고 정책을 두지 않는다(함수로만). anon·authenticated 의 표 권한도 걷는다(552 J7 보다 한 겹 더 — SELECT 도 없음).
--
-- ============================================================
-- 롤백 (S2 이후에는 S2 함수부터 먼저 되돌린다) — 트리거부터(응모 승인 경로를 막지 않게)
-- ============================================================
--   DROP TRIGGER IF EXISTS trg_application_shipping_sync ON public.applications;
--   DROP FUNCTION IF EXISTS public._application_shipping_sync();
--   DROP FUNCTION IF EXISTS public._shipping_provision_columns();
--   DROP FUNCTION IF EXISTS public._shipping_campaign_lock(uuid);
--   DROP TABLE IF EXISTS public.campaign_shipments;
--   DROP TABLE IF EXISTS public.campaign_shipping_lists;
--   DELETE FROM public.role_permissions WHERE feature_key = 'shipping.manage';
--   DELETE FROM public.lookup_values WHERE kind = 'shipping_carrier';
--   그다음 346 의 「1. lookup_values.kind CHECK 확장」 블록을 다시 실행한다(16종으로).
--   (표를 지우면 입력한 송장이 사라진다 — 운영에서는 지우기 전에 반드시 사용자 확인)
-- ============================================================

BEGIN;

-- ── 1. 기준 데이터 종류 + 택배사 처음 값 7개 (결정 8 순서) ──────────

ALTER TABLE public.lookup_values DROP CONSTRAINT IF EXISTS lookup_values_kind_check;

ALTER TABLE public.lookup_values
  ADD CONSTRAINT lookup_values_kind_check
  CHECK (kind IN (
    'channel',
    'category',
    'content_type',
    'ng_item',
    'reject_reason',
    'blacklist_reason',
    'violation_reason',
    'caution',
    'admin_email_kind',
    'cancel_reason',
    'message_hide_reason',
    'admin_proxy_reason',
    'ob_series',
    'ob_category',
    'ob_tier',
    'withdraw_reason',
    'shipping_carrier'
  ));

COMMENT ON COLUMN public.lookup_values.kind IS
  'channel | category | content_type | ng_item | reject_reason | blacklist_reason | '
  'violation_reason | caution | admin_email_kind | cancel_reason | message_hide_reason | '
  'admin_proxy_reason | ob_series | ob_category | ob_tier | withdraw_reason | shipping_carrier';

-- 「기타」는 목록 행이 아니다 — 저장 규칙(carrier_code 비움 + carrier_other)이다
INSERT INTO public.lookup_values (kind, code, name_ko, name_ja, sort_order, active) VALUES
  ('shipping_carrier', 'kpost_ems',  '우체국 EMS',       'EMS（韓国郵便）', 10, true),
  ('shipping_carrier', 'kpacket',    'K-Packet',         'K-Packet',        20, true),
  ('shipping_carrier', 'cj_intl',    'CJ대한통운 국제',  'CJ大韓通運 国際', 30, true),
  ('shipping_carrier', 'lotte_intl', '롯데 국제',        'ロッテ 国際',     40, true),
  ('shipping_carrier', 'japan_post', '일본우편',         '日本郵便',        50, true),
  ('shipping_carrier', 'yamato',     '야마토',           'ヤマト運輸',      60, true),
  ('shipping_carrier', 'sagawa',     '사가와',           '佐川急便',        70, true)
ON CONFLICT (kind, code) DO NOTHING;

-- ── 2. 권한 항목 shipping.manage — 세 등급 쓰기(결정 10 · 441·530 방식) ──
--   🔴 행이 없으면 has_permission 이 등급 둘은 거부, 최고 관리자만 통과(269) — S2 함수보다 먼저 넣는다.
--   매니저의 주소·전화는 이 항목이 아니라 influencer.sensitive_pii 가 가른다(선결 Q2 — S2).
INSERT INTO public.role_permissions (role, feature_key, access_level, default_level)
VALUES
  ('super_admin',      'shipping.manage', 'write', 'write'),
  ('campaign_admin',   'shipping.manage', 'write', 'write'),
  ('campaign_manager', 'shipping.manage', 'write', 'write')
ON CONFLICT (role, feature_key) DO NOTHING;

-- ── 3. 표 ────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.campaign_shipping_lists (
  campaign_id     uuid        PRIMARY KEY REFERENCES public.campaigns(id) ON DELETE CASCADE,
  delivered_at    timestamptz,                       -- NULL = 아직 전달 전 (관리자가 전달 전에 송장을 넣으면 줄만 먼저 생긴다 — S2)
  delivered_by    uuid,
  next_row_no     integer     NOT NULL DEFAULT 1 CHECK (next_row_no >= 1),
  mail_claimed_at timestamptz,                       -- 전달 알림 메일 「선점 먼저」(S7)
  mail_sent_at    timestamptz,
  version         integer     NOT NULL DEFAULT 1,
  created_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.campaign_shipping_lists IS
  '[554·S1] 시딩형 배송 리스트 — 캠페인당 1줄. delivered_at 이 차면 브랜드에게 열린다(되돌리지 않음 — 결정 9). '
  'next_row_no = 다음 줄 번호(D21). 정책 없음 — 함수로만.';

CREATE TABLE IF NOT EXISTS public.campaign_shipments (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id     uuid        NOT NULL REFERENCES public.campaigns(id) ON DELETE CASCADE,
  -- 🔴 함께 지움 — 보관 삭제가 응모를 즉시 지운다(지우기 막음이면 캠페인 삭제가 깨진다)
  application_id  uuid        NOT NULL UNIQUE REFERENCES public.applications(id) ON DELETE CASCADE,
  row_no          integer     NOT NULL CHECK (row_no >= 1),
  added_on        date        NOT NULL,              -- 발송 기한 기준(일본 날짜, D14)
  added_at        timestamptz NOT NULL DEFAULT now(),-- 「새로 추가」 표시 기준(D4)
  carrier_code    text,                              -- lookup_values(kind='shipping_carrier').code — 「기타」면 NULL
  carrier_other   text,                              -- 「기타」일 때 직접 쓴 이름
  tracking_no     text,
  shipped_on      date,
  updated_by      uuid,
  updated_by_kind text        CHECK (updated_by_kind IN ('brand','admin')),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  version         integer     NOT NULL DEFAULT 1,
  CONSTRAINT campaign_shipments_row_no_key UNIQUE (campaign_id, row_no),
  CONSTRAINT campaign_shipments_carrier_one CHECK (carrier_code IS NULL OR carrier_other IS NULL)
);

COMMENT ON TABLE public.campaign_shipments IS
  '[554·S1] 배송 줄 — 응모 1건 = 1줄. 주소·전화·이름은 두지 않는다(읽을 때 응모·회원에서). '
  '상태(발송 전·기한 지남·발송함·취소됨)는 저장하지 않고 S2 가 응모 상태·added_on·tracking_no 로 판정한다. 정책 없음 — 함수로만.';

-- ── 4. 행 단위 보안 — 정책 없음 + 표 권한도 걷는다 [K7] ────────────

ALTER TABLE public.campaign_shipping_lists ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.campaign_shipments      ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.campaign_shipping_lists FROM anon, authenticated;
REVOKE ALL ON public.campaign_shipments      FROM anon, authenticated;

-- ── 5. 내부 함수 둘 ──────────────────────────────────────────

-- 캠페인 단위 잠금 — 트리거·전달·저장(S2)이 같은 열쇠를 쓴다 [K1]
CREATE OR REPLACE FUNCTION public._shipping_campaign_lock(p_campaign_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('campaign_shipping|' || p_campaign_id::text, 0));
END;
$$;

COMMENT ON FUNCTION public._shipping_campaign_lock(uuid) IS
  '[554·S1] 배송 리스트 캠페인 단위 잠금(거래 끝까지). 트리거·전달·저장 함수가 첫 줄에서 잡고 그 뒤에 읽는다. 내부 전용.';

-- 브랜드에 열리는 칸 목록 — 제공 기록 columns 의 한 곳 [K4]
CREATE OR REPLACE FUNCTION public._shipping_provision_columns()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT '["name","name_kana","postal_code","address","phone"]'::jsonb;
$$;

COMMENT ON FUNCTION public._shipping_provision_columns() IS
  '[554·S1] 배송 리스트로 브랜드에 열리는 칸(제공 기록 columns). 자동 추가(트리거)·전달(S2)이 같이 쓴다. 내부 전용.';

-- ── 6. 트리거 함수 + 트리거 ───────────────────────────────────

CREATE OR REPLACE FUNCTION public._application_shipping_sync()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_brand_id  uuid;
  v_name      text;
  v_today     date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  v_ship_id   uuid;
  v_row_no    integer;
BEGIN
  -- 승인으로 바뀐 순간만 (WHEN 이 NEW.status='approved' 를 이미 걸렀다 — 같은 값 재저장은 빠진다)
  IF TG_OP = 'UPDATE' AND OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NULL;
  END IF;

  -- 시딩형 + 보관 아님 (잠금 없이 거른다 — 대부분의 승인은 여기서 끝난다)
  SELECT c.brand_id INTO v_brand_id
    FROM public.campaigns c
   WHERE c.id = NEW.campaign_id
     AND c.recruit_type = 'gifting'
     AND c.deleted_at IS NULL;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- 감사용 아님 (543 과 같은 판정) — 이름도 여기서 [K4]
  SELECT COALESCE(NULLIF(btrim(i.name), ''), NULLIF(btrim(NEW.user_name), ''))
    INTO v_name
    FROM public.influencers i
   WHERE i.id = NEW.user_id
     AND i.is_audit = false;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- 🔴 잠금 → 그 뒤에 「전달됐나」 [K1]
  PERFORM public._shipping_campaign_lock(NEW.campaign_id);

  IF NOT EXISTS (
    SELECT 1 FROM public.campaign_shipping_lists s
     WHERE s.campaign_id = NEW.campaign_id
       AND s.delivered_at IS NOT NULL
  ) THEN
    RETURN NULL;   -- 전달 전 승인은 줄을 만들지 않는다(전달 함수가 그때 넣는다)
  END IF;

  SELECT sh.id INTO v_ship_id
    FROM public.campaign_shipments sh
   WHERE sh.application_id = NEW.id
   FOR UPDATE;

  IF FOUND THEN
    -- D15 되살림 [K2]
    UPDATE public.campaign_shipments sh
       SET added_at = now(),
           added_on = CASE WHEN sh.tracking_no IS NULL THEN v_today ELSE sh.added_on END,
           version  = sh.version + 1
     WHERE sh.id = v_ship_id;
  ELSE
    -- 새 줄 [K3]
    UPDATE public.campaign_shipping_lists s
       SET next_row_no = s.next_row_no + 1
     WHERE s.campaign_id = NEW.campaign_id
    RETURNING s.next_row_no - 1 INTO v_row_no;

    INSERT INTO public.campaign_shipments (campaign_id, application_id, row_no, added_on, added_at)
    VALUES (NEW.campaign_id, NEW.id, v_row_no, v_today, now());
  END IF;

  -- 선결 Q3 — 이 순간 새 사람의 주소가 브랜드에 열린다 = 제공 [K5]
  PERFORM public._record_brand_provision(
    v_brand_id,
    NEW.campaign_id,
    'shipping_auto_add',
    public._shipping_provision_columns(),
    jsonb_build_array(jsonb_build_object('influencer_id', NEW.user_id, 'name', v_name)),
    NULL,
    'system'
  );

  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION public._application_shipping_sync() IS
  '[554·S1] 응모가 승인으로 바뀌면 — 전달된 시딩형 캠페인 + 감사용 아님일 때 배송 줄을 넣거나 되살리고(D15) 제공 기록 shipping_auto_add. '
  '승인 아닌 쪽으로 바뀔 때는 줄을 건드리지 않는다. 캠페인 단위 잠금 뒤에 전달 여부를 읽는다.';

DROP TRIGGER IF EXISTS trg_application_shipping_sync ON public.applications;
CREATE TRIGGER trg_application_shipping_sync
  AFTER INSERT OR UPDATE OF status ON public.applications
  FOR EACH ROW
  WHEN (NEW.status = 'approved')
  EXECUTE FUNCTION public._application_shipping_sync();

-- ── 7. 실행 권한 — 셋 다 내부 전용 ──────────────────────────────
-- 🔴 회수는 두 방향(369). 트리거 함수는 실행 권한과 무관하게 돈다(정의자 권한·트리거 발화는 EXECUTE 를 보지 않는다).
--    두 보조 함수는 정의자 권한 함수(postgres 소유) 안에서만 불린다.
GRANT  EXECUTE ON FUNCTION public._shipping_campaign_lock(uuid)  TO postgres;
GRANT  EXECUTE ON FUNCTION public._shipping_provision_columns()  TO postgres;
GRANT  EXECUTE ON FUNCTION public._application_shipping_sync()   TO postgres;

REVOKE EXECUTE ON FUNCTION public._shipping_campaign_lock(uuid)  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._shipping_campaign_lock(uuid)  FROM anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public._shipping_provision_columns()  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._shipping_provision_columns()  FROM anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public._application_shipping_sync()   FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._application_shipping_sync()   FROM anon, authenticated, service_role;

COMMIT;

-- ============================================================
-- 적용 뒤 확인 (한 단계씩 — 개발서버에서 먼저)
-- ============================================================
-- [0] 적용 전: 택배사와 비슷한 이름이 다른 종류에 없는지(supabase.md 「기준 데이터 중복 확인」) — 기대 0행
--   SELECT kind, code, name_ko, name_ja FROM public.lookup_values
--    WHERE name_ko ~* '(EMS|K-?Packet|CJ|대한통운|롯데|우편|야마토|사가와)' OR name_ja ~* '(EMS|郵便|ヤマト|佐川|ロッテ)';
--
-- [1] 종류·시드·권한 — 기대: 제약에 shipping_carrier, 택배사 7행, 권한 3행 모두 write/write
--   SELECT pg_get_constraintdef(oid) ~ 'shipping_carrier' FROM pg_constraint WHERE conname = 'lookup_values_kind_check';
--   SELECT code, name_ko, sort_order FROM public.lookup_values WHERE kind = 'shipping_carrier' ORDER BY sort_order;
--   SELECT role, access_level, default_level FROM public.role_permissions WHERE feature_key = 'shipping.manage' ORDER BY role;
--
-- [2] 표·권한 — 기대: 두 표 rowsecurity=true · 정책 0개 · anon/authenticated 표 권한 없음 · 함수 셋 anon/auth/svc 모두 false
--   SELECT relname, relrowsecurity FROM pg_class WHERE relname IN ('campaign_shipping_lists','campaign_shipments');
--   SELECT count(*) FROM pg_policies WHERE tablename IN ('campaign_shipping_lists','campaign_shipments');
--   SELECT grantee, table_name, privilege_type FROM information_schema.role_table_grants
--    WHERE table_name IN ('campaign_shipping_lists','campaign_shipments') AND grantee IN ('anon','authenticated');
--   SELECT p.proname, has_function_privilege('anon',p.oid,'EXECUTE') a, has_function_privilege('authenticated',p.oid,'EXECUTE') u,
--          has_function_privilege('service_role',p.oid,'EXECUTE') s, p.proacl::text
--     FROM pg_proc p WHERE p.proname IN ('_shipping_campaign_lock','_shipping_provision_columns','_application_shipping_sync');
--
-- [3] 트리거 — 한 블록 안에서 시험하고 마지막에 예외로 되돌린다(데이터는 남지 않는다. 결과는 오류 문구로 보인다).
--     시딩형 캠페인 하나 + 감사용 아닌 응모 둘(A·B) + 감사용 응모 하나(C)로:
--     ①전달 전 A 승인 → 줄 0 ②전달 흉내(campaign_shipping_lists 행 delivered_at=now()) 뒤 B 승인 → 줄 1(row_no 1) + 제공 기록 1
--     ③B 반려 → 다시 승인 → 같은 줄(row_no 1, version 2) ④C 승인 → 줄 그대로 ⑤캠페인 보관 삭제 흉내(응모 지움) → 줄 0, 오류 없음
--   (실제 블록은 적용 세션에서 개발 데이터로 짠다 — 캠페인·응모 번호가 환경마다 달라서)
--
-- [4] 본인 응모 취소 — 시험 계정으로 인플루언서 화면에서 실제로 눌러 본다(트리거가 응모 표에 붙으므로 — 작업표 완료 정의)
