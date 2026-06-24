-- ============================================================
-- 192_device_push_tokens.sql
-- 2026-06-22
--
-- 목적:
--   iOS 네이티브 푸시 알림 기기 토큰 저장 구조.
--   실제 발송 로직(Edge Function / APNs 연동)은 다음 단계에서 구현.
--   이 마이그레이션은 토큰 저장 테이블만 생성한다.
--
-- 사양서:
--   ios-app/ 폴더 — 인플루언서 Capacitor iOS 앱 (feature/ios-app 브랜치)
--
-- 변경 내용:
--   [A] device_push_tokens 테이블
--       - id uuid PK, user_id(→influencers.id CASCADE), token UNIQUE,
--         platform CHECK(ios), created_at, last_seen_at, revoked_at
--   [B] 인덱스
--       - idx_device_push_tokens_user_id  : 사용자별 토큰 조회
--       - idx_device_push_tokens_active   : revoked_at IS NULL 부분 인덱스
--         (발송 대상 조회 시 활성 토큰만 빠르게 필터)
--   [C] 행 단위 보안 정책(RLS)
--       - SELECT: 본인(auth.uid() = user_id) 또는 관리자(is_admin())
--       - INSERT/UPDATE/DELETE: 직접 DML 금지 — 193 마이그레이션의 RPC 경유
--         (RLS 정책 없음 → anon/authenticated 모두 직접 DML 차단)
--
-- 행 단위 보안 정책 영향:
--   새 테이블이므로 기존 정책과 충돌 없음.
--   notifications 테이블 및 기존 트리거는 건드리지 않음.
--
-- 운영 데이터 영향:
--   신규 테이블 — 기존 데이터 없음.
--
-- 적용 순서:
--   1. 개발서버 SQL Editor 실행 + 검증
--   2. 193_device_push_token_rpcs.sql 적용
--   3. 운영서버 동일 순서 적용
--
-- 롤백:
--   DROP TABLE IF EXISTS public.device_push_tokens;
-- ============================================================

BEGIN;


-- ============================================================
-- A. device_push_tokens 테이블
-- ============================================================
CREATE TABLE IF NOT EXISTS public.device_push_tokens (
  id            uuid          NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id       uuid          NOT NULL
                              REFERENCES public.influencers(id) ON DELETE CASCADE,
  token         text          NOT NULL UNIQUE,
  platform      text          NOT NULL DEFAULT 'ios'
                              CHECK (platform IN ('ios')),
  created_at    timestamptz   NOT NULL DEFAULT now(),
  last_seen_at  timestamptz   NOT NULL DEFAULT now(),
  revoked_at    timestamptz
);

COMMENT ON TABLE public.device_push_tokens IS
  '[192] iOS 기기 APNs 푸시 토큰 저장. 발송 로직은 별도 Edge Function(다음 단계). '
  'token 은 기기 단위 UNIQUE — 계정 전환 시 user_id·last_seen_at 갱신으로 이전 사용자 알림 차단.';

COMMENT ON COLUMN public.device_push_tokens.user_id IS
  'influencers.id(= auth.users.id)를 참조. 인플루언서 탈퇴 시 CASCADE 삭제.';
COMMENT ON COLUMN public.device_push_tokens.token IS
  'APNs device token. 기기 재등록/OS 업데이트 시 바뀔 수 있음 → register_push_token() 이 UPSERT로 갱신.';
COMMENT ON COLUMN public.device_push_tokens.platform IS
  '현재 ios 고정. 향후 android 추가 시 CHECK 조건 확장.';
COMMENT ON COLUMN public.device_push_tokens.last_seen_at IS
  '앱 실행 또는 재등록 시 갱신. 장기 미갱신 토큰은 향후 정리 작업 시 기준으로 사용 가능.';
COMMENT ON COLUMN public.device_push_tokens.revoked_at IS
  'revoke_push_token() 호출 시 NULL → 설정(소프트 해지) 또는 행 삭제(현재 DELETE 방식 채택). '
  '현재 구현에서는 DELETE 후 이 컬럼은 실질적으로 NULL 상태만 존재. 감사 목적 필요 시 소프트 전환 가능.';


-- ============================================================
-- B. 인덱스
-- ============================================================

-- 사용자별 토큰 목록 조회 (마이페이지·로그아웃 등)
CREATE INDEX IF NOT EXISTS idx_device_push_tokens_user_id
  ON public.device_push_tokens (user_id);

-- 발송 대상 조회: 활성(revoked_at IS NULL) 토큰만 빠르게 필터
-- 발송 백엔드(Edge Function)가 WHERE revoked_at IS NULL 조건으로 조회할 때 사용
CREATE INDEX IF NOT EXISTS idx_device_push_tokens_active
  ON public.device_push_tokens (user_id)
  WHERE revoked_at IS NULL;


-- ============================================================
-- C. 행 단위 보안 정책(RLS) 활성화
-- ============================================================
ALTER TABLE public.device_push_tokens ENABLE ROW LEVEL SECURITY;

-- 본인 또는 관리자만 조회 가능
-- (발송 백엔드는 service_role key 경유 → RLS 우회, 별도 정책 불필요)
CREATE POLICY "device_push_tokens_select_own"
  ON public.device_push_tokens
  FOR SELECT
  USING (
    auth.uid() = user_id
    OR public.is_admin()
  );

-- INSERT / UPDATE / DELETE 직접 DML 차단
-- → RLS 정책 없음(Default Deny). register_push_token / revoke_push_token RPC(SECURITY DEFINER)만 허용.
-- (마이그레이션 193에서 SECURITY DEFINER 함수로 우회)


COMMIT;
