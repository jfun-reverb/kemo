-- ============================================================
-- 489_orient_tier_fees_option_fees.sql
-- 2026-10-01 — get_orient_tier_fees 응답에 리뷰어 추가 옵션 금액(option_fees)을 더한다
--
--   베이스: 463_orient_tier_labels_in_quote.sql 의 [2] 절(get_orient_tier_fees) — 현재 원본 463
--   (459 → 461 → 463). 🔴 다른 번호를 베이스로 잡으면 구간 인원·이름·옵션 문구가 사라진다.
--   이유: 전수조사 3차 ①-3 — 작성 폼이 추가 옵션(LIPS·@cosme) 금액을 5,000원으로 고정 표시했다.
--         실제 견적은 quote_settings(reviewer_option_fee_krw_lips·_cosme)를 쓰므로 폼이 같은 값을 받아야 한다.
--
--   바뀌는 것(이것뿐): 응답에 `option_fees` 객체 추가 — 리뷰어: quote_settings 의
--     reviewer_option_fee_krw_lips → 키 lips, reviewer_option_fee_krw_cosme → 키 cosme.
--     행이 없는 키는 생략(0 은 값이라 넣는다). 시딩은 빈 객체.
--   🔴 응답이 두 곳(모집비 직접 지정 시트의 조기 반환 + 끝의 일반 반환) — 둘 다 넣었다.
--     옵션 금액은 직접 지정과 무관한 기준값이다(463 _orient_compute_quote 의 같은 출처·같은 키).
--   나머지 본문은 463 과 글자 그대로(차이는 파일 하단 diff 로 확인).
--
--   CREATE OR REPLACE(인자 uuid 하나, 불변) — 권한은 보존되지만 463 관례대로 회수·부여를 다시 건다.
--
-- 롤백: 463 의 [2] 절 CREATE OR REPLACE FUNCTION public.get_orient_tier_fees 블록과 그 아래 REVOKE·GRANT·COMMENT 를
--   그대로 재실행(option_fees 가 사라진다 — 폼은 키가 없으면 기본 표시로 대체해야 한다).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.get_orient_tier_fees(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sheet       record;
  v_issued      jsonb;
  v_ft          text;
  v_ch          text;
  v_tier_prefix text;    -- [461] 구간 경계(시작값) 열쇠 앞머리 — issued.form_type 으로 정한다
  v_prefix      text;    -- 모집비·진행비 열쇠 앞머리(기존 그대로, v_tier_prefix 와는 다른 표를 가리킨다)
  v_override    numeric;
  v_fees        jsonb;
  v_slots       jsonb;     -- 구간 경계(시작값) 넷 — {"t50":50,"t100":150,"t300":300,"t500plus":500}
  v_min_slots   numeric;   -- [459] 최소 인원 — 행이 없으면 1(아무도 안 막는다)
  v_names       jsonb;     -- [463] 그 형식의 구간 이름 다섯 — {"tmin":"소량", ...}
  v_options     jsonb;     -- [463] 그 형식의 구간 옵션 문구 다섯 — {"tmin":"", ..., "t500plus":"+실검작업"}
  v_opt_fees    jsonb;     -- [489] 리뷰어 추가 옵션 금액 — {"lips":N,"cosme":N}(행 없는 키는 생략, 시딩은 {})
  v_now         timestamptz := now();
BEGIN
  -- 토큰 검사 — preview_orient_quote(430)와 같은 순서
  SELECT s.token_expires_at, s.status, s.data
    INTO v_sheet
    FROM public.orient_sheets s
   WHERE s.token = p_token;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;
  IF v_sheet.status = 'consumed' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'consumed');
  END IF;
  IF v_sheet.status = 'expired' OR (v_sheet.token_expires_at IS NOT NULL AND v_sheet.token_expires_at < v_now) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'expired');
  END IF;

  -- 새 구조 시트만(구간 개념이 없는 옛 시트에는 줄 것이 없다)
  v_issued := v_sheet.data -> 'issued';
  IF v_issued IS NULL OR jsonb_typeof(v_issued) <> 'object' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_new_layout');
  END IF;
  v_ft := v_issued ->> 'form_type';
  v_ch := v_issued ->> 'channel';

  -- [461] 🔴 형식을 **먼저** 정한다 — 459 는 구간 경계를 형식 확인보다 먼저 읽었는데(그때는 공용
  --   열쇠라 상관없었다), 이제 경계가 형식마다 달라 형식을 모르면 어느 표를 읽을지 정할 수 없다.
  v_tier_prefix := public._orient_tier_prefix(v_ft);
  IF v_tier_prefix IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'unknown_form_type');
  END IF;

  -- [463] 구간 이름·옵션 문구 — 그 형식의 값. 행이 없는 구간은 키가 빠진다(462 가 10행을 보장 —
  --   정상 경로에서는 실제로 안 생긴다. 폼은 그 자리에 기본 이름/빈 옵션으로 대체한다 — 사양서 §3-5).
  SELECT COALESCE(jsonb_object_agg(t.tier, l.name), '{}'::jsonb)
    INTO v_names
    FROM unnest(ARRAY['tmin', 't50', 't100', 't300', 't500plus']) AS t(tier)
    JOIN public.quote_tier_labels l ON l.form_type = v_ft AND l.tier = t.tier;
  SELECT COALESCE(jsonb_object_agg(t.tier, l.option_text), '{}'::jsonb)
    INTO v_options
    FROM unnest(ARRAY['tmin', 't50', 't100', 't300', 't500plus']) AS t(tier)
    JOIN public.quote_tier_labels l ON l.form_type = v_ft AND l.tier = t.tier;

  -- [461] 구간 경계(시작값) 넷 — 그 형식의 값. 응답 키는 여전히 t50·t100·t300·t500plus(형식
  --   접두 없음) — 작성 폼(orient.html)이 이 모양만 보고 짜여 있어 응답 모양을 바꾸지 않는다.
  --   행이 없는 구간은 키 자체가 빠진다(폼은 그 구간에 단추를 감춘다 — §3-6).
  SELECT COALESCE(jsonb_object_agg(t.tier, (q.amount)::integer), '{}'::jsonb)
    INTO v_slots
    FROM unnest(ARRAY['t50', 't100', 't300', 't500plus']) AS t(tier)
    JOIN public.quote_settings q ON q.key = v_tier_prefix || 'slots_' || t.tier;

  -- [461] 최소 인원 — 그 형식의 값. 화면이 입력칸 min 과 직접입력 옆 안내에 쓴다. 행이 없으면
  --   1(=제한 없음)로 본다. submit_orient_sheet 의 기본값과 같은 값이어야 어긋남이 없다.
  SELECT amount INTO v_min_slots FROM public.quote_settings WHERE key = v_tier_prefix || 'min_slots';
  v_min_slots := COALESCE(v_min_slots, 1);

  -- [489] 리뷰어 추가 옵션(LIPS·@cosme) 금액 — _orient_compute_quote(463) 의 v_basis 읽기와 같은 출처·같은 키
  --   (reviewer_option_fee_krw_lips / _cosme). 모집비 직접 지정과 무관한 기준값이라 **두 반환 경로 모두** 싣는다.
  --   행이 없는 키는 생략(0 은 값이므로 넣는다). 시딩은 옵션이 없어 빈 객체.
  IF v_ft = 'reviewer' THEN
    SELECT COALESCE(jsonb_object_agg(
             CASE q.key WHEN 'reviewer_option_fee_krw_lips' THEN 'lips' ELSE 'cosme' END,
             q.amount), '{}'::jsonb)
      INTO v_opt_fees
      FROM public.quote_settings q
     WHERE q.key IN ('reviewer_option_fee_krw_lips', 'reviewer_option_fee_krw_cosme');
  ELSE
    v_opt_fees := '{}'::jsonb;
  END IF;

  -- 발급 때 모집비 직접 지정(447) — 443 과 같은 읽기. 키가 있으면(0 포함) 그 값 하나만 준다
  --   ⚠️ 447 은 bigint 로만 넣으므로 숫자가 아닌 값은 올 수 없다. 그래도 한 겹 감싼다 — 443 의 같은 읽기는 부르는 쪽이
  --      예외를 받아 주는데 이 함수는 받아 줄 곳이 없어, 터지면 폼이 아니라 요청 자체가 500 이 된다(데이터베이스 검토 권고)
  BEGIN
    v_override := CASE WHEN v_issued ? 'recruit_fee_krw'
                       THEN NULLIF(v_issued ->> 'recruit_fee_krw', '')::numeric END;
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'reason', 'override_unreadable');
  END;
  IF v_override IS NOT NULL THEN
    RETURN jsonb_build_object('success', true, 'form_type', v_ft, 'channel', v_ch,
                              'override_krw', v_override, 'fees', '{}'::jsonb,
                              'slots', v_slots, 'min_slots', v_min_slots,
                              'names', v_names, 'options', v_options,
                              'option_fees', v_opt_fees);
  END IF;

  -- 열쇠말 앞머리(모집비·진행비, 461·463 무변경) — 443 의 v_fee_key 와 같은 조립. 이미 형식이
  --   reviewer|seeding 로 확정됐으므로(위 v_tier_prefix 가드) 여기서 NULL 이 될 일은 없지만
  --   방어적으로 남겨 둔다.
  v_prefix := CASE v_ft
    WHEN 'reviewer' THEN 'reviewer_recruit_fee_krw_'
    WHEN 'seeding'  THEN 'seeding_fee_krw_' || COALESCE(v_ch, '') || '_'
    ELSE NULL END;
  IF v_prefix IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'unknown_form_type');
  END IF;

  -- [459] 구간 단가 — tmin 을 포함해 다섯(직접입력한 인원이 tmin 구간에 들면 그 단가를 보여줘야
  --   한다). 행이 없는 구간은 키 자체가 빠진다(화면은 그 자리에 금액을 안 그린다 — 0원으로 그리지 않는다).
  SELECT COALESCE(jsonb_object_agg(t.tier, q.amount), '{}'::jsonb)
    INTO v_fees
    FROM unnest(ARRAY['tmin', 't50', 't100', 't300', 't500plus']) AS t(tier)
    JOIN public.quote_settings q ON q.key = v_prefix || t.tier;

  RETURN jsonb_build_object('success', true, 'form_type', v_ft, 'channel', v_ch,
                            'override_krw', NULL, 'fees', v_fees,
                            'slots', v_slots, 'min_slots', v_min_slots,
                            'names', v_names, 'options', v_options,
                              'option_fees', v_opt_fees);
