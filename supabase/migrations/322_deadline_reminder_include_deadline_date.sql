-- ============================================================
-- 322_deadline_reminder_include_deadline_date.sql
-- 전수조사 후속 묶음 F — F-9: 마감을 연장해도 재안내가 안 나가는 문제
--
-- 계보(이 표를 건드린 마이그레이션 — 재정의 시 항상 최신 파일을 원본으로
--   삼을 것, feedback_function_redefine_latest_base 재발 방지):
--   130(원본, UNIQUE 4-튜플 정의) → 138(인덱스 존재 확인만, 제약 무변경)
--   → 290(kind CHECK 확장만, 제약 무변경) → 322(이 파일, UNIQUE 를 5-튜플로 확장)
--
-- 배경:
--   deadline_reminder_email_sent 의 중복 방지 열쇠가
--   UNIQUE (influencer_id, campaign_id, kind, d_minus) 4개 조합이다(마이그레이션 130).
--   deadline_date 칸은 이미 표에 있지만(NOT NULL) 열쇠에는 없다.
--
--   그래서 캠페인 마감일을 연장하면, "옛 마감일 기준으로 이미 D-5/D-1 안내를
--   보냈다"는 이력이 4-튜플만으로 매칭되어 "새 마감일 기준 D-5/D-1"까지
--   막아버린다 — 인플루언서는 연장된 마감을 다시 안내받지 못한다.
--
--   (Edge Function 쪽 대응은 이 마이그레이션과 짝을 이룬다 —
--    supabase/functions/notify-influencer-daily-digest/index.ts 의 중복 차단
--    Set 열쇠도 이 파일과 같은 시점에 deadline_date 를 포함하도록 이미 고쳤다.
--    이 마이그레이션만 적용하고 그 코드 배포가 안 됐다면, 애플리케이션이
--    여전히 4-튜플로 걸러 보내는 시도 자체를 안 하므로 증상은 그대로다.
--    반대로 코드만 배포되고 이 마이그레이션이 빠지면, 11번 벌크 INSERT 가
--    옛 4-튜플 UNIQUE 제약에 걸려 23505 로 실패한다 — 두 변경은 반드시
--    함께 나가야 한다.)
--
-- 부작용 검토(의도한 동작인지 판단 — 사용자 확인 필요):
--   마감일이 연장 → 원복 → 재연장처럼 여러 번 바뀌면, 그때마다 "새 마감일"로
--   집계되어 같은 사람이 같은 (캠페인, 종류, D-N) 안내를 여러 번 받을 수 있다.
--   이 저장소 CLAUDE.md 의 "마감일 연장 시 상태 자동 전환 확인"(2026-07-30)
--   기능은 캠페인 편집에서 마감일을 과거→미래로 바꾸는 경우를 이미 정식
--   흐름으로 다루고 있고, 그 경우 인플루언서가 다시 안내를 받는 것은
--   "재안내가 안 나간다"는 이번 결함의 정반대 방향(놓치는 것보다 한 번
--   더 받는 게 안전)이라 의도한 동작으로 판단한다. 같은 마감일로 되돌아가면
--   (deadline_date 가 이전과 동일) 기존 이력이 그대로 매칭돼 재발송되지
--   않는다 — 실제로 새로 바뀐 마감일에 대해서만 새 이력이 쌓인다.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- [사전 확인 1] 기존 행이 새 제약(5-튜플)을 위반하지 않는지 확인.
--   이론상 4-튜플이 이미 유일했던 표에 칸을 하나 더 추가해 비교하는 것은
--   "더 느슨한" 방향이라(4개가 같으면 5개도 항상 같다) 위반이 있을 수
--   없지만, 이 저장소는 "당연히 안전하다"는 가정만으로 진행하지 않는다
--   (마이그레이션 104→305 사고 — 가정이 아니라 직접 확인).
--   0행이 아니면 아래 ADD CONSTRAINT 가 실패하기 전에 여기서 먼저 걸린다.
-- ------------------------------------------------------------
DO $$
DECLARE
  v_dupe_count integer;
