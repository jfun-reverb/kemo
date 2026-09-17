-- 447_orient_issue_recruit_fee_override.sql
-- 발급할 때 그 시트만 모집비(리뷰어)·진행비(시딩)를 다르게 지정한다.
-- 사양서: docs/specs/2026-09-16-orient-sheet-tiered-pricing-and-fields.md §4-11 (결정 21)
-- 작업표: docs/specs/2026-09-16-orient-sheet-tiered-pricing-breakdown.md 작업 4 (마이그레이션 ⑤)
--
-- ── 무엇을 하나 ──────────────────────────────────────────────────────────
-- create_orient_sheet(🔴 베이스 **424** — 190→192→195→205→**424**)에 다섯 번째 인자 p_recruit_fee_krw 를 더해
-- data.issued.recruit_fee_krw 로 저장한다. 그 세 자리 말고는 424 와 글자 그대로 같다.
--
-- 기준값은 표준 단가이고 협의로 그 건만 다르게 가는 경우가 있다. 그때 기준값을 고치면
-- **다른 모든 시트가 함께 바뀌므로** 시트 단위 예외가 필요하다.
--
-- · 값이 없으면(NULL) **키를 안 만든다** — jsonb_strip_nulls 가 뺀다. 견적은 기준값의 구간 단가로 간다.
-- · **0 은 허용**한다(무료 진행). 「비움」과 뜻이 다르므로 키의 유무로 가른다. 음수는 거부(invalid_recruit_fee).
-- · 읽는 쪽은 이미 있다 — _orient_compute_quote(443) 가 issued.recruit_fee_krw 를 보고 줄 이름 끝에 「· 직접 지정」을 붙인다.
--   같은 함수를 두 번 고치지 않으려고 계산 분기를 443 에 먼저 넣어 두었다.
-- · issued 아래라 서버 키 보존(425·445)이 지킨다. 브랜드 폼은 이 값을 바꾸지 못한다.
-- · 발급 뒤에는 못 바꾼다(이번 범위) — 잘못 넣었으면 시트를 지우고 다시 발급한다.
--
-- 🔴 인자가 늘어 CREATE OR REPLACE 로는 안 된다 — 옛 4인자를 DROP 한 뒤 새로 만든다.
--    🔴 DROP 하는 순간 424 가 걸어 둔 실행 권한이 **함께 사라진다.** 같은 파일에서 다시 건다.
--    빠뜨리면 발급이 0행이 아니라 **오류로 통째로 막힌다**(authenticated 에 권한이 없어진다).
--    회수는 두 방향(PUBLIC · anon) — 서로를 대신하지 못한다(369·370).
--
-- ⚠️ 옛 4인자 호출은 그대로 된다 — 다섯 번째 인자에 DEFAULT NULL 이 있다.
--    그래서 **화면(작업 13)보다 이 파일이 먼저** 나가도 발급이 깨지지 않는다. 반대 순서(화면 먼저)는
--    화면이 다섯 번째 인자를 보내 「함수를 찾을 수 없다」로 발급이 막힌다.
--
-- 롤백:
--   DROP FUNCTION IF EXISTS public.create_orient_sheet(uuid, uuid, text, text, bigint);
--   → 424 의 CREATE FUNCTION 블록 + 권한 세 줄 재실행. 🔴 화면(작업 13)을 먼저 되돌린다.

BEGIN;

DROP FUNCTION IF EXISTS public.create_orient_sheet(uuid, uuid, text, text);

