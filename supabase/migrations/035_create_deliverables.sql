-- ============================================================
-- migration: 035_create_deliverables
-- purpose  : 결과물(deliverables) 관리 시스템 Stage 0
--            - deliverables 테이블 신설 (영수증·게시물 URL 통합)
--            - deliverable_events 테이블 신설 (상태 변경 이력)
--            - receipts → deliverables dual-write 트리거
--            - 기존 receipts 전량 백필 (ON CONFLICT DO NOTHING)
--            - applications.oriented_at, reviewed_version 컬럼 추가
--            - RLS 정책, 낙관적 락 RPC 포함
--
-- 적용 순서:
--   1. 개발 DB (qysmxtipobomefudyixw.supabase.co) 먼저 적용 후 검증
--   2. 운영 DB (twofagomeizrtkwlhsuv.supabase.co) 적용
--
-- rollback:
--   -- 트리거 제거
--   DROP TRIGGER IF EXISTS trg_receipts_to_deliverables ON receipts;
--   DROP FUNCTION IF EXISTS public.sync_receipt_to_deliverable();
--   DROP TRIGGER IF EXISTS trg_deliverables_updated_at ON deliverables;
--   DROP FUNCTION IF EXISTS public.set_deliverables_updated_at();
--   DROP TRIGGER IF EXISTS trg_deliverable_status_event ON deliverables;
--   DROP FUNCTION IF EXISTS public.record_deliverable_status_event();
--   -- RPC 제거
--   DROP FUNCTION IF EXISTS public.update_deliverable_status(uuid, text, integer, text, text);
--   -- 테이블 제거 (CASCADE로 RLS 정책도 삭제됨)
--   DROP TABLE IF EXISTS deliverable_events CASCADE;
--   DROP TABLE IF EXISTS deliverables CASCADE;
--   -- applications 컬럼 제거
--   ALTER TABLE applications DROP COLUMN IF EXISTS oriented_at;
--   ALTER TABLE applications DROP COLUMN IF EXISTS reviewed_version;
-- ============================================================