END;
$$;

-- 🔴 회수 방향은 둘(369·370) — PUBLIC 을 걷고, 필요한 역할에만 다시 준다. 브랜드는 로그인 없이 폼을 쓰므로 anon 이 필요하다
REVOKE EXECUTE ON FUNCTION public.get_orient_tier_fees(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.get_orient_tier_fees(uuid) TO anon, authenticated;
COMMENT ON FUNCTION public.get_orient_tier_fees(uuid) IS
  '[489, 베이스 463] 오리엔시트 작성 폼용 — 살아 있는 토큰의 형식(reviewer|seeding)을 먼저 정하고(모르면 '
  'unknown_form_type), 그 형식의 구간 단가 다섯(tmin·t50·t100·t300·t500plus) + 구간 경계(시작값) 넷(slots) + '
  '최소 인원(min_slots, 행 없으면 1) + 구간 이름 다섯(names)·옵션 문구 다섯(options) + [489] 리뷰어 추가 옵션 금액'
  '(option_fees — lips·cosme, 행 없는 키 생략, 시딩은 빈 객체)을 돌려준다. 두 반환 경로(모집비 직접 지정·일반) 모두 '
  'names·options·option_fees 를 싣는다. 발급 때 모집비를 직접 지정한 시트는 override_krw 하나 + 빈 fees. 읽기 전용. '
  'anon GRANT(preview_orient_quote 가 이미 basis 전체를 주므로 새 노출 없음). 🔴 다음 재정의의 베이스는 489.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ══════════════════════════════════════════════════════════════════════
-- 확인 (개발 DB 적용 후 — 한 단계씩 실행하고 결과를 본 뒤 다음으로)
-- ══════════════════════════════════════════════════════════════════════
/*
-- [V1] 정의에 option_fees 가 들어갔나 + 권한 (기대: has_opt=true / proacl 맨 앞이 '=X/' 가 아님, anon·authenticated 있음)
SELECT position('option_fees' in pg_get_functiondef(p.oid)) > 0 AS has_opt,
       md5(pg_get_functiondef(p.oid)) AS def_md5,
       p.proacl::text AS proacl
  FROM pg_proc p WHERE p.oid = 'public.get_orient_tier_fees(uuid)'::regprocedure;

-- [V2] 옵션 기준값 행 (응답과 대조)
SELECT key, amount FROM public.quote_settings WHERE key LIKE 'reviewer_option_fee_krw_%' ORDER BY key;

-- [V3] 응답 모양 — 익명 호출 가능(anon). 새 구조 리뷰어 시트 토큰으로:
--   SELECT public.get_orient_tier_fees('<리뷰어 새 구조 시트 토큰>'::uuid) -> 'option_fees';
--   기대: {"lips": N, "cosme": N}  (V2 와 같은 값)
-- [V4] 시딩 시트 토큰: -> 'option_fees'  기대: {}
-- [V5] 🔴 모집비 직접 지정 시트(issued.recruit_fee_krw 있음): override_krw 가 값이어도 option_fees 가 같이 와야 한다
--   SELECT r -> 'override_krw', r -> 'option_fees' FROM (SELECT public.get_orient_tier_fees('<직접 지정 시트 토큰>'::uuid) AS r) s;
-- 기존 칸(fees·slots·min_slots·names·options·override_krw)은 463 과 같은 모양이어야 한다.
*/
