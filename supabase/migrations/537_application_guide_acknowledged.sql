-- ============================================================
-- 537_application_guide_acknowledged.sql
-- 응모 완료 모달 — 「안내 확인 시각」 칸 + 기록 함수 + 314 삽입 가드 재정의
--
-- 사양서: docs/specs/2026-10-15-client-figma-reviewer-apply-screens.md §7(7-2 결정 5·8 · 7-5)
-- 작업표: docs/specs/2026-10-15-client-figma-reviewer-apply-screens-breakdown.md 조각 1
--
-- 무엇을
--   ① applications.guide_acknowledged_at timestamptz NULL — 회원이 응모 직후 모달에서
--      「위 내용을 확인했습니다」 체크 뒤 「확인」을 누른 시각(문의 대응 근거).
--   ② acknowledge_application_guide(p_application_id uuid) RETURNS timestamptz
--      — 본인 응모에만 · 이미 값이 있으면 덮지 않는다(두 번 불러도 같은 값) ·
--        남의 응모와 없는 응모를 구분하지 않는다(application_not_found 하나) ·
--        취소된 응모·탈퇴 확정 회원도 거부하지 않는다(시각 한 칸을 적을 뿐이라 해가 없다 · 모달은 저장 직후라 취소 상태가 되기 어렵고,
--        거부하면 확인 기록만 사라질 뿐 얻는 것이 없다).
--   ③ 실행 권한 — 두 방향 회수(PUBLIC 과 anon 을 따로 걷는다 — 마이그레이션 369·370 참고)
--      후 authenticated 에만 부여(509 와 같은 꼴).
--   ④ 314 guard_application_insert_status 재정의 — 회원이 응모를 넣을 때 이 칸을 미리
--      채워 보내면 서버가 지운다(사양서 결정 8). 베이스 314(그 뒤 재정의 파일 없음 —
--      `grep -ln guard_application_insert_status supabase/migrations/` 결과 314 하나).
--
-- ⚠️ 314 는 CREATE OR REPLACE FUNCTION 만 한다 — 트리거는 다시 만들지 않는다.
--    트리거 이름(trg_application_insert_status_guard)이 알파벳순으로 049 의
--    trg_monitor_auto_approve 보다 앞서야 리뷰어형 자동 승인이 산다(314 헤더).
--    함수 본문만 바꾸면 트리거는 그대로 새 본문을 부른다.
-- ⚠️ 314 의 앞 단계 통과 조항(행사 예약 함수 표시 · 비로그인 · 관리자)은 그대로 둔다 —
--    그래서 「서버가 지운다」는 **일반 회원 삽입에만** 해당한다(행사 예약 함수는 이 칸을
--    보내지 않는다).
--
-- 회원이 응모 행을 직접 UPDATE 하는 길은 열지 않는다(지금도 없다). 기록은 ② 함수로만.
-- applications 의 UPDATE 트리거는 전부 `UPDATE OF status` 라 이 칸만 바꾸는 갱신에
-- 신청 인원 재계산·이벤트 기록·정산 보류가 딸려 오지 않는다(작업표 코드 대조 S12).
--
-- 편집기 경고: 안 뜸 — DROP·DELETE 없음. ⚠️ 314 를 다시 정의하므로 경고 없이 동작이 바뀐다.
-- 롤백: 파일 하단(함수 → 314 원래 본문 → 칸 순).
-- ============================================================

BEGIN;

-- ① 칸 ---------------------------------------------------------
ALTER TABLE public.applications
  ADD COLUMN IF NOT EXISTS guide_acknowledged_at timestamptz NULL;

COMMENT ON COLUMN public.applications.guide_acknowledged_at IS
  '[537] 응모 직후 「응모 완료 모달」에서 회원이 안내를 확인(체크 → 「확인」)한 시각.
   기록은 acknowledge_application_guide() 로만, 한 번 정해지면 덮지 않는다.
   응모 삽입 때 미리 채워 보낸 값은 314 가드(guard_application_insert_status)가 지운다.
   중립 갈래(재조회 실패·가구매 표시 등)는 기록하지 않아 NULL 로 남는다.';

