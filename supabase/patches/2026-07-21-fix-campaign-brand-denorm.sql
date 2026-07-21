-- =============================================================================
-- 패치: campaigns.brand(비정규화 한국어 표시 필드) 마스터(brands.name) 재동기화
-- 작성일: 2026-07-21
-- 대상 서버: 개발(qysmxtipobomefudyixw) 먼저 → 검증 → 운영(nrwtujmlbktxjgdwlpjj)
--
-- 증상 (운영 데이터에서 확인):
--   관리자 「결과물 관리」·「캠페인 관리」 목록의 브랜드명이 일부 캠페인만
--   일본어/영문으로 표시됨. 예: 벤튼 캠페인 다수 → "ベントン", 퓨어리카 → "Purelica".
--
-- 직접 원인:
--   campaigns.brand(관리자 표시용 비정규화 한국어 스냅샷)가 brands.name(마스터,
--   정상적으로 한국어)와 어긋나 있음. campaigns.brand_id 는 정상적으로 올바른
--   마스터 행을 가리키고 있음 — brand_id 연결 자체는 문제 없음.
--   관리자 표시 헬퍼 brandLabelAdmin(c) = c.brand || c.brand_en || c.brand_ja
--   (dev/lib/shared.js) 가 이 stale 값을 그대로 보여줘서 일본어로 노출됨.
--
--   ⚠️ brand_ja / brand_en 은 이 패치 대상이 아님 — 그대로 둔다.
--      인플루언서용 헬퍼 brandLabelInflu = c.brand_ja || ... 가 일본어를 정확히
--      기대하므로, brand_ja 를 건드리면 인플루언서 화면이 오히려 깨진다.
--
-- 근본 원인 조사 (코드 조사, 상세는 작업 응답 참조):
--   1) 레거시 캠페인은 브랜드 마스터(brands) 도입 이전 자유 텍스트 brand 필드였고,
--      마이그레이션 089(계층 채번 백필, STEP 4·5)가 이 자유 텍스트를 정규화 매칭해
--      brand_id 를 연결했다. 매칭되는 마스터가 없으면 그 자유 텍스트(일본어/영문
--      포함)를 이름으로 하는 새 brands 행을 자동 생성하기도 했다.
--   2) 이후 브랜드 정리(신규 한국어 마스터 생성·중복 브랜드 정리 등) 과정에서
--      campaigns.brand_id 는 올바른 한국어 마스터로 재연결됐지만, campaigns.brand
--      텍스트 자체는 그대로 방치됐다. brand_id 재연결은 merge_brands RPC(마이그
--      174·175, 텍스트도 동기화함)를 거치지 않은 경로였던 것으로 추정.
--   3) 마이그레이션 172(brand_ja/brand_en 컬럼 추가)는 신규 컬럼만 마스터에서
--      백필했고, 기존 brand(한국어) 컬럼은 "이미 올바르다"고 가정해 재검증하지
--      않았다 — 이 가정이 16건에 대해 틀렸다.
--   4) 마이그레이션 173(trg_brands_sync_campaigns)은 brands.name/name_ja/name_en
--      이 "수정"될 때만 발화하는 AFTER UPDATE 트리거다. campaigns.brand_id 재연결
--      이벤트에는 반응하지 않으므로, 위 1)·2) 로 어긋난 기존 행은 저절로 고쳐지지
--      않았다.
--   5) 관리자 캠페인 편집 모달을 열고 저장하면 onCampBrandChange()(dev/js/admin.js)
--      가 브랜드 드롭다운 선택값 기준으로 hidden brand 필드를 마스터 name 으로
--      덮어써 저장 시점에 자동 교정된다 — 하지만 이 16건은 브랜드 재연결 이후
--      한 번도 편집 모달에서 저장되지 않아 고쳐질 기회가 없었다(다수가 closed/ended
--      상태라 운영자가 재편집할 일이 적었을 것으로 추정).
--
-- 안전성 확인 — campaigns 테이블에 걸린 UPDATE 트리거 전수 점검 (2026-07-21):
--   - trg_campaign_no                          : BEFORE INSERT 전용 → UPDATE 무관
--   - trg_campaigns_first_active_at (마이그140) : BEFORE UPDATE OF status 전용
--                                                 → brand 만 바꾸는 UPDATE 는 미발화
--   - trg_reject_pending_on_campaign_end(176)   : AFTER UPDATE OF status 전용
--                                                 → brand 만 바꾸는 UPDATE 는 미발화
--   - trg_block_closed_caution_participation
--     (마이그075→097→108→156)                  : BEFORE UPDATE(전체 컬럼 대상)이지만
--                                                 caution_items/caution_set_id,
--                                                 participation_steps/participation_set_id,
--                                                 ng_items/ng_set_id 3종만 감시.
--                                                 brand 컬럼은 감시 대상이 아니므로
--                                                 closed/ended 캠페인도 안전하게 통과.
--   결론: brand 컬럼만 단독으로 UPDATE 하는 이 패치는 어떤 트리거도 부작용 없이
--         통과한다. 트리거 DISABLE 등 별도 우회 조치 불필요.
--
--   ⚠️ updated_at 은 의도적으로 갱신하지 않는다. campaigns.updated_at 은
--      "관리자가 실제로 편집한 시점"만 기록하는 컬럼(마이그066 주석 —
--      "조회수/자동 종료 등 시스템 UPDATE는 이 함수를 거치지 않아 수정일 오염
--      없음")이라, 이번처럼 백엔드 데이터 정합성 보정은 같은 원칙으로 건드리지
--      않는다.
--
-- 영향 범위:
--   - public.campaigns.brand 컬럼만 UPDATE. brand_ja/brand_en/brand_id/기타 컬럼 불변.
--   - 운영 기준 대상 16건 (brand_id 로 연결된 campaigns 중 brand <> brands.name).
--   - 개발서버는 별도로 재확인 필요(운영과 데이터가 다를 수 있음 — 0건일 수도 있음).
--
-- 실행 순서: 1(확인) → 2(미리보기) → 3(BEGIN/UPDATE/검증/COMMIT) → 4(사후 검증)
--   각 단계 결과 확인 후 다음 단계 진행 (한 번에 몰아서 실행 금지).
--
-- 롤백:
--   이 패치는 stale 값을 마스터 값으로 "정정"하는 것이라 되돌릴 이전 값을 별도
--   보존하지 않는다(정정이 곧 목적). 만약 되돌려야 한다면 아래로 이전 값을 복원:
--     -- 3단계 전 SELECT id, brand AS old_brand 결과를 미리 저장해뒀다가
--     UPDATE public.campaigns SET brand = '<old_brand>' WHERE id = '<id>';
--   (그래서 3단계 실행 전 반드시 2단계 미리보기 결과를 별도로 보관해 둘 것)
-- =============================================================================


-- =============================================================================
-- 1단계: 대상 건수 확인 (읽기 전용)
--
-- 기대값(운영): 16건 내외. 개발서버는 다를 수 있음(0건 포함).
-- =============================================================================
SELECT COUNT(*) AS mismatch_count
FROM public.campaigns c
JOIN public.brands b ON b.id = c.brand_id
WHERE c.brand_id IS NOT NULL
  AND c.brand IS DISTINCT FROM b.name;


-- =============================================================================
-- 2단계: 정정 전/후 미리보기 (읽기 전용) — 실행 전 결과를 반드시 별도 보관
-- =============================================================================
SELECT
  c.id                AS campaign_id,
  c.campaign_no,
  c.title,
  c.status,
  c.brand             AS current_brand_stale,
  b.name              AS master_brand_name,
  c.brand_ja,         -- 참고용, 변경 안 됨
  c.brand_en          -- 참고용, 변경 안 됨
FROM public.campaigns c
JOIN public.brands b ON b.id = c.brand_id
WHERE c.brand_id IS NOT NULL
  AND c.brand IS DISTINCT FROM b.name
ORDER BY c.created_at;


-- =============================================================================
-- 3단계: 실제 정정 UPDATE — BEGIN/COMMIT 으로 감싸서 결과 확인 후 커밋
--
-- brand_ja / brand_en / brand_id / updated_at 등 다른 컬럼은 절대 건드리지 않음.
-- =============================================================================
BEGIN;

UPDATE public.campaigns c
SET brand = b.name
FROM public.brands b
WHERE c.brand_id = b.id
  AND c.brand IS DISTINCT FROM b.name;

-- 변경 건수 확인 (COMMIT 전에 반드시 확인 — 1단계에서 본 건수와 일치해야 함)
SELECT COUNT(*) AS updated_rows
FROM public.campaigns c
JOIN public.brands b ON b.id = c.brand_id
WHERE c.brand_id IS NOT NULL
  AND c.brand = b.name;
-- 참고: 이 카운트는 "일치하는 전체 행"이라 패치 이전부터 이미 일치하던 행도 포함됨.
-- 진짜 이번 UPDATE로 바뀐 행 수는 별도로 세려면 아래를 COMMIT 전에 함께 실행:
--   (Postgres 는 UPDATE 문 실행 후 "UPDATE N" 메시지로 즉시 영향 행 수를 보여줌 —
--    SQL Editor 실행 결과 하단의 그 표시를 1단계 mismatch_count 와 대조할 것)

-- 결과 확인 후:
-- 1단계 mismatch_count 와 "UPDATE N" 이 일치하면 → COMMIT; 실행
-- 예상과 다르면 → ROLLBACK; 실행 후 원인 파악
ROLLBACK;  -- 처음엔 ROLLBACK 유지, 확인 후 COMMIT으로 교체


-- =============================================================================
-- 4단계: 정정 완료 검증 (COMMIT 이후 실행)
--
-- 기대값: mismatch_count_after = 0
-- =============================================================================
SELECT COUNT(*) AS mismatch_count_after
FROM public.campaigns c
JOIN public.brands b ON b.id = c.brand_id
WHERE c.brand_id IS NOT NULL
  AND c.brand IS DISTINCT FROM b.name;

-- brand_ja / brand_en 은 이 패치로 변경되지 않았어야 함 — 표본 대조
SELECT
  c.id, c.brand, c.brand_ja, c.brand_en, b.name, b.name_ja, b.name_en
FROM public.campaigns c
JOIN public.brands b ON b.id = c.brand_id
WHERE c.brand_id IS NOT NULL
ORDER BY c.updated_at DESC
LIMIT 20;


-- =============================================================================
-- 향후 재발 방지 권고 (이 패치와 별도 — 사양/코드 변경 필요, 여기서 적용하지 않음)
--
-- A) campaigns.brand_id 가 재연결(UPDATE)될 때도 brand/brand_ja/brand_en 을
--    마스터 값으로 재동기화하는 트리거 또는 서버 로직 보강.
--    현재 173(trg_brands_sync_campaigns)은 brands.name/name_ja/name_en 이
--    "수정"될 때만 발화 — campaigns.brand_id 재연결 이벤트는 감시하지 않는다.
--    예: BEFORE UPDATE OF brand_id ON public.campaigns 트리거로 NEW.brand_id 가
--    가리키는 brands 행의 name/name_ja/name_en 을 NEW.brand/brand_ja/brand_en 에
--    강제 주입 (관리자 클라이언트가 이미 하는 동기화를 DB 레벨에서 이중 보장).
-- B) 정기 데이터 정합성 점검 — campaigns.brand <> brands.name(brand_id 연결 건)
--    쿼리를 서비스 점검(project_service_health_audit) 체크리스트에 추가해
--    이번처럼 몇 달간 방치되는 것을 조기 발견.
-- =============================================================================
