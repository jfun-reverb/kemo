-- ============================================================
-- 555_cs_category_lookup.sql
-- CS 이력 관리 — 작업 1-1 (CS 항목 기준 데이터 + 「미분류(과거)」 잠금)
-- 사양서: docs/specs/2026-10-16-cs-history-management.md D-4·D-7·4-4 ①
-- 작업표: docs/specs/2026-10-19-cs-history-management-breakdown.md 1-1 (S-11)
--
-- ⚠️ 종류 검사 제약의 현재 원본은 554(17종 — 346 + 'shipping_carrier', 배송 리스트).
--   이 파일은 554 를 베이스로 'cs_category' 1종을 더해 18종으로 만든다. 346 을 베이스로
--   잡으면 'shipping_carrier' 가 빠져 554 시드 7행 때문에 제약 추가가 실패한다
--   (554 머리말의 「현재 원본 = 346」은 554 작성 시점 기준 — 554 자신이 새 원본).
--   🔴 다른 세션이 같은 제약을 고치는 중일 수 있다 — 병합 직전 origin/dev 를 다시 볼 것.
--
-- ⚠️ 기존 동종 항목 중복 확인: grep -rn "cs_category|legacy_unclassified"
--   supabase/ dev/ → 0건(작성 전). 가까운 기존 종류 없음(응모 취소 사유·
--   탈퇴 사유는 다른 사건).
--
-- 「미분류(과거)」(legacy_unclassified)는 백필 전용 항목이다(D-7). 관리자
-- 화면에서 끄거나 고치거나 지우면 통계의 과거 건이 이름을 잃으므로 서버
-- 트리거로 막는다. 마이그레이션·패치(관리 계정)·서비스 키는 통과 — 판정은
-- current_user 라서 트리거 함수는 반드시 SECURITY INVOKER(정의자 권한이면
-- 늘 소유자로 보여 판정이 무력해진다 — 493~499 와 같은 함정).
--
-- 편집기 경고: 뜸 — 무해(종류 제약과 트리거를 지우고 같은 이름으로 다시 만든다)
-- 롤백: 파일 하단.
-- ============================================================

-- 1. 종류 검사 제약 확장 (17종 → 18종, 베이스 554)
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
    'shipping_carrier',
    'cs_category'
  ));

COMMENT ON COLUMN public.lookup_values.kind IS
  'channel | category | content_type | ng_item | reject_reason | blacklist_reason | '
  'violation_reason | caution | admin_email_kind | cancel_reason | message_hide_reason | '
  'admin_proxy_reason | ob_series | ob_category | ob_tier | withdraw_reason | shipping_carrier | cs_category';

-- 2. 시드 — CS 항목 8행 (D-4 일곱 + 미분류(과거))
INSERT INTO public.lookup_values (kind, code, name_ko, name_ja, sort_order, active) VALUES
  ('cs_category', 'refund',              '환불',         '返金',           10, true),
  ('cs_category', 'campaign',            '캠페인',       'キャンペーン',   20, true),
  ('cs_category', 'shipping',            '배송',         '配送',           30, true),
  ('cs_category', 'operation',           '운영',         '運営',           40, true),
  ('cs_category', 'product',             '제품',         '商品',           50, true),
  ('cs_category', 'settlement',          '정산',         '精算',           60, true),
  ('cs_category', 'other',               '기타',         'その他',         70, true),
  ('cs_category', 'legacy_unclassified', '미분류(과거)', '未分類（過去）', 900, true)
ON CONFLICT (kind, code) DO NOTHING;  -- 재실행해도 관리자가 고친 이름·활성 여부를 덮지 않는다

