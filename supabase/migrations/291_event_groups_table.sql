-- ============================================================
-- 291_event_groups_table.sql
-- 오프라인 팝업 방문 예약(티켓팅) — 같은 행사를 여러 캠페인으로 나눈 경우
-- 하나로 묶는 「행사 묶음」 표
-- 사양서: docs/specs/2026-07-30-offline-popup-ticketing.md (선행 280~290)
-- 관련 문서: 이번 팝업(2026-08-28~30)이 8/28(초대 전용)·8/29~30(일반 공개)
--   2개 캠페인으로 나뉘면서, 현장 입장 확인 페이지(dev/event-scan.html)를
--   캠페인 1개 고정에서 캠페인 목록 조회로 바꾸기로 함에 따라 발생.
--
-- 왜 필요한가:
--   부스 단말이 캠페인 하나에 고정되면 8/29 아침에는 8/28 캠페인만 보고 있어
--   빈 명단을 보게 된다. 「같은 행사」로 묶어 사흘 내내 같은 화면으로 운영하면서
--   다른 팝업 행사와는 안 섞이게 한다.
--
-- 왜 자유 문자열이 아니라 별도 표인가 (사용자 결정):
--   자유 입력 칸이면 「REVERB팝업」과 「REVERB 팝업」처럼 띄어쓰기 하나로 두
--   행사가 조용히 갈라진다. 목록에서 골라서만 넣게 하면(캠페인 편집 화면의
--   드롭다운 — dev/ 구현은 후속) 이 오타 분기 자체가 구조적으로 불가능해진다.
--   그래도 표 안에서 이름이 또 오타로 갈리는 걸 막기 위해 정규화 이름에
--   유일 제약을 건다(아래).
--
-- 정규화 이름 유일 제약 — companies(마이그레이션 118·119) 패턴 그대로 미러링:
--   118 원본 함수는 lower(trim(name)) 뿐이라 다중 공백을 못 잡는다.
--   119 가 그 함정을 발견하고 lower(trim(regexp_replace(name,'\s+',' ','g')))
--   로 공백을 압축하는 최종 패턴으로 바꿨다. 이번 요구의 핵심이 정확히
--   「REVERB팝업」 vs 「REVERB 팝업」(공백 개수 차이)이므로, 이 표는 처음부터
--   118 원본이 아니라 119 최종 패턴을 베이스로 만든다(118→119 순서를
--   되풀이하지 않는다).
--
-- 캠페인 연결 — 브랜드↔회사(brands.company_id)와 동일한 방식:
--   campaigns.event_group_id 를 ON DELETE SET NULL 로 건다. 묶음을 지워도
--   그 묶음을 참조하던 캠페인의 저장·조회가 막히지 않고 연결만 끊어진다.
--   막는 방식(RESTRICT)으로 걸면 행사 종료 후 묶음 정리 한 번이 그 캠페인의
--   이후 모든 저장을 막게 된다.
--
--   ⚠️ 의도적으로 걸지 않은 제약 2가지:
--   ① 「같은 브랜드끼리만 묶을 수 있다」— 합동 팝업은 브랜드가 서로 다른
--      캠페인을 묶어야 하므로 브랜드 일치 검증을 걸면 그 사용 사례 자체가
--      막힌다.
--   ② 「행사 모드(event_mode=true) 캠페인만 묶을 수 있다」를 데이터베이스
--      CHECK/트리거로 강제 — 지금은 화면(관리자 편집 폼)이 행사 모드일 때만
--      묶음 칸을 보여주고, 현장 확인 페이지(event-scan.html)도 행사 모드
--      캠페인만 읽는 것으로 계획돼 있어 사실상 그렇게 쓰이지만, 이건 화면
--      쪽 계약이다. 데이터베이스에 강제로 박아 두면 나중에 모집 형식·행사
--      운영 방식이 바뀔 때(예: 리뷰어형에도 행사 모드를 허용하기로 결정)
--      이 표까지 함께 마이그레이션해야 저장이 풀린다. 캠페인 표 210행
--      CLAUDE.md 「event_mode」 항목이 이미 이 함정(리뷰어형에 event_mode
--      를 켜면 049 자동승인 트리거와 충돌)을 다루고 있어, 묶음 표까지
--      같은 위험을 겹쳐 지지 않는다.
--
-- 접근 권한:
--   조회 = 관리자 전체(is_admin()) — 현장 확인 페이지가 관리자 로그인을
--   요구하므로 그대로 읽힌다.
--   만들기·고치기·지우기 = is_campaign_admin() 이상(companies 118 과 동일 등급).
--
-- 마이그레이션 275(캠페인 동시 저장 방어)와의 관계:
--   새 칸 campaigns.event_group_id 는 275 의 제외 목록(version·updated_at·
--   view_count·applied_count·order_index·first_active_at) 에 없으므로
--   **자동으로 낙관적 락 보호 대상**이 된다(280 의 두 칸·285 의 한 칸과 같은
--   판단). 별도 조치 불필요 — 관리자 편집 저장은 기존과 동일하게
--   updateCampaign(id, updates, expectedVersion) 으로 현재 버전을 함께
--   넘기면 된다.
--
-- 마이그레이션 265·266(캠페인 전체 항목 변경 이력)과의 관계 — 의도적 제외:
--   이 칸을 화이트리스트에 넣지 않는다. 앞선 행사 관련 칸 3개(280 의
--   event_mode·is_invite_only, 285 의 event_place)가 전부 같은 판단으로
--   빠져 있다. 화이트리스트는 세 곳(265 의 CHECK 제약 조건 · 266 의 v_fields
--   항목 배열 · 266 트리거의 AFTER UPDATE OF 감시 컬럼 목록)이 항상 같은
--   집합이어야 하고, 어긋나면 CHECK 위반으로 캠페인 저장 트랜잭션 전체가
--   실패한다. 행사 캠페인은 소수·기간 한정이라 이 위험을 새로 지지 않는다.
--
-- 적용 순서 — 반드시 데이터베이스가 코드보다 먼저:
--   275 적용 때와 같은 순서다. 이 마이그레이션(데이터베이스)을 먼저 개발·운영
--   순서로 적용한 뒤에 dev/ 쪽 코드(관리자 편집 폼의 묶음 드롭다운, 현장 확인
--   페이지의 캠페인 목록 조회)를 배포한다. 순서가 바뀌면 아직 없는 칸
--   (event_group_id)·아직 없는 표(event_groups)를 화면이 먼저 참조하게 돼
--   캠페인 저장 자체가 실패한다.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

