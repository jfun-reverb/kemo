-- ============================================================
-- 292_event_groups_name_normalized_fix.sql
-- 마이그레이션 291(행사 묶음 표)의 정규화 규칙 결함 교정
-- 사양서: docs/specs/2026-08-05-event-group-and-scoped-checkin.md §4-1
--
-- ⚠️ 291 파일은 이미 개발 데이터베이스에 적용됐으므로 수정하지 않는다.
--   이 파일은 291 이 만든 함수를 새 규칙으로 "다시 정의"하는
--   교체 마이그레이션이다(companies 표가 118→119 로 교체했던 것과 같은 방식).
--
-- 무엇이 잘못됐었나 (개발 데이터베이스 실측, 2026-08-05):
--   291 의 정규화 함수는
--     lower(trim(regexp_replace(name, '\s+', ' ', 'g')))
--   였다. 이건 "연속 공백을 하나로 압축"하는 규칙이지 "공백 제거"가
--   아니다. 그래서 「REVERB팝업」(공백 0개)과 「REVERB 팝업」(공백 1개)은
--   압축해도 서로 다른 문자열로 남아 유일 제약을 피해 **둘 다 저장됐다**.
--   291 파일 하단 주석 [3]에 "실패해야 정상"이라고 적혀 있었던 것 자체가
--   틀린 서술이었다(compress ≠ strip 를 착각).
--
--   291 헤더 주석이 근거로 든 "companies 마이그레이션 118→119 최종 패턴"도
--   목적이 다르다. 119 는 "제이펀"과 "제이 펀"을 **다른 회사로 남기는 것이
--   맞는** 회사명 정책이라 압축까지만 하면 충분했다. 이번 행사 묶음 이름은
--   반대로 "REVERB팝업"과 "REVERB 팝업"을 **같은 묶음으로** 봐야 하므로
--   압축이 아니라 완전 제거가 맞는 규칙이다. 두 정책은 서로 다른 요구라
--   같은 패턴을 그대로 옮겨 쓸 수 없었다.
--
-- 무엇으로 바뀌는가:
--   lower(trim(regexp_replace(name, '\s+', ' ', 'g')))            -- 291(폐기)
--   ↓
--   lower(regexp_replace(coalesce(name, ''), '[\s　]+', '', 'g'))  -- 292(신규)
--
--   공백을 압축하지 않고 전부 제거한다(문자 자체를 지우므로 trim 은
--   불필요 — 양 끝 공백도 이미 지워진다). 일반 공백·탭·줄바꿈 등은
--   정규식 문자 클래스 `\s` 로 잡히고, 여기에 **전각 공백(U+3000, 　)**
--   1개를 명시적으로 추가했다 — 이건 사용자 요청(모든 공백 문자)을
--   문자 그대로 해석하면 `\s` 만으로 충분하지만, 일본어 키보드 입력에서
--   흔히 섞여 들어오는 U+3000 전각 공백은 POSIX `\s` 가 못 잡는 별도
--   문자라서 방치하면 같은 사고(「REVERB　팝업」전각 공백이 딴 값으로
--   저장됨)가 형태만 바뀌어 재발할 수 있다고 판단해 방어적으로 추가했다.
--   요청 범위를 벗어난 판단이므로 이 사실을 명시해 둔다(리뷰 시 이견 있으면
--   되돌리기 쉽게 이 문단만 삭제하고 `[\s　]+` 를 `\s+` 로 되돌리면 된다).
--
-- 기존 행 재계산 — 검증용 테스트 행 삭제가 먼저 필요한 이유:
--   개발 데이터베이스에 이미 「REVERB팝업」·「REVERB 팝업」 두 행이 들어가
--   있다(291 검증 과정에서 생성됨, 서로 다른 name_normalized 로 저장돼
--   유일 제약을 피해 둘 다 성공했었다). 새 규칙으로 재계산하면 두 행의
--   name_normalized 가 똑같아져 유일 제약 위반으로 이 마이그레이션
--   자체가 실패한다.
--   이 두 행은 291 검증 목적으로만 만든 쓰레기 데이터이고 실사용 행사가
--   아니므로, 재계산 전에 **이름이 정확히 이 두 값과 일치하는 행만**
--   선택적으로 지운다(다른 이름의 정상 행은 절대 건드리지 않음).
--   운영 데이터베이스는 291 이 아직 적용되지 않아 event_groups 표 자체가
--   없거나 있어도 0행이므로, 이 삭제문은 운영에서 사실상 아무 일도 안 한다.
--
--   삭제 후에도 혹시 모를 다른 중복(이 두 값 이외의 이름이 새 규칙에서
--   충돌하는 경우)이 있으면, 재계산 직전 사전 점검이 알아보기 쉬운
--   오류 메시지로 멈춘다(무슨 값이 몇 개 충돌하는지는 안내만, 실제 처리는
--   운영자가 수동으로 정리 후 재실행).
--
-- 적용 순서 (운영 배포 시 반드시 지킬 것):
--   운영 데이터베이스에는 291 이 아직 적용되지 않았다. 291 → 292 를
--   **반드시 이 순서로, 두 파일 다** 적용한다(292 는 291 이 만든 함수를
--   전제로 "재정의"하는 파일이라 291 없이 단독 적용 불가 — CREATE OR
--   REPLACE 대상 함수 자체가 없어서가 아니라 event_groups 표·트리거가
--   없으면 이 파일의 문(DELETE·UPDATE)이 대상 표를 못 찾아 실패한다).
--
--   ⚠️ 291 파일 하단의 검증 절차 [3]("REVERB 팝업" 삽입이 "실패해야
--   정상")은 **291 만 적용한 직후에는 통과하지 않는다** — 그 시점엔 아직
--   압축 규칙이라 두 값 다 성공하는 게 291 단독 기준으로는 "정상"이다.
--   운영에서 291 을 적용한 뒤 그 검증 SQL을 그대로 돌리면 "고장났다"고
--   오판하게 되니, **291 적용 직후에는 그 검증 [3]을 돌리지 말고 바로
--   292 를 이어서 적용**한 다음 이 파일 하단의 재검증 절차로 확인한다.
--
-- 아직 이 표를 참조하는 화면 코드가 없음 (2026-08-05 기준):
--   관리자 캠페인 편집 폼의 묶음 드롭다운, 현장 확인 페이지의 목록 조회
--   모두 미착수(dev/ 미포함) — 그래서 지금이 정규화 규칙을 바꿔도
--   화면 쪽 영향이 0인, 가장 안전한 시점이다.
--
-- 롤백: 파일 하단 참고 (291 의 압축 규칙 함수 정의로 되돌림 — 단,
--   되돌려도 이미 292 가 지운 테스트 행 2개는 복원되지 않는다는 점 주의).
-- ============================================================

BEGIN;

-- ── 1. 검증용 테스트 행 정리 (이름이 정확히 이 두 값일 때만) ──
--    운영은 event_groups 가 비어 있거나 아예 없는 상태라 사실상 0행 영향.
DELETE FROM public.event_groups
 WHERE name IN ('REVERB팝업', 'REVERB 팝업');

-- ── 2. 사전 점검 — 새 규칙에서 여전히 충돌하는 이름이 남아있으면 여기서 멈춤 ──
DO $$
DECLARE
  v_dupe_groups int;
BEGIN
  SELECT count(*) INTO v_dupe_groups
  FROM (
    SELECT lower(regexp_replace(coalesce(name, ''), '[\s　]+', '', 'g')) AS norm
      FROM public.event_groups
     GROUP BY 1
    HAVING count(*) > 1
  ) dupes;

  IF v_dupe_groups > 0 THEN
    RAISE EXCEPTION
      'event_groups: 공백을 완전히 제거하는 새 정규화 규칙을 적용하면 서로 같아지는 이름 묶음이 %개 있습니다. 관리자 화면 또는 SQL로 이름을 수동 정리한 뒤 이 마이그레이션을 다시 실행하세요.',
      v_dupe_groups;
  END IF;
END $$;

-- ── 3. 정규화 함수 재정의 — 압축이 아니라 전부 제거 ──
CREATE OR REPLACE FUNCTION public.set_event_group_name_normalized()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- [292] 291 의 "연속 공백 압축" 규칙을 폐기하고 "공백 완전 제거"로 교체.
  -- \s(일반 공백·탭·줄바꿈 등) + U+3000(전각 공백) 를 전부 지운다.
  -- 문자 자체를 지우므로 trim 은 불필요(양 끝 공백도 이미 제거됨).
  NEW.name_normalized := lower(regexp_replace(coalesce(NEW.name, ''), '[\s　]+', '', 'g'));
  IF NEW.name_normalized = '' THEN
    RAISE EXCEPTION 'event group name must not be empty' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.set_event_group_name_normalized() IS
  '[292] event_groups.name_normalized 자동 계산 — lower + 공백(일반+전각) 완전 제거.
  291 의 "다중 공백 압축" 규칙은 「REVERB팝업」과 「REVERB 팝업」을 구분하지
  못해 폐기됨(개발 데이터베이스 실측). companies(119)의 압축 패턴과는
  의도적으로 다른 규칙 — companies 는 "제이펀"≠"제이 펀"이 맞는 정책, 이
  표는 그 반대(같은 값으로 취급)가 맞는 정책이라 갈라짐.';

REVOKE ALL ON FUNCTION public.set_event_group_name_normalized() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_event_group_name_normalized() FROM authenticated;
REVOKE ALL ON FUNCTION public.set_event_group_name_normalized() FROM anon;
GRANT EXECUTE ON FUNCTION public.set_event_group_name_normalized() TO PUBLIC;

-- 트리거는 291 이 이미 함수 이름으로 연결해 두었으므로 재생성 불필요
-- (CREATE OR REPLACE FUNCTION 이 같은 이름을 그대로 유지하면 트리거는
-- 자동으로 새 함수 본문을 사용한다). 그래도 재적용 안전을 위해 명시:
DROP TRIGGER IF EXISTS trg_event_groups_name_normalized ON public.event_groups;
CREATE TRIGGER trg_event_groups_name_normalized
  BEFORE INSERT OR UPDATE OF name ON public.event_groups
  FOR EACH ROW
  EXECUTE FUNCTION public.set_event_group_name_normalized();

-- ── 4. 기존 행 재계산 — 새 규칙으로 name_normalized 다시 채움 ──
-- name 컬럼을 SET 절에 명시하면(값이 실제로 안 바뀌어도) "UPDATE OF name"
-- 트리거가 모든 행에 대해 발동한다 — PostgreSQL 표준 동작. 위 [2]에서
-- 충돌이 없다고 확인했으므로 여기서 유일 제약에 걸릴 일은 없다.
UPDATE public.event_groups SET name = name;

COMMIT;

-- ============================================================
-- 재검증 (SQL Editor에서 1단계씩 순서대로 — 292 적용 후 실행)
-- ============================================================
-- [1] 함수가 새 규칙으로 바뀌었는지 직접 계산으로 확인
-- SELECT lower(regexp_replace('REVERB 팝업', '[\s　]+', '', 'g'));   -- → 'reverb팝업'
-- SELECT lower(regexp_replace('REVERB팝업',  '[\s　]+', '', 'g'));   -- → 'reverb팝업' (위와 동일해야 함)
--
-- [2] ★ 핵심 재검증 — 이번엔 실제로 거부되는지
-- INSERT INTO public.event_groups (name) VALUES ('REVERB팝업');
--   → 성공
-- INSERT INTO public.event_groups (name) VALUES ('REVERB 팝업');
--   → 실패해야 정상 (unique constraint "event_groups_name_normalized_key" violation)
-- INSERT INTO public.event_groups (name) VALUES ('REVERB　팝업');  -- 전각 공백
--   → 이것도 실패해야 정상 (전각 공백도 같은 값으로 취급)
--
-- 검증 후 테스트 행 정리:
-- DELETE FROM public.event_groups WHERE name = 'REVERB팝업';
--
-- [3] 기존 행(있다면)이 전부 새 규칙으로 재계산됐는지 표본 확인
-- SELECT name, name_normalized FROM public.event_groups ORDER BY created_at DESC LIMIT 20;
--   → name_normalized 에 공백이 전혀 없어야 함
-- ============================================================

-- ============================================================
-- 롤백 (291 의 "압축" 규칙 함수 정의로 되돌림)
-- ⚠️ 되돌려도 이 마이그레이션이 지운 테스트 행 2개(REVERB팝업/REVERB 팝업)는
--   복원되지 않는다. 그 시점 이후 새로 들어간 실사용 행은 name_normalized
--   가 압축 규칙 기준으로 재계산되지 않은 채 남으므로, 롤백 후에는 아래
--   4번 재계산 UPDATE 를 반드시 함께 실행할 것.
-- ============================================================
-- BEGIN;
-- CREATE OR REPLACE FUNCTION public.set_event_group_name_normalized()
-- RETURNS trigger
-- LANGUAGE plpgsql
-- SECURITY DEFINER
-- SET search_path = ''
-- AS $$
-- BEGIN
--   NEW.name_normalized := lower(trim(regexp_replace(coalesce(NEW.name, ''), '\s+', ' ', 'g')));
--   IF NEW.name_normalized = '' THEN
--     RAISE EXCEPTION 'event group name must not be empty' USING ERRCODE = '23514';
--   END IF;
--   RETURN NEW;
-- END;
-- $$;
--
-- REVOKE ALL ON FUNCTION public.set_event_group_name_normalized() FROM PUBLIC;
-- REVOKE ALL ON FUNCTION public.set_event_group_name_normalized() FROM authenticated;
-- REVOKE ALL ON FUNCTION public.set_event_group_name_normalized() FROM anon;
-- GRANT EXECUTE ON FUNCTION public.set_event_group_name_normalized() TO PUBLIC;
--
-- UPDATE public.event_groups SET name = name;  -- 압축 규칙으로 재계산
-- COMMIT;
-- ============================================================
