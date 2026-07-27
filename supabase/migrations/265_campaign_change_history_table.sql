-- ============================================================
-- 265_campaign_change_history_table.sql
-- 캠페인 전체 항목 변경 이력 PR 1 — 1/2 (이력 테이블)
-- 사양서: docs/specs/2026-07-27-campaign-full-change-history.md §4-3·§4-4
--
-- 목적:
--   campaigns 표는 지금 「주의사항/참여방법/NG」 3영역만 변경 이력이 남고
--   (campaign_caution_history, 마이그레이션 077·109) 제목·모집 인원·기간·상태 같은
--   나머지 항목은 전혀 기록되지 않는다(2026-07-27 실측 확인: 모집 인원만 바꿔도
--   이력 0행). 이 마이그레이션은 그 나머지 항목을 기록할 신규 표만 만든다.
--   실제 기록(트리거)은 다음 마이그레이션 266 에서 이어진다.
--
-- 기존 표와의 관계 — 병존(A안, 사양서 §4-2):
--   caution_items / participation_steps / ng_items 는 이 표에 넣지 않는다.
--   그 3영역은 지금처럼 campaign_caution_history + record_caution_history() RPC
--   그대로 유지한다(신청자 수·경고 통과 여부 같은 화면 맥락 정보가 이미 거기 있어
--   새 표로 옮기면 정보 손실 + 이중 기록 위험이 생긴다 — 사양서 §2-1 ⑥).
--
-- 구조 — brand_application_history(마이그레이션 079)와 동일한 "필드별 1행" 모델:
--   한 번의 UPDATE(=한 번의 저장)에서 바뀐 컬럼마다 행 1개. 같은 저장에서 나온
--   행들은 change_group_id 로 묶어(사양서 §4-3) 화면에서 "저장 묶음 카드" 1개로
--   접어 보여줄 수 있게 한다(079 는 이 개념이 없었음 — 캠페인은 추적 컬럼이
--   48개로 훨씬 많아 묶음이 없으면 저장 1회에 수십 행이 스크롤을 뒤덮는다).
--
-- field_name 화이트리스트(48개, CHECK 제약으로 고정) — 사양서 §4-4 그대로 채택:
--   기본(8)  title / brand_id / brand_ko / brand_ja / brand_en / product / product_ko / product_url
--   모집(8)  recruit_type / channel / channel_match / primary_channel / slots /
--            min_followers / category / content_types
--   금액(3)  product_price / reward / reward_note
--   일정(8)  recruit_start / deadline / purchase_start / purchase_end /
--            visit_start / visit_end / submission_end / winner_announce
--   본문(5)  description / appeal / guide / hashtags / mentions
--   이미지(10) img1~img8 / image_url / image_crops
--   운영(3)  status / proxy_purchase / source_application_id
--   삭제(2)  deleted_at / deleted_by  ← Q5 결정(2026-07-27)으로 포함
--
--   실제 campaigns 컬럼 존재 여부는 전부 직접 확인 완료(마이그레이션 002·015·021·
--   026·034·036·041·043·051·072·074·088·172·197·254 등). 사양서 초안이 예시로
--   짚었던 winner_announce(043)/content_types(002)/appeal(원본)/image_crops(041)
--   포함 48개 전부 실존 컬럼 — 제외한 컬럼 없음.
--
--   화이트리스트에서 의도적으로 뺀 것(사양서 §4-4 「제외」 + 「보류」):
--     view_count(263) / applied_count(058) / updated_at(066) / first_active_at(140)
--       — 사용자 조작이 아니라 조회·신청·저장마다 자동 갱신되는 값이라 넣으면
--         실사용 트래픽만큼 이력이 폭증한다(사양서 §2-1 C3).
--     order_index — 순서 정리 1회에 수십 행이 쌓인다(§2-1 C4).
--     campaign_no / legacy_no — 연결·해제·브랜드 병합 시 서버가 재발급하는
--       채번 성격 컬럼, 이 감사와 목적이 다르다.
--     emoji — 실사용 없음.
--     caution_set_id/caution_items/participation_set_id/participation_steps/
--     ng_set_id/ng_items — 병존(A안)이라 새 표에서 제외, 기존 경로 유지.
--
-- 접근 정책(행 단위 보안):
--   SELECT 는 is_super_admin() 만(077 과 동일 — 이번 단계는 최고 관리자 전용
--   유지, 사양서 Q3 "동적 권한으로 조절"은 PR 4 에서 별도 처리).
--   INSERT/UPDATE/DELETE 정책은 정의하지 않는다 → 클라이언트 직접 쓰기 전부
--   암묵 거부. 266 의 SECURITY DEFINER 트리거 함수만 기록 가능(077·079 패턴).
--
-- 삭제 정책(Q6, 2026-07-27 결정):
--   campaign_id 는 ON DELETE CASCADE — 캠페인을 완전 삭제(purge_campaign)하면
--   이력도 함께 사라진다. 개인정보가 없는 표라 남겨도 되지만, 캠페인이 사라진
--   뒤에 남는 이력은 어느 캠페인 것인지 알 길이 없어 쓸모가 적다는 사용자 판단.
--   보관 삭제(soft delete, deleted_at 세팅)는 행 자체가 안 지워지므로 영향 없음
--   — 오히려 보관 삭제/복구 이력은 deleted_at/deleted_by 가 화이트리스트에
--   포함돼 있어 이 표에 정상적으로 남는다.
--
-- 인덱스:
--   (campaign_id, changed_at DESC) — 캠페인 상세 화면 타임라인 조회
--   (change_group_id)              — 저장 묶음 카드 펼침 조회
--
-- 영향:
--   신규 표만 추가. 기존 campaigns/campaign_caution_history 어느 것도 건드리지
--   않는다. 아직 트리거가 없으므로(266 에서 추가) 이 마이그레이션만 적용한
--   상태에서는 이 표가 항상 빈 채로 남는다 — 회귀 없음.
--
-- 롤백:
--   DROP TABLE IF EXISTS public.campaign_change_history CASCADE;
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.campaign_change_history (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id      uuid        NOT NULL REFERENCES public.campaigns(id) ON DELETE CASCADE,
  change_group_id  uuid        NOT NULL,   -- 저장 1회 = 같은 값(같은 UPDATE 문에서 나온 행들의 묶음 기준)
  changed_by       uuid        NULL,       -- admins.auth_id(auth.uid()). admins 행이 삭제돼도 이력 보존 위해 FK 미설정(077 패턴)
  changed_by_name  text        NULL,       -- 변경 시점 admins.name 스냅샷. NULL 이면 화면에서 "시스템 / 직접 수정" 표시
  changed_at       timestamptz NOT NULL DEFAULT now(),
  field_name       text        NOT NULL
                     CHECK (field_name IN (
                       'title','brand_id','brand','brand_ko','brand_ja','brand_en','product','product_ko','product_url',
                       'recruit_type','channel','channel_match','primary_channel','slots','min_followers','category','content_types',
                       'product_price','reward','reward_note',
                       'recruit_start','deadline','purchase_start','purchase_end','visit_start','visit_end','submission_end','winner_announce',
                       'description','appeal','guide','hashtags','mentions',
                       'img1','img2','img3','img4','img5','img6','img7','img8','image_url','image_crops',
                       'status','proxy_purchase','source_application_id',
                       'deleted_at','deleted_by'
                     )),
  old_value        jsonb       NULL,
  new_value        jsonb       NULL,
  change_source    text        NOT NULL DEFAULT 'admin'
                     CHECK (change_source IN ('admin', 'auto', 'system'))
                     -- admin  = 사람이 저장 버튼을 눌러 발생(기본값)
                     -- auto   = 서버가 일정에 따라 자동 전이(모집중 전환/모집마감/종료)한 것으로 추정
                     -- system = auth.uid() 가 없는 호출(서버 함수·SQL 직접 수정 등 로그인 세션 밖)
);