-- ============================================================
-- 1. deliverables 테이블
-- ============================================================
CREATE TABLE IF NOT EXISTS deliverables (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- 연관 관계
  application_id       uuid NOT NULL REFERENCES applications(id) ON DELETE CASCADE,
  user_id              uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  campaign_id          uuid NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,

  -- 결과물 종류: 영수증(receipt) / 게시물 URL(post)
  kind                 text NOT NULL CHECK (kind IN ('receipt', 'post')),

  -- 검수 상태
  status               text NOT NULL DEFAULT 'pending'
                         CHECK (status IN ('pending', 'approved', 'rejected')),

  -- 반려 사유
  reject_reason        text,
  reject_template_code text,  -- 반려 사유 템플릿 코드 (기준 데이터화 예정)

  -- 검수자 정보 (관리자 auth.uid)
  reviewed_by          uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  reviewed_at          timestamptz,

  -- 낙관적 락: 동시 편집 충돌 방지
  version              integer NOT NULL DEFAULT 1,

  -- 제출 시각 (별도 관리 — created_at은 행 생성 시각, submitted_at은 최초 제출 시각)
  submitted_at         timestamptz NOT NULL DEFAULT now(),

  -- ── receipt 전용 필드 (kind='post'일 때 NULL 허용) ──
  receipt_url          text,        -- Supabase Storage URL
  purchase_date        date,
  purchase_amount      numeric,     -- 정수 아닌 numeric으로 (소수점 허용, 엔화·달러 모두 대응)
  memo                 text,

  -- ── post 전용 필드 (kind='receipt'일 때 NULL 허용) ──
  post_url             text,        -- 대표 게시물 URL (중복 제출 시 이력은 post_submissions에)
  post_channel         text,        -- 채널 자동 판별 결과 or 수동 선택 (instagram/x/tiktok/youtube/qoo10)
  post_submissions     jsonb NOT NULL DEFAULT '[]'::jsonb,
  -- post_submissions 구조:
  -- [{ "url": "...", "channel": "...", "submitted_at": "ISO8601" }, ...]

  -- 공통 타임스탬프
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE deliverables IS '캠페인 결과물 (영수증·게시물 URL) 통합 테이블. receipts 테이블과 dual-write로 동기화 (Stage 2까지 안전망).';
COMMENT ON COLUMN deliverables.version IS '낙관적 락용 버전. UPDATE 시 기대값과 불일치하면 차단.';
COMMENT ON COLUMN deliverables.post_submissions IS '게시물 URL 제출 이력 배열. 동일 URL 재제출 시 날짜만 누적, 다른 URL은 별도 행 아닌 이 배열에 추가.';
COMMENT ON COLUMN deliverables.submitted_at IS '최초 제출 시각. 재제출 시 updated_at만 갱신.';

-- ── 인덱스 ──
CREATE INDEX IF NOT EXISTS idx_deliverables_application_id ON deliverables(application_id);
CREATE INDEX IF NOT EXISTS idx_deliverables_campaign_id    ON deliverables(campaign_id);
CREATE INDEX IF NOT EXISTS idx_deliverables_user_id        ON deliverables(user_id);
CREATE INDEX IF NOT EXISTS idx_deliverables_status_kind    ON deliverables(status, kind);
CREATE INDEX IF NOT EXISTS idx_deliverables_submitted_at   ON deliverables(submitted_at DESC);

-- post URL 중복 방지: 동일 application에서 같은 post_url은 1건만 (NULL 제외)
-- kind='post' 이고 post_url IS NOT NULL 인 행에만 적용되는 partial unique index
CREATE UNIQUE INDEX IF NOT EXISTS uidx_deliverables_post_url
  ON deliverables(application_id, kind, post_url)
  WHERE kind = 'post' AND post_url IS NOT NULL;


-- ============================================================
-- 2. deliverable_events 테이블 (상태 변경·되돌리기 이력)
-- ============================================================
CREATE TABLE IF NOT EXISTS deliverable_events (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  deliverable_id  uuid NOT NULL REFERENCES deliverables(id) ON DELETE CASCADE,
  actor_id        uuid REFERENCES auth.users(id) ON DELETE SET NULL,  -- 관리자 또는 인플루언서 uid

  -- 액션 종류
  action          text NOT NULL CHECK (action IN (
                    'submit',     -- 인플루언서 최초 제출
                    'resubmit',   -- 인플루언서 재제출 (반려 후)
                    'approve',    -- 관리자 승인
                    'reject',     -- 관리자 반려
                    'revert'      -- 관리자 되돌리기 (approved/rejected → pending)
                  )),

  -- 상태 전이 기록
  from_status     text CHECK (from_status IN ('pending', 'approved', 'rejected')),
  to_status       text CHECK (to_status   IN ('pending', 'approved', 'rejected')),

  reason          text,     -- 반려 사유 자유 입력 (reject 시)
  metadata        jsonb,    -- 확장용 (버전, 이전 값 스냅샷 등)
  created_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE deliverable_events IS '결과물 상태 변경 이력. 트리거로 자동 기록, 직접 INSERT 금지.';

CREATE INDEX IF NOT EXISTS idx_deliverable_events_deliverable_id ON deliverable_events(deliverable_id);
CREATE INDEX IF NOT EXISTS idx_deliverable_events_created_at     ON deliverable_events(created_at DESC);


-- ============================================================
-- 3. applications 컬럼 추가
-- ============================================================

-- OT(오리엔테이션) 발송 체크 (기프팅·방문형 캠페인, 관리자 수동 토글)
ALTER TABLE applications
  ADD COLUMN IF NOT EXISTS oriented_at timestamptz;

COMMENT ON COLUMN applications.oriented_at IS 'OT 시트 발송 완료 시각. NULL = 미발송. 관리자 수동 토글.';

-- 낙관적 락: 관리자 심사 동시 편집 충돌 방지
ALTER TABLE applications
  ADD COLUMN IF NOT EXISTS reviewed_version integer NOT NULL DEFAULT 1;

COMMENT ON COLUMN applications.reviewed_version IS '낙관적 락용 버전. 심사 처리 시 기대값과 불일치하면 차단.';


-- ============================================================
-- 4. RLS 정책 설정
-- ============================================================
ALTER TABLE deliverables ENABLE ROW LEVEL SECURITY;
ALTER TABLE deliverable_events ENABLE ROW LEVEL SECURITY;


-- ── deliverables RLS ──

-- 인플루언서: 본인 결과물 조회
CREATE POLICY "deliverables_select_own"
  ON deliverables FOR SELECT
  USING (auth.uid() = user_id);

-- 인플루언서: 본인 결과물 등록 (status 기본값 pending, INSERT 시 status 강제 불가)
CREATE POLICY "deliverables_insert_own"
  ON deliverables FOR INSERT
  WITH CHECK (
    auth.uid() = user_id
    AND status = 'pending'  -- 인플루언서는 pending으로만 INSERT 가능
  );

-- 인플루언서: 본인 결과물 수정 (pending 상태일 때만, status 변경 불가)
-- status 컬럼 변경은 update_deliverable_status RPC(SECURITY DEFINER)로만 가능
CREATE POLICY "deliverables_update_own_pending"
  ON deliverables FOR UPDATE
  USING (auth.uid() = user_id AND status = 'pending')
  WITH CHECK (
    auth.uid() = user_id
    AND status = 'pending'  -- 인플루언서는 status를 'pending'으로만 유지 가능
  );

-- 관리자: 전체 조회
CREATE POLICY "deliverables_select_admin"
  ON deliverables FOR SELECT
  USING (is_admin());

-- 관리자: 전체 수정 (상태 변경 포함)
CREATE POLICY "deliverables_update_admin"
  ON deliverables FOR UPDATE
  USING (is_admin())
  WITH CHECK (is_admin());

-- 관리자: 삭제 (되돌리기 등 예외적 경우)
CREATE POLICY "deliverables_delete_admin"
  ON deliverables FOR DELETE
  USING (is_admin());


-- ── deliverable_events RLS ──

-- 인플루언서·관리자: 본인 관련 이벤트 조회 (deliverable 경유 조인으로 필터링)
CREATE POLICY "deliverable_events_select_own"
  ON deliverable_events FOR SELECT
  USING (
    -- 자신이 액터이거나, 자신의 결과물에 대한 이벤트
    actor_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM deliverables d
      WHERE d.id = deliverable_id AND d.user_id = auth.uid()
    )
  );

-- 관리자: 전체 조회
CREATE POLICY "deliverable_events_select_admin"
  ON deliverable_events FOR SELECT
  USING (is_admin());

-- INSERT는 SECURITY DEFINER 트리거/함수에서만 — 직접 INSERT 정책 없음 (차단)


-- ============================================================
-- 5. updated_at 자동 갱신 트리거 (deliverables)
-- ============================================================
CREATE OR REPLACE FUNCTION public.set_deliverables_updated_at()
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

DROP TRIGGER IF EXISTS trg_deliverables_updated_at ON deliverables;
CREATE TRIGGER trg_deliverables_updated_at
  BEFORE UPDATE ON deliverables
  FOR EACH ROW EXECUTE FUNCTION public.set_deliverables_updated_at();


-- ============================================================
-- 6. deliverable_events 자동 기록 트리거
--    deliverables.status 변경 감지 → events INSERT
-- ============================================================
CREATE OR REPLACE FUNCTION public.record_deliverable_status_event()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_action text;
BEGIN
  -- 상태가 변하지 않으면 이벤트 기록 안 함
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  -- 액션 결정
  v_action := CASE
    WHEN OLD.status = 'pending'   AND NEW.status = 'approved'  THEN 'approve'
    WHEN OLD.status = 'pending'   AND NEW.status = 'rejected'  THEN 'reject'
    WHEN OLD.status = 'approved'  AND NEW.status = 'pending'   THEN 'revert'
    WHEN OLD.status = 'rejected'  AND NEW.status = 'pending'   THEN 'resubmit'
    WHEN OLD.status = 'approved'  AND NEW.status = 'rejected'  THEN 'reject'
    WHEN OLD.status = 'rejected'  AND NEW.status = 'approved'  THEN 'approve'
    ELSE 'revert'
  END;

  INSERT INTO public.deliverable_events (
    deliverable_id,
    actor_id,
    action,
    from_status,
    to_status,
    reason,
    metadata
  ) VALUES (
    NEW.id,
    auth.uid(),  -- 트리거 호출 시 세션 uid (NULL이면 트리거/내부 처리)
    v_action,
    OLD.status,
    NEW.status,
    NEW.reject_reason,
    jsonb_build_object('version_before', OLD.version, 'version_after', NEW.version)
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_deliverable_status_event ON deliverables;
CREATE TRIGGER trg_deliverable_status_event
  AFTER UPDATE ON deliverables
  FOR EACH ROW EXECUTE FUNCTION public.record_deliverable_status_event();


-- ============================================================
-- 7. receipts → deliverables dual-write 트리거
--    Stage 2 전까지 기존 receipts INSERT/UPDATE/DELETE를 자동 동기화
-- ============================================================
CREATE OR REPLACE FUNCTION public.sync_receipt_to_deliverable()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.deliverables (
      id,              -- receipts.id 재사용 (1:1 추적 가능)
      application_id,
      user_id,
      campaign_id,
      kind,
      status,          -- 신규 영수증은 pending (검수 대기)
      receipt_url,
      purchase_date,
      purchase_amount,
      memo,
      submitted_at,
      created_at,
      updated_at
    ) VALUES (
      NEW.id,
      NEW.application_id,
      NEW.user_id,
      NEW.campaign_id,
      'receipt',
      'pending',
      NEW.receipt_url,
      NEW.purchase_date,
      NEW.purchase_amount::numeric,
      NEW.memo,
      COALESCE(NEW.created_at, now()),
      COALESCE(NEW.created_at, now()),
      now()
    )
    ON CONFLICT (id) DO NOTHING;  -- 이미 존재하면 무시 (idempotent)

  ELSIF TG_OP = 'UPDATE' THEN
    -- receipts 수정 시 deliverables 동기화 (status는 건드리지 않음 — 검수 상태 별도 관리)
    UPDATE public.deliverables SET
      receipt_url     = NEW.receipt_url,
      purchase_date   = NEW.purchase_date,
      purchase_amount = NEW.purchase_amount::numeric,
      memo            = NEW.memo,
      updated_at      = now()
    WHERE id = NEW.id AND kind = 'receipt';

  ELSIF TG_OP = 'DELETE' THEN
    -- receipts 삭제 시 deliverables도 삭제 (하드 삭제 — 이력 보존이 필요하면 soft delete로 변경)
    DELETE FROM public.deliverables WHERE id = OLD.id AND kind = 'receipt';

  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_receipts_to_deliverables ON receipts;
CREATE TRIGGER trg_receipts_to_deliverables
  AFTER INSERT OR UPDATE OR DELETE ON receipts
  FOR EACH ROW EXECUTE FUNCTION public.sync_receipt_to_deliverable();


-- ============================================================
-- 8. 낙관적 락 RPC: update_deliverable_status
--    인수:
--      p_id               — deliverable UUID
--      p_new_status       — 변경할 상태 ('approved'|'rejected'|'pending')
--      p_expected_version — 클라이언트가 알고 있는 현재 version
--      p_reason           — 반려 사유 (optional, reject 시 권장)
--      p_template_code    — 반려 사유 템플릿 코드 (optional)
--    반환:
--      updated_version int  — 갱신 후 버전 (충돌 시 -1 반환)
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_deliverable_status(
  p_id               uuid,
  p_new_status       text,
  p_expected_version integer,
  p_reason           text    DEFAULT NULL,
  p_template_code    text    DEFAULT NULL
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_rows_updated integer;
  v_new_version  integer;
BEGIN
  -- 관리자 권한 확인
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'permission_denied: 관리자만 결과물 상태를 변경할 수 있습니다.';
  END IF;

  -- 상태값 유효성 확인
  IF p_new_status NOT IN ('pending', 'approved', 'rejected') THEN
    RAISE EXCEPTION 'invalid_status: 유효하지 않은 상태값입니다. (pending|approved|rejected)';
  END IF;

  -- 낙관적 락 + 상태 업데이트
  UPDATE public.deliverables
  SET
    status               = p_new_status,
    reject_reason        = CASE WHEN p_new_status = 'rejected' THEN p_reason ELSE NULL END,
    reject_template_code = CASE WHEN p_new_status = 'rejected' THEN p_template_code ELSE NULL END,
    reviewed_by          = CASE WHEN p_new_status IN ('approved', 'rejected') THEN auth.uid() ELSE reviewed_by END,
    reviewed_at          = CASE WHEN p_new_status IN ('approved', 'rejected') THEN now() ELSE reviewed_at END,
    version              = version + 1
  WHERE
    id      = p_id
    AND version = p_expected_version;  -- 낙관적 락: 기대 버전과 다르면 0행 UPDATE

  GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

  IF v_rows_updated = 0 THEN
    -- 충돌 발생 — 클라이언트가 stale 데이터를 가지고 있음
    RETURN -1;
  END IF;

  -- 갱신된 version 반환
  SELECT version INTO v_new_version FROM public.deliverables WHERE id = p_id;
  RETURN v_new_version;
END;
$$;

COMMENT ON FUNCTION public.update_deliverable_status IS
  '결과물 상태 변경 RPC. 낙관적 락으로 동시 편집 충돌 방지. 반환값 -1 = 충돌(클라이언트 재조회 필요).';


-- ============================================================
-- 9. 최초 제출 이벤트 기록 RPC: submit_deliverable
--    트리거가 UPDATE만 감지하므로, 최초 INSERT 시 submit 이벤트를 별도 기록
--    인수:
--      p_deliverable_id — deliverable UUID
--    용도: 인플루언서가 결과물 INSERT 후 즉시 호출
-- ============================================================
CREATE OR REPLACE FUNCTION public.submit_deliverable(
  p_deliverable_id uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_exists boolean;
BEGIN
  -- 본인 결과물인지 확인
  SELECT EXISTS (
    SELECT 1 FROM public.deliverables
    WHERE id = p_deliverable_id AND user_id = auth.uid()
  ) INTO v_exists;

  IF NOT v_exists THEN
    RAISE EXCEPTION 'permission_denied: 본인의 결과물만 제출할 수 있습니다.';
  END IF;

  -- 첫 번째 이벤트가 없을 때만 submit 기록 (중복 방지)
  INSERT INTO public.deliverable_events (
    deliverable_id,
    actor_id,
    action,
    from_status,
    to_status,
    reason,
    metadata
  )
  SELECT
    p_deliverable_id,
    auth.uid(),
    'submit',
    NULL,
    'pending',
    NULL,
    '{}'::jsonb
  WHERE NOT EXISTS (
    SELECT 1 FROM public.deliverable_events
    WHERE deliverable_id = p_deliverable_id AND action = 'submit'
  );
END;
$$;

COMMENT ON FUNCTION public.submit_deliverable IS
  '최초 제출 이벤트 기록. INSERT 트리거가 없으므로 클라이언트가 결과물 INSERT 후 호출.';


-- ============================================================
-- 10. 기존 receipts 전량 백필 → deliverables (idempotent)
--     기존 영수증은 삽입 당시 자동 승인 처리되었으므로 status='approved'
--     receipts에 status 컬럼 없음 확인 완료 (020_create_receipts.sql 기준)
-- ============================================================
INSERT INTO deliverables (
  id,
  application_id,
  user_id,
  campaign_id,
  kind,
  status,
  receipt_url,
  purchase_date,
  purchase_amount,
  memo,
  submitted_at,
  created_at,
  updated_at
)
SELECT
  r.id,
  r.application_id,
  r.user_id,
  r.campaign_id,
  'receipt'         AS kind,
  'approved'        AS status,  -- 기존 영수증은 승인된 것으로 간주
  r.receipt_url,
  r.purchase_date,
  r.purchase_amount::numeric,
  r.memo,
  COALESCE(r.created_at, now()) AS submitted_at,
  COALESCE(r.created_at, now()) AS created_at,
  now()             AS updated_at
FROM receipts r
ON CONFLICT (id) DO NOTHING;  -- 이미 존재하는 행은 건너뜀 (재실행 안전)

-- ── 백필 검증 쿼리 (마이그레이션 후 실행하여 COUNT 일치 확인) ──
-- SELECT
--   (SELECT COUNT(*) FROM receipts)             AS receipts_count,
--   (SELECT COUNT(*) FROM deliverables
--    WHERE kind = 'receipt')                    AS deliverables_receipt_count,
--   (SELECT COUNT(*) FROM receipts) =
--   (SELECT COUNT(*) FROM deliverables
--    WHERE kind = 'receipt')                    AS counts_match;
--
-- 기대값: counts_match = true


-- ============================================================
-- 완료 확인용 코멘트
-- ============================================================
COMMENT ON TABLE deliverables IS
  '[035] Stage 0: 결과물 관리 시스템. receipts와 dual-write 동기화 중 (Stage 2에서 receipts deprecated 예정).';
