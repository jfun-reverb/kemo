-- ============================================================
-- migration: 054_admin_receive_brand_notify
-- purpose  : admins 테이블에 '광고주 신청 알림 수신' 플래그 추가
--            - notify-brand-application Edge Function이
--              이 플래그가 true인 관리자에게만 알림 메일 발송
--            - 관리자 계정 페인 UI에서 토글 가능
--
-- 적용:
--   1. 개발 DB (qysmxtipobomefudyixw)
--   2. 운영 DB (twofagomeizrtkwlhsuv)
--   3. 초기 수신자(jfun@jfun.co.kr)를 기본 true로 설정하고 싶으면
--      적용 후 별도 UPDATE 실행 (파일 하단 참고)
-- ============================================================

ALTER TABLE admins
  ADD COLUMN IF NOT EXISTS receive_brand_notify boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN admins.receive_brand_notify IS
  '[054] 광고주(브랜드) 신청 폼 접수 시 알림 메일 수신 여부 — notify-brand-application Edge Function이 참조';


-- ============================================================
-- 초기 수신자 설정 (필요 시)
-- admins 테이블에 jfun@jfun.co.kr 계정이 있다면 기본 수신자로 지정
-- 없다면 관리자 페이지에서 수동으로 체크하거나 UPDATE 실행
-- ============================================================
UPDATE admins SET receive_brand_notify = true
  WHERE email = 'jfun@jfun.co.kr';


-- ============================================================
-- ROLLBACK
-- ============================================================
-- ALTER TABLE admins DROP COLUMN IF EXISTS receive_brand_notify;