-- ② 기록 함수 ---------------------------------------------------
CREATE OR REPLACE FUNCTION public.acknowledge_application_guide(p_application_id uuid)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_at  timestamptz;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  -- 본인 응모이고 아직 값이 없을 때만 지금 시각을 남긴다
  UPDATE public.applications
     SET guide_acknowledged_at = now()
   WHERE id = p_application_id
     AND user_id = v_uid
     AND guide_acknowledged_at IS NULL
  RETURNING guide_acknowledged_at INTO v_at;

  IF v_at IS NOT NULL THEN
    RETURN v_at;
  END IF;

  -- 0행 — 이미 값이 있으면 그 값(두 번 불러도 같은 결과), 없으면 거부
  SELECT a.guide_acknowledged_at INTO v_at
    FROM public.applications a
   WHERE a.id = p_application_id
     AND a.user_id = v_uid;

  IF NOT FOUND THEN
    -- 남의 응모와 없는 응모를 구분하지 않는다(남의 응모 아이디 존재 여부를 흘리지 않게)
    RAISE EXCEPTION 'application_not_found';
  END IF;

  RETURN v_at;
END;
$$;

COMMENT ON FUNCTION public.acknowledge_application_guide(uuid) IS
  '[537] 응모 완료 모달 「확인」 — 본인 응모의 guide_acknowledged_at 을 지금 시각으로(이미 있으면 그 값).
   거부: not_authenticated · application_not_found(남의 응모·없는 응모 구분 없음). 실행 권한 authenticated 만.';