BEGIN
  SELECT count(*) INTO v_dupe_count
  FROM (
    SELECT influencer_id, campaign_id, kind, d_minus, deadline_date
    FROM public.deadline_reminder_email_sent
    GROUP BY influencer_id, campaign_id, kind, d_minus, deadline_date
    HAVING count(*) > 1
  ) dupes;

  IF v_dupe_count > 0 THEN
    RAISE EXCEPTION
      '[322] deadline_reminder_email_sent 에 5-튜플 기준 중복 행이 % 건 있어 마이그레이션을 중단합니다 — 먼저 데이터를 정리하세요',
      v_dupe_count;
  END IF;

  RAISE NOTICE '[322] 사전 확인 통과 — 5-튜플 기준 중복 행 없음';
END;
$$;

-- ------------------------------------------------------------
-- [1] 기존 UNIQUE 제약을 이름이 아니라 "정의(컬럼 구성)"로 찾아서 지운다.
--   이름을 하드코딩해 IF EXISTS 로 지우면, 이름이 틀렸을 때 아무 일도
--   안 일어난 채 조용히 다음 줄로 넘어간다 — 그게 바로 마이그레이션 104가
--   재현한 사고다(마이그레이션 305 참고, 3개월간 재응모 기능이 죽어 있었음).
--   여기서는 정확한 이름을 pg_constraint 에서 직접 찾고, 못 찾으면(0개
--   또는 2개 이상 매칭) 예외를 던져 마이그레이션을 즉시 중단한다.
-- ------------------------------------------------------------
DO $$
DECLARE
  v_conname text;
  v_match_count integer;
BEGIN
  -- contype='u'(유니크 제약) 이면서 구성 컬럼이 정확히
  -- {influencer_id, campaign_id, kind, d_minus} 4개인 제약을 찾는다.
  -- (컬럼 순서는 안 보고 "구성 집합"만 비교 — CREATE TABLE 인라인 UNIQUE(...)
  --  는 나열 순서대로 conkey 에 들어가지만, 여기선 순서에 의존하지 않는다)
  SELECT c.conname, count(*) OVER () INTO v_conname, v_match_count
  FROM pg_constraint c
  WHERE c.conrelid = 'public.deadline_reminder_email_sent'::regclass
    AND c.contype = 'u'
    AND (
      SELECT array_agg(a.attname ORDER BY a.attname)
      FROM unnest(c.conkey) AS k(attnum)
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
    ) = ARRAY['campaign_id', 'd_minus', 'influencer_id', 'kind']::name[]
  LIMIT 1;

  IF v_conname IS NULL THEN
    RAISE EXCEPTION
      '[322] deadline_reminder_email_sent 에서 (influencer_id, campaign_id, kind, d_minus) 4-튜플 유니크 제약을 찾지 못했습니다 — 마이그레이션 130 이후 구조가 예상과 다릅니다. 수동 확인 필요';
  END IF;

  IF v_match_count > 1 THEN
    RAISE EXCEPTION
      '[322] 같은 4-튜플 유니크 제약이 % 개 발견돼 어느 것을 지울지 확정할 수 없습니다 — 수동 확인 필요', v_match_count;
  END IF;

  RAISE NOTICE '[322] 기존 유니크 제약 발견: % — 삭제합니다', v_conname;
  EXECUTE format('ALTER TABLE public.deadline_reminder_email_sent DROP CONSTRAINT %I', v_conname);

  -- 삭제 후 정말 사라졌는지 재확인 (같은 이름으로 다시 조회했을 때 0행이어야 함)
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.deadline_reminder_email_sent'::regclass
      AND conname = v_conname
  ) THEN
    RAISE EXCEPTION '[322] 제약 삭제 후에도 % 이(가) 여전히 남아 있습니다', v_conname;
  END IF;

  RAISE NOTICE '[322] 기존 4-튜플 유니크 제약 삭제 확인 완료';
END;
$$;