COMMENT ON TABLE public.campaign_change_history IS
  '[265] campaigns 전체 항목(주의사항/참여방법/NG 3영역 제외 — 그건 campaign_caution_history 병존) '
  '변경 이력. 필드별 1행, 같은 저장은 change_group_id 로 묶음. 기록은 266 의 AFTER UPDATE 트리거만.';
COMMENT ON COLUMN public.campaign_change_history.change_group_id IS
  '[265] 같은 UPDATE 트랜잭션에서 발생한 행들의 묶음 식별자. 화면에서 "저장 묶음 카드" 1개로 접어 표시.';
COMMENT ON COLUMN public.campaign_change_history.changed_by IS
  '[265] 변경자 auth.uid(). admins 행이 삭제돼도 이력이 끊기지 않도록 FK 미설정(077 선례).';
COMMENT ON COLUMN public.campaign_change_history.changed_by_name IS
  '[265] 변경 시점 admins.name 스냅샷. NULL = 로그인 세션 없이 발생(서버 함수/SQL 직접 수정).';
COMMENT ON COLUMN public.campaign_change_history.change_source IS
  '[265] admin=사람 저장 / auto=서버 자동 전이 추정 / system=auth.uid() 없음. 판정 로직은 266 트리거 함수.';

CREATE INDEX IF NOT EXISTS idx_campaign_change_history_campaign_changed_at
  ON public.campaign_change_history (campaign_id, changed_at DESC);