-- ============================================================
-- 1. 행사 묶음 표
-- ============================================================
CREATE TABLE IF NOT EXISTS public.event_groups (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name             text        NOT NULL,
  name_normalized  text        UNIQUE NOT NULL,
  status           text        NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active', 'archived')),
  memo             text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_by       uuid REFERENCES auth.users(id) ON DELETE SET NULL
);

COMMENT ON TABLE public.event_groups IS
  '[291] 오프라인 행사 묶음 — 같은 행사가 캠페인 여러 개로 나뉠 때(초대 전용/일반
  공개 등) 하나로 묶는다. 목록에서 골라서만 연결(자유 문자열 금지 — 띄어쓰기
  오타로 같은 행사가 갈라지는 것을 막기 위한 사용자 결정).';
COMMENT ON COLUMN public.event_groups.name_normalized IS
  '[291] 중복 차단용 정규화 키. lower(trim(regexp_replace(name,''\s+'','' '',''g''))).
  companies(마이그레이션 118→119 최종 패턴) 미러링 — 공백 개수 차이도 중복으로 본다.
  직접 입력 불가, 트리거가 자동 계산.';
COMMENT ON COLUMN public.event_groups.status IS
  '[291] active=사용중, archived=보관. 지워도 캠페인 연결은 끊어질 뿐 저장이
  막히지 않으므로(event_group_id ON DELETE SET NULL), 재사용 여지가 있으면
  삭제 대신 archived 권장.';

CREATE INDEX IF NOT EXISTS event_groups_status_idx ON public.event_groups (status);

-- ── 정규화 이름 자동 계산 트리거 (119 최종 패턴 그대로) ──
CREATE OR REPLACE FUNCTION public.set_event_group_name_normalized()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.name_normalized := lower(trim(regexp_replace(coalesce(NEW.name, ''), '\s+', ' ', 'g')));
  IF NEW.name_normalized = '' THEN
    RAISE EXCEPTION 'event group name must not be empty' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.set_event_group_name_normalized() IS
  '[291] event_groups.name_normalized 자동 계산 — lower+trim+다중 공백 단일 압축.
  companies.set_company_name_normalized(마이그레이션 119 최종 버전) 패턴 미러링.';

