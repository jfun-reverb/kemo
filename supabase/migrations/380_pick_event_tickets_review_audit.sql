-- ============================================================
-- 380_pick_event_tickets_review_audit.sql
-- 뽑기(pick_event_tickets)도 떨어뜨리기처럼 「누가 언제 승인했나」를 남긴다
-- 사양서: docs/specs/2026-08-24-event-invite-only-selection-breakdown.md
--         §9 「S-4」 · §2 ⑨(「뽑기는 감사 대칭이 없다」)
-- 선행: 379(pick_event_tickets · reject_event_tickets 최초 생성 — 이 파일이
--       재정의하는 원본)
--
-- 🔴 무엇을 왜 — 379 의 reject_event_tickets(떨어뜨리기)는 신청을 rejected
--    로 바꿀 때 reviewed_by·reviewed_at 을 함께 채우는데(379:419-424),
--    pick_event_tickets(뽑기)는 신청을 approved 로 바꿀 때 그 두 칸을
--    안 채운다(379:268-271, UPDATE 한 줄이 status 만 SET 한다). 사양서·
--    작업표·구현 지시문 어디에도 뽑기 쪽에 그 요구가 없었다 — 일부러 뺀
--    것이 아니라 문서 누락이 코드까지 내려온 것이다. 관리자 신청 관리
--    화면(dev/js/admin-applications.js:168, formatReviewer(a.reviewed_by))
--    이 그 칸을 그리므로, 행사 당선자만 그 자리가 비어 있었다.
--    사용자가 「채운다」로 결정(2026-08-25).
--
-- 이 파일이 하는 것: pick_event_tickets(uuid[]) 재정의(CREATE OR REPLACE,
--   베이스 379) — 신청 UPDATE 한 곳에 reviewed_by·reviewed_at 두 칸만
--   더한다. 그 외 로직·시그니처·주석·검증 흐름은 379 와 문자 단위로 같다.
--   reject_event_tickets 는 이미 맞으므로 손대지 않는다.
--
-- ── admin_name 조회 방식 — reject_event_tickets 와 동일하게 새로 추가 ────
--   379 의 pick_event_tickets 원본에는 관리자 이름을 조회하는 변수·SELECT
--   가 아예 없었다(신청 상태만 바꿨으므로 필요가 없었다). 이 재정의는
--   379 의 reject_event_tickets 가 쓰는 것과 똑같은 조회를 그대로 가져온다:
--     SELECT a.name INTO v_admin_name FROM public.admins a WHERE a.auth_id = v_uid;
--   폴백은 이 저장소 관례대로 '(이름미상)' — '관리자' 를 쓰지 않는다
--   (마이그레이션 128·144·145·167·168·178·302·323·324·327·379 가 이미
--   이 표기를 쓴다).
--
-- 🔴 배포 순서 경고 — 메일 함수를 먼저 배포한 뒤에 이 마이그레이션을 적용
--    한다 (반드시 이 순서. 반대로 하면 그 사이 구간에 행사 당선자에게
--    잘못된 메일이 나간다) ─────────────────────────────────────────
--   이 재정의로 pick_event_tickets 가 reviewed_at 을 채우는 순간, 다음날
--   아침 인플루언서 일일 다이제스트 메일(notify-influencer-daily-digest)의
--   당선 섹션 조회 문이 그 응모를 주워 담기 시작한다 — 그 조회는
--     status IN ('approved','rejected') AND reviewed_at 이 어제 KST 창
--   인 신청을 모은다(supabase/functions/notify-influencer-daily-digest/
--   index.ts:73-75). 379 적용 전에는 뽑기로 approved 된 신청의 reviewed_at
--   이 항상 NULL 이라 그 창에 걸릴 수가 없어서, 이 문제가 지금까지 조용히
--   가려져 있었다.
--
--   그 문을 막는 것은 별도 코드 — 같은 파일 675-698번째 줄 부근의
--   event_mode 제외 분기(「event_mode — 행사 캠페인은 당선 섹션에서 뺀다」,
--   2026-08-24 결정 3, 커밋 5d6cefbc)다. 이 필터는 event_mode=true 인
--   캠페인의 approved 신청을 당선 메일 대상에서 통째로 뺀다(방문형 응모는
--   결과물 제출도 보수도 없는데, 그 메일의 당선 섹션은 「報酬 -」와 결과물
--   제출 마감일을 담기 때문 — 방문객에게는 둘 다 사실이 아니다).
--
--   ⚠️ 그 필터가 든 Edge Function 배포는 **git 머지와 완전히 별개**다.
--   supabase/functions/* 는 `supabase functions deploy <함수명>` 을 사람이
--   따로 실행해야 실제로 반영된다(.claude/rules/supabase.md 「메일 발송
--   테스트 환경 정책」 — 이 저장소가 항상 그렇다). 코드가 저장소에
--   머지돼 있다는 사실은 그 함수가 실제로 배포됐다는 증거가 아니다.
--
--   🔴 따라서 순서가 정해져 있다:
--     1) 먼저 notify-influencer-daily-digest 를 배포한다
--        (`supabase functions deploy notify-influencer-daily-digest
--          --project-ref <해당 서버>`)
--     2) 그 배포가 실제로 반영된 것을 확인한 **뒤에** 이 마이그레이션을
--        적용한다
--   반대로 하면(이 마이그레이션이 먼저 들어가고 함수 배포가 늦어지면),
--   그 사이 구간에 뽑힌 행사 당선자에게 「報酬 -」(보수 -)와 결과물 제출
--   마감일이 든 메일이 실제로 나간다 — 방문객은 보수도 결과물도 없다.
--
--   ⚠️ 이 저장소는 정산 3단계에서 「버튼은 열렸는데 함수가 없던 15시간」을
--   겪었다(CLAUDE.md 「실제 송금 기록(3단계)」 항목, 2026-08-18~19 —
--   화면이 먼저 나가고 그 화면이 부르는 데이터베이스 함수가 다음 날에야
--   적용돼, 그 구간엔 눌러도 실패했을 뿐 다행히 실제 피해는 없었다).
--   이번은 **반대 방향**이다 — 데이터베이스 쪽(이 마이그레이션)이 먼저
--   들어가면 메일 함수는 이미 배포돼 있으므로 문제가 없고, **메일 함수가
--   나중인 채로 이 마이그레이션이 먼저 들어가면** 그 구간에 실제로 잘못된
--   메일이 발송된다. 정산 3단계는 "버튼이 실패했을 뿐"이었지만 이번은
--   "메일이 실제로 나간다"는 점에서 더 무겁다.
--
-- ── 알려진 한계 — 이 재정의는 감사 칸 2개만 채울 뿐, 그 값을 화면·엑셀이
--    어떻게 쓰는지는 바꾸지 않는다 ──────────────────────────────────
--   dev/js/admin-applications.js:168 의 formatReviewer(a.reviewed_by) 는
--   이미 reviewed_by 가 채워진 다른 모든 승인·반려 경로와 똑같은 방식으로
--   이 값을 그린다 — 별도 분기가 필요 없다.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.pick_event_tickets(
  p_ticket_ids uuid[]
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid              uuid := auth.uid();
  v_ids              uuid[];
  v_id               uuid;
  v_ticket           public.event_tickets%ROWTYPE;
  v_mode             text;
  v_inf_name         text;
  v_admin_name       text;
  v_invalid          jsonb := '[]'::jsonb;
  v_slot_ids         uuid[];
  v_slot_id          uuid;
  v_slot_row         public.event_slots%ROWTYPE;
  v_confirmed_cnt    integer;
  v_requested_cnt    integer;
  v_capacity_issues  jsonb := '[]'::jsonb;
  v_camp_title       text;
BEGIN
  IF v_uid IS NULL OR NOT public.is_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'permission_denied');
  END IF;

  IF p_ticket_ids IS NULL OR array_length(p_ticket_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_input');
  END IF;

  -- 중복 제거 + 오름차순 정렬(잠금 순서를 이 배열 순서 그대로 따른다).
  v_ids := ARRAY(SELECT DISTINCT unnest(p_ticket_ids) ORDER BY 1);

  -- [380] reject_event_tickets(379)와 같은 조회 — 신청 UPDATE 에 남길
  -- 처리자 이름. 379 의 pick_event_tickets 원본에는 없었다.
  SELECT a.name INTO v_admin_name FROM public.admins a WHERE a.auth_id = v_uid;

  -- ── 1단계: 대상 티켓을 오름차순으로 한 건씩 잠그며 개별 검증 ────────
  --   쓰기 전에 전수 확인부터 끝낸다(§2 ④ "부분 실패는 전부 거부"). 아직
  --   아무것도 UPDATE 하지 않았으므로 여기서 RETURN 해도 되돌릴 것이 없다.
  FOREACH v_id IN ARRAY v_ids LOOP
    SELECT * INTO v_ticket FROM public.event_tickets WHERE id = v_id FOR UPDATE;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'not_found', 'ticket_id', v_id);
    END IF;

    SELECT c.event_selection_mode INTO v_mode
      FROM public.campaigns c WHERE c.id = v_ticket.campaign_id;

    -- 선정형 캠페인의 티켓만 받는다(설계 0 서버 절반, 검증 7-B).
    IF v_mode IS DISTINCT FROM 'selection' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'not_selection_mode', 'ticket_id', v_id);
    END IF;

    IF v_ticket.status <> 'waitlist' THEN
      SELECT COALESCE(NULLIF(btrim(COALESCE(i.name_kanji, '')), ''), i.name, i.email)
        INTO v_inf_name
        FROM public.influencers i WHERE i.id = v_ticket.influencer_id;

      v_invalid := v_invalid || jsonb_build_array(jsonb_build_object(
        'ticket_id',       v_id,
        'influencer_name', v_inf_name,
        'reason', CASE v_ticket.status
                    WHEN 'confirmed' THEN 'already_confirmed'
                    WHEN 'cancelled' THEN 'already_cancelled'
                    ELSE 'invalid_status'
                  END
      ));
    END IF;
  END LOOP;

  IF jsonb_array_length(v_invalid) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_tickets', 'tickets', v_invalid);
  END IF;

  -- ── 2단계: 관련 타임을 오름차순으로 한 건씩 잠그고 정원을 확인 ──────
  --   타임 잠금은 반드시 티켓 잠금 **뒤에** 한다(파일 헤더 「교착 방지」).
  v_slot_ids := ARRAY(
    SELECT DISTINCT t.slot_id FROM public.event_tickets t
     WHERE t.id = ANY(v_ids)
     ORDER BY t.slot_id
  );

  FOREACH v_slot_id IN ARRAY v_slot_ids LOOP
    SELECT * INTO v_slot_row FROM public.event_slots WHERE id = v_slot_id FOR UPDATE;

    -- 이미 확정된 수(잠근 뒤에 다시 세므로 동시 처리와 안전하게 직렬화된다)
    SELECT count(*) INTO v_confirmed_cnt
      FROM public.event_tickets t
     WHERE t.slot_id = v_slot_id AND t.status = 'confirmed';

    -- 이번 요청에서 이 타임으로 뽑으려는 수
    SELECT count(*) INTO v_requested_cnt
      FROM public.event_tickets t
     WHERE t.slot_id = v_slot_id AND t.id = ANY(v_ids);

    IF v_confirmed_cnt + v_requested_cnt > v_slot_row.capacity THEN
      v_capacity_issues := v_capacity_issues || jsonb_build_array(jsonb_build_object(
        'slot_id',          v_slot_id,
        'slot_date',        v_slot_row.slot_date,
        'start_time',       v_slot_row.start_time,
        'capacity',         v_slot_row.capacity,
        'already_confirmed', v_confirmed_cnt,
        'requested',        v_requested_cnt,
        'remaining',        GREATEST(v_slot_row.capacity - v_confirmed_cnt, 0)
      ));
    END IF;
  END LOOP;

  -- 정원 초과는 전부 거부 — 누구·어느 타임 때문인지 돌려준다(확정 6).
  IF jsonb_array_length(v_capacity_issues) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'capacity_exceeded', 'slots', v_capacity_issues);
  END IF;

  -- ── 3단계: 통과 — 실제 확정 처리 ───────────────────────────────
  -- [289] 이 UPDATE 두 건(티켓·신청)이 신청 상태 변경 차단 트리거를
  -- 지나가려면 반드시 이 표시가 먼저 서 있어야 한다(317 파일 헤더가 같은
  -- 함정을 기록 — 안 세우면 뽑기 전체가 롤백된다).
  PERFORM set_config('reverb.event_ticket_bypass', 'on', true);

  UPDATE public.event_tickets
     SET status            = 'confirmed',
         waitlist_position = NULL,
         version           = version + 1
   WHERE id = ANY(v_ids);

  -- [380] reviewed_by·reviewed_at 추가 — 떨어뜨리기(379 의
  -- reject_event_tickets)는 이미 채우는데 뽑기만 안 채워서, 행사 당선자만
  -- 「누가 언제 승인했나」가 관리자 신청 관리 화면에 비어 있었다
  -- (dev/js/admin-applications.js:168 formatReviewer). 폴백은 이 저장소
  -- 관례대로 '(이름미상)'.
  UPDATE public.applications a
     SET status      = 'approved',
         reviewed_by = COALESCE(v_admin_name, '(이름미상)'),
         reviewed_at = now()
    FROM public.event_tickets t
   WHERE t.id = ANY(v_ids) AND t.application_id = a.id;

  -- ── 당선 알림 — 확정된 티켓마다(확정 4). 실패해도 확정 자체는 되돌리지
  --   않는다(283·288·317 원문과 같은 판단 — "알림은 못 갔지만 당선은
  --   확정됐다"가 반대 경우보다 낫다).
  FOR v_ticket IN SELECT * FROM public.event_tickets WHERE id = ANY(v_ids) LOOP
    BEGIN
      SELECT * INTO v_slot_row FROM public.event_slots WHERE id = v_ticket.slot_id;
      SELECT c.title INTO v_camp_title FROM public.campaigns c WHERE c.id = v_ticket.campaign_id;

      INSERT INTO public.notifications (
        user_id, kind, ref_table, ref_id, title, body
      ) VALUES (
        v_ticket.influencer_id,
        'event_selection_won',
        'event_tickets',
        v_ticket.id,
        '当選のお知らせ',
        COALESCE(v_camp_title, 'イベント')
          || 'に当選しました。'
          || to_char(v_slot_row.slot_date, 'MM月DD日')
          || ' ' || to_char(v_slot_row.start_time, 'HH24:MI')
          || ' にご来場ください。入場チケットからQRコードをご確認いただけます。'
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok',              true,
    'confirmed_count', array_length(v_ids, 1),
    'ticket_ids',      to_jsonb(v_ids)
  );
END;
$$;

COMMENT ON FUNCTION public.pick_event_tickets(uuid[]) IS
  '[380, 베이스 379] 관리자 전용. 선정형 행사 캠페인에서 심사중(waitlist)인 '
  '티켓들을 지목해 한 번에 당선(confirmed)으로 확정한다. 짝이 되는 신청도 '
  'approved 로 바꾸며 이번에 reviewed_by(처리자 이름, 없으면 (이름미상))·'
  'reviewed_at(now())도 함께 채운다(380 — 379 원본은 이 두 칸을 안 채워 '
  '행사 당선자만 관리자 신청 관리 화면의 처리자 표시가 비어 있었다). 당선 '
  '알림(event_selection_won, 376)도 티켓마다 발송. 타임을 오름차순으로 '
  '잠근 뒤 정원(확정 수 + 이번 요청 수 ≤ capacity)을 확인해 넘치면 전부 '
  '거부하고 어느 타임에서 몇 명이 넘쳤는지 반환한다(부분 통과 없음). '
  '선정형이 아닌 캠페인의 티켓·이미 확정·취소된 티켓·존재하지 않는 티켓은 '
  '각각 다른 reason 으로 거부. 실패는 예외가 아니라 {ok:false, reason:...}. '
  '승격 함수(_promote_next_event_waitlist 등)는 부르지 않는다 — 선정형은 '
  '순번이 없다(378).';

REVOKE ALL ON FUNCTION public.pick_event_tickets(uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pick_event_tickets(uuid[]) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pick_event_tickets(uuid[]) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 (1단계씩 — 결과 확인 후 다음 단계로. .claude/rules/supabase.md
-- 「SQL 검증 순차 안내」)
-- ============================================================
--
-- 🔴 [0단계 — 적용 전, 반드시 먼저] notify-influencer-daily-digest 의
--   event_mode 제외 필터가 실제로 배포돼 있는지 확인한다. 코드가 저장소에
--   있다는 사실은 배포 증거가 아니다(파일 헤더 「배포 순서 경고」).
--   확인 방법 — 배포된 함수 자체를 내려받아 그 필터 코드가 들어있는지
--   grep 한다(대시보드 UI 로도 같은 내용을 볼 수 있지만 CLI 가 재현 가능):
--     supabase functions download notify-influencer-daily-digest \
--       --project-ref <해당 서버 project ref>
--     grep -n "event_mode === true" \
--       supabase/functions/notify-influencer-daily-digest/index.ts
--   → 안 나오면(또는 다운로드된 코드가 이 저장소의 최신 버전과 다르면)
--     이 마이그레이션을 적용하지 말고 먼저
--     `supabase functions deploy notify-influencer-daily-digest --project-ref <해당 서버>`
--     를 실행한다. 그 배포가 끝난 뒤에만 아래 [1단계]로 넘어간다.
--
-- [1단계] 함수가 오버로드 없이 재정의됐는지 (SQL 편집기, 서비스 키로 실행
--   가능 — 로그인 세션 불필요)
-- SELECT p.oid::regprocedure AS signature
--   FROM pg_proc p
--  WHERE p.pronamespace = 'public'::regnamespace
--    AND p.proname = 'pick_event_tickets';
--   → 1건: pick_event_tickets(uuid[])
--
-- [2단계] 실행 권한 — 두 방향(PUBLIC·anon)이 여전히 회수돼 있는지.
--   ⚠️ has_function_privilege 만 보면 방향을 구분 못 한다. proacl 의 맨 앞
--   "=X/" 유무를 함께 볼 것(있으면 PUBLIC 에게도 권한이 남아 있다는 뜻 —
--   있으면 안 된다).
-- SELECT p.proname,
--        p.proacl::text AS acl,
--        has_function_privilege('anon', p.oid, 'EXECUTE')          AS anon_can,
--        has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authed_can
--   FROM pg_proc p
--  WHERE p.pronamespace = 'public'::regnamespace
--    AND p.proname = 'pick_event_tickets';
--   → acl 에 "=X/" 없음, anon_can=false, authed_can=true (379 적용 직후와
--     동일해야 한다 — 이 재정의로 달라지면 안 된다)
--
-- [3단계] 🔴 관리자 가드가 걸려 있어 SQL 편집기(서비스 키)로는 실제 동작을
--   재현할 수 없다 — auth.uid() 가 비어 있어 permission_denied 로만 답한다.
--   여기서부터는 개발서버에 준비한 시험 캠페인(비공개+선정형, T2)과
--   실제 로그인한 관리자 브라우저 콘솔에서 확인한다:
--
--   const {data} = await db.rpc('pick_event_tickets', {p_ticket_ids: ['<waitlist 티켓 id>']});
--   console.log(data);
--     → {ok:true, confirmed_count:1, ticket_ids:[...]}
--
--   -- 🔴 검증 A(이번 재정의의 핵심): 뽑힌 신청의 reviewed_by·reviewed_at
--   --   이 채워졌는지 — 관리자 브라우저 콘솔에서 로그인한 그 관리자
--   --   이름이 reviewed_by 에 그대로 들어갔는지 확인
--   SELECT id, status, reviewed_by, reviewed_at
--     FROM public.applications
--    WHERE id IN (
--      SELECT application_id FROM public.event_tickets WHERE id = '<위 티켓 id>'
--    );
--     → status='approved', reviewed_by='<로그인한 관리자 이름>' (admins.name
--       이 비어 있으면 '(이름미상)'), reviewed_at NOT NULL
--
--   -- 검증 B: admin-applications.js 화면의 신청 목록에서 이 신청 행의
--   --   「검수자」 칸에 위 이름이 실제로 그려지는지 눈으로 확인
--   --   (formatReviewer(a.reviewed_by), dev/js/admin-applications.js:168)
--
--   -- 검증 C(379 회귀 확인 — 이 재정의가 다른 걸 안 건드렸는지):
--   --   여러 명을 한 번에 뽑아도 전부 confirmed + 짝 신청 approved +
--   --   notifications 에 event_selection_won 이 인원 수만큼 생기는지
--   SELECT id, status, waitlist_position FROM public.event_tickets WHERE id = ANY(ARRAY['<id1>','<id2>']::uuid[]);
--   SELECT kind, ref_id, title FROM public.notifications WHERE kind='event_selection_won' ORDER BY created_at DESC LIMIT 5;
--
--   -- 검증 D(379 회귀 확인): 정원을 넘겨 뽑으면 여전히 전부 거부되는지
--   const r = await db.rpc('pick_event_tickets', {p_ticket_ids: ['<정원 넘게 고른 waitlist id 여러 개>']});
--   console.log(r.data);
--     → {ok:false, reason:'capacity_exceeded', slots:[{slot_id,...,remaining:N}]}
--
--   -- 검증 E(379 회귀 확인): 선착순형 캠페인의 티켓을 넣으면 여전히 거부되는지
--   const r2 = await db.rpc('pick_event_tickets', {p_ticket_ids: ['<선착순형 confirmed/waitlist 티켓 id>']});
--   console.log(r2.data);  -- → {ok:false, reason:'not_selection_mode', ticket_id:...}
--
--   -- 🔴 검증 F(다음날 아침 메일 대상에서 실제로 빠지는지): 발송 없이
--   --   확인하려면 같은 조건을 데이터로 재현한다(2026-08-07 마감 안내
--   --   검증에서 쓴 방법과 동일 — 개발서버 실제 발송 금지,
--   --   .claude/rules/supabase.md). 위 검증 A 의 reviewed_at 이 어제 KST
--   --   09:00 이전 창에 들어오는 값이면서, 그 캠페인이 event_mode=true 인지
--   --   함께 확인:
--   SELECT a.id, a.status, a.reviewed_at, c.event_mode,
--          a.reviewed_at >= (date_trunc('day', now() AT TIME ZONE 'Asia/Seoul') - interval '1 day') AT TIME ZONE 'Asia/Seoul'
--            AND a.reviewed_at < date_trunc('day', now() AT TIME ZONE 'Asia/Seoul') AT TIME ZONE 'Asia/Seoul'
--            AS in_yesterday_window
--     FROM public.applications a
--     JOIN public.campaigns c ON c.id = a.campaign_id
--    WHERE a.id = '<위 신청 id>';
--     → event_mode=true 이고 in_yesterday_window=true 인 채로도, 실제
--       발송 시 메일 함수의 event_mode 제외 분기가 이 신청을 당선 섹션에서
--       뺀다(0단계에서 확인한 배포된 필터가 이 역할을 한다).
--
-- ============================================================
-- 롤백
-- ============================================================
-- ⚠️ 되돌려도 이미 뽑기로 채워진 reviewed_by·reviewed_at 값은 그대로
--    남는다 — DROP/재생성은 함수 정의만 되돌릴 뿐 이미 UPDATE 된 신청
--    행의 값을 지우지 않는다. 되돌린 뒤 그 값이 실제로 남아 있어도
--    되는지(감사 기록으로는 오히려 남는 편이 맞다) 판단은 사람이 한다.
--
-- BEGIN;
-- -- 379 원본으로 되돌리기 — reviewed_by·reviewed_at 관련 3줄만 뺀 채
-- -- 379 파일의 pick_event_tickets 정의 전체를 그대로 다시 실행한다.
-- -- (이 파일 자체에는 379 원본 전문을 중복 보관하지 않는다 —
-- --  379_event_selection_pick_reject.sql 을 그대로 다시 CREATE OR REPLACE.)
-- COMMIT;
--
-- NOTIFY pgrst, 'reload schema';