CREATE INDEX IF NOT EXISTS idx_campaign_change_history_group_id
  ON public.campaign_change_history (change_group_id);

-- ============================================================
-- 행 단위 보안 정책(RLS) — SELECT 만 부여. INSERT/UPDATE/DELETE 정책 없음(암묵 거부).
--   이번 단계는 077 과 동일하게 최고 관리자 전용 유지. 등급별 동적 권한 전환은
--   사양서 §4-7 마이그레이션 ③(PR 4, 선택)에서 별도 처리 — 이 마이그레이션 범위 아님.
-- ============================================================
ALTER TABLE public.campaign_change_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "campaign_change_history_select_super" ON public.campaign_change_history;

CREATE POLICY "campaign_change_history_select_super" ON public.campaign_change_history
  FOR SELECT TO authenticated
  USING (public.is_super_admin());

-- PostgREST 스키마 캐시 리로드 (신규 표 즉시 조회 가능하도록 — 254 등 최근 패턴)
NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 SQL (마이그레이션 적용 후 SQL Editor에서 실행 — 1단계)
-- ============================================================
-- [1] 표·인덱스 존재 확인
-- SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename='campaign_change_history';
-- SELECT indexname FROM pg_indexes WHERE schemaname='public' AND tablename='campaign_change_history';
-- 기대값: 표 1행, 인덱스 2행(campaign_id+changed_at, change_group_id) + PK 인덱스 1행

-- [2] 화이트리스트 CHECK 제약 확인 (범위 밖 값은 거부돼야 함 — 실제 캠페인 아무 것이나 사용)
-- INSERT INTO public.campaign_change_history (campaign_id, change_group_id, field_name)
--   VALUES ('<검증용_캠페인_ID>', gen_random_uuid(), 'view_count');
-- 기대값: 오류(new row violates check constraint) — view_count 는 화이트리스트에 없으므로 실패해야 정상

-- [3] RLS 확인 — INSERT 정책 자체가 없으므로 화이트리스트 안의 값이어도 실패해야 정상
-- INSERT INTO public.campaign_change_history (campaign_id, change_group_id, field_name)
--   VALUES ('<검증용_캠페인_ID>', gen_random_uuid(), 'title');
-- 기대값: 오류(row-level security policy) — SQL Editor 는 service_role 이라 통과할 수 있음, 그 경우
--         해당 행을 수동으로 DELETE 하고 클라이언트(anon/authenticated) 세션에서 재확인
-- ============================================================
