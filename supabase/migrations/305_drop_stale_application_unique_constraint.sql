-- ============================================================
-- 305_drop_stale_application_unique_constraint.sql
-- 「취소 후 재응모」를 도입 이래 막아 온 옛 유일 제약 제거
-- 사양서: (조사 요청 응답 — 별도 사양서 없음, 이 파일 헤더가 근거 문서)
--
-- ── 무엇이 잘못되어 있었나 ─────────────────────────────────────
--   applications 표에는 유일 제약이 **둘** 있다.
--     ① uidx_applications_user_campaign  (마이그레이션 050) — 취소 여부와
--        무관하게 "1인 1캠페인 1건". 가장 엄격함.
--     ② applications_user_camp_active_uidx (마이그레이션 104) —
--        WHERE status <> 'cancelled' — 취소된 행은 제외하고 "활성 행 1건"만
--        허용. 마이그레이션 104는 "취소 후 재응모를 허용한다"는 의도로
--        ①을 지우고 ②로 **교체**하려 했다.
--
--   그런데 104는 지울 이름을 PostgreSQL 자동 명명 규칙 이름
--   (`applications_user_id_campaign_id_key`)으로 적었다. 실제 이름은 050이
--   직접 지은 `uidx_applications_user_campaign`이었기 때문에
--   `DROP CONSTRAINT IF EXISTS`가 "그런 이름 없음 → 조용히 통과"로 끝나고,
--   ①은 오늘까지 살아 있었다. 더 엄격한 ①이 항상 먼저 걸리므로 ②는 도입
--   이래 한 번도 효과를 낸 적이 없다 — "취소한 캠페인에 재응모 가능"은
--   CLAUDE.md에 적힌 서술과 달리 실제로는 한 번도 동작하지 않았다.
--
--   운영 실측(2026-07-31): 지금 이 결함으로 막혀 있는 사람 0명. 취소
--   이력이 있는 캠페인은 전부 마감됐고 마지막 취소는 2026-05-12. 활성
--   피해가 0인 지금이 고치기 가장 안전한 시점이라고 판단했다.
--
-- ── 지운 뒤 무엇이 달라지나 ────────────────────────────────────
--   앞으로는 ②(활성 행만 유일)만 남는다. 즉 같은 사람이 같은 캠페인에
--   "취소된 옛 행 + 새 활성 행" 두 줄을 가질 수 있게 된다 — 이 플랫폼에
--   지금까지 한 번도 없었던 데이터 모양이다.
--
--   조사 결과(코드 전수 확인, 이 파일 작성 세션) 이 데이터 모양을 이미
--   전제하고 짜여 있는 곳과, 전제 없이도 안전한 곳만 있었다. **깨지는
--   곳은 발견되지 않았다.**
--     · dev/js/application.js (신청 여부 조회), dev/lib/storage.js
--       (checkDuplicateApplication) — 이미 `.neq('status','cancelled')`로
--       필터링 후 `.maybeSingle()`을 쓰고 있어 여러 행이 생겨도 활성 행
--       하나만 정확히 집힌다(104 작성 당시부터 이 모양을 전제하고 짜여
--       있었다 — 정작 막고 있던 건 이 제약 자체였다).
--     · recompute_campaign_applied_count / check_monitor_slots (058·179) —
--       status IN ('pending','approved') 필터라 취소 행은 자동 제외.
--     · buildDeliverableGroups(admin-deliverables.js) · 엑셀 내보내기
--       (admin-excel.js) — 전부 application_id 단위로 그룹핑. 사람 단위가
--       아니라 "신청 건" 단위라 옛 행·새 행이 섞이지 않는다.
--     · settlements — application_id UNIQUE + 정산 후보 조건이
--       `a.status='approved'` 라 취소 행은 애초에 후보에도 안 들어온다.
--     · event_tickets(마이그레이션 282~288)의 재예약 되살리기 로직
--       (`SELECT id INTO v_app_id FROM applications WHERE user_id=...
--       AND campaign_id=...`, 상태 필터 없음) — 이 조회 자체는 status를
--       안 가리지만, 행사 캠페인의 신청 행은 이 함수 계열(reserve/cancel/
--       admin-cancel)로만 만들어지고 절대 일반 응모 경로(insertApplication)
--       를 안 타므로(dev/js/application.js가 event_mode 캠페인을 분기해
--       submitEventReservation으로 보낸다) 실제로는 사람당 항상 최대 1행만
--       존재한다 — ①을 지워도 이 전제는 바뀌지 않는다.
--       ⚠️ 단, RLS의 INSERT 정책(applications_insert_own)은
--       `auth.uid()=user_id`만 검사해 어떤 캠페인이든 직접 INSERT를 막지
--       않는다. 브라우저 콘솔로 행사 캠페인에 신청 행을 직접 꽂는 등
--       우회를 하면 이 함수의 무정렬 단일 조회가 "취소된 옛 행"과
--       "우회로 만든 새 행" 중 임의의 하나를 되살릴 수 있다 — 이는 ①이
--       있어도 있던 별개의 기존 취약점(정원·초대코드 우회)의 연장선이라
--       이번 변경이 새로 만드는 위험은 아니다. 필요하면 후속으로
--       `SELECT id INTO v_app_id ... ORDER BY created_at DESC LIMIT 1`
--       추가를 검토할 것(이번 마이그레이션 범위 밖 — 적용하지 않음).
--
--   부수적으로 확인된 것(막힌 건 아님, 참고): 관리자 "캠페인별 신청자"
--   화면 상단 "신청 N명" 숫자는 취소 이력 행도 셈에 포함해(신청 row
--   개수 기준) 재응모 이력이 있는 사람은 그 카드에서 "N명"에 2번
--   반영된다. 승인·심사중 숫자는 활성 행만 집계해 영향 없다. 화면 표시
--   방식은 이번 마이그레이션 범위 밖(요청에 따라 화면 코드는 손대지
--   않음) — 필요하면 별도 사양서로.
--
-- ── 왜 이번에도 "지웠다고 믿지 않는다" ─────────────────────────
--   이번 결함 자체가 "IF EXISTS가 오타를 삼켰다"였다. 같은 실수를
--   되풀이하지 않기 위해, 이 마이그레이션은 DROP 직후 pg_constraint를
--   직접 조회해 **정말 없어졌는지 트랜잭션 안에서 스스로 검증**하고,
--   실패하면 RAISE EXCEPTION으로 전체를 롤백한다. "성공한 것처럼 보이는
--   실패"를 남기지 않는다.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

