-- ============================================================
-- 260_campaigns_created_by.sql
-- 캠페인 등록 관리자 기록 — created_by 컬럼 추가
--
-- 배경 (코드 리뷰에서 확인됨):
--   dev/js/admin.js 의 addCampaign() 이 신규 캠페인 등록 시 camp 객체에
--   created_by: currentUser.id 를 실어 insertCampaign()
--   (db.from('campaigns').insert) 을 호출하기 시작했다. 그런데
--   campaigns 테이블에는 created_by 컬럼이 없어(마이그레이션 137의
--   created_by 는 admin_notices 전용이었고 campaigns 에는 추가 이력이
--   전혀 없었음) INSERT 가 PGRST204(존재하지 않는 컬럼) 오류로 전부
--   실패한다. 이 컬럼을 먼저 추가해야 addCampaign() 이 깨지지 않는다.
--
--   삭제된 캠페인 상세 모달(openDeletedCampDetail, dev/js/admin.js)이
--   c.created_by 값을 읽어 등록한 관리자 이름을 보여준다. 이 마이그레이션
--   적용 이후(2026-07-23~) 등록되는 캠페인만 값이 채워지고, 그 이전에
--   이미 등록된 기존 캠페인은 created_by 가 NULL로 남아 "정보 없음"으로
--   표시된다 (소급 백필 없음 — 등록 시점 기록이 없던 데이터라 되짚을 방법이 없음).
--
-- 변경 사항:
--   1. campaigns.created_by uuid NULL — 캠페인을 등록한 관리자의 auth_id.
--      FK 없음(의도적) — deleted_by(마이그레이션 254)·influencer_flags.updated_by
--      등 기존 감사용 컬럼과 동일 패턴. admins 행이 나중에 삭제/권한해제
--      되어도 "누가 등록했는지" 이력이 끊기지 않도록 참조 무결성 제약을
--      걸지 않는다.
--   2. 인덱스 없음 — created_by 로 campaigns 를 필터링/조회하는 화면·쿼리가
--      없다(단건 상세 모달에서 auth_id 로 admins 를 역조회하는 용도뿐).
--      마이그레이션 254 의 deleted_by 도 같은 이유로 인덱스가 없어 일관성을
--      맞췄다(반면 deleted_at 은 「삭제됨」 탭 목록 조회에 실제 쓰여 부분
--      인덱스가 있음 — 조회 패턴이 다르므로 다른 처리가 맞다).
--
-- RLS 영향 없음 확인:
--   campaigns 의 행 단위 보안 정책(마이그레이션 001_enable_rls.sql)은
--   campaigns_select_public(누구나 SELECT) / campaigns_insert_admin
--   / campaigns_update_admin / campaigns_delete_admin 4개이며, 전부
--   is_admin() 판정만 검사하고 created_by(또는 다른 어떤 컬럼값)도
--   참조하지 않는다. 따라서 이 컬럼 추가는 기존 권한 동작에 영향이 없다.
--
-- 이 마이그레이션은 컬럼만 추가한다. 값 채우기는 addCampaign() 이 INSERT
-- 시점에 currentUser.id 를 실어 보내는 것으로 이미 클라이언트 쪽에서
-- 처리되어 있다(이 마이그레이션 적용 전까지는 그 INSERT 가 실패하고 있었음).
--
-- 롤백:
--   ALTER TABLE public.campaigns DROP COLUMN IF EXISTS created_by;
-- ============================================================

ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS created_by uuid NULL;

COMMENT ON COLUMN public.campaigns.created_by IS
  '[260] 캠페인을 등록한 관리자 auth_id (감사용). 2026-07-23 이 마이그레이션 '
  '적용 이후 등록분부터 기록되며, 그 이전 등록된 캠페인은 NULL(정보 없음). '
  'FK 없음 — admins 행이 나중에 삭제/권한해제 되어도 "누가 등록했는지" '
  '이력이 끊기지 않도록 deleted_by(254) 등 기존 감사 컬럼과 동일 패턴을 따름.';

-- PostgREST 스키마 캐시 리로드 (신규 컬럼 즉시 반영 — 252·254 컬럼 마이그레이션 패턴)
NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (마이그레이션 적용 후 SQL Editor에서 아래 순서대로 1단계씩 실행)
-- ============================================================
-- [1] 컬럼 존재 + nullable 확인
-- SELECT column_name, data_type, is_nullable
--   FROM information_schema.columns
--  WHERE table_schema='public' AND table_name='campaigns'
--    AND column_name = 'created_by';

-- [2] 기존 행은 전부 NULL 인지 확인 (신규 등록 전이면 count 가 전체 행수와 같아야 함)
-- SELECT count(*) AS total_rows,
--        count(*) FILTER (WHERE created_by IS NULL) AS null_created_by
--   FROM public.campaigns;
