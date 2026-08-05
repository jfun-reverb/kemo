-- ============================================================
-- 295_orient_sheet_memos.sql
-- 2026-08-05
--
-- 목적:
--   오리엔시트 상세 화면에서 관리자가 모집 건(카드)마다 남기는 「내부 메모」
--   저장소를 만든다. 브랜드사에게 보이지 않는 관리자 전용 대화 기록이다.
--
-- 사양서:
--   docs/specs/2026-08-05-orient-sheet-internal-memo.md §설계 2, 확정된 결정
--   작업표  docs/specs/2026-08-05-orient-sheet-internal-memo-breakdown.md 작업 4
--
-- 신규 표 2개:
--   [A] orient_sheet_memos       — 메모 본체 (여러 건 쌓기, brand_application_memos
--                                    [080] 과 같은 구조 — 계속 고쳐 쓰는 메모장이 아니다)
--   [B] orient_sheet_memo_reads  — 메모별 관리자 읽음 이력
--                                    (brand_application_memo_reads [125] 패턴 그대로 미러)
--
-- 카드 참조 방식 — 외래 키가 아니다:
--   메모는 어느 「모집 건(카드)」에 붙는지를 orient_sheets.data.cards[].uid
--   (마이그레이션 293·294에서 심은 카드 고유 번호) 값을 그대로 저장해 가리킨다.
--   카드는 jsonb 배열 안에 있어 관계형 외래 키를 걸 수 없다. 브랜드가 그 카드를
--   지워도 메모 행은 남고, 상세 화면이 "삭제된 모집 건의 메모" 묶음으로 보여준다
--   (사양서 §설계 4, §의심 4). card_name_snapshot 은 그 판단을 돕는 스냅샷이다.
--
-- ⚠️ 본문 열 이름 = body_html (기존 brand_application_memos.text 를 따라 하지 않음)
--   그 표(080)의 text 열은 서식 없는 줄글이지만, 이번 메모는 굵게·기울임·밑줄·
--   취소선·링크 서식이 들어간 리치 텍스트다. 이름만 보고 같은 성격으로 오인하지
--   않도록 서식 글임이 드러나는 이름을 쓴다 (작업표 「어긋남 2」).
--   길이 상한 20,000자(char_length 기준) — 시트 전체(data jsonb)의 100KB 상한(마이그
--   레이션 293)보다 훨씬 작게 잡았다. 메모는 짧은 대화 기록이라 실제 사용량은
--   수백 자 내외로 예상되고, 상한은 "이론상 극단적으로 긴 붙여넣기"를 막는 안전판
--   역할만 하면 충분하다. 빈 글(공백만)도 CHECK 로 차단.
--
-- 접근 정책(행 단위 보안) — 등급 분기 없음, 관리자 전원:
--   확정 결정 ④(수정·삭제 권한)와 ⑥(열람 등급)이 둘 다 "관리자 전원"으로
--   확정됐다(캠페인 매니저 등급 포함). 그래서 조회·작성·수정·삭제가 전부
--   is_admin() 한 줄로 끝난다 — brand_application_memos(080)와 동일 패턴.
--   ⚠️ 나중에 등급 제한이 필요해지면 조회와 쓰기를 함께 좁혀야 한다(사양서 §의심 8).
--   읽음 기록 표는 조회는 관리자 전원, 작성(INSERT)은 본인 행만.
--
-- 시트 삭제 시 메모도 함께 삭제 — 의도된 확정 결정 (감사 기록으로 남기지 않는다):
--   orient_sheet_id 는 ON DELETE CASCADE. delete_orient_sheet() 함수는 이 파일에서
--   한 글자도 고치지 않는다 — 연쇄 삭제에 그대로 맡긴다.
--
-- 낙관적 락(version)을 걸지 않는다 — 의도된 확정 결정 (마지막 저장 승리):
--   메모는 짧고 작성자·시각이 항상 남아 되짚을 수 있다는 판단.
--
-- 이 파일이 하지 않는 것 (범위 밖 — 다음 마이그레이션 296이 담당):
--   - 읽음 처리 원격 호출 함수(mark_orient_sheet_memos_read)
--   - 집계 조회 원격 호출 함수(get_orient_sheet_memo_summaries)
--   메모 자체의 작성·수정·삭제는 이 표에 대한 일반 조회/쓰기로 처리한다
--   (brand_application_memos 와 동일 — 별도 함수 불필요).
--
-- 선행 조건:
--   마이그레이션 293·294(카드 고유 번호 안전망·기존 시트 채우기)가 개발서버에
--   적용·검증까지 끝난 상태를 전제로 한다(사양서 §6 의존 순서 — 1단계 완료 후 2단계).
--
-- 롤백:
--   표 2개를 DROP 한다(다른 곳이 아직 이 표를 쓰지 않는 시점이라 안전).
--   파일 하단 [롤백 SQL] 참조.
-- ============================================================