-- ── 0. 사전 조건 확인 — 재응모를 지탱할 새 부분 유일 색인이 실제로
--       있는지 먼저 확인한다. 이게 없는 채로 옛 제약만 지우면 같은
--       사람이 같은 캠페인에 활성 행을 여러 개 가질 수 있게 되어(중복
--       응모 완전 무방비) 더 나쁜 상태가 된다 — 반드시 먼저 확인.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
     WHERE schemaname = 'public'
       AND tablename  = 'applications'
       AND indexname  = 'applications_user_camp_active_uidx'
  ) THEN
    RAISE EXCEPTION
      '중단: applications_user_camp_active_uidx(마이그레이션 104) 색인이 없습니다. '
      '이 색인이 없으면 옛 제약을 지웠을 때 중복 응모를 막을 수단이 전혀 남지 '
      '않으므로 진행하지 않습니다.';
  END IF;
END $$;

-- ── 1. 옛 제약 제거 (진짜 이름으로) ────────────────────────────
--    이번엔 자동 명명 규칙 이름이 아니라 050이 실제로 지은 이름을 쓴다.
ALTER TABLE public.applications
  DROP CONSTRAINT IF EXISTS uidx_applications_user_campaign;

-- ── 2. 트랜잭션 내부 자기 검증 — "지웠다"를 코드가 직접 증명한다 ──
--    104의 실패 패턴(이름을 잘못 적어 DROP이 조용히 통과)이 반복되지
--    않았는지, 지운 직후 pg_constraint를 다시 조회해 확인한다.
DO $$
DECLARE
  v_still_exists boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'public.applications'::regclass
       AND conname  = 'uidx_applications_user_campaign'
  ) INTO v_still_exists;

  IF v_still_exists THEN
    RAISE EXCEPTION
      '중단: uidx_applications_user_campaign 제약이 DROP 이후에도 여전히 '
      '존재합니다. 마이그레이션 104와 같은 실패 패턴(이름 불일치로 DROP이 '
      '조용히 무효화)이 재현됐을 가능성이 있습니다 — 즉시 원인을 확인하세요.';
  END IF;

  -- 새 부분 유일 색인은 이번 작업으로 건드리지 않았지만, 같은 트랜잭션
  -- 안에서 "여전히 있다"를 한 번 더 확인해 둔다 — 방어적 이중 확인.
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
     WHERE schemaname = 'public'
       AND tablename  = 'applications'
       AND indexname  = 'applications_user_camp_active_uidx'
  ) THEN
    RAISE EXCEPTION
      '중단: applications_user_camp_active_uidx 색인이 트랜잭션 도중 사라졌습니다.';
  END IF;
