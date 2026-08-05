-- ============================================================
-- 294_orient_card_uid_backfill.sql
-- 2026-08-05
--
-- 목적:
--   이미 저장돼 있는 오리엔시트 카드 중 고유 번호(data.cards[].uid)가
--   없는 것에 번호를 일괄 부여한다.
--
-- 사양서:
--   docs/specs/2026-08-05-orient-sheet-internal-memo.md §설계 1
--   작업표  docs/specs/2026-08-05-orient-sheet-internal-memo-breakdown.md 작업 3
--
-- 전제 (반드시 확인):
--   1) 293_orient_card_uid_safety_net.sql 이 **먼저** 적용돼 있어야 한다
--      (여기서 쓰는 _orient_apply_card_uids 함수가 293에서 생긴다).
--   2) 브랜드 작성 폼(작업 2)이 배포된 **뒤**에 도는 편이 낫다 —
--      폼 배포가 늦을수록 옛 폼이 카드 개수를 바꿔 저장해서
--      그 시트 메모가 전부 고아가 되는 구간이 길어진다.
--   3) ⚠️ **제출 알림 자동 메일이 「덧칠 방지 장치」가 든 버전으로 배포돼 있는지**
--      먼저 확인할 것 (supabase/functions/notify-orient-submitted).
--      아래 「알림 메일」 항목 참조.
--
-- 하는 일:
--   번호 없는 카드가 하나라도 있는 시트만 골라 data 를 다시 쓴다.
--   보정 규칙은 293의 _orient_apply_card_uids 를 그대로 재사용한다
--   (같은 함수를 쓰므로 번호 형식이 저장 경로와 완전히 같다).
--   기존 데이터를 제 자신과 대조하도록 넘기므로
--     · 번호가 있는 카드 → 그대로 유지
--     · 번호가 없는 카드 → 물려받을 것도 없으니 새 번호 부여
--   가 되어, **여러 번 돌려도 결과가 같다**(멱등).
--
-- ⚠️ 낙관적 락 값(version)은 **올리지 않는다.**
--   version 은 자동 장치가 아니라 저장 함수 안에서 명시적으로 올린다.
--   여기서 data 만 바꾸면, 브랜드가 열어 둔 작성 화면에
--   「다른 곳에서 수정됨」 충돌이 뜨지 않는다.
--
-- ⚠️ 알림 메일:
--   이 갱신은 상태가 「제출됨」인 시트도 건드리므로, 제출 알림 웹훅의
--   행 조건(status='submitted')을 다시 통과한다. 실제 발송은 마이그레이션 234가
--   붙인 게이트(「마지막 제출 시각이 그대로면 건너뜀」)가 막아 주는데,
--   **그 게이트는 마이그레이션이 아니라 알림 함수 코드 쪽에 있다.**
--   → 실행 직후 관리자 메일함에 「수정 재제출」 메일이 안 왔는지 눈으로 확인할 것.
--   (이 파일은 last_submitted_at 을 건드리지 않으므로 게이트가 정상 동작하면 조용하다.)
--
-- 운영 데이터 영향:
--   운영 시트의 data 를 직접 고치는 **유일한** 작업이다.
--   ⚠️ 운영에 넣기 전 백업 여부를 사용자에게 확인할 것.
--
-- 롤백:
--   부여한 번호를 지우는 것은 **권장하지 않는다** —
--   지우면 293의 물려주기 안전망이 쓸 재료가 사라져,
--   옛 폼이 저장할 때 번호가 전부 새로 붙는다(그 시트 메모가 고아가 된다).
--   문제가 생기면 되돌리기보다 다음 단계(메모 표 생성)를 멈추는 쪽으로 대응한다.
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_before int;
  v_rows   int;
  v_after  int;
BEGIN
  -- 채우기 전: 번호 없는 카드를 가진 시트 수
  SELECT count(*)
    INTO v_before
    FROM public.orient_sheets o
   WHERE jsonb_typeof(o.data -> 'cards') = 'array'
     AND EXISTS (
           SELECT 1
             FROM jsonb_array_elements(o.data -> 'cards') AS c
            WHERE jsonb_typeof(c) = 'object'
              AND NULLIF(btrim(COALESCE(c ->> 'uid', '')), '') IS NULL
         );

  -- 실제 채우기 — 번호가 빠진 시트만 건드린다
  --   (조건 없이 전체를 다시 쓰면 멀쩡한 시트까지 갱신돼
  --    제출 알림 웹훅을 불필요하게 깨우고 updated_at 이 흔들린다)
  UPDATE public.orient_sheets o
     SET data = public._orient_apply_card_uids(o.data, o.data)
   WHERE jsonb_typeof(o.data -> 'cards') = 'array'
     AND EXISTS (
           SELECT 1
             FROM jsonb_array_elements(o.data -> 'cards') AS c
            WHERE jsonb_typeof(c) = 'object'
              AND NULLIF(btrim(COALESCE(c ->> 'uid', '')), '') IS NULL
         );

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  -- 채운 뒤: 남아 있는 시트 수 (0이어야 정상)
  SELECT count(*)
    INTO v_after
    FROM public.orient_sheets o
   WHERE jsonb_typeof(o.data -> 'cards') = 'array'
     AND EXISTS (
           SELECT 1
             FROM jsonb_array_elements(o.data -> 'cards') AS c
            WHERE jsonb_typeof(c) = 'object'
              AND NULLIF(btrim(COALESCE(c ->> 'uid', '')), '') IS NULL
         );

  RAISE NOTICE '[294] 번호 없는 시트: 전 % 건 → 갱신 % 건 → 후 % 건 (후=0 이어야 정상)',
    v_before, v_rows, v_after;

  IF v_after <> 0 THEN
    RAISE EXCEPTION '[294] 채우기 후에도 번호 없는 카드가 남았습니다 (% 건). 롤백합니다.', v_after;
  END IF;
END;
$$;

COMMIT;


-- ============================================================
-- 실행 후 눈으로 확인하는 조회 (선택 — 위 NOTICE 로 충분하면 생략 가능)
--
--   -- ① 번호 없는 카드가 0건인지
--   SELECT count(*) AS 번호없는시트
--     FROM public.orient_sheets o
--    WHERE jsonb_typeof(o.data -> 'cards') = 'array'
--      AND EXISTS (SELECT 1 FROM jsonb_array_elements(o.data -> 'cards') AS c
--                   WHERE jsonb_typeof(c) = 'object'
--                     AND NULLIF(btrim(COALESCE(c ->> 'uid', '')), '') IS NULL);
--
--   -- ② 한 시트 안에서 번호가 겹치지 않는지 (겹치면 메모가 두 카드에 동시에 보인다)
--   SELECT o.id, c ->> 'uid' AS uid, count(*) AS 건수
--     FROM public.orient_sheets o,
--          jsonb_array_elements(o.data -> 'cards') AS c
--    WHERE jsonb_typeof(o.data -> 'cards') = 'array'
--    GROUP BY o.id, c ->> 'uid'
--   HAVING count(*) > 1;
-- ============================================================