REVOKE ALL ON FUNCTION public.set_event_group_name_normalized() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_event_group_name_normalized() FROM authenticated;
REVOKE ALL ON FUNCTION public.set_event_group_name_normalized() FROM anon;
GRANT EXECUTE ON FUNCTION public.set_event_group_name_normalized() TO PUBLIC;

DROP TRIGGER IF EXISTS trg_event_groups_name_normalized ON public.event_groups;
CREATE TRIGGER trg_event_groups_name_normalized
  BEFORE INSERT OR UPDATE OF name ON public.event_groups
  FOR EACH ROW
  EXECUTE FUNCTION public.set_event_group_name_normalized();

-- ── updated_at 자동 갱신 트리거 ──
CREATE OR REPLACE FUNCTION public.touch_event_groups_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.touch_event_groups_updated_at() IS
  '[291] event_groups.updated_at 자동 갱신 트리거 함수.';

REVOKE ALL ON FUNCTION public.touch_event_groups_updated_at() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.touch_event_groups_updated_at() FROM authenticated;
REVOKE ALL ON FUNCTION public.touch_event_groups_updated_at() FROM anon;
GRANT EXECUTE ON FUNCTION public.touch_event_groups_updated_at() TO PUBLIC;

DROP TRIGGER IF EXISTS trg_event_groups_updated_at ON public.event_groups;
CREATE TRIGGER trg_event_groups_updated_at
  BEFORE UPDATE ON public.event_groups
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_event_groups_updated_at();

-- ── 행 단위 보안 정책 — 조회는 관리자 전체, 쓰기는 campaign_admin 이상(companies 118 미러링) ──
ALTER TABLE public.event_groups ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS event_groups_select_admin ON public.event_groups;
CREATE POLICY event_groups_select_admin
  ON public.event_groups
  FOR SELECT
  USING (public.is_admin());

DROP POLICY IF EXISTS event_groups_insert_admin ON public.event_groups;
CREATE POLICY event_groups_insert_admin
  ON public.event_groups
  FOR INSERT
  WITH CHECK (public.is_campaign_admin());

DROP POLICY IF EXISTS event_groups_update_admin ON public.event_groups;
CREATE POLICY event_groups_update_admin
  ON public.event_groups
  FOR UPDATE
  USING (public.is_campaign_admin())
  WITH CHECK (public.is_campaign_admin());

DROP POLICY IF EXISTS event_groups_delete_admin ON public.event_groups;
CREATE POLICY event_groups_delete_admin
  ON public.event_groups
  FOR DELETE
  USING (public.is_campaign_admin());

