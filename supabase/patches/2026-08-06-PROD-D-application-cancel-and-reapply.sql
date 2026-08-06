-- ═══════════════════════════════════════════════════════════════
-- 운영 배포 묶음 D — 응모 취소 정상화 + 재응모 허용 (마이그레이션 305·306)
-- 만든 날짜: 2026-08-06
--
-- 이 묶음은 오프라인 팝업·정산과 **무관한 별개 결함 두 건**입니다.
-- 다른 묶음(A·B·C)과 순서 의존이 없어 언제 실행해도 됩니다.
--
-- ⚠️ 306 은 **3개월간 완전히 죽어 있던 기능을 되살립니다.**
--    인플루언서의 「응모 취소」가 2026-05-12 저녁부터 모든 호출에서 실패했고,
--    오류가 화면에서 일반 문구로 덮여 관리자 오류 로그에도 흔적이 없었습니다.
--    적용 즉시 취소가 다시 동작합니다.
--
-- ⚠️ 305 는 「취소한 캠페인에 다시 응모」를 처음으로 가능하게 합니다.
--    적용 뒤에는 **같은 사람·같은 캠페인에 여러 줄**(취소된 옛 줄 + 새 줄)이
--    생길 수 있습니다. 관리자 신청자 목록에 같은 사람이 두 번 보이는 것은
--    정상이며, 응모 수 집계는 취소된 줄을 세지 않습니다(개발서버 검증 완료).
--
-- 코드 배포와의 관계: **화면 코드 변경 없음.** 이 SQL 만으로 완결됩니다.
-- ═══════════════════════════════════════════════════════════════

-- ============================================================
-- [1/2] 305 — 옛 응모 중복 제약 제거
-- ============================================================
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

