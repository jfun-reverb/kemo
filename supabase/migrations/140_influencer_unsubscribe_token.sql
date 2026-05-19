-- ============================================================
-- 140_influencer_unsubscribe_token.sql
-- 2026-05-19
--
-- 목적:
--   캠페인 홍보 메일 수신거부·재구독 인프라.
--   influencers 테이블에 컬럼 2종 추가 + campaigns 테이블에 first_active_at 추가.
--
-- 사양서:
--   docs/specs/2026-05-19-campaign-promo-email.md §3-2, §16-3
--
-- 변경 내용:
--   [A] influencers 테이블
--       - unsubscribe_token uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE
--         : 인플 1명당 영구 1개 토큰. 메일 클릭만으로 수신거부·클릭 추적 가능.
--         기존 행은 DEFAULT 적용으로 자동 백필됨.
--       - marketing_unsubscribed_at timestamptz NULL
--         : 수신거부 시각 감사 기록. 재구독 시 NULL 로 초기화.
--
--   [B] campaigns 테이블
--       - first_active_at timestamptz NULL
--         : 캠페인이 처음 active 상태로 전환된 시각.
--         「어제 신규 캠페인」 판별을 created_at/recruit_start 대신 이 컬럼으로 함.
--         (created_at: 드래프트 등록 시각 / recruit_start: 예약 시작일 — 둘 다 활성화 시각이 아님)
--       - 트리거: status 가 처음 active 로 바뀔 때 first_active_at = now() 기록 (이후 불변)
--       - 백필: 이미 active/closed/expired 인 캠페인 → COALESCE(recruit_start, created_at) 로 소급 추정
--
--   [C] 함수 2종
--       - unsubscribe_by_token(p_token uuid) — 익명 anon GRANT, 메일 클릭만으로 수신거부
--       - resubscribe_marketing()             — authenticated GRANT, 마이페이지 재구독
--
-- 행 단위 보안 정책:
--   influencers: 신규 컬럼은 기존 정책 자동 적용 (본인 SELECT/UPDATE, 관리자 SELECT)
--   campaigns: 신규 컬럼은 기존 정책 자동 적용 (SELECT 공개, CUD 관리자)
--
-- 운영 데이터 영향:
--   - influencers 컬럼 추가: DEFAULT 자동 백필 (기존 1,398행 이상 안전)
--   - campaigns 백필: UPDATE WHERE 조건 제한, 기존 데이터 무결성 유지
--
-- 적용 순서:
--   1. 개발서버 SQL Editor 실행 + 검증
--   2. 운영서버 SQL Editor 실행
--
-- 롤백:
--   DROP TRIGGER IF EXISTS trg_campaigns_first_active_at ON public.campaigns;
--   DROP FUNCTION IF EXISTS public._record_first_active_at();
--   ALTER TABLE public.campaigns DROP COLUMN IF EXISTS first_active_at;
--   ALTER TABLE public.influencers DROP COLUMN IF EXISTS marketing_unsubscribed_at;
--   ALTER TABLE public.influencers DROP COLUMN IF EXISTS unsubscribe_token;
--   DROP FUNCTION IF EXISTS public.resubscribe_marketing();
--   DROP FUNCTION IF EXISTS public.unsubscribe_by_token(uuid);
-- ============================================================

BEGIN;


-- ============================================================
-- A-1. influencers.unsubscribe_token
--   NOT NULL DEFAULT gen_random_uuid() UNIQUE
--   기존 행은 DEFAULT 적용 → 즉시 백필
-- ============================================================
ALTER TABLE public.influencers
  ADD COLUMN IF NOT EXISTS unsubscribe_token uuid NOT NULL DEFAULT gen_random_uuid();

-- UNIQUE 제약 별도 추가 (IF NOT EXISTS 지원 위해 분리)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'public.influencers'::regclass
       AND conname  = 'influencers_unsubscribe_token_key'
  ) THEN
    ALTER TABLE public.influencers
      ADD CONSTRAINT influencers_unsubscribe_token_key UNIQUE (unsubscribe_token);
  END IF;
END;
$$;

COMMENT ON COLUMN public.influencers.unsubscribe_token IS
  '[140] 홍보 메일 수신거부·클릭 추적용 영구 토큰. UUID v4 (122 bit 엔트로피). 메일 링크에 포함 — 로그인 없이 수신거부/클릭 기록 가능.';


-- ============================================================
-- A-2. influencers.marketing_unsubscribed_at
--   수신거부 시각 감사 기록. NULL = 수신거부 안 함.
--   재구독 시 NULL 로 초기화.
-- ============================================================
ALTER TABLE public.influencers
  ADD COLUMN IF NOT EXISTS marketing_unsubscribed_at timestamptz;

COMMENT ON COLUMN public.influencers.marketing_unsubscribed_at IS
  '[140] 마케팅 메일 수신거부 시각. NULL 이면 거부 이력 없음. 재구독 시 NULL 로 초기화. marketing_opt_in=false 와 함께 설정.';


-- ============================================================
-- B-1. campaigns.first_active_at
--   캠페인이 처음 active 로 전환된 시각.
--   get_promo_digest_targets 가 「어제 KST 활성화된 신규 캠페인」을
--   created_at/recruit_start 가 아닌 이 컬럼으로 정확히 판별.
-- ============================================================
ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS first_active_at timestamptz;

COMMENT ON COLUMN public.campaigns.first_active_at IS
  '[140] 캠페인이 처음 active 상태로 전환된 시각. 홍보 메일 「신규 캠페인」 판별 기준. 트리거 _record_first_active_at() 가 자동 기록 (이후 불변).';