-- ------------------------------------------------------------
-- [2] 5-튜플 유니크 제약 신규 추가 (이름을 직접 지정 — 다음에 이 표를
--   또 건드릴 마이그레이션이 이름을 추측하지 않도록).
-- ------------------------------------------------------------
ALTER TABLE public.deadline_reminder_email_sent
  ADD CONSTRAINT deadline_reminder_email_sent_infl_camp_kind_dminus_deadline_key
  UNIQUE (influencer_id, campaign_id, kind, d_minus, deadline_date);

COMMENT ON CONSTRAINT deadline_reminder_email_sent_infl_camp_kind_dminus_deadline_key
  ON public.deadline_reminder_email_sent IS
  '[322] 마감일 연장 후 재안내 허용 — 130 의 4-튜플 UNIQUE 를 deadline_date 포함 5-튜플로 확장';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 SQL (개발 데이터베이스 적용 후, SQL Editor 에서 1단계씩 실행)
-- ============================================================
/*

-- [V0] 새 제약이 5개 컬럼으로 정확히 걸렸는지 확인
SELECT pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conrelid = 'public.deadline_reminder_email_sent'::regclass
  AND conname  = 'deadline_reminder_email_sent_infl_camp_kind_dminus_deadline_key';
-- 기대값: UNIQUE (influencer_id, campaign_id, kind, d_minus, deadline_date)

-- [V1] 옛 4-튜플 제약이 더는 없는지 확인 (contype='u' 인 제약이 위 V0 것 하나뿐이어야 함)
SELECT conname, pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conrelid = 'public.deadline_reminder_email_sent'::regclass
  AND contype = 'u';
-- 기대값: 1행, V0 과 동일한 제약만

-- [V2] 기존 행이 그대로 조회되는지 확인 — 값 손실 없어야 함
SELECT count(*) FROM public.deadline_reminder_email_sent;

-- [V3] 마감일이 다른 같은 (influencer, campaign, kind, d_minus) 조합 INSERT 가
--   더는 막히지 않는지 스모크 테스트 (테스트 행이므로 즉시 롤백)
BEGIN;
INSERT INTO public.deadline_reminder_email_sent
  (influencer_id, campaign_id, kind, d_minus, deadline_date)
VALUES
  ('00000000-0000-0000-0000-000000000000',
   (SELECT id FROM public.campaigns LIMIT 1),
   'receipt', 5, current_date),
  ('00000000-0000-0000-0000-000000000000',
   (SELECT id FROM public.campaigns LIMIT 1),
   'receipt', 5, current_date + 7);  -- 마감일만 다름 → 5-튜플에서는 다른 행, 통과해야 함
ROLLBACK;

-- [V4] 반대로 완전히 같은 5-튜플은 여전히 막히는지 확인 (진짜 중복 방지 유지)
BEGIN;
INSERT INTO public.deadline_reminder_email_sent
  (influencer_id, campaign_id, kind, d_minus, deadline_date)
VALUES
  ('00000000-0000-0000-0000-000000000000',
   (SELECT id FROM public.campaigns LIMIT 1),
   'receipt', 5, current_date);
-- 같은 값으로 다시 INSERT → 23505 유니크 위반이 나야 정상
INSERT INTO public.deadline_reminder_email_sent
  (influencer_id, campaign_id, kind, d_minus, deadline_date)
VALUES
  ('00000000-0000-0000-0000-000000000000',
   (SELECT id FROM public.campaigns LIMIT 1),
   'receipt', 5, current_date);
ROLLBACK;

*/

-- ============================================================
-- 롤백 (적용 취소 시 아래 실행 — 130 버전 4-튜플로 복원)
-- ============================================================
/*

BEGIN;

ALTER TABLE public.deadline_reminder_email_sent
  DROP CONSTRAINT IF EXISTS deadline_reminder_email_sent_infl_camp_kind_dminus_deadline_key;

ALTER TABLE public.deadline_reminder_email_sent
  ADD CONSTRAINT deadline_reminder_email_sent_influencer_id_campaign_id_kind_d_minus_key
  UNIQUE (influencer_id, campaign_id, kind, d_minus);

NOTIFY pgrst, 'reload schema';

COMMIT;

*/
