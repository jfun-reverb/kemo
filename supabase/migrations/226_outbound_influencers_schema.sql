-- ============================================================
-- 226_outbound_influencers_schema.sql
-- 인플루언서 추천 도구 1단계-a — 1/4 (데이터 모델)
-- 사양서: docs/specs/2026-07-08-influencer-recommendation.md
-- 인계서: docs/specs/2026-07-09-influencer-recommendation-stage1-handoff.md §PR 1단계-a
--
-- outbound_influencers: 영업팀이 직접 컨택하는 아웃바운드 시딩·타이업 인플루언서
--   명단(현재 구글시트 약 50명, globalreverb 미가입 — 별도 자산). 기존 influencers
--   테이블(= auth.users 1:1, 정산·마스킹 결합)과 물리적으로 분리한 신규 테이블.
--
-- 권한 (매우 중요 — HANDOFF 「주의」 섹션 명시 함정):
--   RLS 는 is_admin() 이 아니라 has_permission('outbound.view', '...') 로 건다.
--   campaign_manager 는 마이그레이션 228 시드로 이 기능이 'hidden' 이라, 화면뿐
--   아니라 API 직접 조회·쓰기도 막혀야 한다(settlements 마이그레이션 217 과 동일 정신).
--   마스터 쓰기 권한은 원격 호출 함수(RPC)가 아니라 **직접 정책**으로 허용한다
--   (HANDOFF 결정 #2 — 비금전 기준데이터 성격이라 admin_notices/lookup_values류
--   패턴을 따름. settlements 처럼 금전 트랜잭션이 아니므로 RPC 강제 불필요).
--
-- 컬럼 설계 메모:
--   - series_code/category_code: 세분→계열 매핑은 이 테이블에 부모 컬럼을 두지
--     않는다. 매핑은 마이그레이션 227 lookup_values 시드가 아니라 클라이언트
--     코드 상수 `OB_CATEGORY_SERIES`(dev/lib/shared.js, PR 1단계-b 예정)에 두고
--     저장 시 series_code 를 자동 채운다(HANDOFF §PR-a 2번 항목).
--   - 채널 4종 팔로워는 bigint NULL — "미상"과 "0명"을 구분해야 하므로 0 이 아닌
--     NULL 이 기본(HANDOFF 「주의」 NULL vs 0).
--   - 가격 5종도 동일하게 bigint NULL(빈값=NULL, 0과 구분 — 2단계 예산 필터가
--     "가격 미상"을 별도로 취급하기 위함).
--   - rep_image_path: Storage 오브젝트 상대 경로(`{id}/{random}.{ext}`)를 저장한다
--     (마이그레이션 229 버킷). 공개 버킷이라 화면(PR 1단계-b)에서 공개 URL을
--     조립하거나 `imgThumb()` 헬퍼로 변환해 렌더링한다 — 컬럼 자체엔 풀 URL을
--     저장하지 않는다(향후 버킷 이전 시 대응 용이).
--   - rep_posts jsonb: 대표 게시물 링크 최대 5개(각 {url, thumb_path}) 배열.
--     개수 제한은 애플리케이션 레벨에서 강제(PR 1단계-b) — DB CHECK 는 두지 않음
--     (jsonb 배열 길이 CHECK 는 갱신마다 비용이 크고, 가변 항목 편집 UX 와 상충).
--   - content_consent: 브랜드 뷰(5단계) 노출 전 인플 동의 여부 게이트 — 1단계에서
--     선탑재만(HANDOFF 결정 #5), 실제 브랜드 뷰 분기는 5단계 구현.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

-- ============================================================
-- 1. outbound_influencers 테이블
-- ============================================================
CREATE TABLE IF NOT EXISTS public.outbound_influencers (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- 기본
  name_ko          text NOT NULL,
  account_id       text,

  -- 분류 (lookup_values 코드 문자열 스냅샷 — 마이그레이션 227)
  series_code      text,
  category_code    text,
  tier_code        text,

  -- 채널별 핸들 + 팔로워 (핸들은 클라이언트 normalizeSnsFields 정규화 후 저장)
  ig_handle        text,
  ig_followers     bigint      CHECK (ig_followers      IS NULL OR ig_followers      >= 0),
  tiktok_handle    text,
  tiktok_followers bigint      CHECK (tiktok_followers  IS NULL OR tiktok_followers  >= 0),
  youtube_handle   text,
  youtube_followers bigint     CHECK (youtube_followers IS NULL OR youtube_followers >= 0),
  x_handle         text,
  x_followers      bigint      CHECK (x_followers       IS NULL OR x_followers       >= 0),

  -- 가격 (빈값=NULL, 0과 구분 — "가격 미상" vs "무료")
  price_feed       bigint      CHECK (price_feed      IS NULL OR price_feed      >= 0),
  price_reels      bigint      CHECK (price_reels     IS NULL OR price_reels     >= 0),
  price_story      bigint      CHECK (price_story     IS NULL OR price_story     >= 0),
  price_tiktok     bigint      CHECK (price_tiktok    IS NULL OR price_tiktok    >= 0),
  price_secondary  bigint      CHECK (price_secondary IS NULL OR price_secondary >= 0),

  -- 운영 (내부 전용 — 브랜드 뷰[5단계]에서 반드시 제외해야 하는 필드)
  contact_channel  text,
  agency           text,
  nego_memo        text,
  availability     text NOT NULL DEFAULT 'available'
                     CHECK (availability IN ('available', 'unavailable', 'adjusting')),

  -- 콘텐츠 (관리자 수동 등록 — 자동 수집 없음, 약관 벽)
  rep_image_path   text,
  rep_posts        jsonb NOT NULL DEFAULT '[]'::jsonb,
  content_consent  boolean NOT NULL DEFAULT false,

  -- 메타
  is_active        boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.outbound_influencers IS
  '[226] 아웃바운드 시딩·타이업 인플루언서 명단(영업팀 직접 컨택, globalreverb 미가입). '
  '기존 influencers(auth.users 1:1)와 분리된 별도 자산. 구글시트 1회 이관 대상(PR 1단계-c). '
  '권한은 has_permission(''outbound.view'', ...) — is_admin() 사용 금지(campaign_manager 차단 목적).';
COMMENT ON COLUMN public.outbound_influencers.account_id IS
  '대표 계정 식별자(검색·매칭용 자유 텍스트). SNS 핸들과 별개.';
COMMENT ON COLUMN public.outbound_influencers.series_code IS
  '계열 코드(lookup_values kind=ob_series 스냅샷). category_code 저장 시 클라이언트가 '
  'OB_CATEGORY_SERIES 매핑으로 자동 채움(마이그레이션 227 주석 참고).';
COMMENT ON COLUMN public.outbound_influencers.category_code IS
  '세분 카테고리 코드(lookup_values kind=ob_category 스냅샷).';
COMMENT ON COLUMN public.outbound_influencers.tier_code IS
  '등급 티어 코드(lookup_values kind=ob_tier 스냅샷). 시트값 우선 + 수동 수정 '
  '(HANDOFF 결정 #3 — 팔로워 자동계산 안 함, 시트값과 충돌 방지).';
COMMENT ON COLUMN public.outbound_influencers.price_feed IS
  '피드 게시 단가(엔화 ¥ — 시트 원본이 엔화, 사용자 확정 2026-07-09). NULL=가격 미상. '
  'price_reels/story/tiktok/secondary 도 동일 통화(엔화).';
COMMENT ON COLUMN public.outbound_influencers.availability IS
  'available(진행가능) | unavailable(불가) | adjusting(조율중). 1단계는 단순 상태만(HANDOFF 확정).';
COMMENT ON COLUMN public.outbound_influencers.nego_memo IS
  '내부 전용 협상 메모. 브랜드 뷰(5단계)에 절대 노출 금지 — 데이터·렌더 양쪽에서 구획 필요(HANDOFF 주의).';
COMMENT ON COLUMN public.outbound_influencers.rep_image_path IS
  'Storage 버킷 outbound-influencer-images 내 오브젝트 경로({id}/{random}.{ext}, 마이그레이션 229). '
  '풀 URL 아님 — 화면에서 공개 URL 조립 또는 imgThumb() 헬퍼로 변환.';
COMMENT ON COLUMN public.outbound_influencers.rep_posts IS
  '대표 게시물 배열(최대 5개, 애플리케이션 레벨 강제). 각 원소 {url, thumb_path}.';
COMMENT ON COLUMN public.outbound_influencers.content_consent IS
  '대표 이미지·게시물을 브랜드 뷰(5단계)에 노출해도 된다는 인플 동의 여부. '
  '1단계는 컬럼만 선탑재(기본 false) — 실제 게이트 분기는 5단계 구현.';

CREATE INDEX IF NOT EXISTS idx_outbound_influencers_series
  ON public.outbound_influencers(series_code);
CREATE INDEX IF NOT EXISTS idx_outbound_influencers_category
  ON public.outbound_influencers(category_code);
CREATE INDEX IF NOT EXISTS idx_outbound_influencers_tier
  ON public.outbound_influencers(tier_code);
CREATE INDEX IF NOT EXISTS idx_outbound_influencers_availability
  ON public.outbound_influencers(availability);
CREATE INDEX IF NOT EXISTS idx_outbound_influencers_is_active
  ON public.outbound_influencers(is_active) WHERE is_active = true;

-- ── updated_at 자동 갱신 트리거 (217_settlements_schema.sql 컨벤션 미러) ──
CREATE OR REPLACE FUNCTION public.touch_outbound_influencers_updated_at()
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

COMMENT ON FUNCTION public.touch_outbound_influencers_updated_at() IS
  '[226] outbound_influencers.updated_at 자동 갱신 트리거 함수.';

REVOKE ALL ON FUNCTION public.touch_outbound_influencers_updated_at() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.touch_outbound_influencers_updated_at() TO PUBLIC;

DROP TRIGGER IF EXISTS trg_outbound_influencers_updated_at ON public.outbound_influencers;
CREATE TRIGGER trg_outbound_influencers_updated_at
  BEFORE UPDATE ON public.outbound_influencers
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_outbound_influencers_updated_at();

-- ============================================================
-- 2. RLS
-- ============================================================
ALTER TABLE public.outbound_influencers ENABLE ROW LEVEL SECURITY;

-- SELECT: has_permission('outbound.view','read') 이상 (super_admin 무조건 통과,
--   campaign_manager 는 마이그레이션 228 시드로 'hidden' → 이 정책에서 false)
CREATE POLICY outbound_influencers_select ON public.outbound_influencers
  FOR SELECT TO authenticated
  USING (public.has_permission('outbound.view', 'read'));

-- INSERT/UPDATE/DELETE: has_permission('outbound.view','write') 이상 — 직접 정책
--   (HANDOFF 결정 #2: 비금전 기준데이터 성격이라 RPC 강제 불필요, lookup_values류 패턴)
CREATE POLICY outbound_influencers_insert ON public.outbound_influencers
  FOR INSERT TO authenticated
  WITH CHECK (public.has_permission('outbound.view', 'write'));

CREATE POLICY outbound_influencers_update ON public.outbound_influencers
  FOR UPDATE TO authenticated
  USING (public.has_permission('outbound.view', 'write'))
  WITH CHECK (public.has_permission('outbound.view', 'write'));

CREATE POLICY outbound_influencers_delete ON public.outbound_influencers
  FOR DELETE TO authenticated
  USING (public.has_permission('outbound.view', 'write'));

-- 인플루언서·anon 정책 0개 — 이 테이블은 관리자 전용 내부 자산(HANDOFF 명시).

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
-- ============================================================
/*

-- [V0] 테이블·컬럼 생성 확인
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'outbound_influencers'
ORDER BY ordinal_position;

-- [V1] RLS 정책 확인 (4행 기대: select/insert/update/delete)
SELECT policyname, cmd, roles::text, qual, with_check
FROM pg_policies
WHERE tablename = 'outbound_influencers'
ORDER BY policyname;

-- [V2] 트리거 확인
SELECT tgname, tgrelid::regclass, tgtype
FROM pg_trigger
WHERE tgrelid = 'public.outbound_influencers'::regclass AND NOT tgisinternal;

*/

-- ============================================================
-- 롤백
-- ============================================================
-- DROP POLICY IF EXISTS outbound_influencers_delete ON public.outbound_influencers;
-- DROP POLICY IF EXISTS outbound_influencers_update ON public.outbound_influencers;
-- DROP POLICY IF EXISTS outbound_influencers_insert ON public.outbound_influencers;
-- DROP POLICY IF EXISTS outbound_influencers_select ON public.outbound_influencers;
-- DROP TRIGGER IF EXISTS trg_outbound_influencers_updated_at ON public.outbound_influencers;
-- DROP FUNCTION IF EXISTS public.touch_outbound_influencers_updated_at();
-- DROP TABLE IF EXISTS public.outbound_influencers;
