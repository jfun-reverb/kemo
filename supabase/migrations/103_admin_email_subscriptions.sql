-- ════════════════════════════════════════════════════════════════════
-- migration 103: 관리자 메일 수신 설정 분리 (멀티 메일 종류)
-- ════════════════════════════════════════════════════════════════════
--
-- 사양: docs/specs/2026-05-11-admin-email-subscriptions.md
--
-- 배경:
--   기존 admins.receive_brand_notify (boolean) 는 「브랜드 서베이 접수」
--   단일 메일에만 적용. 응모 취소·기타 알림 등 메일 종류가 늘어남에
--   따라 메일별 on/off 를 다중 관리할 수 있는 구조로 분리한다.
--
-- 변경 사항:
--   1. admin_email_subscriptions 신규 테이블 (admin_id + mail_kind)
--   2. 행 단위 보안 정책(RLS) 2건 — SELECT 관리자, CUD 본인 또는 super_admin
--   3. lookup_values(kind='admin_email_kind') 시드 2건
--   4. 기존 admins.receive_brand_notify=true 행 이관
--   5. admins.receive_brand_notify 컬럼 COMMENT 로 deprecated 표시
--   6. get_subscribed_admin_emails(p_mail_kind) 헬퍼 함수
--
-- 안전:
--   - DROP COLUMN admins.receive_brand_notify 는 본 마이그레이션 범위
--     외 (다음 배포 안정성 확인 후 별도 마이그레이션)
--   - 이관은 idempotent (ON CONFLICT DO NOTHING)
-- ════════════════════════════════════════════════════════════════════

-- ── 1. admin_email_subscriptions 신규 테이블 ────────────────────────
CREATE TABLE IF NOT EXISTS public.admin_email_subscriptions (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_id    uuid NOT NULL REFERENCES public.admins(id) ON DELETE CASCADE,
  mail_kind   text NOT NULL,
  subscribed  boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid REFERENCES auth.users(id) ON DELETE SET NULL,

  UNIQUE (admin_id, mail_kind)
);

CREATE INDEX IF NOT EXISTS admin_email_subscriptions_admin_idx
  ON public.admin_email_subscriptions (admin_id);

CREATE INDEX IF NOT EXISTS admin_email_subscriptions_kind_subscribed_idx
  ON public.admin_email_subscriptions (mail_kind, subscribed)
  WHERE subscribed = true;

COMMENT ON TABLE public.admin_email_subscriptions IS
  '관리자별 메일 수신 구독 설정. (admin_id, mail_kind) 조합으로 on/off. '
  'mail_kind 는 lookup_values(kind=''admin_email_kind'') code 참조. '
  'subscribed=false 행도 허용 (명시적 끄기 흔적). '
  '도입: migration 103 (2026-05-11).';

-- ── 2. 행 단위 보안 정책 (RLS) ──────────────────────────────────────
ALTER TABLE public.admin_email_subscriptions ENABLE ROW LEVEL SECURITY;

-- SELECT: 모든 관리자 (super_admin 이 다른 관리자 설정 조회 + 본인 설정 조회)
DROP POLICY IF EXISTS admin_email_sub_select_admin
  ON public.admin_email_subscriptions;
CREATE POLICY admin_email_sub_select_admin
  ON public.admin_email_subscriptions FOR SELECT
  USING (public.is_admin());

-- INSERT/UPDATE/DELETE: super_admin 또는 본인 행만
DROP POLICY IF EXISTS admin_email_sub_cud_self_or_super
  ON public.admin_email_subscriptions;
CREATE POLICY admin_email_sub_cud_self_or_super
  ON public.admin_email_subscriptions FOR ALL
  USING (
    public.is_super_admin()
    OR admin_id IN (SELECT id FROM public.admins WHERE auth_id = auth.uid())
  )
  WITH CHECK (
    public.is_super_admin()
    OR admin_id IN (SELECT id FROM public.admins WHERE auth_id = auth.uid())
  );

-- ── 3. lookup_values 시드 — 메일 종류 카탈로그 ──────────────────────
INSERT INTO public.lookup_values (kind, code, name_ko, name_ja, sort_order, active)
VALUES
  ('admin_email_kind', 'brand_notify',       '브랜드 서베이 접수', 'ブランドサーベイ受付', 10, true),
  ('admin_email_kind', 'application_cancel', '응모 취소 알림',    '応募取消通知',         20, true)
ON CONFLICT (kind, code) DO NOTHING;

-- ── 4. 기존 admins.receive_brand_notify=true 데이터 이관 ────────────
-- idempotent: 이미 이관된 행은 ON CONFLICT 로 건너뜀
INSERT INTO public.admin_email_subscriptions (admin_id, mail_kind, subscribed)
SELECT id, 'brand_notify', true
FROM public.admins
WHERE receive_brand_notify = true
ON CONFLICT (admin_id, mail_kind) DO NOTHING;

-- ── 5. 기존 컬럼 deprecated 표시 (DROP 은 별도 마이그레이션) ─────────
COMMENT ON COLUMN public.admins.receive_brand_notify IS
  'DEPRECATED (2026-05-11, migration 103). '
  '대체: admin_email_subscriptions(mail_kind=''brand_notify''). '
  '안정성 확인 후 별도 마이그레이션에서 DROP 예정.';

-- ── 6. 헬퍼 함수 — 특정 메일 종류 구독 관리자 이메일 목록 ────────────
-- Edge Function (notify-brand-application, notify-application-cancelled 등)
-- 이 호출. SECURITY DEFINER 로 RLS 우회하되 search_path 고정으로 탈취 방어.
CREATE OR REPLACE FUNCTION public.get_subscribed_admin_emails(p_mail_kind text)
RETURNS TABLE (email text)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT a.email
  FROM public.admins a
  JOIN public.admin_email_subscriptions s ON s.admin_id = a.id
  WHERE s.mail_kind = p_mail_kind
    AND s.subscribed = true;
$$;

GRANT EXECUTE ON FUNCTION public.get_subscribed_admin_emails(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_subscribed_admin_emails(text) TO service_role;

COMMENT ON FUNCTION public.get_subscribed_admin_emails(text) IS
  '특정 메일 종류를 구독 중인 관리자 이메일 목록 반환. '
  'Edge Function 의 수신자 조회 헬퍼. '
  '도입: migration 103 (2026-05-11).';