BEGIN;


-- ============================================================
-- SECTION 1. orient_sheet_memos — 메모 본체
-- ============================================================
CREATE TABLE IF NOT EXISTS public.orient_sheet_memos (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  orient_sheet_id    uuid        NOT NULL
                       REFERENCES public.orient_sheets(id) ON DELETE CASCADE,
  card_uid           text        NOT NULL CHECK (btrim(card_uid) <> ''),
  card_name_snapshot text        NULL,
  body_html          text        NOT NULL
                       CHECK (btrim(body_html) <> '' AND char_length(body_html) <= 20000),
  author_id          uuid        NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  author_name        text        NULL,   -- 삭제된 관리자 이름 보존용 스냅샷 (080과 동일)
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.orient_sheet_memos IS
  '[295] 오리엔시트 모집 건(카드)별 내부 메모. 관리자 전용, 브랜드사 비노출. '
  '메모마다 row 1개(brand_application_memos[080] 구조 미러). '
  'orient_sheet_id 는 ON DELETE CASCADE — 시트 삭제 시 함께 삭제(의도된 결정, 감사 미보존).';

COMMENT ON COLUMN public.orient_sheet_memos.card_uid IS
  '어느 모집 건(카드)의 메모인지. orient_sheets.data.cards[].uid 값(마이그레이션 293·294) '
  '을 그대로 저장 — 외래 키 아님(카드는 jsonb 배열 안에 있어 관계형 참조 불가). '
  '카드가 지워져도 이 값은 남아, 화면이 "삭제된 모집 건의 메모"로 모아 보여준다.';

COMMENT ON COLUMN public.orient_sheet_memos.card_name_snapshot IS
  '작성 시점 그 카드의 제품명 스냅샷. 카드가 지워진 뒤 어느 모집 건이었는지 '
  '알아보기 위함. 빌 수 있음(NULL 이면 화면이 "이름 없는 모집 건"으로 표기).';

COMMENT ON COLUMN public.orient_sheet_memos.body_html IS
  '메모 본문 — 서식(굵게·기울임·밑줄·취소선·링크) 이 들어간 리치 텍스트. '
  '⚠️ brand_application_memos.text(서식 없는 줄글)와 열 이름을 다르게 쓴 이유가 이것 — '
  'body_html 이라는 이름 자체로 리치 텍스트임을 드러낸다. '
  '저장 전 애플리케이션 단에서 정화(sanitize)를 거쳐야 한다(사진 태그 미허용, 작업 7). '
  '길이 상한 20,000자·공백만인 빈 글 CHECK 로 차단.';

COMMENT ON COLUMN public.orient_sheet_memos.author_name IS
  '작성 시점 관리자 이름 스냅샷. author_id(auth.users) 가 삭제돼도 이름 보존 (080과 동일).';


-- ============================================================
-- SECTION 2. 인덱스
-- ============================================================

-- 상세 모달이 시트 하나의 메모 전체를 최신순으로 가져올 때
CREATE INDEX IF NOT EXISTS idx_orient_sheet_memos_sheet_created
  ON public.orient_sheet_memos (orient_sheet_id, created_at DESC);

-- 집계 조회(296의 get_orient_sheet_memo_summaries)가 (시트, 카드) 짝으로 묶을 때
CREATE INDEX IF NOT EXISTS idx_orient_sheet_memos_sheet_card
  ON public.orient_sheet_memos (orient_sheet_id, card_uid);


-- ============================================================
-- SECTION 3. 행 단위 보안 정책 — 관리자 전원, 등급 분기 없음
--   확정 결정 ④(수정·삭제)·⑥(열람)이 둘 다 "전원"이라 정책이 한 줄로 끝난다.
-- ============================================================
ALTER TABLE public.orient_sheet_memos ENABLE ROW LEVEL SECURITY;

CREATE POLICY "orient_sheet_memos_select"
  ON public.orient_sheet_memos FOR SELECT
  TO authenticated
  USING (public.is_admin());

CREATE POLICY "orient_sheet_memos_insert"
  ON public.orient_sheet_memos FOR INSERT
  TO authenticated
  WITH CHECK (public.is_admin());

CREATE POLICY "orient_sheet_memos_update"
  ON public.orient_sheet_memos FOR UPDATE
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

CREATE POLICY "orient_sheet_memos_delete"
  ON public.orient_sheet_memos FOR DELETE
  TO authenticated
  USING (public.is_admin());


-- ============================================================
-- SECTION 4. updated_at 자동 갱신 트리거 — "수정됨" 표시용 (080 패턴 미러)
-- ============================================================
CREATE OR REPLACE FUNCTION public.touch_orient_sheet_memos_updated_at()
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

COMMENT ON FUNCTION public.touch_orient_sheet_memos_updated_at IS
  '[295] orient_sheet_memos BEFORE UPDATE 트리거. updated_at 자동 갱신 — 화면의 "수정됨" 표시 근거.';

DROP TRIGGER IF EXISTS trg_orient_sheet_memos_updated_at ON public.orient_sheet_memos;

CREATE TRIGGER trg_orient_sheet_memos_updated_at
  BEFORE UPDATE ON public.orient_sheet_memos
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_orient_sheet_memos_updated_at();


-- ============================================================
-- SECTION 5. orient_sheet_memo_reads — 관리자별 읽음 이력
--   brand_application_memo_reads(125) 구조 그대로 미러.
--   (memo_id, auth_id) 가 열쇠, 메모 삭제 시 함께 정리(ON DELETE CASCADE).
-- ============================================================
CREATE TABLE IF NOT EXISTS public.orient_sheet_memo_reads (
  memo_id    uuid        NOT NULL
               REFERENCES public.orient_sheet_memos(id) ON DELETE CASCADE,
  auth_id    uuid        NOT NULL,
  read_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (memo_id, auth_id)
);

CREATE INDEX IF NOT EXISTS idx_orient_sheet_memo_reads_auth
  ON public.orient_sheet_memo_reads (auth_id);

COMMENT ON TABLE public.orient_sheet_memo_reads IS
  '[295] orient_sheet_memos 의 관리자별 읽음 이력. brand_application_memo_reads(125) '
  '패턴 미러. memo_id FK ON DELETE CASCADE 로 메모 삭제 시 자동 정리. '
  '읽음 처리 단위는 시트(마이그레이션 296 mark_orient_sheet_memos_read 참조) — '
  '카드에 붙은 메모뿐 아니라 카드가 사라진 고아 메모도 함께 처리된다.';

ALTER TABLE public.orient_sheet_memo_reads ENABLE ROW LEVEL SECURITY;

-- SELECT: 관리자 전체 (LEFT JOIN 시 본인 행 필터링은 원격 호출 함수에서)
CREATE POLICY "orient_sheet_memo_reads_select"
  ON public.orient_sheet_memo_reads FOR SELECT
  TO authenticated
  USING (public.is_admin());

-- INSERT: 본인 행만, 관리자만
CREATE POLICY "orient_sheet_memo_reads_insert"
  ON public.orient_sheet_memo_reads FOR INSERT
  TO authenticated
  WITH CHECK (auth_id = auth.uid() AND public.is_admin());

-- UPDATE/DELETE 정책 없음 — mark_orient_sheet_memos_read 원격 호출 함수(296) 전용


-- ============================================================
-- SECTION 6. PostgREST 스키마 캐시 재로드
-- ============================================================
NOTIFY pgrst, 'reload schema';


COMMIT;


-- ════════════════════════════════════════════════════════════
-- [검증 SQL] — 개발 DB에서 마이그레이션 적용 후 SQL Editor에서 1단계씩 실행
-- ════════════════════════════════════════════════════════════
/*

-- 1. 표 2개 존재 확인
SELECT tablename FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN ('orient_sheet_memos', 'orient_sheet_memo_reads')
ORDER BY tablename;
-- 2행

-- 2. 인덱스 확인
SELECT tablename, indexname FROM pg_indexes
WHERE tablename IN ('orient_sheet_memos', 'orient_sheet_memo_reads')
ORDER BY tablename, indexname;
-- orient_sheet_memos: PK + sheet_created + sheet_card = 3건
-- orient_sheet_memo_reads: PK + auth = 2건

-- 3. 행 단위 보안 정책 확인 (orient_sheet_memos 4건 / reads 2건)
SELECT tablename, policyname, cmd FROM pg_policies
WHERE tablename IN ('orient_sheet_memos', 'orient_sheet_memo_reads')
ORDER BY tablename, cmd;

-- 4. 트리거 확인
SELECT tgname, tgenabled FROM pg_trigger
WHERE tgrelid = 'public.orient_sheet_memos'::regclass;
-- trg_orient_sheet_memos_updated_at, enabled

-- 5. CASCADE 동작 확인 — 임시 시트를 만들고 지워서 메모·읽음기록이 함께 사라지는지
--    (이 블록은 자체적으로 정리까지 한다 — 남는 데이터 없음)
DO $$
DECLARE
  v_brand_id uuid;
  v_sheet_id uuid;
  v_memo_id  uuid;
BEGIN
  SELECT id INTO v_brand_id FROM public.brands ORDER BY created_at LIMIT 1;
  IF v_brand_id IS NULL THEN
    RAISE NOTICE '브랜드가 없어 CASCADE 검증 스킵';
    RETURN;
  END IF;

  INSERT INTO public.orient_sheets (brand_id, token, status, data, version, token_expires_at, orient_no)
  VALUES (v_brand_id, gen_random_uuid(), 'draft', '{}'::jsonb, 1, now() + interval '1 day',
          'BTEST-M' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 6))
  RETURNING id INTO v_sheet_id;

  INSERT INTO public.orient_sheet_memos (orient_sheet_id, card_uid, body_html, author_name)
  VALUES (v_sheet_id, 'test-uid', '<b>검증용</b>', '(검증)')
  RETURNING id INTO v_memo_id;

  INSERT INTO public.orient_sheet_memo_reads (memo_id, auth_id)
  VALUES (v_memo_id, gen_random_uuid());

  DELETE FROM public.orient_sheets WHERE id = v_sheet_id;

  IF EXISTS (SELECT 1 FROM public.orient_sheet_memos WHERE id = v_memo_id)
     OR EXISTS (SELECT 1 FROM public.orient_sheet_memo_reads WHERE memo_id = v_memo_id) THEN
    RAISE EXCEPTION 'CASCADE 실패 — 시트를 지웠는데 메모·읽음기록이 남아 있음';
  END IF;

  RAISE NOTICE 'CASCADE 정상 — 시트 삭제 시 메모·읽음기록이 함께 사라짐';
END;
$$;

*/


-- ════════════════════════════════════════════════════════════
-- [롤백 SQL] — 운영 적용 후 문제 발생 시 순서대로 실행
-- ════════════════════════════════════════════════════════════
/*

DROP TABLE IF EXISTS public.orient_sheet_memo_reads;

DROP TRIGGER IF EXISTS trg_orient_sheet_memos_updated_at ON public.orient_sheet_memos;
DROP FUNCTION IF EXISTS public.touch_orient_sheet_memos_updated_at();
DROP TABLE IF EXISTS public.orient_sheet_memos;

NOTIFY pgrst, 'reload schema';

*/