-- 3. 「미분류(과거)」 잠금 — 화면(로그인 역할)에서 이름·활성·종류·코드 변경과 삭제 거부
--   ⚠️ 정렬 번호(sort_order)만 바뀌는 수정은 통과시킨다 — 기준 데이터 화면의 순서 변경
--      (storage.js swapLookupOrder)은 두 행을 한 행씩 따로 고치고 오류를 안 본다. 막으면
--      옆 행만 바뀌어 정렬 번호가 겹친 채 남는다.
--   ⚠️ 관리자가 SECURITY DEFINER 함수를 거쳐 이 표를 고치면 소유자 역할로 보여 통과한다 —
--      지금 그런 함수는 없다. 새로 만들면 그 함수 안에서 같은 검사를 할 것.
CREATE OR REPLACE FUNCTION public.guard_cs_legacy_lookup()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  -- 마이그레이션·패치(관리 계정)·서비스 키는 통과
  IF current_user NOT IN ('authenticated', 'anon') THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    IF OLD.kind = 'cs_category' AND OLD.code = 'legacy_unclassified' THEN
      RAISE EXCEPTION 'cs_legacy_locked' USING ERRCODE = 'P0001';
    END IF;
    RETURN OLD;
  END IF;

  -- 새로 만들기: 이 코드의 행을 화면에서 만들 수 없다
  IF TG_OP = 'INSERT' THEN
    IF NEW.kind = 'cs_category' AND NEW.code = 'legacy_unclassified' THEN
      RAISE EXCEPTION 'cs_legacy_locked' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
  END IF;

  -- 수정: 다른 행을 이 코드로 바꾸는 것 차단
  IF NEW.kind = 'cs_category' AND NEW.code = 'legacy_unclassified'
     AND (OLD.kind IS DISTINCT FROM NEW.kind OR OLD.code IS DISTINCT FROM NEW.code) THEN
    RAISE EXCEPTION 'cs_legacy_locked' USING ERRCODE = 'P0001';
  END IF;

  -- 수정: 이 행의 이름·활성·종류·코드 변경 차단(정렬 번호는 허용)
  IF OLD.kind = 'cs_category' AND OLD.code = 'legacy_unclassified'
     AND (OLD.kind IS DISTINCT FROM NEW.kind OR OLD.code IS DISTINCT FROM NEW.code
          OR OLD.name_ko IS DISTINCT FROM NEW.name_ko OR OLD.name_ja IS DISTINCT FROM NEW.name_ja
          OR OLD.active IS DISTINCT FROM NEW.active) THEN
    RAISE EXCEPTION 'cs_legacy_locked' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_lookup_cs_legacy_lock ON public.lookup_values;
CREATE TRIGGER trg_lookup_cs_legacy_lock
  BEFORE INSERT OR UPDATE OR DELETE ON public.lookup_values
  FOR EACH ROW EXECUTE FUNCTION public.guard_cs_legacy_lookup();

-- 트리거 함수는 직접 부를 일이 없다(트리거 발동은 실행 권한을 보지 않는다)
REVOKE ALL ON FUNCTION public.guard_cs_legacy_lookup() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.guard_cs_legacy_lookup() FROM anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL 편집기에서 1단계씩)
-- ============================================================
/*
-- [V1] 제약 18종('shipping_carrier'·'cs_category' 포함)
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'lookup_values_kind_check';

-- [V2] 시드 8행
SELECT code, name_ko, name_ja, sort_order, active FROM public.lookup_values
WHERE kind = 'cs_category' ORDER BY sort_order;

-- [V3] 함수 속성 — prosecdef=false · search_path 고정 · proacl 맨 앞 「=X/」 없음
SELECT prosecdef, proconfig, proacl::text FROM pg_proc WHERE proname = 'guard_cs_legacy_lookup';

-- [V4] 로그인 관리자 역할 실측 — 항목마다 begin … rollback 을 따로(오류가 나면 트랜잭션이 깨진다)
--   <관리자 uid> 는 admins.auth_id
-- begin;
-- set local role authenticated;
-- select set_config('request.jwt.claims', '{"sub":"<관리자 uid>","role":"authenticated"}', true);
-- ① 이름 변경 → cs_legacy_locked
-- update public.lookup_values set name_ko = 'x' where kind = 'cs_category' and code = 'legacy_unclassified';
-- ② 삭제 → cs_legacy_locked
-- delete from public.lookup_values where kind = 'cs_category' and code = 'legacy_unclassified';
-- ③ 정렬 번호만 → 통과
-- update public.lookup_values set sort_order = 901 where kind = 'cs_category' and code = 'legacy_unclassified';
-- ④ 다른 행 이름 → 통과
-- update public.lookup_values set name_ko = name_ko where kind = 'cs_category' and code = 'other';
-- rollback;
*/

-- ============================================================
-- 롤백 (cs_category 를 쓰는 CS 건이 생기기 전에만)
-- ============================================================
-- 편집기 경고: 뜸 — 롤백 전용(트리거·함수 삭제, cs_category 8행 삭제)
-- DROP TRIGGER IF EXISTS trg_lookup_cs_legacy_lock ON public.lookup_values;
-- DROP FUNCTION IF EXISTS public.guard_cs_legacy_lookup();
-- DELETE FROM public.lookup_values WHERE kind = 'cs_category';   -- 제약 되돌리기 전에 먼저
-- ALTER TABLE public.lookup_values DROP CONSTRAINT IF EXISTS lookup_values_kind_check;
-- ALTER TABLE public.lookup_values ADD CONSTRAINT lookup_values_kind_check CHECK (kind IN (
--   'channel','category','content_type','ng_item','reject_reason','blacklist_reason','violation_reason',
--   'caution','admin_email_kind','cancel_reason','message_hide_reason','admin_proxy_reason',
--   'ob_series','ob_category','ob_tier','withdraw_reason','shipping_carrier'));   -- 554 판