-- ============================================================
-- 2. 캠페인 연결 칸 — ON DELETE SET NULL (brands.company_id 와 동일한 방식)
-- ============================================================
ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS event_group_id uuid
    REFERENCES public.event_groups(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.campaigns.event_group_id IS
  '[291] 소속 행사 묶음(event_groups) 외래 키. NULL 허용 — 묶음을 지워도 이 칸만
  NULL 로 끊어지고 캠페인 저장은 막히지 않는다(brands.company_id 패턴 미러링).
  브랜드 일치·행사 모드(event_mode) 여부를 데이터베이스에서 강제하지 않는다
  (합동 팝업·향후 형식 변경 대비 — 파일 헤더 참고). 목록에서 골라서만 넣는
  UI 는 후속 구현(dev/ 미포함, 이 마이그레이션은 데이터베이스만).';

CREATE INDEX IF NOT EXISTS campaigns_event_group_id_idx ON public.campaigns (event_group_id);

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (SQL Editor에서 1단계씩 순서대로 — 중간에 오류가 나면 즉시 멈추고 원인 확인)
-- ============================================================
-- [1] 표·컬럼 생성 확인
-- SELECT column_name, data_type, is_nullable, column_default
--   FROM information_schema.columns
--  WHERE table_schema='public' AND table_name='event_groups'
--  ORDER BY ordinal_position;
--
-- SELECT column_name, data_type, is_nullable
--   FROM information_schema.columns
--  WHERE table_schema='public' AND table_name='campaigns' AND column_name='event_group_id';
--   → uuid, YES
--
-- [2] 기존 캠페인은 전부 NULL (도입 즉시 동작 변화 0)
-- SELECT count(*) FROM public.campaigns WHERE event_group_id IS NOT NULL;   -- 0
--
-- [3] ⛔ 이 블록은 **돌리지 마세요 — 292 로 대체됐습니다.**
--   아래 「실패해야 정상」이라는 서술 자체가 틀렸습니다(2026-08-05 개발 실측).
--   이 파일의 정규화는 공백을 **압축**만 하고 제거하지 않아 「REVERB팝업」과
--   「REVERB 팝업」이 **둘 다 저장됩니다.** 291 만 적용한 상태에서 이걸 돌리면
--   통과하지 않는 게 정상인데 「고장 났다」로 오판하게 됩니다.
--   → 291 적용 후 곧바로 292_event_groups_name_normalized_fix.sql 을 이어서
--     적용하고, **292 하단의 재검증 절차**를 쓰세요.
--
-- [3-폐기] ★ (옛 검증 — 공백 하나 차이도 중복으로 거부되는지)
-- INSERT INTO public.event_groups (name) VALUES ('REVERB팝업');
--   → 성공
-- INSERT INTO public.event_groups (name) VALUES ('REVERB 팝업');
--   → 실패해야 정상 (unique constraint "event_groups_name_normalized_key" violation)
--     두 값 모두 name_normalized = 'reverb팝업' 로 계산되기 때문(공백은
--     regexp_replace 로 압축된 뒤 trim 되어 사실상 제거됨).
--   검증 후 테스트 행 정리: DELETE FROM public.event_groups WHERE name = 'REVERB팝업';
--
-- [4] 캠페인 연결 → 묶음 삭제 시 캠페인 저장이 막히지 않는지
-- -- (1) 테스트 묶음 생성 + 실제 캠페인 1개에 연결
-- INSERT INTO public.event_groups (name) VALUES ('__검증용_임시묶음__') RETURNING id;
-- UPDATE public.campaigns SET event_group_id = '<위에서 나온 id>' WHERE id = '<검증용_캠페인_ID>';
-- -- (2) 묶음 삭제
-- DELETE FROM public.event_groups WHERE name = '__검증용_임시묶음__';
-- -- (3) 캠페인 행이 여전히 존재하고 event_group_id 만 NULL 로 끊겼는지 확인
-- SELECT id, event_group_id FROM public.campaigns WHERE id = '<검증용_캠페인_ID>';
--   → event_group_id IS NULL, 캠페인 행 자체는 그대로
--
-- [5] 275 낙관적 락이 새 컬럼을 보호하는지(제외 목록에 안 들어갔는지)
-- SELECT id, version FROM public.campaigns WHERE id = '<검증용_캠페인_ID>';
-- UPDATE public.campaigns SET event_group_id = NULL WHERE id = '<검증용_캠페인_ID>';
-- SELECT version FROM public.campaigns WHERE id = '<검증용_캠페인_ID>';   -- +1 이어야 함(값이 이미 NULL이면 변화 없어 버전도 그대로 — 위 [4]에서 값이 있었던 캠페인으로 확인)
--
-- [6] 행 단위 보안 정책 확인
-- SELECT policyname, cmd FROM pg_policies
--  WHERE schemaname='public' AND tablename='event_groups' ORDER BY policyname;
--   → select/insert/update/delete 4개
-- ============================================================

-- ============================================================
-- 롤백 (역순: 캠페인 칸 → 트리거·함수 → 표)
-- ============================================================
-- BEGIN;
-- DROP INDEX IF EXISTS public.campaigns_event_group_id_idx;
-- ALTER TABLE public.campaigns DROP COLUMN IF EXISTS event_group_id;
--
-- DROP TRIGGER IF EXISTS trg_event_groups_updated_at ON public.event_groups;
-- DROP FUNCTION IF EXISTS public.touch_event_groups_updated_at();
-- DROP TRIGGER IF EXISTS trg_event_groups_name_normalized ON public.event_groups;
-- DROP FUNCTION IF EXISTS public.set_event_group_name_normalized();
--
-- DROP POLICY IF EXISTS event_groups_delete_admin ON public.event_groups;
-- DROP POLICY IF EXISTS event_groups_update_admin ON public.event_groups;
-- DROP POLICY IF EXISTS event_groups_insert_admin ON public.event_groups;
-- DROP POLICY IF EXISTS event_groups_select_admin ON public.event_groups;
--
-- DROP TABLE IF EXISTS public.event_groups;
-- COMMIT;
