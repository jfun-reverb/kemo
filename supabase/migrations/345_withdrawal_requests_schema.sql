-- ============================================================
-- 345_withdrawal_requests_schema.sql
-- 회원 탈퇴 — 작업 3 (탈퇴 신청 표)
-- 사양서: docs/specs/2026-08-18-member-withdrawal.md §4-1·§4-6 ①
-- 작업표: docs/specs/2026-08-19-member-withdrawal-breakdown.md 작업 3
--
-- withdrawal_requests: 인플루언서 탈퇴 신청 1건 = 1행.
--   상태 4종(pending_payout/scheduled/done/cancelled)을 오가는 상태 표 —
--   settlements(마이그레이션 217)와 같은 성격(본인 소유 레코드)이라
--   그 파일의 컨벤션(RLS 조회만 정책, INSERT/UPDATE 는 SECURITY DEFINER
--   함수만)을 그대로 미러한다. 실제 신청·취소·상태 전이 함수는 후속
--   작업(5·6·7)에서 만든다 — 이 마이그레이션은 표만 만든다.
--
-- ⚠️ 인플루언서 표에 칸으로 두지 않고 별도 표로 두는 이유(사양서 §4-6 ①):
--   한 사람이 탈퇴했다가(6개월 뒤) 재가입해서 다시 탈퇴 신청을 낼 수 있고,
--   같은 사람이 신청 후 취소했다가 다시 신청할 수도 있다 — 이력이 여러 줄
--   쌓이는 게 정상이라 influencers 표에 칸으로 두면 마지막 것만 남는다.
--
-- ⚠️ 활성 신청은 사람당 하나 — 부분 유일 색인(아래 §2)으로 강제한다.
--   cancelled·done 은 "종료된" 상태라 그 색인에서 뺀다 — 안 빼면
--   한 번 취소(또는 완료)한 사람이 새 신청 행을 못 만든다.
--
-- ⚠️ 날짜·시각 판정은 전부 일본 시각(Asia/Tokyo) 기준이다(사양서 §4-1·경우의
--   수 ⑩). scheduled_date 가 "그날 + 5일" 을 담는 자리이므로, 이 값을
--   채우는 후속 함수(작업 5·7)는 반드시 일본 시각 기준 오늘 날짜로 계산할 것.
--   completed_at 은 시:분:초까지 있는 timestamptz 라 시간대 계산이 필요
--   없지만, "그 날짜가 지났는가"를 비교할 때(로그인 차단 등)는 일본 시각
--   기준 날짜로 비교해야 한다(후속 작업 8).
--
-- ⚠️ influencer_id ON DELETE CASCADE 로 두는 이유(사용자 확인 필요 없이
--   기존 컨벤션을 그대로 따름):
--   사양서 §4-7 은 "회원 행을 통째로 지울 수 없다"고 못 박았고(정산 감사
--   이력이 ON DELETE RESTRICT 라 막힘), 정상적인 탈퇴 플로우는 influencers
--   행을 절대 삭제하지 않는다(칸 비우기만 한다, 작업 9·10 소관). 이 표가
--   실제로 CASCADE 를 타는 경우는 오직 레거시 관리자 전용 경로
--   delete_admin_completely()(마이그레이션 031)뿐이고, 그 경로는 이미
--   settlements 행이 하나라도 있으면 사전 체크(마이그레이션 251)가 삭제
--   자체를 막는다. 다만 251 의 사전 체크는 settlements 만 보고
--   withdrawal_requests 는 보지 않는다 — settlements 없이 withdrawal_requests
--   만 있는 인플루언서를 delete_admin_completely 로 지우면 이 표의 행도
--   조용히 함께 사라진다(감사 관점에서 아쉬우나, applications·deliverables
--   등 인플루언서의 "본인 소유 레코드" 전부가 이미 같은 방식으로 CASCADE
--   되고 있어 이 표만 다르게 두면 그 삭제 경로 자체가 실패하거나 어중간하게
--   남는 쪽이 더 혼란스럽다). settlement_events 처럼 "제3자 감사 이력"이
--   아니라 "본인 신청 기록"이라 CASCADE 가 기존 컨벤션과 맞다고 판단했다.
--   ⚠️ 이 레거시 경로에도 251 과 같은 사전 체크를 추가할지는 이번 마이그레이션
--   범위 밖 — 필요하면 별도 마이그레이션으로.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

