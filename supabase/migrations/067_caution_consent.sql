-- ============================================================
-- 067_caution_consent.sql
-- 캠페인 신청 시 "주의사항 동의" 기능 추가
-- 작성일: 2026-04-22
--
-- 배경:
--   캠페인에 PR 태그 필수·게시 기한 엄수 등 주의사항을 설정하고,
--   인플루언서가 신청 시 해당 주의사항에 명시적으로 동의하도록 한다.
--   주의사항 항목은 lookup_values(kind='caution')로 관리 가능하게 하고,
--   캠페인마다 사용할 항목 코드 배열과 커스텀 HTML을 저장할 컬럼을 추가한다.
--   신청 레코드에는 동의 시각과 동의 시점 스냅샷을 보존해 감사 추적에 활용한다.
--
-- 영향 테이블:
--   lookup_values     — kind CHECK 제약 확장 + kind='caution' 시드 5건
--   campaigns         — caution_lookup_codes, caution_custom_html 컬럼 추가
--   applications      — caution_agreed_at, caution_snapshot 컬럼 추가
--
-- RLS 영향:
--   campaigns/applications 컬럼 추가는 테이블 단위 기존 정책이 자동 커버.
--   lookup_values 는 SELECT 공개(기존) + CUD 관리자 전용(기존) 정책 적용.
--   신규 RLS 정책 추가 불필요.
--
-- 066 패턴 검토:
--   campaigns/applications 에 추가되는 모든 컬럼은 NULL 허용이므로
--   기존 레코드 초기화(UPDATE)가 필요하지 않다.
--   066의 3단계 NOT NULL 전환 패턴은 이번 건에 불필요.
--
-- 롤백:
--   -- Step 1: applications 컬럼 제거
--   ALTER TABLE public.applications
--     DROP COLUMN IF EXISTS caution_agreed_at,
--     DROP COLUMN IF EXISTS caution_snapshot;
--
--   -- Step 2: campaigns 컬럼 제거
--   ALTER TABLE public.campaigns
--     DROP COLUMN IF EXISTS caution_lookup_codes,
--     DROP COLUMN IF EXISTS caution_custom_html;
--
--   -- Step 3: caution 시드 제거 (선택적)
--   DELETE FROM public.lookup_values WHERE kind = 'caution';
--
--   -- Step 4: lookup_values.kind CHECK 제약 원복 (060 상태로)
--   ALTER TABLE public.lookup_values DROP CONSTRAINT IF EXISTS lookup_values_kind_check;
--   ALTER TABLE public.lookup_values
--     ADD CONSTRAINT lookup_values_kind_check
--     CHECK (kind IN (
--       'channel','category','content_type','ng_item',
--       'reject_reason','blacklist_reason','violation_reason'
--     ));
-- ============================================================

BEGIN;


-- ============================================================
-- Step 1: lookup_values.kind CHECK 제약 확장
--   현재 (060 기준): channel / category / content_type / ng_item /
--                    reject_reason / blacklist_reason / violation_reason
--   추가: 'caution'
--
--   PostgreSQL은 CHECK 제약을 인-플레이스 수정할 수 없어 DROP → ADD 방식 사용.
--   기존 행의 kind 값은 모두 유효하므로 ADD가 즉시 성공한다.
-- ============================================================

ALTER TABLE public.lookup_values DROP CONSTRAINT IF EXISTS lookup_values_kind_check;

ALTER TABLE public.lookup_values
  ADD CONSTRAINT lookup_values_kind_check
  CHECK (kind IN (
    'channel',
    'category',
    'content_type',
    'ng_item',
    'reject_reason',
    'blacklist_reason',
    'violation_reason',
    'caution'
  ));

COMMENT ON COLUMN public.lookup_values.kind IS
  'channel | category | content_type | ng_item | reject_reason | blacklist_reason | violation_reason | caution';


-- ============================================================
-- Step 2: lookup_values — kind='caution' 시드 5건
--   ON CONFLICT (kind, code) DO NOTHING: 재실행 안전 (024에서 UNIQUE(kind,code) 정의됨)
-- ============================================================

INSERT INTO public.lookup_values (kind, code, name_ko, name_ja, sort_order, active)
VALUES
  ('caution', 'pr_tag_required',       'PR 태그 필수',           '#PR タグの記載が必須です',            10, true),
  ('caution', 'no_negative_review',    '부정적 리뷰 금지',       '商品への否定的な表現はお控えください', 20, true),
  ('caution', 'delivery_address_jp_only', '일본 국내 배송지만 가능', '配送先は日本国内のみ対応します',  30, true),
  ('caution', 'post_within_deadline',  '게시 기한 엄수',         '投稿期限は必ずお守りください',        40, true),
  ('caution', 'keep_post_3months',     '게시물 3개월 유지',      '投稿は3ヶ月間削除しないでください',   50, true)
ON CONFLICT (kind, code) DO NOTHING;


-- ============================================================
-- Step 3: campaigns 컬럼 2개 추가
--   caution_lookup_codes: 이 캠페인에 적용할 caution 코드 배열
--                         (lookup_values.code 참조, FK 없음 — 유연성 우선)
--   caution_custom_html:  관리자가 직접 입력하는 추가 주의사항 HTML
--                         NULL이면 커스텀 주의사항 없음
-- ============================================================

ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS caution_lookup_codes text[] NOT NULL DEFAULT '{}'::text[],
  ADD COLUMN IF NOT EXISTS caution_custom_html  text NULL;

COMMENT ON COLUMN public.campaigns.caution_lookup_codes IS
  '신청 시 동의 필요한 주의사항 코드 배열. lookup_values(kind=caution).code 값 참조.';
COMMENT ON COLUMN public.campaigns.caution_custom_html IS
  '관리자가 캠페인별로 추가 작성하는 커스텀 주의사항 HTML. NULL이면 미사용.';


-- ============================================================
-- Step 4: applications 컬럼 2개 추가
--   caution_agreed_at: 인플루언서가 주의사항에 동의한 시각
--                      NULL이면 동의 불필요(주의사항 없는 캠페인)였거나
--                      마이그레이션 이전 신청 건
--   caution_snapshot:  동의 시점의 주의사항 내용 스냅샷 (감사 추적용)
--                      예: [{"code":"pr_tag_required","name_ja":"#PR..."},...]
--                      + 커스텀 HTML 포함 가능
-- ============================================================

ALTER TABLE public.applications
  ADD COLUMN IF NOT EXISTS caution_agreed_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS caution_snapshot  jsonb        NULL;

COMMENT ON COLUMN public.applications.caution_agreed_at IS
  '주의사항 동의 시각. NULL = 주의사항이 없던 캠페인이거나 마이그레이션 이전 신청.';
COMMENT ON COLUMN public.applications.caution_snapshot IS
  '동의 시점 주의사항 스냅샷. lookup 항목 변경 후에도 원본 내용 보존.';


-- PostgREST schema cache 즉시 재로드
NOTIFY pgrst, 'reload schema';

COMMIT;