CREATE FUNCTION public.create_orient_sheet(
  p_brand_id        uuid,
  p_application_id  uuid DEFAULT NULL,
  p_form_type       text DEFAULT NULL,   -- [424] 'reviewer' | 'seeding' | NULL(옛 구조, 전환 구간 전용)
  p_channel         text DEFAULT NULL,   -- [424] 시딩 채널 1개(5종). 리뷰어면 무시
  p_recruit_fee_krw bigint DEFAULT NULL  -- [447] 이 시트만 모집비(리뷰어)·진행비(시딩)를 1건당 이 값으로. NULL = 기준값의 구간 단가
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  -- 205 채번용 변수
  v_brand_seq     integer;
  v_brands_name   text;
  v_app_brand_id  uuid;
  v_brand_name    text;
  v_orient_seq    integer;
  v_orient_no     text;
  -- INSERT 용
  v_new_id        uuid;
  v_new_token     uuid;
  v_expires_at    timestamptz;
  v_init_data     jsonb;
  -- [424]
  v_form_type     text;      -- 정리된 형식(NULL = 옛 구조)
  v_channel       text;      -- 정리된 채널(시딩만)
  v_card          jsonb;     -- 발급 때 미리 만드는 카드 1개
BEGIN

  -- ── 권한 가드: campaign_manager 포함 전체 관리자 (205 와 동일) ──────────
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (관리자 로그인 필요)' USING ERRCODE = '42501';
  END IF;

  -- [447] 모집비 직접 지정 — 0 이상만. 🔴 0 은 허용한다(무료 진행) — 「비움(기준값)」과 「0(공짜)」은 다른 뜻이라 **키의 유무**로 가른다.
  --   옛 구조(형식 없음) 발급에는 issued 가 없어 담을 자리가 없다 → 값이 와도 버린다(아래 v_form_type 분기).
  IF p_recruit_fee_krw IS NOT NULL AND p_recruit_fee_krw < 0 THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_recruit_fee');
  END IF;

  -- ── [424] 형식·채널 검증 — 값이 있을 때만. 빈 문자열은 NULL 로 본다 ──────
  v_form_type := NULLIF(btrim(COALESCE(p_form_type, '')), '');
  v_channel   := NULLIF(btrim(COALESCE(p_channel, '')), '');

  IF v_form_type IS NOT NULL THEN
    IF v_form_type NOT IN ('reviewer', 'seeding') THEN
      -- proxy_purchase(가구매)도 여기서 거부 — 새 구조에서는 가구매를 발급할 수 없다(§4-1)
      RETURN jsonb_build_object('success', false, 'reason', 'invalid_form_type');
    END IF;
    IF v_form_type = 'seeding' THEN
      IF v_channel IS NULL THEN
        RETURN jsonb_build_object('success', false, 'reason', 'channel_required');
      END IF;
      IF v_channel NOT IN ('instagram_feed', 'instagram_reels', 'x', 'tiktok', 'youtube') THEN
        RETURN jsonb_build_object('success', false, 'reason', 'invalid_channel');
      END IF;
    ELSE
      v_channel := NULL;   -- 리뷰어는 채널 개념이 없다 — 들어와도 버린다
    END IF;
  END IF;

  -- ── 브랜드 존재 검증 + brand_seq + brands.name 취득 (205 와 동일) ──────
  SELECT b.brand_seq, b.name
    INTO v_brand_seq, v_brands_name
    FROM public.brands b
   WHERE b.id = p_brand_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'brand_not_found');
  END IF;

  IF v_brand_seq IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'brand_seq_missing');
  END IF;

  -- ── brand.name prefill 결정 (205 와 동일) ─────────────────────────────
  IF p_application_id IS NOT NULL THEN
    SELECT ba.brand_id, ba.brand_name
      INTO v_app_brand_id, v_brand_name
      FROM public.brand_applications ba
     WHERE ba.id = p_application_id;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'reason', 'application_not_found');
    END IF;

    IF v_app_brand_id IS DISTINCT FROM p_brand_id THEN
      RETURN jsonb_build_object('success', false, 'reason', 'brand_mismatch');
    END IF;

    IF v_brand_name IS NULL OR v_brand_name = '' THEN
      v_brand_name := v_brands_name;
    END IF;
  ELSE
    v_brand_name := v_brands_name;
  END IF;

  -- ── 동시성 + 카운터 + orient_no (205 와 동일) ─────────────────────────
  PERFORM pg_advisory_xact_lock(hashtext(p_brand_id::text)::bigint);

  INSERT INTO public.brand_orient_counter (brand_id, last_seq)
  VALUES (p_brand_id, 1)
  ON CONFLICT (brand_id)
  DO UPDATE SET last_seq = public.brand_orient_counter.last_seq + 1
  RETURNING last_seq INTO v_orient_seq;

  IF v_orient_seq > 999 THEN
    RAISE EXCEPTION
      '[create_orient_sheet] O-seq 오버플로 (>999) for brand_id=%', p_brand_id
      USING ERRCODE = '22003';
  END IF;

  v_orient_no := 'B' || lpad(v_brand_seq::text, 4, '0')
              || '-O' || lpad(v_orient_seq::text, 3, '0');

  -- ── data 초기값 ───────────────────────────────────────────────────────
  IF v_form_type IS NULL THEN
    -- 옛 구조 (205 와 동일) — §15-11: {brand:{name,intro,official_accounts}, cards:[]}
    v_init_data := jsonb_build_object(
      'brand', jsonb_build_object(
        'name',              COALESCE(v_brand_name, ''),
        'intro',             '',
        'official_accounts', ''
      ),
      'cards', '[]'::jsonb
    );
  ELSE
    -- [424] 새 구조 (사양서 §4-1 JSON 그대로) — brand 에 intro·official_accounts 키 없음,
    --   카드 1개를 발급 때 미리 만든다(uid 는 첫 저장 때 서버가 붙인다 — 293).
    --   ⚠️ cards 배열은 그대로 둔다 — uid·메모·발행 표시·연결/해제·삭제가 전부 cards[i] 를 본다.
    IF v_form_type = 'seeding' THEN
      v_card := jsonb_build_object(
        'form_type', 'seeding',
        'product',   jsonb_build_object('name', '', 'slots', ''),
        'recruit',   jsonb_build_object('recruit_start', ''),
        'sale',      jsonb_build_object('market', 'Qoo10', 'url', '', 'price_regular', ''),
        'seeding',   jsonb_build_object(
                       'channels',       jsonb_build_array(v_channel),
                       'appeal',         '',
                       'hashtags',       '[]'::jsonb,
                       'account_tags',   '',
                       'shooting_guide', '',
                       'shipping_note',  ''
                     ),
        'ng',        '',
        'cautions',  '',
        'images',    '[]'::jsonb
      );
    ELSE
      v_card := jsonb_build_object(
        'form_type',    'reviewer',
        'product',      jsonb_build_object('name', '', 'slots', ''),
        'recruit',      jsonb_build_object('recruit_start', ''),
        'sale',         jsonb_build_object('market', 'Qoo10', 'url', '', 'price_regular', ''),
        'review_guide', '',
        'images',       '[]'::jsonb
      );
    END IF;

    v_init_data := jsonb_build_object(
      'issued', jsonb_strip_nulls(jsonb_build_object(
        'form_type', v_form_type,
        'channel',   v_channel,        -- 리뷰어는 NULL → strip 으로 키 자체가 빠진다
        'issued_at', now(),
        -- [447] NULL 이면 strip 으로 키 자체가 빠진다 = 기준값의 구간 단가. 0 은 숫자라 남는다.
        --   issued 아래라 445(=425)의 서버 키 보존이 그대로 지켜 준다 — 브랜드 폼이 덮어쓰지 못한다.
        --   읽는 곳: _orient_compute_quote(443) 의 v_override
        'recruit_fee_krw', p_recruit_fee_krw
      )),
      'brand', jsonb_build_object(
        'name',         COALESCE(v_brand_name, ''),
        'contact_name', '',
        'email',        '',
        'phone',        ''
      ),
      'cards', jsonb_build_array(v_card)
    );
  END IF;

  -- ── INSERT (205 와 동일 — form_type 칸만 [424] 값 반영) ────────────────
  v_new_id     := gen_random_uuid();
  v_new_token  := gen_random_uuid();
  v_expires_at := now() + interval '30 days';

  INSERT INTO public.orient_sheets (
    id, brand_id, application_id, form_type, token, token_expires_at,
    created_by, status, data, version, orient_no
  ) VALUES (
    v_new_id, p_brand_id, p_application_id,
    v_form_type,          -- [424] 새 구조면 형식 사본(목록 필터·집계용), 옛 구조면 NULL(205 와 같음)
    v_new_token, v_expires_at, auth.uid(), 'draft', v_init_data, 0, v_orient_no
  );

  RETURN jsonb_build_object(
    'success',          true,
    'id',               v_new_id,
    'token',            v_new_token,
    'token_expires_at', v_expires_at,
    'orient_no',        v_orient_no
  );