-- ============================================================
-- B-2. campaigns.first_active_at — 기존 데이터 백필
--   active/closed/expired 캠페인: COALESCE(recruit_start, created_at) 소급 추정
--   draft/scheduled: 아직 활성화 안 됨 → NULL 유지
--   scheduled 캠페인 중 recruit_start 가 과거인 경우(=이미 지났으나 수동 전이 안 된 이상 상태) 도 동일하게 처리
-- ============================================================
UPDATE public.campaigns
  SET first_active_at = COALESCE(recruit_start::timestamptz, created_at)
  WHERE status IN ('active', 'closed', 'expired')
    AND first_active_at IS NULL;


-- ============================================================
-- B-3. 트리거: status 가 처음 active 로 바뀔 때 first_active_at 기록
--   BEFORE UPDATE 로 NEW 행을 직접 수정 (타임스탬프 정밀도 보장)
--   조건: NEW.status = 'active' AND OLD.status <> 'active' AND NEW.first_active_at IS NULL
--   → 두 번째 active 전환(closed → active 등 재개)은 기록 안 함 (첫 번째만)
-- ============================================================
CREATE OR REPLACE FUNCTION public._record_first_active_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $func$
BEGIN
  -- 처음으로 active 가 되는 순간만 기록 (이미 first_active_at 있으면 불변 유지)
  IF NEW.status = 'active'
     AND OLD.status <> 'active'
     AND NEW.first_active_at IS NULL
  THEN
    NEW.first_active_at := now();
  END IF;
  RETURN NEW;
END;
$func$;

COMMENT ON FUNCTION public._record_first_active_at() IS
  '[140] campaigns.status 가 처음 active 로 전환될 때 first_active_at 를 기록하는 트리거 함수. SECURITY DEFINER + search_path 고정.';

DROP TRIGGER IF EXISTS trg_campaigns_first_active_at ON public.campaigns;
CREATE TRIGGER trg_campaigns_first_active_at
  BEFORE UPDATE OF status ON public.campaigns
  FOR EACH ROW EXECUTE FUNCTION public._record_first_active_at();


-- ============================================================
-- C-1. unsubscribe_by_token(p_token uuid) — 익명 수신거부
--   메일 수신거부 링크 클릭만으로 호출 (로그인 불요)
--   anon + authenticated 양쪽 GRANT
--   토큰 미매칭 시 success=false 반환 (HTTP 200, 에러 코드 포함)
-- ============================================================
CREATE OR REPLACE FUNCTION public.unsubscribe_by_token(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_influencer record;
BEGIN
  -- 토큰으로 인플루언서 조회 (influencers.id = auth.users.id, PK)
  SELECT id, name_kanji, name
    INTO v_influencer
    FROM public.influencers
   WHERE unsubscribe_token = p_token;

  IF NOT FOUND THEN
    -- UUID v4 엔트로피(122 bit)로 무차별 대입 사실상 불가
    -- 잘못된 토큰은 success=false 반환 (HTTP 에러 코드 없이 정상 응답 — 열거 공격 방지)
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_token');
  END IF;

  -- 이미 수신거부 상태라도 멱등 처리 (중복 호출 안전)
  UPDATE public.influencers
     SET marketing_opt_in            = false,
         marketing_unsubscribed_at   = now()
   WHERE id = v_influencer.id;

  RETURN jsonb_build_object(
    'success', true,
    'name', COALESCE(
      NULLIF(TRIM(v_influencer.name_kanji), ''),
      NULLIF(TRIM(v_influencer.name), ''),
      ''
    )
  );
END;
$$;

-- PostgreSQL 기본은 PUBLIC EXECUTE 권한 부여 → REVOKE 후 명시 GRANT 로 표면적 최소화
REVOKE EXECUTE ON FUNCTION public.unsubscribe_by_token(uuid) FROM PUBLIC;
-- 익명(anon) GRANT 필수: 메일 링크는 비로그인 상태에서 클릭
GRANT EXECUTE ON FUNCTION public.unsubscribe_by_token(uuid) TO anon, authenticated;

COMMENT ON FUNCTION public.unsubscribe_by_token(uuid) IS
  '[140] 홍보 메일 수신거부 링크용 익명 RPC. anon GRANT — 로그인 없이 토큰만으로 marketing_opt_in=false 설정. SECURITY DEFINER + search_path 고정.';


-- ============================================================
-- C-2. resubscribe_marketing() — 마이페이지 재구독
--   auth.uid() 기반 본인 확인 (파라미터 없이 현재 로그인 사용자 적용)
--   marketing_agreed_at 갱신: 특정전자메일법 「동의 근거 기록」 의무
-- ============================================================
CREATE OR REPLACE FUNCTION public.resubscribe_marketing()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  UPDATE public.influencers
     SET marketing_opt_in          = true,
         marketing_unsubscribed_at = NULL,          -- 거부 이력 초기화
         marketing_agreed_at       = now()          -- 특정전자메일법 의무: 재동의 시각 갱신
   WHERE id = auth.uid();  -- influencers.id = auth.users.id (PK)
$$;

-- Supabase 기본 정책: 새 함수에 anon/authenticated/service_role 자동 GRANT.
-- PUBLIC + anon 명시 REVOKE 로 보안 표면적 최소화 (authenticated 본인만 호출).
-- (anon 호출 시 auth.uid()=NULL 이라 실제 피해는 없으나 호출 시도 자체를 차단)
REVOKE EXECUTE ON FUNCTION public.resubscribe_marketing() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resubscribe_marketing() TO authenticated;

COMMENT ON FUNCTION public.resubscribe_marketing() IS
  '[140] 마이페이지에서 마케팅 메일 재구독. 본인(auth.uid()) 만 적용. marketing_agreed_at 를 갱신해 특정전자메일법 동의 근거 기록 요건 충족. SECURITY DEFINER + search_path 고정.';


COMMIT;