-- ============================================================
-- [2/2] 306 — cancel_application 인플루언서 조회 칸 정정
-- ============================================================
-- ════════════════════════════════════════════════════════════════════
-- migration 306: 본인 응모 취소(cancel_application) 완전 장애 긴급 수정
-- ────────────────────────────────────────────────────────────────────
-- ── 무엇이 잘못되어 있었나 ─────────────────────────────────────────
--   마이그레이션 113(2026-05-12 18:16 커밋)이 cancel_application 을
--   재정의하면서 아래 줄을 추가했다:
--
--     SELECT * INTO v_influencer FROM public.influencers WHERE auth_id = v_app.user_id;
--
--   그런데 public.influencers 표에는 auth_id 라는 칸이 없다. 그 표는
--   id 칸 자체가 로그인 계정 식별자(= auth.users.id)다(다른 여러
--   마이그레이션 주석에도 반복 기록된 사실 — 153·167 참조). 그 결과
--   이 SELECT 문이 실행되는 순간 PostgreSQL이
--   `column "auth_id" does not exist`(오류코드 42703)를 던지고
--   cancel_application 함수 전체가 실패한다.
--
--   즉 **2026-05-12 저녁 배포 이후 오늘까지 약 3개월간, 인플루언서가
--   스스로 응모를 취소하는 기능이 100% 실패했다.** 캠페인 상태·결과물
--   승인 여부 등 취소 판정 로직 자체는 멀쩡하고, 딱 이 한 줄(관리자
--   공지 본문에 인플루언서 이름·이메일을 넣기 위한 조회)에서만 죽는다.
--
--   실측 근거:
--     · 개발·운영 데이터베이스 양쪽 public.influencers 에 auth_id 칸 0개
--     · 운영 마지막 성공 취소 시각 = 2026-05-12 10:14(마이그레이션 113
--       배포 이전) — 그 뒤로 성공 취소 0건
--     · 개발서버에서 cancel_application 을 실제로 호출해
--       "column \"auth_id\" does not exist" 재현 완료
--
-- ── 왜 3개월간 아무도 몰랐나 (코드 조사 결과, 참고용 — 이 마이그레이션은
--    DB 함수만 고친다. 아래 화면 쪽 개선은 범위 밖) ──────────────────
--   1. dev/lib/storage.js 의 cancelApplication() 이 RPC 오류를 try/catch
--      로 직접 삼켜 {ok:false, error: e.message} 로 "정상 반환"한다.
--      즉 이 오류는 한 번도 "처리되지 않은 예외"인 적이 없어
--      window.onerror·unhandledrejection 훅(마이그레이션 165 오류 수집)에
--      걸리지 않는다.
--   2. dev/js/mypage.js 의 submitCancelApplicationFromPage() 는 이 오류를
--      화면에 보여줄 때 friendlyErrorJa() 를 거치지 않고 자체 정적
--      매핑(errKey 사전)만 사용한다. friendlyErrorJa() 는 내부에서
--      collectClientError() 를 호출해 "처리된 에러"도 관리자 오류 로그로
--      보내는데(ui.js:129), 이 경로는 그 함수를 아예 호출하지 않으므로
--      매핑에 없는 이 오류는 어디에도 기록되지 않고 조용히
--      「取消に失敗しました。再度お試しください」(일반 실패 안내)만
--      떴다. 인플루언서 입장에서는 "다시 시도해도 안 되는 일반 오류"로만
--      보였을 것이다.
--   3. 참고: 마이그레이션 305(취소 후 재응모 옛 유일 제약 정리, 별도
--      결함)가 "운영 마지막 취소 2026-05-12" 라는 같은 사실을 이미
--      기록해 두었으나, 그 세션은 이를 "취소 자체는 되지만 재응모만
--      막혀 있다"는 다른 결함으로 진단했다. 실제로는 그 시점부터
--      취소 자체가 안 됐던 것 — 두 결함이 겹쳐 있었을 뿐 서로 다른
--      원인이다(마이그레이션 305는 이 결함과 무관하게 유효).
--
-- ── 수정 내용 ────────────────────────────────────────────────────────
--   재정의 베이스 확인: cancel_application 을 재정의하는 마이그레이션은
--   104(원본)·113(현재까지 가장 최근 정의) 뿐이다(전 파일 grep 확인,
--   113 이후 306 이전 재정의 없음). 113 본문을 그대로 베이스로 삼고
--   93번째 줄 한 곳만 고친다: auth_id = v_app.user_id → id = v_app.user_id
--
--   그 외 판정 로직(본인 검증·상태 검증·결과물 승인 차단·cancel_phase
--   도출·사유/동의 강제·admin_notices 발송)은 113과 100% 동일 — 이
--   부분들은 이미 정상 동작하던 로직이라 손대지 않는다.
--
--   ⚠️ v_influencer 를 못 찾는 경우(이론상 응모 행이 있으면 인플루언서
--   행도 항상 있어야 하지만) 방어: plpgsql의 SELECT ... INTO 는(STRICT
--   가 아니므로) 0행이어도 예외를 던지지 않고 전체 NULL 로우를 담을
--   뿐이다. 아래에서 이름·이메일은 이미 COALESCE 로 감싸여 있어
--   NULL 이어도 공지 본문 조립·취소 자체는 계속 성공한다 — 별도
--   방어 코드 추가가 필요 없다(113 원본이 이미 안전하게 짜여 있었다).
--
-- ── 영향 범위 ─────────────────────────────────────────────────────
--   cancel_application(uuid, text, text, boolean) 함수 재정의 1건뿐.
--   테이블·색인·트리거·행 단위 보안 정책 변경 없음. 마이그레이션
--   305(유일 제약 정리)와 서로 독립적 — 순서 무관하게 적용 가능.
--
-- ROLLBACK:
--   -- 113 본문으로 CREATE OR REPLACE 복원(= auth_id 버그가 있는
--   -- 상태로 되돌리는 것과 같음. 되돌릴 이유가 없으므로 권장하지 않음.
--   -- 굳이 되돌려야 한다면 113_application_cancel_digest_infra.sql
--   -- 의 CREATE OR REPLACE FUNCTION 블록을 그대로 재실행할 것.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.cancel_application(
  p_application_id  uuid,
  p_reason_code     text DEFAULT NULL,
  p_reason_note     text DEFAULT NULL,
  p_acknowledged    boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_app             public.applications%ROWTYPE;
  v_campaign        public.campaigns%ROWTYPE;
  v_influencer      public.influencers%ROWTYPE;
  v_phase           text;
  v_phase_ko        text;
  v_recruit_type_ko text;
  v_reason_label    text;
  v_deliv_approved  boolean;
  v_notice_title    text;
  v_notice_body     text;
  v_supplement_html text;

  -- 내부 escape 매크로용 임시 변수 (replace 체인 가독성 보강)
  -- admin_notices.body_html 는 클라이언트에서 다시 DOMPurify 통과시키지만,
  -- 방어 깊이 차원에서 서버 단에서도 1차 escape — DB값(캠페인/이름/사유)에
  -- 무언가 비정상 텍스트가 섞였을 때 onerror= 등 이벤트 속성 주입 차단.
  v_campaign_no_esc    text;
  v_campaign_title_esc text;
  v_influencer_name    text;
  v_influencer_email   text;
  v_reason_label_esc   text;
BEGIN
  -- 1. 신청 행 잠금 + 본인 검증
  SELECT * INTO v_app
  FROM public.applications
  WHERE id = p_application_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'application_not_found' USING ERRCODE = '22023';
  END IF;

  IF v_app.user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'not_owner' USING ERRCODE = '42501';
  END IF;

  -- 2. 상태 검증
  IF v_app.status NOT IN ('pending','approved') THEN
    RAISE EXCEPTION 'invalid_status' USING ERRCODE = '22023';
  END IF;

  -- 3. 결과물 1건이라도 승인됐으면 차단
  SELECT EXISTS (
    SELECT 1 FROM public.deliverables
    WHERE application_id = p_application_id AND status = 'approved'
  ) INTO v_deliv_approved;

  IF v_deliv_approved THEN
    RAISE EXCEPTION 'deliverable_already_approved' USING ERRCODE = '22023';
  END IF;

  -- 4. 캠페인 / 인플루언서 조회 (cancel_phase 도출 + admin_notices 본문 빌드)
  --    [마이그레이션 306] influencers 는 id 자체가 로그인 계정 식별자다.
  --    auth_id 라는 칸은 애초에 존재하지 않는다(113의 원인 결함 수정).
  SELECT * INTO v_campaign   FROM public.campaigns   WHERE id = v_app.campaign_id;
  SELECT * INTO v_influencer FROM public.influencers WHERE id = v_app.user_id;

  -- 5. cancel_phase 도출 (104 와 동일 로직 유지)
  v_phase := CASE
    WHEN v_campaign.purchase_start IS NOT NULL
         AND now() >= v_campaign.purchase_start::timestamptz
         AND (v_campaign.purchase_end IS NULL OR now() <= v_campaign.purchase_end::timestamptz) THEN 'purchase'
    WHEN v_campaign.visit_start IS NOT NULL
         AND now() >= v_campaign.visit_start::timestamptz
         AND (v_campaign.visit_end IS NULL OR now() <= v_campaign.visit_end::timestamptz) THEN 'visit'
    WHEN v_campaign.submission_end IS NOT NULL AND now() > v_campaign.submission_end::timestamptz THEN 'post'
    WHEN v_campaign.purchase_end   IS NOT NULL AND now() > v_campaign.purchase_end::timestamptz   THEN 'post'
    WHEN v_campaign.visit_end      IS NOT NULL AND now() > v_campaign.visit_end::timestamptz      THEN 'post'
    WHEN v_campaign.deadline       IS NOT NULL AND now() <= v_campaign.deadline::timestamptz      THEN 'recruit'
    ELSE 'other'
  END;

  -- 6. recruit 외 단계는 사유·동의 필수
  IF v_phase != 'recruit' THEN
    IF NOT COALESCE(p_acknowledged, false) THEN
      RAISE EXCEPTION 'acknowledgement_required' USING ERRCODE = '22023';
    END IF;
    IF p_reason_code IS NULL OR length(trim(p_reason_code)) = 0 THEN
      RAISE EXCEPTION 'reason_required' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- 7. UPDATE
  UPDATE public.applications
  SET status             = 'cancelled',
      previous_status    = v_app.status,
      cancelled_at       = now(),
      cancel_reason_code = NULLIF(trim(p_reason_code), ''),
      cancel_reason      = NULLIF(trim(p_reason_note), ''),
      cancel_phase       = v_phase
  WHERE id = p_application_id;

  -- 8. admin_notices 즉시 등록 (recruit 외 단계만 — 모집기간 취소 노이즈 차단)
  IF v_phase != 'recruit' THEN
    v_phase_ko := CASE v_phase
      WHEN 'purchase' THEN '구매기간'
      WHEN 'visit'    THEN '방문기간'
      WHEN 'post'     THEN '결과물 제출기간'
      ELSE '기타'
    END;

    v_recruit_type_ko := CASE COALESCE(v_campaign.recruit_type, '')
      WHEN 'monitor' THEN '리뷰어'
      WHEN 'gifting' THEN '기프팅'
      WHEN 'visit'   THEN '방문형'
      ELSE COALESCE(v_campaign.recruit_type, '-')
    END;

    SELECT name_ko INTO v_reason_label
    FROM public.lookup_values
    WHERE kind = 'cancel_reason'
      AND code = NULLIF(trim(p_reason_code), '')
    LIMIT 1;
    v_reason_label := COALESCE(v_reason_label, '-');

    -- HTML escape — DB 값(캠페인/이름/이메일/사유)도 일관되게 1차 처리.
    -- 줄바꿈 변환은 보충(reason_note) 만 적용 — title/name 등은 한 줄 텍스트.
    v_campaign_no_esc :=
      replace(replace(replace(COALESCE(v_campaign.campaign_no, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
    v_campaign_title_esc :=
      replace(replace(replace(COALESCE(v_campaign.title, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
    v_influencer_name :=
      replace(replace(replace(COALESCE(v_influencer.name, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
    v_influencer_email :=
      replace(replace(replace(COALESCE(v_influencer.email, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
    v_reason_label_esc :=
      replace(replace(replace(v_reason_label, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');

    v_notice_title := '응모 취소 — '
      || COALESCE(v_campaign.title, '캠페인')
      || ' / '
      || COALESCE(v_influencer.name, '인플루언서');

    -- 보충 텍스트: 자유 입력이라 줄바꿈도 보존.
    IF p_reason_note IS NOT NULL AND length(trim(p_reason_note)) > 0 THEN
      v_supplement_html :=
        '<p><b>보충:</b> '
        || replace(
             replace(
               replace(
                 replace(trim(p_reason_note), '&', '&amp;'),
                 '<', '&lt;'),
               '>', '&gt;'),
             E'\n', '<br>')
        || '</p>';
    ELSE
      v_supplement_html := '';
    END IF;

    v_notice_body :=
      '<div>'
      || '<p><b>캠페인:</b> ['
        || v_campaign_no_esc
        || '] '
        || v_campaign_title_esc
        || ' (' || v_recruit_type_ko || ')</p>'
      || '<p><b>인플루언서:</b> '
        || v_influencer_name
        || ' · '
        || v_influencer_email
        || '</p>'
      || '<p><b>취소 일시:</b> '
        || to_char((now() AT TIME ZONE 'Asia/Seoul'), 'YYYY-MM-DD HH24:MI')
        || ' KST</p>'
      || '<p><b>시점:</b> ' || v_phase_ko || '</p>'
      || '<p><b>사유:</b> ' || v_reason_label_esc || '</p>'
      || v_supplement_html
      || '</div>';

    INSERT INTO public.admin_notices (
      title, body_html, category,
      created_by, created_by_name,
      status, published_at, published_by, published_by_name
    ) VALUES (
      v_notice_title, v_notice_body, 'warning',
      NULL, 'system',
      'published', now(), NULL, 'system'
    );
  END IF;

  RETURN jsonb_build_object(
    'cancel_phase',    v_phase,
    'cancelled_at',    now(),
    'previous_status', v_app.status
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.cancel_application(uuid, text, text, boolean) TO authenticated;

COMMENT ON FUNCTION public.cancel_application(uuid, text, text, boolean) IS
  '캠페인 신청 본인 취소. 사양 §2-4 + §6. '
  '본인 검증 + 결과물 승인 차단 + cancel_phase 도출 + 사유·동의 강제 + UPDATE. '
  'migration 113 에서 recruit 외 단계 admin_notices 자동 등록 추가. '
  'migration 306 에서 influencers 조회 컬럼 오류(auth_id → id) 수정 '
  '— 113 배포(2026-05-12) 이후 약 3개월간 본 함수가 100% 실패하던 결함.';

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- 검증 (마이그레이션 실행 후 SQL 편집기에서 확인용 — 1단계씩 순서대로
-- 결과를 확인하며 진행할 것. 한 번에 다 실행하지 말 것)
-- ════════════════════════════════════════════════════════════════════
--
-- 1) 함수 정의에 auth_id 가 더 이상 없는지 확인
-- SELECT pg_get_functiondef('public.cancel_application(uuid,text,text,boolean)'::regprocedure);
--   → 본문에 "auth_id" 문자열이 없어야 하고, "WHERE id = v_app.user_id" 가
--     있어야 한다.
--
-- 2) 실제로 취소가 성공하는지 (개발 데이터베이스, 테스트 계정 — 반드시
--    본인 소유 응모로 테스트. RLS 상 auth.uid() 로 본인 검증하므로
--    로그인한 그 계정의 응모 id 를 넣어야 함. service_role/SQL 편집기는
--    로그인 세션이 없어 not_owner(42501)로 막히니, 이 검증은 브라우저
--    로그인 상태에서 앱 화면으로 직접 눌러보는 것을 권장)
--
--    화면 검증 순서:
--    ① 테스트 인플루언서로 로그인 → 임의 캠페인에 응모(pending 상태)
--    ② 마이페이지 → 응모이력에서 그 응모 「취消」(모집기간 중이면
--       사유 입력 없이 바로 처리되는 간단 모드)
--    ③ 「取消しました」류 성공 토스트가 뜨는지, 응모이력이 取消 탭으로
--       이동하고 상태가 取消済み 로 바뀌는지 확인
--
-- 3) SQL 로 결과 재확인 (위 ②에서 사용한 응모 id 로)
-- SELECT id, status, previous_status, cancelled_at, cancel_phase, cancel_reason_code
--   FROM public.applications
--  WHERE id = '<취소한 응모 id>';
--   → status='cancelled', cancelled_at 이 now() 근처, previous_status
--     가 취소 전 상태(pending 등)여야 한다.
--
-- 4) 모집기간이 아닌 단계(구매기간·방문기간·결과물 제출기간)에서 취소한
--    경우, 관리자 공지사항에 알림이 제대로 등록되는지 확인
-- SELECT title, category, created_at
--   FROM public.admin_notices
--  WHERE title LIKE '응모 취소 — %'
--  ORDER BY created_at DESC
--  LIMIT 5;
--   → 방금 취소한 캠페인명/인플루언서명이 제목에 정상적으로 들어 있어야
--     한다(과거 113 결함 상태에서는 이 지점까지 도달한 적이 자체가
--     없으므로, 이 표에 응모 취소 관련 행이 2026-05-12 이후로 하나도
--     없었을 것 — 아래 5번으로 교차 확인).
--
-- 5) (참고용, 선택) 결함이 실제로 3개월간 지속됐다는 사실 재확인
-- SELECT COUNT(*) AS cancel_notices_since_113
--   FROM public.admin_notices
--  WHERE title LIKE '응모 취소 — %'
--    AND created_at >= '2026-05-12 18:16:00+09';
--   → 이 마이그레이션 적용 전 시점에 실행하면 0건이 나와야 정상
--     (그 사이 모집기간 취소만 있었다면 admin_notices 자체가 안 남으므로
--     0건이 나와도 결함의 반증은 아님 — 3)의 화면 재현이 1차 근거).
-- ════════════════════════════════════════════════════════════════════
