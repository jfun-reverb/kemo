-- ============================================================
-- 235_message_translation.sql
-- 2026-07-13
--
-- 목적:
--   응모건 메시지(application_messages)에 자동 번역 파이프라인을 붙인다.
--   인플루언서(일본어)↔관리자(한국어)가 서로 다른 언어로 쓴 메시지를
--   상대방 언어로 번역해 "원문+번역" 병기 표시한다 (사양서 §결정 2).
--
-- 사양서:
--   docs/specs/2026-07-13-message-translation.md
--
-- 아키텍처 (사양서 §결정 4):
--   application_messages INSERT
--     → 데이터베이스 웹훅(Dashboard 수동 설정, 본 파일이 자동 등록하지 않음)
--     → Edge Function `translate-message` (supabase/functions/translate-message/index.ts)
--     → Google Cloud Translation v2 API 호출
--     → 결과를 application_messages 행에 UPDATE (service_role)
--
--   클라이언트는 이 함수를 직접 호출하지 않는다(functions.invoke 미사용) →
--   브라우저 간 교차 출처 호출이 아니므로 CORS 헤더가 필요 없다
--   (.claude/rules/supabase.md 「Edge Function CORS」 판정 기준 — 웹훅·서버 간 호출).
--
-- 신규 컬럼 3개 (application_messages):
--   body_translated  text  — 번역본 (상대 언어). NULL = 미번역(과거 메시지·처리 전·실패 포함)
--   translated_lang  text  — 번역 도착 언어 ('ko'|'ja')
--   translate_status text  — 'pending'|'done'|'failed'|'skipped'
--   ※ send_application_message RPC(마이그레이션 144)는 수정하지 않는다.
--     신규 메시지의 위 3컬럼은 DEFAULT 없이 전부 NULL 로 INSERT 되고,
--     상태 기록은 Edge Function 이 전담한다. 웹훅이 유실돼도 NULL 유지 →
--     조회 화면은 원문만 표시(폴백)하므로 발송·조회 흐름은 절대 막히지 않는다.
--
-- 재정의 함수 1개:
--   get_application_messages(uuid) — 반환 테이블에 위 3컬럼 추가.
--   반환 타입이 바뀌므로 DROP 후 CREATE 필요 (PostgreSQL 제약 — 기존 컬럼 뒤에
--   컬럼만 추가하는 것은 RETURNS TABLE 특성상 OUT 파라미터 목록이 바뀌어 DROP 필수).
--   DROP 시 GRANT/REVOKE 가 함께 사라지므로 마이그레이션 144 원본과 동일하게
--   재적용한다 (REVOKE ... FROM PUBLIC, anon / GRANT ... TO authenticated).
--
--   마스킹 규칙: body_translated 는 body 와 완전히 동일한 CASE 분기를 따른다
--   (마스킹되는 행은 번역본도 NULL로 가려 원문 존재 힌트를 차단 — 사양서 §의심 4).
--   translated_lang·translate_status 도 마스킹 시 함께 NULL 처리한다(둘 다
--   "번역이 있었다/진행 중이었다"는 사실 자체를 숨김).
--
-- 필요한 수동 설정 (본 SQL 파일로는 처리되지 않음, 개발/운영 각각):
--   1) Dashboard → Database → Webhooks → Create new Webhook
--        Name    : translate-message
--        Table   : public.application_messages
--        Events  : INSERT
--        Type    : Supabase Edge Functions
--        Function: translate-message
--        HTTP Method: POST / Headers: 기본
--   2) supabase secrets set GOOGLE_TRANSLATE_API_KEY=xxx --project-ref <ref>
--   3) supabase functions deploy translate-message --project-ref <ref>
--
-- 전제 조건:
--   마이그레이션 234 (orient_notify_debounce) 적용 완료
--   public.application_messages 존재 (마이그레이션 144)
--   public.is_admin() 함수 존재
--
-- 적용 순서:
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor 실행 + 검증
--   2. 운영서버(nrwtujmlbktxjgdwlpjj) SQL Editor 실행
--
-- 롤백:
--   BEGIN;
--   DROP FUNCTION IF EXISTS public.get_application_messages(uuid);
--   -- 144 원본 정의로 복원 (컬럼 3개 없는 버전) — 144 파일 §14 CREATE 문 그대로 재실행
--   ALTER TABLE public.application_messages
--     DROP COLUMN IF EXISTS body_translated,
--     DROP COLUMN IF EXISTS translated_lang,
--     DROP COLUMN IF EXISTS translate_status;
--   COMMIT;
--   ※ 롤백 후에는 144_application_messages.sql 의 §14 get_application_messages
--     CREATE 문(컬럼 3개 없는 원본)을 다시 실행해 함수를 원상 복구해야 한다.
-- ============================================================

