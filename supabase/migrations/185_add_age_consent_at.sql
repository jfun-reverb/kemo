-- ============================================================
-- 185_add_age_consent_at.sql
-- 2026-06-17
--
-- 목적:
--   연령 정책 게이트(PR 5) 에서 기존 회원이 생년월일·성별을 입력할 때
--   개인정보 수집·이용 동의 시각을 기록하기 위한 컬럼 추가.
--
-- 법적 근거:
--   개인정보보호법(PIPA) + APPI — 생년월일·성별은 신규 수집 항목이므로
--   수집 시점 동의 사실을 기록해야 함.
--   기존 가입 동의(terms_agreed_at·privacy_agreed_at, 마이그레이션 022)는
--   가입 시점 기준 동의이므로, 연령 정책 시행 후 추가 수집 동의는 별도 컬럼으로 분리.
--
-- 변경 요약:
--   [A] influencers.age_consent_at TIMESTAMPTZ NULL 컬럼 추가
--       - NULL: 아직 게이트를 통과하지 않은 기존 회원 (기존 1,400여 행 무변경)
--       - 값 있음: 연령 정책 게이트에서 생년월일·성별 수집에 동의한 시각 (UTC)
--
-- 행 단위 보안 정책(RLS) 영향:
--   influencers 테이블의 현행 UPDATE 정책("influencers_update_allow", 마이그레이션 137):
--     USING/WITH CHECK = (is_admin() OR (SELECT auth.uid()) = id)
--   컬럼 단위 제한이 없으므로 본인(auth.uid()=id)이 age_consent_at 을 UPDATE 할 수 있음.
--   → 별도 RLS 정책 추가 불필요.
--
-- 트리거 간섭 확인 (마이그레이션 180):
--   trg_lock_influencer_birthdate (BEFORE UPDATE ON influencers) 는
--   birthdate 컬럼 변경만 검사:
--     IF OLD.birthdate IS NOT NULL AND OLD.birthdate IS DISTINCT FROM NEW.birthdate THEN RAISE;
--   age_consent_at 은 이 조건과 무관 — 트리거 간섭 없음.
--
-- 클라이언트 저장 방식:
--   dev/lib/storage.js updateInfluencer(userId, updates) 에
--   { birthdate, gender, age_consent_at } 를 한 번에 전달.
--   RPC 분리 불필요 — 기존 updateInfluencer 패턴으로 충분.
--   (updateInfluencer 는 retryWithRefresh 래퍼 포함, 세션 만료 자동 갱신)
--
-- 운영 데이터 영향:
--   - NULL 기본값 컬럼 추가: 기존 행 변경 없음, 잠금 없음.
--   - 트리거/정책 추가 없음 — DDL 1줄.
--
-- 롤백:
--   ALTER TABLE public.influencers DROP COLUMN IF EXISTS age_consent_at;
-- ============================================================

BEGIN;

-- ============================================================
-- [A] influencers.age_consent_at 컬럼 추가
-- ============================================================

ALTER TABLE public.influencers
  ADD COLUMN IF NOT EXISTS age_consent_at TIMESTAMPTZ NULL;

COMMENT ON COLUMN public.influencers.age_consent_at IS
  '연령 정책 게이트에서 생년월일·성별 개인정보 수집·이용에 동의한 시각(UTC).
   NULL = 아직 동의 미완료(기존 회원 초기값).
   PR 5 응모 게이트 진입 시 동의 완료 → now() 기록.
   마이그레이션 022(terms_agreed_at·privacy_agreed_at)와 같은 동의 기록 패턴.';

-- ============================================================
-- 검증 쿼리 (SQL Editor 에서 적용 후 실행)
--
-- 1단계 — 컬럼 존재 확인:
--   SELECT column_name, data_type, is_nullable
--     FROM information_schema.columns
--    WHERE table_schema = 'public'
--      AND table_name = 'influencers'
--      AND column_name = 'age_consent_at';
--   → 1행, data_type='timestamp with time zone', is_nullable='YES'
--
-- 2단계 — 기존 행 NULL 확인 (샘플):
--   SELECT id, age_consent_at
--     FROM public.influencers
--    LIMIT 5;
--   → age_consent_at 모두 NULL
-- ============================================================

COMMIT;
