-- ============================================================
-- 576_brands_guard_direct_contacts.sql
-- 관리자 브랜드 상세 탭 재구성 — 작업 15(직접 고치기 막기 · 사양서 5-5 · 작업표 결정 S5=A)
-- 사양서: docs/specs/2026-10-21-admin-brand-detail-tabs.md · 작업표 docs/specs/2026-10-21-admin-brand-detail-tabs-breakdown.md
--
-- 왜: 담당자 목록은 이제 서버 함수(574 admin_save_brand_contact·admin_delete_brand_contact, 531/533 대표 바꾸기)만 고친다.
--   그런데 brands 표 UPDATE 정책(082 — 캠페인 관리자 이상)이 그대로라, 옛 캐시 화면·콘솔이 contacts 를 통째로 보내면
--   잠금(계정이 있는 동안 대표 줄 고정 — 574 _brand_contacts_locked)과 옛 대표 칸 맞추기를 건너뛴다.
--   정책을 통째로 닫으면 회사 일괄 할당(assignBrandsToCompany)·「새 브랜드」 등록이 죽으므로 담당자 칸만 막는다.
--
-- 만드는 것
--   1) 트리거 함수 _guard_brands_direct_contacts() — 🔴 반드시 SECURITY INVOKER (492·497 교훈)
--      · current_user = 'authenticated'(로그인 사용자가 표를 직접 UPDATE) 이고 contacts·primary_contact_name·primary_phone·
--        primary_email 중 하나라도 값이 바뀌면 거부 — 코드 brand_contacts_direct_write (오류 코드 42501)
--      · 서버 함수(정의자 권한) 안의 UPDATE 는 current_user = 함수 소유자(postgres)라 저절로 통과 — 574·531·533·528 병합·
--        122 광고주 신청 접수 등. 서비스 키·SQL 편집기·예약 실행도 통과
--      · 🔴 492 와 달리 관리자를 통과시키지 않는다 — 막으려는 대상이 바로 관리자 화면의 직접 저장이다
--      · 값이 같으면 통과(IS DISTINCT FROM) — 옛 화면이 담당자를 안 고치고 통째로 보낸 저장은 그대로 된다
--        (⚠️ 단 옛 화면은 담당자 줄을 다듬어 보내서(앞뒤 공백·추가 열쇠 제거) 저장된 줄과 글자가 다르면 거부된다 — 운영 순서 참고)
--   2) 트리거 trg_brands_guard_direct_contacts BEFORE UPDATE OF contacts, primary_contact_name, primary_phone, primary_email
--      · 삽입(INSERT)은 대상 아님 — 「새 브랜드」 등록은 담당자 여러 줄을 한 번에 넣는 지금 방식 그대로
--   3) 옛 대표 칸 셋 보정(작업 14 발견 ①) — contacts 에 대표 줄이 있는데 primary_* 셋이 모두 비어 있는 브랜드만,
--      574 _brand_set_contacts 와 같은 규칙(is_primary 첫 객체 줄, 앞뒤 공백 정리, 빈 값 NULL)으로 채운다.
--      이미 값이 있는 브랜드는 건드리지 않는다. 여러 번 돌려도 같은 결과(이 거래는 postgres 로 돌아 위 트리거를 통과)
--
-- 알고 있는 것
--   · 옛 화면 경로 둘이 이 뒤로 실패한다 — 옛 브랜드 상세 모달 저장(saveBrandDetail → updateBrand, 담당자를 바꾼 경우)과
--     오리엔시트 발급 뒤 「담당자 저장」(osSaveIssuedContact — 계정 모드가 꺼진 환경에서만 나온다. ⚠️ 그 함수는 실패를 안 보고
--     「저장했습니다」를 띄운다 — 의심 11, 출시 뒤 도달하지 않음). 개발서버는 둘 다 도달하지 않는다(새 페이지 · 계정 모드)
--   · 브랜드 계정 사용자도 authenticated 지만 brands UPDATE 정책이 없어 원래 못 쓴다 — 이 트리거와 무관
--
-- 🔴 운영 순서: 화면 병합(새 페이지 — 옛 운영 화면은 contacts 를 통째로 보낸다) **뒤에** 넣는다(작업 17 의 마지막).
-- 편집기 경고: 뜸 — 「Potential issue detected · destructive operations」(DROP TRIGGER IF EXISTS 때문). 데이터는 안 지운다 — 「Run query」.
--   2026-10-21 개발서버 적용(기록 표 576 줄 14:27:07 JST) · 함수 INVOKER, 실행 권한 postgres·service_role 만(맨 앞 =X/ 없음)
--   적용 전 확인: contacts 를 고치는 함수 여섯(574 넷·091/122·397)은 모두 소유자 postgres · DEFINER. 보정 대상 4개 → 적용 뒤
--   「담당자는 있는데 대표 칸 셋이 빈 브랜드」 0개
-- 개발서버 실제 호출(2026-10-21, 로그인 관리자 콘솔 — 캠페인 매니저 계정 · 시험 브랜드 「시험브랜드0923…」, 끝난 뒤 원래 값):
--   contacts 직접 UPDATE → 42501 brand_contacts_direct_write · primary_email 만 직접 → 거부 · 같은 값 그대로 통째 저장 → 성공
--   · 이름만 직접 → 성공 · company_id 직접(회사 일괄 할당과 같은 쓰기) → 성공 · 574 담당자 저장(대표 칸 셋 맞춤)·삭제 → 성공
--   · 「새 브랜드」 삽입(담당자 한 줄 포함) → 성공(시험 브랜드는 SQL 편집기에서 지움 — 매니저는 삭제 권한 없음)
--   · 533 대표 바꾸기는 실행하지 않았다(계정·메일이 따른다) — 같은 정의자 권한 경로(_brand_contacts_mark_primary)라 574 와 같다
-- 롤백: DROP TRIGGER IF EXISTS trg_brands_guard_direct_contacts ON public.brands;
--       DROP FUNCTION IF EXISTS public._guard_brands_direct_contacts();
--   (보정한 옛 대표 칸 셋은 되돌리지 않는다 — contacts 와 맞춘 값이라 해가 없다)
-- ============================================================
BEGIN;