BEGIN;


-- ============================================================
-- 1. application_messages — 번역 컬럼 3개 추가
-- ============================================================
ALTER TABLE public.application_messages
  ADD COLUMN body_translated  text NULL,
  ADD COLUMN translated_lang  text NULL
    CHECK (translated_lang IN ('ko','ja')),
  ADD COLUMN translate_status text NULL
    CHECK (translate_status IN ('pending','done','failed','skipped'));

COMMENT ON COLUMN public.application_messages.body_translated IS
  '[235] 자동 번역본 (상대 언어). NULL = 미번역 — 과거 메시지(마이그레이션 235 이전 발송)·'
  '웹훅 처리 전·번역 실패 모두 NULL 이며, 화면은 이 경우 원문만 표시(폴백). '
  '마스킹 대상 메시지(get_application_messages 의 body=NULL 케이스)는 이 컬럼도 함께 NULL 로 가려진다.';

COMMENT ON COLUMN public.application_messages.translated_lang IS
  '[235] 번역 도착 언어. ko = 한국어로 번역됨(인플루언서 원문을 관리자가 보는 경우), '
  'ja = 일본어로 번역됨(관리자 원문을 인플루언서가 보는 경우). body_translated 가 NULL 이면 이 값도 NULL.';

COMMENT ON COLUMN public.application_messages.translate_status IS
  '[235] 번역 처리 상태. pending=Edge Function 처리 대기(웹훅 지연 구간), '
  'done=번역 완료, failed=외부 번역 API 실패(원문 폴백 유지), '
  'skipped=번역 불필요(빈 본문·원문과 대상 언어가 동일하게 감지됨). '
  'NULL=이 메시지에 대해 번역 파이프라인이 아직 실행되지 않음(웹훅 미도달 포함).';


-- ============================================================
-- 2. get_application_messages 재정의 — 번역 컬럼 3개 반환 추가
--    원본: 마이그레이션 144 §14 (로직 100% 보존, 반환 컬럼만 확장)
--    반환 타입 변경이라 DROP 후 CREATE 필수 (GRANT 재적용 필요)
-- ============================================================
DROP FUNCTION IF EXISTS public.get_application_messages(uuid);

