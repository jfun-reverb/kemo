-- ============================================================
-- 466_brand_memos.sql
-- 2026-09-23
--
-- 목적:
--   브랜드 상세 화면의 「영업 메모」를 **여러 건 쌓는 기록**으로 바꾼다.
--   지금은 brands.memo 글자 칸 하나라 누가 언제 썼는지 안 남고, 고치면 앞의 글이 사라진다.
--
-- 사양서: docs/specs/2026-09-23-brand-memo-entries.md (§3-A, 확정된 결정 A·B·D·G)
--
-- 구조는 오리엔시트 내부 메모(297)와 같다. 다른 점 셋:
--   ① card_uid·card_name_snapshot 이 없다 — 메모가 붙는 대상이 **브랜드 하나**다.
--      297 이 외래 키를 못 건 이유(카드가 jsonb 배열 안)가 여기엔 없어 **진짜 외래 키**를 건다.
--   ② 읽음 기록 표(brand_memo_reads)를 **이번에 만들지 않는다** — 사용자 결정 A
--      (안 읽음 표시·목록 숫자 배지 제외). 운영 브랜드가 77개라 목록에 배지를 달면
--      거의 모든 행에 숫자가 떠 「원래 빨간 화면」이 된다는 판단. 나중에 넣을 때는
--      orient_sheet_memo_reads(297) 를 그대로 본뜨면 된다.
--   ③ 기존 글 이전문이 없다 — **옮길 글이 0건**이다(2026-09-23 실측: 운영 브랜드 77개·
--      개발 33개 중 memo 에 글이 있는 브랜드 **0**). 있었다면 마이그레이션 080 처럼
--      첫 메모로 옮겼을 것이다. 「왜 안 옮겼나」를 다시 묻지 않도록 여기 적어 둔다.
--
-- ⚠️ brands.memo 칸은 **지우지 않는다.** 대신 같은 배포에서 화면이 그 칸에 쓰는 줄을
--    없앤다(_collectBrandFormPatch 의 memo:). 마이그레이션 124 가 치운 사고가 정확히
--    「옛 칸을 남겼는데 화면이 계속 거기 쓴 것」이었다 — 옛 칸과 새 표가 동시에 살아 있으면
--    같은 메모가 두 벌이 된다.
--
-- 🔴 delete_brand(현재 원본 325)는 **한 글자도 고치지 않는다.**
--    그 함수는 연결 셋(캠페인·서베이 신청·오리엔시트)을 세고 화면도 **같은 셋**을 본다.
--    메모를 넷째 조건으로 더하면 「버튼은 뜨는데 누르면 실패」가 생긴다.
--    메모는 아래 ON DELETE CASCADE 로 브랜드와 함께 사라진다(의도된 결정 — 감사 미보존).
--
-- 접근 정책: 조회·작성·수정·삭제 전부 is_admin() 한 줄(등급 분기 없음).
--   지금도 캠페인 매니저가 brands.memo 를 쓰고 있어(폼 저장에 포함) 이래야 동작 변화가 0이다.
--
-- 낙관적 잠금 없음 — 마지막 저장 승리(297 과 같은 결정. 짧은 글이고 작성자·시각이 남는다).
--
-- 이 파일이 하지 않는 것:
--   - merge_brands 재정의(병합할 때 메모를 대상 브랜드로 옮기는 일) → 다음 마이그레이션
--     🔴 그 함수의 **현재 원본은 328**이다(175 → 328). 175 를 베이스로 잡으면 328 이 넣은
--     **오리엔시트 이동·멱등성 판정·moved_orient_sheets 반환**이 통째로 사라진다.
--   - 화면 변경 → 별도 병합 요청
--
-- 롤백: DROP TABLE public.brand_memos; DROP FUNCTION public.touch_brand_memos_updated_at();
--       (아직 아무도 이 표를 쓰지 않는 시점에서만 안전)
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.brand_memos (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  brand_id    uuid        NOT NULL REFERENCES public.brands(id) ON DELETE CASCADE,
  body_html   text        NOT NULL
                CHECK (btrim(body_html) <> '' AND char_length(body_html) <= 20000),
  author_id   uuid        NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  author_name text        NULL,   -- 삭제된 관리자 이름 보존용 스냅샷(080·297 과 동일)
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.brand_memos IS
  '[466] 브랜드별 영업 메모. 관리자 전용, 브랜드사 비노출. 메모마다 행 1개 '
  '(orient_sheet_memos[297]·brand_application_memos[080] 구조 미러). '
  'brand_id 는 ON DELETE CASCADE — 브랜드 삭제 시 함께 삭제(의도된 결정, 감사 미보존).';

COMMENT ON COLUMN public.brand_memos.body_html IS
  '메모 본문 — 서식(굵게·기울임·밑줄·취소선·링크)이 들어간 글. 사진은 허용하지 않는다. '
  '저장 전 화면에서 sanitizeMemoHtml 로 정화한 값이 들어온다(그리는 쪽에서도 다시 정화). '
  '길이 상한 20,000자·공백만인 빈 글은 CHECK 로 차단.';

COMMENT ON COLUMN public.brand_memos.author_name IS
  '작성 시점 관리자 이름 스냅샷. author_id(auth.users)가 지워져도 이름은 남는다.';

-- 상세 화면이 브랜드 하나의 메모를 최신순으로 가져올 때 + 목록 집계가 브랜드별로 묶을 때
CREATE INDEX IF NOT EXISTS idx_brand_memos_brand_created
  ON public.brand_memos (brand_id, created_at DESC);

ALTER TABLE public.brand_memos ENABLE ROW LEVEL SECURITY;

CREATE POLICY "brand_memos_select"
  ON public.brand_memos FOR SELECT
  TO authenticated
  USING (public.is_admin());

CREATE POLICY "brand_memos_insert"
  ON public.brand_memos FOR INSERT
  TO authenticated
  WITH CHECK (public.is_admin());

CREATE POLICY "brand_memos_update"
  ON public.brand_memos FOR UPDATE
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

CREATE POLICY "brand_memos_delete"
  ON public.brand_memos FOR DELETE
  TO authenticated
  USING (public.is_admin());

CREATE OR REPLACE FUNCTION public.touch_brand_memos_updated_at()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.touch_brand_memos_updated_at IS
  '[466] brand_memos BEFORE UPDATE 트리거. updated_at 자동 갱신 — 화면의 「수정됨」 표시 근거.';

DROP TRIGGER IF EXISTS trg_brand_memos_updated_at ON public.brand_memos;

CREATE TRIGGER trg_brand_memos_updated_at
  BEFORE UPDATE ON public.brand_memos
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_brand_memos_updated_at();

COMMIT;

-- ============================================================
-- [적용 뒤 확인]
--   SELECT count(*) FROM pg_policies WHERE tablename = 'brand_memos';        -- 4
--   SELECT count(*) FROM pg_indexes  WHERE tablename = 'brand_memos';        -- 2 (기본 키 + 위 색인)
--   -- 연쇄 삭제(되돌리는 트랜잭션 안에서):
--   --   BEGIN;
--   --     INSERT INTO public.brands(name) VALUES ('__시험__') RETURNING id;  \gset
--   --     INSERT INTO public.brand_memos(brand_id, body_html) VALUES (:'id', '<p>시험</p>');
--   --     DELETE FROM public.brands WHERE id = :'id';
--   --     SELECT count(*) FROM public.brand_memos WHERE brand_id = :'id';    -- 0
--   --   ROLLBACK;
-- [롤백] DROP TABLE public.brand_memos;  DROP FUNCTION public.touch_brand_memos_updated_at();
-- ============================================================