END;
$$;

-- 🔴 DROP 으로 옛 권한이 사라졌다 — 같은 파일에서 다시 건다. 대상은 authenticated(anon 아님 — 205·424)
REVOKE EXECUTE ON FUNCTION public.create_orient_sheet(uuid, uuid, text, text, bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.create_orient_sheet(uuid, uuid, text, text, bigint) FROM anon;
GRANT  EXECUTE ON FUNCTION public.create_orient_sheet(uuid, uuid, text, text, bigint) TO authenticated;

COMMENT ON FUNCTION public.create_orient_sheet(uuid, uuid, text, text, bigint) IS
  '[195+205+424+447] 오리엔시트 발급. is_admin() 가드 — campaign_manager 포함 전체 관리자. '
  'p_form_type(reviewer|seeding) 이 있으면 새 구조: data.issued{form_type,channel,issued_at[,recruit_fee_krw]} + 카드 1개 미리 생성. '
  '[447] p_recruit_fee_krw(0 이상, NULL=기준값) → issued.recruit_fee_krw. 0 은 무료 진행으로 허용, 음수는 invalid_recruit_fee. 옛 구조 발급에는 무시. '
  '거부 reason: invalid_form_type·channel_required·invalid_channel·invalid_recruit_fee·brand_not_found·brand_seq_missing 등. '
  '실행 권한 authenticated 만. 🔴 다음 재정의의 베이스는 447.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ══════════════════════════════════════════════════════════════════════
-- 검증 (사양서 §9-1 6-d~6-g)
-- ══════════════════════════════════════════════════════════════════════
--
-- [V1] 6-g 🔴 실행 권한 — 지우고 다시 만든 뒤 **반드시** 본다
--
--   SELECT has_function_privilege('anon',          'public.create_orient_sheet(uuid, uuid, text, text, bigint)', 'EXECUTE') AS anon_,
--          has_function_privilege('authenticated', 'public.create_orient_sheet(uuid, uuid, text, text, bigint)', 'EXECUTE') AS auth_,
--          (SELECT proacl::text FROM pg_proc
--            WHERE oid = 'public.create_orient_sheet(uuid, uuid, text, text, bigint)'::regprocedure) AS acl,
--          (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--            WHERE n.nspname = 'public' AND p.proname = 'create_orient_sheet') AS 같은_이름_함수_수;
--   -- 기대: false / true / acl 맨 앞에 「=X/」 없음 / 1 (옛 4인자가 남아 둘이면 호출이 모호해진다)
--
-- [V2] 발급은 is_admin() 가드라 SQL 편집기(서비스 키)로는 못 부른다 — 관리자 로그인 브라우저 콘솔에서:
--
--   await db.rpc('create_orient_sheet', { p_brand_id: '<브랜드 id>', p_form_type: 'reviewer', p_recruit_fee_krw: 7000 })
--   → success, 그 시트의 data.issued.recruit_fee_krw = 7000          (6-d)
--   await db.rpc('create_orient_sheet', { p_brand_id: '<브랜드 id>', p_form_type: 'reviewer', p_recruit_fee_krw: 0 })
--   → issued.recruit_fee_krw = 0 (키가 **있다**)                       (6-e — 0 은 「비움」과 다르다)
--   await db.rpc('create_orient_sheet', { p_brand_id: '<브랜드 id>', p_form_type: 'reviewer' })
--   → issued 에 recruit_fee_krw 키가 **없다**
--   await db.rpc('create_orient_sheet', { p_brand_id: '<브랜드 id>', p_form_type: 'reviewer', p_recruit_fee_krw: -1 })
--   → success=false, reason='invalid_recruit_fee'
--   ⚠️ 시험으로 만든 시트는 관리자 화면 「삭제」로 지운다.
--
-- [V3] 6-f 시딩 시트에 예외를 넣고 작성 폼에서 「견적 보기」 → seeding 줄 단가가 그 값, 이름 끝 「· 직접 지정」