-- ③ 실행 권한 — 두 방향 회수 후 회원에게만
REVOKE EXECUTE ON FUNCTION public.acknowledge_application_guide(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.acknowledge_application_guide(uuid) TO authenticated;

-- ④ 314 삽입 가드 재정의 — 본문은 314 그대로 + 넷째 단계에 한 줄 ------------
CREATE OR REPLACE FUNCTION public.guard_application_insert_status()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- 1. 오프라인 행사 예약 함수(reserve_event_ticket 등, 288)가 세워 둔 표시 → 통과
  IF COALESCE(current_setting('reverb.event_ticket_bypass', true), '') = 'on' THEN
    RETURN NEW;
  END IF;

  -- 2. 배치·마이그레이션·서비스 키 — 로그인 세션이 없으면 통과(272 와 동일 조항)
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  -- 3. 관리자 — 대리 응모 경로는 없지만 관리자를 겸한 회원의 본인 응모는 여기서 통과한다(272 와 동일 조항).
  --    그 경우 미리 채운 안내 확인 시각은 지워지지 않는다 — 위험이 낮아 314 구조를 그대로 둔다
  IF public.is_admin() THEN
    RETURN NEW;
  END IF;

  -- 4. 그 외 전부 — 클라이언트가 무엇을 보냈든 심사중으로 강제한다.
  --    monitor(리뷰어) 캠페인은 바로 다음 trg_monitor_auto_approve(049)가 approved 로 다시 덮는다.
  NEW.status      := 'pending';
  NEW.reviewed_by := NULL;
  NEW.reviewed_at := NULL;
  -- [537] 안내 확인 시각은 acknowledge_application_guide() 로만 남는다 — 삽입 때 미리 채운 값은 지운다
  NEW.guide_acknowledged_at := NULL;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.guard_application_insert_status() IS
  '[314 → 537] 응모 삽입 시 상태값 위조 차단. BEFORE INSERT ON applications.
   판정: reverb.event_ticket_bypass=on 통과(288 예약 함수) → auth.uid() NULL
   통과(배치) → is_admin() 통과(대비 조항, 현재 미도달) → 그 외 status를
   pending 으로, reviewed_by/reviewed_at/guide_acknowledged_at(537) 을 NULL 로 강제.
   monitor 캠페인은 이 트리거 다음의 trg_monitor_auto_approve(049)가 approved
   로 다시 덮어써 자동 승인 정책은 그대로 유지된다(트리거 이름 알파벳순
   trg_application_insert_status_guard < trg_monitor_auto_approve — 이름 바꾸지 말 것).';

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 — 1단계씩 순서대로(중간에 기대와 다르면 멈추고 원인부터)
-- ============================================================
--
-- [1] 칸 존재
-- SELECT column_name, data_type, is_nullable
--   FROM information_schema.columns
--  WHERE table_schema = 'public' AND table_name = 'applications' AND column_name = 'guide_acknowledged_at';
--   → 1행, timestamp with time zone, YES
--
-- [2] 실행 권한 — 맨 앞 「=X/」(PUBLIC) 없음 · anon 없음 · authenticated 있음
-- SELECT p.proacl::text,
--        has_function_privilege('anon', p.oid, 'EXECUTE')          AS anon_exec,
--        has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth_exec
--   FROM pg_proc p
--  WHERE p.proname = 'acknowledge_application_guide' AND p.pronamespace = 'public'::regnamespace;
--   → proacl 에 '=X/' 로 시작하는 항목 없음 · anon= 없음 · anon_exec=false · auth_exec=true
--
-- [3] 트리거 순서 그대로(314 를 다시 정의했지만 트리거는 안 건드렸다)
-- SELECT tgname FROM pg_trigger
--  WHERE tgrelid = 'public.applications'::regclass AND NOT tgisinternal AND tgname LIKE 'trg_%'
--  ORDER BY tgname;
--   → trg_application_insert_status_guard 가 trg_monitor_auto_approve 보다 앞
--
-- [4] 비로그인으로 부르면 거부(편집기 기본 역할 — 로그인 회원이 아니다)
-- SELECT public.acknowledge_application_guide(gen_random_uuid());
--   → ERROR: not_authenticated
--
-- [5] 미리 채운 확인 시각을 서버가 지우는지 · 덮지 않는지 · 남의 응모는 거부하는지 — 블록 하나.
--     ⚠️ 이 블록은 **끝에서 일부러 오류를 내 모든 변경을 되돌린다** — 결과는 그 오류 문구(JSON)로 읽는다.
--        (Supabase 편집기는 마지막 문장 결과만 보여 주고, 한 트랜잭션 안에서는 now() 가 고정이라
--         「두 번 불러 같은 시각」으로는 덮어쓰기를 증명할 수 없다 — 그래서 과거 값을 심어 본다)
--     ⚠️ 편집기 역할은 postgres 라 행 단위 보안 정책(applications_insert_own)은 재현되지 않는다 — 트리거만 본다.
--     실행 조건: <캠페인 id> = 모집 중(마감 가드 272)인 시딩 캠페인(행사 전용 아님) · <회원 A> = 그 캠페인에
--       아직 응모하지 않은 탈퇴 아닌 시험 회원(359·연령 가드 180 통과) · <회원 B> = 다른 시험 회원.
-- DO $v$
-- DECLARE v_id uuid; v_ins timestamptz; v_ack timestamptz; v_other text := 'no_error';
-- BEGIN
--   PERFORM set_config('request.jwt.claims', json_build_object('sub','<회원 A auth_id>')::text, true);
--   INSERT INTO public.applications (user_id, campaign_id, message, status, guide_acknowledged_at)
--   VALUES ('<회원 A auth_id>'::uuid, '<캠페인 id>'::uuid, '검증용', 'pending', '2000-01-01')
--   RETURNING id, guide_acknowledged_at INTO v_id, v_ins;          -- 기대 v_ins = NULL(314 재정의가 지움)
--   UPDATE public.applications SET guide_acknowledged_at = '2000-01-01' WHERE id = v_id;   -- 과거 값을 심는다
--   v_ack := public.acknowledge_application_guide(v_id);           -- 기대 2000-01-01(덮지 않음)
--   PERFORM set_config('request.jwt.claims', json_build_object('sub','<회원 B auth_id>')::text, true);
--   BEGIN PERFORM public.acknowledge_application_guide(v_id); EXCEPTION WHEN OTHERS THEN v_other := SQLERRM; END;
--   RAISE EXCEPTION 'VERIFY %', json_build_object('inserted_ack', v_ins, 'ack_after_seed', v_ack, 'other_user', v_other);
-- END $v$;
--   → 오류 문구 VERIFY {"inserted_ack" : null, "ack_after_seed" : "2000-01-01T00:00:00+…", "other_user" : "application_not_found"}
--     (오류로 끝나 아무것도 남지 않는다 — 이게 정상이다)
--
-- ============================================================
-- 롤백(함수 → 314 원래 본문 → 칸)
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS public.acknowledge_application_guide(uuid);
-- -- 314 본문으로 되돌리기: supabase/migrations/314_application_insert_status_guard.sql 의
-- --   CREATE OR REPLACE FUNCTION 블록만 다시 실행(트리거 블록은 실행할 필요 없음)
-- ALTER TABLE public.applications DROP COLUMN IF EXISTS guide_acknowledged_at;
-- COMMIT;
-- NOTIFY pgrst, 'reload schema';
-- ============================================================