-- ============================================================
-- 1. withdrawal_requests 테이블
-- ============================================================
CREATE TABLE IF NOT EXISTS public.withdrawal_requests (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  influencer_id      uuid NOT NULL REFERENCES public.influencers(id) ON DELETE CASCADE,
  status             text NOT NULL DEFAULT 'pending_payout'
                        CHECK (status IN ('pending_payout', 'scheduled', 'done', 'cancelled')),
  reason_code        text,
  reason_note        text,
  requested_at       timestamptz NOT NULL DEFAULT now(),
  scheduled_date     date,
  completed_at       timestamptz,
  requested_by_kind  text NOT NULL DEFAULT 'self'
                        CHECK (requested_by_kind IN ('self', 'admin')),
  processed_by       uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  uncancelled_count  integer NOT NULL DEFAULT 0 CHECK (uncancelled_count >= 0),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.withdrawal_requests IS
  '[345] 회원 탈퇴 신청. 인플루언서 1명이 여러 줄을 가질 수 있다(취소 후 재신청, '
  '6개월 뒤 재가입 후 재탈퇴 등) — influencers 표에 칸으로 두지 않은 이유. '
  '상태 4종을 오간다: pending_payout(미지급 대기)→scheduled(5일 유예)→done(확정) '
  '/ (대기·유예 중) → cancelled(취소). 신청·취소·상태 전이 함수는 후속 작업.';
COMMENT ON COLUMN public.withdrawal_requests.status IS
  'pending_payout(받을 돈이 남아 대기) | scheduled(5일 유예 중, scheduled_date 확정) | '
  'done(탈퇴 확정 — 로그인 차단·파기 대상) | cancelled(회원이 유예 중 취소, 행은 보존).';
COMMENT ON COLUMN public.withdrawal_requests.reason_code IS
  'lookup_values(kind=''withdraw_reason'') code 참조(실제 외래 키 제약 없음 — '
  '이 저장소의 lookup_values 참조 컨벤션, cancel_reason_code 와 동일). NULL 허용 — '
  '필수 여부는 신청 함수(후속 작업 5)가 신청 주체(requested_by_kind)에 따라 판단.';
COMMENT ON COLUMN public.withdrawal_requests.reason_note IS
  '회원이 직접 입력한 자유 텍스트(선택). 사양서 §4-3 — "기타" 선택 시에만 권장, 필수 아님.';
COMMENT ON COLUMN public.withdrawal_requests.scheduled_date IS
  '탈퇴 확정 예정일(날짜만, 일본 시각 기준). 기준은 항상 "예정(scheduled) 상태가 '
  '되는 그날 + 5일" 하나뿐 — 미지급이 없으면 신청 함수가, 있었다가 지급이 끝나면 '
  '상태 전이 예약 실행(후속 작업 7)이 이 값을 채운다. "지급 완료일 + 5일" 로 '
  '계산하지 않는다(사양서 §4-1 — 예약 실행이 매일 1회라 최대 하루 어긋나고, 회원은 '
  '통지받은 날에야 알기 때문).';
COMMENT ON COLUMN public.withdrawal_requests.completed_at IS
  '탈퇴가 실제로 확정(done)된 시각. 이 값이 방침이 말하는 "탈퇴 확정일"의 기준점 — '
  '재가입 차단 6개월·PayPal 5년·결과물 이미지 6개월 파기가 전부 이 시각을 기준으로 '
  '센다(후속 작업 10·11·12·13).';
COMMENT ON COLUMN public.withdrawal_requests.requested_by_kind IS
  'self(본인이 신청) | admin(관리자가 자격 상실 등으로 대신 신청 — 약관 제6조 3항). '
  '같은 표에 담되 감사에서 갈리도록 구분.';
COMMENT ON COLUMN public.withdrawal_requests.processed_by IS
  '관리자가 대신 신청했거나(requested_by_kind=admin) 취소·상태를 손으로 개입한 경우의 '
  '처리자. 본인 신청·자동 전이(예약 실행)는 NULL.';
COMMENT ON COLUMN public.withdrawal_requests.uncancelled_count IS
  '탈퇴 신청 시 자동 철회를 시도했으나(결과물 승인됨·송금완료 정산 있음 등으로) '
  '철회하지 못하고 남은 응모 수. 0이면 관리자 화면에 표시하지 않는다(후속 작업 14).';

-- ============================================================
-- 2. 활성 신청은 사람당 하나 — 부분 유일 색인
--    cancelled·done 은 "종료된" 상태라 제외한다. 안 빼면 한 번 취소(또는
--    완료)한 사람이 새로 신청 행을 못 만든다(applications_user_camp_active_uidx,
--    마이그레이션 104 와 같은 패턴 — 종료 상태는 유일성 검사에서 뺀다).
-- ============================================================
CREATE UNIQUE INDEX IF NOT EXISTS withdrawal_requests_active_uidx
  ON public.withdrawal_requests (influencer_id)
  WHERE status IN ('pending_payout', 'scheduled');

-- ============================================================
-- 3. 조회 보조 색인
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_withdrawal_requests_influencer_id
  ON public.withdrawal_requests (influencer_id);

-- 상태 전이 예약 실행(후속 작업 7)이 매일 스캔할 후보를 좁히기 위한 부분 색인
CREATE INDEX IF NOT EXISTS idx_withdrawal_requests_status_pending
  ON public.withdrawal_requests (status) WHERE status = 'pending_payout';
CREATE INDEX IF NOT EXISTS idx_withdrawal_requests_status_scheduled
  ON public.withdrawal_requests (status, scheduled_date) WHERE status = 'scheduled';

-- ============================================================
-- 4. updated_at 자동 갱신 트리거 (settlements·companies 등과 동일 컨벤션)
-- ============================================================
CREATE OR REPLACE FUNCTION public.touch_withdrawal_requests_updated_at()
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

COMMENT ON FUNCTION public.touch_withdrawal_requests_updated_at() IS
  '[345] withdrawal_requests.updated_at 자동 갱신 트리거 함수.';

REVOKE ALL ON FUNCTION public.touch_withdrawal_requests_updated_at() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.touch_withdrawal_requests_updated_at() TO PUBLIC;

DROP TRIGGER IF EXISTS trg_withdrawal_requests_updated_at ON public.withdrawal_requests;
CREATE TRIGGER trg_withdrawal_requests_updated_at
  BEFORE UPDATE ON public.withdrawal_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_withdrawal_requests_updated_at();

-- ============================================================
-- 5. RLS — 조회 정책만. INSERT/UPDATE/DELETE 는 정책을 두지 않는다
--    (settlements, 마이그레이션 217 과 동일 컨벤션) — 신청·취소·상태
--    전이는 전부 후속 작업(5·6·7)의 SECURITY DEFINER 함수만 수행한다.
--    정책이 없으면 authenticated 의 직접 INSERT/UPDATE/DELETE 는 RLS
--    기본 거부(permissive 정책 매칭 없음)로 원천 차단된다.
-- ============================================================
ALTER TABLE public.withdrawal_requests ENABLE ROW LEVEL SECURITY;

-- 인플루언서: 본인 행만 조회 (influencers.id = auth.uid())
CREATE POLICY withdrawal_requests_select_own ON public.withdrawal_requests
  FOR SELECT TO authenticated
  USING (influencer_id = auth.uid());

-- 관리자: 전체 조회 (일반 관리자 판정 — 정산과 달리 동적 권한 게이트 요구 없음,
--   사양서 §4-4 "전용 페인을 새로 만들지 않는다" — 인플루언서 관리에 얹으므로
--   그 화면과 같은 기준인 is_admin() 을 쓴다)
CREATE POLICY withdrawal_requests_select_admin ON public.withdrawal_requests
  FOR SELECT TO authenticated
  USING (public.is_admin());

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
-- ============================================================
/*

-- [V0] 테이블·컬럼 생성 확인
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'withdrawal_requests'
ORDER BY ordinal_position;

-- [V1] CHECK 제약 확인 (status 4종 · requested_by_kind 2종)
SELECT conname, pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conrelid = 'public.withdrawal_requests'::regclass AND contype = 'c'
ORDER BY conname;

-- [V2] 부분 유일 색인 확인 (WHERE 절이 pending_payout/scheduled 만 포함하는지)
SELECT indexname, indexdef
FROM pg_indexes
WHERE tablename = 'withdrawal_requests'
ORDER BY indexname;

-- [V3] influencer_id 외래 키 ON DELETE 규칙 확인 (CASCADE = 'c' 기대)
SELECT conname, confrelid::regclass AS references_table, confdeltype
FROM pg_constraint
WHERE conrelid = 'public.withdrawal_requests'::regclass AND contype = 'f';

-- [V4] RLS 정책 확인 (SELECT 2개만 있고 INSERT/UPDATE/DELETE 정책이 없는지)
SELECT policyname, cmd, roles
FROM pg_policies
WHERE tablename = 'withdrawal_requests'
ORDER BY policyname;

-- [V5] 직접 INSERT 가 차단되는지 (로그인한 인플루언서 세션에서 실행 — 서비스 키로는
--   RLS 자체가 우회되므로 이 검증은 SQL 편집기가 아니라 실제 로그인 세션에서만
--   유효하다. 여기서는 "정책이 없어 authenticated 삽입이 원천 거부됨"을
--   구조로만 확인했다는 점 참고)
SELECT true AS reminder_use_logged_in_session;

-- [V6] 활성 유일 색인이 실제로 막는지 (테스트 인플루언서 계정으로, 되돌릴 수 있는
--   상태에서만 — 완료 후 반드시 DELETE 로 정리할 것)
-- INSERT INTO public.withdrawal_requests (influencer_id, status)
--   VALUES ('<테스트 인플루언서 id>', 'pending_payout');
-- INSERT INTO public.withdrawal_requests (influencer_id, status)   -- 기대: 유일 색인 위반으로 실패
--   VALUES ('<같은 id>', 'scheduled');
-- DELETE FROM public.withdrawal_requests WHERE influencer_id = '<테스트 인플루언서 id>';

*/

-- ============================================================
-- 롤백
-- ============================================================
-- DROP POLICY IF EXISTS withdrawal_requests_select_admin ON public.withdrawal_requests;
-- DROP POLICY IF EXISTS withdrawal_requests_select_own ON public.withdrawal_requests;
-- DROP TRIGGER IF EXISTS trg_withdrawal_requests_updated_at ON public.withdrawal_requests;
-- DROP FUNCTION IF EXISTS public.touch_withdrawal_requests_updated_at();
-- DROP INDEX IF EXISTS idx_withdrawal_requests_status_scheduled;
-- DROP INDEX IF EXISTS idx_withdrawal_requests_status_pending;
-- DROP INDEX IF EXISTS idx_withdrawal_requests_influencer_id;
-- DROP INDEX IF EXISTS withdrawal_requests_active_uidx;
-- DROP TABLE IF EXISTS public.withdrawal_requests;
-- ⚠️ 후속 마이그레이션(346 이후 작업 5~14)이 이 표를 참조하는 함수를 이미
--   만들었다면, 이 표를 먼저 굴리면 그 함수들이 실패한다 — 역순으로(최신
--   번호부터) 롤백할 것.