CREATE OR REPLACE FUNCTION public.get_application_messages(
  p_application_id uuid
) RETURNS TABLE (
  id                      uuid,
  application_id          uuid,
  sender_kind             text,
  sender_name             text,
  body                    text,        -- 마스킹 시 NULL
  attachments             jsonb,       -- 마스킹 시 '[]'::jsonb
  created_at              timestamptz,
  read_by_influencer_at   timestamptz,
  broadcast_id            uuid,
  hidden_by_admin_at      timestamptz,
  self_withdrawn_at       timestamptz,
  self_withdrawn_by_kind  text,
  mask_state              text,        -- 'visible' | 'hidden_by_admin' | 'self_withdrawn_influencer' | 'self_withdrawn_admin'
  body_translated         text,        -- [235] 번역본. 마스킹 시 NULL (body 와 동일 분기)
  translated_lang         text,        -- [235] 'ko'|'ja'. 마스킹 시 NULL
  translate_status        text         -- [235] 'pending'|'done'|'failed'|'skipped'. 마스킹 시 NULL
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
#variable_conflict use_column
DECLARE
  v_caller_is_admin  boolean;
  v_app_owner        uuid;
BEGIN
  -- 응모 소유자 확인
  SELECT user_id INTO v_app_owner
    FROM public.applications WHERE id = p_application_id;

  IF v_app_owner IS NULL THEN
    RAISE EXCEPTION '応募が見つかりません';
  END IF;

  -- 호출자 권한 판별
  v_caller_is_admin := public.is_admin();

  -- 인플루언서 본인 또는 관리자가 아니면 차단
  IF NOT v_caller_is_admin AND v_app_owner <> auth.uid() THEN
    RAISE EXCEPTION '権限がありません';
  END IF;

  RETURN QUERY
  SELECT
    m.id,
    m.application_id,
    m.sender_kind,
    m.sender_name,
    -- body 마스킹 분기 (144 원본과 동일)
    CASE
      WHEN v_caller_is_admin THEN
        -- 관리자: 인플루언서 본인 회수(케이스 E)만 마스킹
        CASE
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN NULL  -- 케이스 E: 양쪽 마스킹 (관리자도 못 봄)
          ELSE m.body  -- 케이스 D(강제숨김), F(관리자회수), G(visible) 모두 원본 유지
        END
      ELSE
        -- 인플루언서: 강제 숨김(A) 또는 회수(B) 시 마스킹
        CASE
          WHEN m.hidden_by_admin_at IS NOT NULL THEN NULL  -- 케이스 A
          WHEN m.self_withdrawn_at  IS NOT NULL THEN NULL  -- 케이스 B
          ELSE m.body                                      -- 케이스 C
        END
    END AS body,
    -- attachments 마스킹 분기 (body 와 동일 로직)
    CASE
      WHEN v_caller_is_admin THEN
        CASE
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN '[]'::jsonb
          ELSE m.attachments
        END
      ELSE
        CASE
          WHEN m.hidden_by_admin_at IS NOT NULL THEN '[]'::jsonb
          WHEN m.self_withdrawn_at  IS NOT NULL THEN '[]'::jsonb
          ELSE m.attachments
        END
    END AS attachments,
    m.created_at,
    m.read_by_influencer_at,
    m.broadcast_id,
    m.hidden_by_admin_at,
    m.self_withdrawn_at,
    m.self_withdrawn_by_kind,
    -- mask_state 계산 (144 원본과 동일)
    CASE
      WHEN v_caller_is_admin THEN
        CASE
          -- 우선순위: 인플루언서 본인 회수(E)를 D보다 먼저 판별
          -- (혹시 hidden_by_admin_at + self_withdrawn_at 둘 다 있는 예외 케이스 대비)
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN 'self_withdrawn_influencer'  -- 케이스 E
          WHEN m.hidden_by_admin_at IS NOT NULL
            THEN 'hidden_by_admin'            -- 케이스 D
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'admin'
            THEN 'self_withdrawn_admin'       -- 케이스 F
          ELSE 'visible'                      -- 케이스 G
        END
      ELSE
        CASE
          WHEN m.hidden_by_admin_at IS NOT NULL
            THEN 'hidden_by_admin'                    -- 케이스 A
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN 'self_withdrawn_influencer'           -- 케이스 B (본인 회수)
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'admin'
            THEN 'self_withdrawn_admin'               -- 케이스 B (관리자 회수)
          ELSE 'visible'                              -- 케이스 C
        END
    END AS mask_state,
    -- [235] body_translated — body 와 완전히 동일한 마스킹 분기
    --       (원문이 가려지면 번역본도 가려 "번역이 있었다"는 힌트조차 차단)
    CASE
      WHEN v_caller_is_admin THEN
        CASE
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN NULL
          ELSE m.body_translated
        END
      ELSE
        CASE
          WHEN m.hidden_by_admin_at IS NOT NULL THEN NULL
          WHEN m.self_withdrawn_at  IS NOT NULL THEN NULL
          ELSE m.body_translated
        END
    END AS body_translated,
    -- [235] translated_lang — body_translated 와 동일 분기로 마스킹
    CASE
      WHEN v_caller_is_admin THEN
        CASE
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN NULL
          ELSE m.translated_lang
        END
      ELSE
        CASE
          WHEN m.hidden_by_admin_at IS NOT NULL THEN NULL
          WHEN m.self_withdrawn_at  IS NOT NULL THEN NULL
          ELSE m.translated_lang
        END
    END AS translated_lang,
    -- [235] translate_status — 동일 분기로 마스킹 (진행 상태 자체도 숨김)
    CASE
      WHEN v_caller_is_admin THEN
        CASE
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN NULL
          ELSE m.translate_status
        END
      ELSE
        CASE
          WHEN m.hidden_by_admin_at IS NOT NULL THEN NULL
          WHEN m.self_withdrawn_at  IS NOT NULL THEN NULL
          ELSE m.translate_status
        END
    END AS translate_status
  FROM public.application_messages m
  WHERE m.application_id = p_application_id
  ORDER BY m.created_at ASC;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_application_messages(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_application_messages(uuid) TO authenticated;

COMMENT ON FUNCTION public.get_application_messages(uuid) IS
  '[144, 235] 응모건 메시지 목록 조회 RPC. 서버 측 마스킹 처리 (사양서 §9). '
  '인플루언서: 강제숨김+회수 시 body=NULL, attachments=[]. '
  '관리자: 인플루언서 본인 회수만 양쪽 마스킹, 강제숨김·관리자회수는 원본 유지 (비대칭). '
  'mask_state: visible|hidden_by_admin|self_withdrawn_influencer|self_withdrawn_admin. '
  '[235] body_translated/translated_lang/translate_status 추가 — 자동 번역 파이프라인'
  '(docs/specs/2026-07-13-message-translation.md). body 와 완전히 동일한 마스킹 분기를 따른다. '
  'SECURITY DEFINER + search_path 고정.';


COMMIT;