END $$;

COMMIT;

-- ============================================================
-- 검증 (마이그레이션 실행 후 SQL 편집기에서 확인용 — COMMIT까지 이미
-- 성공했다면 위 DO 블록이 통과했다는 뜻이라 사실 아래는 "다시 눈으로
-- 확인"하는 절차다. 여러 단계이므로 한 번에 다 실행하지 말고 1번부터
-- 순서대로 결과를 확인하며 진행할 것)
-- ============================================================
--
-- 1) applications 표에 남아 있는 유일 제약·색인 전수 확인
--    → uidx_applications_user_campaign 는 목록에 없어야 하고,
--      applications_user_camp_active_uidx 는 있어야 한다(partial, 정의문에
--      "WHERE" 절 포함).
-- SELECT conname, contype, pg_get_constraintdef(oid) AS def
--   FROM pg_constraint
--  WHERE conrelid = 'public.applications'::regclass
--  ORDER BY conname;
--
-- SELECT indexname, indexdef
--   FROM pg_indexes
--  WHERE schemaname='public' AND tablename='applications'
--    AND indexdef ILIKE '%UNIQUE%'
--  ORDER BY indexname;
--
-- 2) 실제로 "취소 후 재응모"가 되는지 (개발 데이터베이스, 테스트 계정)
--    ① 테스트 인플루언서로 아무 캠페인에 응모 (INSERT 성공 확인)
--    ② 그 응모를 cancel_application RPC로 취소 (status='cancelled')
--    ③ 같은 캠페인에 다시 응모 (INSERT가 이번엔 성공해야 한다 — 이전에는
--       23505 unique_violation으로 실패하던 지점)
--    ④ applications 에서 그 (user_id, campaign_id) 로 조회 → 2행이어야
--       한다(취소 1건 + 새 응모 1건)
--    SELECT id, status, cancelled_at, created_at
--      FROM public.applications
--     WHERE user_id = '<테스트 인플루언서 id>'
--       AND campaign_id = '<테스트 캠페인 id>'
--     ORDER BY created_at;
--
-- 3) 같은 캠페인에 "활성 행 2개"는 여전히 막히는지 (중복 응모 방지 유지 확인)
--    ②에서 되살린 새 응모(pending) 상태에서 세 번째 응모를 시도 →
--    applications_user_camp_active_uidx 위반으로 거부돼야 한다.
--    (화면에서는 friendlyErrorJa 가 「이미 응모하셨습니다」 류 안내로 바꿔
--    보여준다 — dev/js/ui.js 는 이미 두 제약 이름을 모두 정규식에 넣어
--    두어서 코드 수정 없이도 계속 정상 동작한다)
--
-- ============================================================
-- 롤백
-- ============================================================
-- ⚠️ 옛 제약을 되살리면 "취소 후 재응모"가 다시 원천 차단된다(도입 이래
--    있던 상태로 되돌아감). 되살리기 전에 그 시점 이후 새로 생긴 재응모
--    데이터(같은 user_id+campaign_id 조합의 활성 행이 2개 이상 존재하는
--    경우는 없다는 게 전제이므로, 취소+활성 조합만 있다면 문제없이
--    되살릴 수 있다)가 있는지 먼저 아래로 확인:
--
-- SELECT user_id, campaign_id, COUNT(*) AS row_cnt,
--        COUNT(*) FILTER (WHERE status <> 'cancelled') AS active_cnt
--   FROM public.applications
--  GROUP BY user_id, campaign_id
-- HAVING COUNT(*) > 1;
--   → active_cnt 가 모두 1 이하면 롤백 가능(옛 제약 위반 없음).
--     active_cnt 가 2 이상인 조합이 있으면 그 표부터 정리해야 롤백된다.
--
-- BEGIN;
-- ALTER TABLE public.applications
--   ADD CONSTRAINT uidx_applications_user_campaign
--   UNIQUE (user_id, campaign_id);
-- COMMIT;
-- ============================================================
