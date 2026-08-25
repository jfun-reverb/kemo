-- ============================================================
-- 373_device_push_tokens.sql
-- 2026-06-22 (마지막 수정 2026-08-21 — 번호 재배정·재실행 안전성)
--
-- ⚠️ 적용 이력 — 「이걸 아직 안 돌렸나?」를 파일 이름으로 판단하지 말 것
--   이 파일은 **번호가 두 번 바뀌었다**: 처음 192 → 332 → 373.
--   개발 브랜치가 그 번호들을 먼저 써서 파일 이름이 겹쳤기 때문이다(332 는 일별 방문자수).
--   ★ 개발 데이터베이스: **적용됨** (2026-08-25 파일 통째로 재실행 완료).
--      처음엔 옛 192 번호로 들어갔고, 그 뒤 파일에 더한 두 가지(표 설명 문구 [192]→[373],
--      재실행 안전용 DROP POLICY IF EXISTS)가 빠져 있어 2026-08-25 에 함께 넣었다.
--      알맹이(표·행 단위 보안 정책·보안 켜짐)는 그전에도 정상이었고 어긋난 건 설명 문구뿐이었다.
--      재실행 후 실측: 설명 문구 [373] / 정책 device_push_tokens_select_own(SELECT) / 보안 켜짐 true / 저장된 토큰 0건.
--      (적용 이력은 파일 이름이 아니라 데이터베이스에만 있어, 이름만 보면 안 돌린 것처럼 보인다.
--       확인하려면 `device_push_tokens 표` 가 있는지 직접 조회할 것.)
--   ★ 운영 데이터베이스: **아직 안 들어갔다.** iOS 푸시를 운영에 켤 때 373·374 순서로 적용.
--   ⚠️ 이 파일은 통째로 다시 돌려도 안전하다(표·색인은 「있으면 건너뛰기」, 정책은 지우고 다시 만든다).
--
-- 목적:
--   iOS 네이티브 푸시 알림 기기 토큰 저장 구조.
--   실제 발송 로직(Edge Function / APNs 연동)은 다음 단계에서 구현.
--   🔴 **발송을 만들기 전에 374 파일 머리말의 「토큰 주인 바꾸기」 경고를 먼저 읽을 것.**
--      지금 이 구조가 안전한 이유 하나가 「발송이 없다」인데, 그건 통제가 아니라 기능의 부재다.
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
--       - INSERT/UPDATE/DELETE: 직접 DML 금지 — 374 마이그레이션의 RPC 경유
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
--   2. 374_device_push_token_rpcs.sql 적용
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
  '[373] iOS 기기 APNs 푸시 토큰 저장. 발송 로직은 별도 Edge Function(다음 단계). '
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
-- ⚠️ 정책 생성에는 「이미 있으면 건너뛰기」가 없어, 이 파일을 두 번 돌리면 여기서 멈춘다.
--    표·색인 생성은 두 번 돌려도 괜찮은데 이 줄만 그렇지 않아 파일 전체가 재실행 불가였다.
--    먼저 지우고 다시 만들어 재실행을 안전하게 한다(291·292 가 쓰는 방식).
DROP POLICY IF EXISTS "device_push_tokens_select_own" ON public.device_push_tokens;
CREATE POLICY "device_push_tokens_select_own"
  ON public.device_push_tokens
  FOR SELECT
  USING (
    auth.uid() = user_id
    OR public.is_admin()
  );

-- INSERT / UPDATE / DELETE 직접 DML 차단
-- → RLS 정책 없음(Default Deny). register_push_token / revoke_push_token RPC(SECURITY DEFINER)만 허용.
-- (마이그레이션 374에서 SECURITY DEFINER 함수로 우회)


COMMIT;