-- ── 1. 트리거 함수 ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._guard_brands_direct_contacts()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER   -- 🔴 DEFINER 로 바꾸면 current_user 가 늘 함수 소유자라 아무것도 안 막는다(조용히 무력화)
SET search_path = ''
AS $$
BEGIN
  -- 로그인 사용자가 표를 직접 고친 요청만 본다. 서버 함수(정의자 권한)·서비스 키·예약 실행은 통과
  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;

  IF NEW.contacts             IS DISTINCT FROM OLD.contacts
  OR NEW.primary_contact_name IS DISTINCT FROM OLD.primary_contact_name
  OR NEW.primary_phone        IS DISTINCT FROM OLD.primary_phone
  OR NEW.primary_email        IS DISTINCT FROM OLD.primary_email
  THEN
    RAISE EXCEPTION 'brand_contacts_direct_write'
      USING ERRCODE = 'insufficient_privilege',
            HINT    = '담당자는 브랜드 상세 「담당자」 탭에서 한 줄씩 저장합니다(admin_save_brand_contact).';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public._guard_brands_direct_contacts() IS
  '[576] brands BEFORE UPDATE OF contacts, primary_contact_name, primary_phone, primary_email. current_user=authenticated(직접 UPDATE)이고 값이 바뀌면 brand_contacts_direct_write(42501). 서버 함수 안 UPDATE 는 통과. 관리자도 막는다. 🔴 SECURITY INVOKER 필수(DEFINER 면 조용히 무력화).';

GRANT  EXECUTE ON FUNCTION public._guard_brands_direct_contacts() TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public._guard_brands_direct_contacts() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._guard_brands_direct_contacts() FROM anon, authenticated;

-- ── 2. 트리거 ─────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS trg_brands_guard_direct_contacts ON public.brands;
CREATE TRIGGER trg_brands_guard_direct_contacts
  BEFORE UPDATE OF contacts, primary_contact_name, primary_phone, primary_email
  ON public.brands
  FOR EACH ROW
  EXECUTE FUNCTION public._guard_brands_direct_contacts();

-- ── 3. 옛 대표 칸 셋 보정 (작업 14 발견 ① — 대표 줄은 있는데 셋이 모두 빈 브랜드만) ──────
WITH prim AS (
  SELECT b.id,
         (SELECT e.elem   -- 배열 아닌 값에서 jsonb_array_elements 가 오류 내지 않게(실행 순서에 기대지 않는다)
            FROM jsonb_array_elements(CASE WHEN jsonb_typeof(b.contacts) = 'array' THEN b.contacts ELSE '[]'::jsonb END)
                 WITH ORDINALITY AS e(elem, ord)
           WHERE jsonb_typeof(e.elem) = 'object' AND e.elem->>'is_primary' = 'true'
           ORDER BY e.ord
           LIMIT 1) AS p
    FROM public.brands b
   WHERE jsonb_typeof(b.contacts) = 'array'
     AND NULLIF(btrim(COALESCE(b.primary_contact_name, '')), '') IS NULL
     AND NULLIF(btrim(COALESCE(b.primary_phone, '')), '') IS NULL
     AND NULLIF(btrim(COALESCE(b.primary_email, '')), '') IS NULL
)
UPDATE public.brands b
   SET primary_contact_name = NULLIF(btrim(COALESCE(prim.p->>'name',  '')), ''),
       primary_phone        = NULLIF(btrim(COALESCE(prim.p->>'phone', '')), ''),
       primary_email        = NULLIF(btrim(COALESCE(prim.p->>'email', '')), '')
  FROM prim
 WHERE b.id = prim.id
   AND prim.p IS NOT NULL
   AND (NULLIF(btrim(COALESCE(prim.p->>'name',  '')), '') IS NOT NULL
     OR NULLIF(btrim(COALESCE(prim.p->>'phone', '')), '') IS NOT NULL
     OR NULLIF(btrim(COALESCE(prim.p->>'email', '')), '') IS NOT NULL);

INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '576', '576_brands_guard_direct_contacts.sql');
COMMIT;
