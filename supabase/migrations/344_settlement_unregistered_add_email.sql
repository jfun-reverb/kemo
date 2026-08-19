-- ============================================================
-- 344_settlement_unregistered_add_email.sql
-- 관리자 정산 「미등록」 검색 — 이름·가나·이메일 통합 (사용자 결정 2026-08-19)
--
-- ▶ 왜
--   정산 「미등록」 탭의 검색을 이름·가나·이메일 세 가지로 확장하기로 했다. 그런데
--   `get_past_unregistered_settlements()` 는 지금 이메일을 안 내려준다(이름·가나만).
--   두 안(①화면이 인플루언서 명단을 따로 조회해 합치기 ②서버 함수가 이메일도 함께
--   내려주기) 중 **사용자가 ②를 선택**했다.
--
-- ▶ 베이스 = **337**(계보 232 → 262 → 300 → 324 → 337). 337 의 정의를 그대로 떼어
--   왔고, **더한 것은 딱 한 줄** — 반환 목록에 `influencer_email text` 를
--   `influencer_name_kana` 바로 뒤에 추가 + 본문에 `public.influencers` 를 한 번 더
--   조인해 그 값을 채웠다. 판정(`_settlement_cert_candidates()`)·금액 계산·
--   `WHERE` 조건(`c.is_success`)·정렬(원래 없음)은 337 과 **문자 단위로 동일**하다.
--
-- ▶ `DROP FUNCTION` 이 필요한 이유 — `CREATE OR REPLACE` 로는 안 된다
--   337 은 반환 항목 수·이름·자료형이 그대로였기 때문에 `CREATE OR REPLACE` 로
--   끝났다(337 자신의 주석 — "덮어쓰기로 끝나 호출부 영향이 0"). 이번엔 **반환
--   목록에 항목을 하나 끼워 넣으므로** PostgreSQL 이 `CREATE OR REPLACE` 를 거부한다
--   (반환 서명이 다른 함수로 취급됨) — `DROP FUNCTION` 후 `CREATE FUNCTION` 이 필수.
--
-- ▶ ⚠️ DROP 하면 실행 권한(GRANT)이 함께 사라진다 — 반드시 다시 건다
--   `DROP FUNCTION` 은 그 함수 오브젝트 자체를 지우므로 232 에서 건 `GRANT EXECUTE
--   ... TO authenticated` 도 함께 없어진다. 337 이 `CREATE OR REPLACE` 였던 건
--   "권한이 안 사라지는 방식"을 우연이 아니라 **의도적으로** 고른 것이었다(337 은
--   반환 서명이 안 바뀌어 그 방식이 가능했을 뿐). 이 파일은 반환 서명이 바뀌므로
--   그 방식을 못 쓰고, 대신 **아래에서 232 와 정확히 같은 두 줄을 다시 실행한다**:
--     REVOKE ALL ON FUNCTION public.get_past_unregistered_settlements() FROM PUBLIC;
--     GRANT EXECUTE ON FUNCTION public.get_past_unregistered_settlements() TO authenticated;
--   ⚠️ 이 두 줄을 빼먹으면 함수 자체는 정상 생성되지만, `authenticated` 역할(로그인한
--   관리자 세션)이 호출 권한을 잃어 **관리자 화면에서 "권한 없음"으로 조용히 죽는다**
--   (SQL 편집기는 소유자 권한이라 이 문제가 재현되지 않는다 — 아래 [검증 4] 참고).
--   262·300·324 도 반환 항목을 늘릴 때마다 이 두 줄을 매번 다시 실행해 왔다(선례).
--
-- ▶ 이 함수를 부르는 다른 데이터베이스 함수가 있는가 — 확인 결과: 없다
--   전수 검색(`grep -rn "get_past_unregistered_settlements()" supabase/migrations/*.sql`)
--   결과, 실제로 이 함수를 **호출(SELECT ... FROM ...)** 하는 곳은 없다.
--   `register_past_settlements()`(233)는 이름이 비슷해 헷갈리기 쉽지만, 실제 본문은
--   `_settlement_cert_candidates()` 를 **직접** 부른다(233:98) — 이 함수를 경유하지
--   않는다. 233 파일 안에 `get_past_unregistered_settlements()` 가 등장하는 자리는
--   전부 **검증 SQL 주석**(`/* ... */` 블록 안의 예시 쿼리)이지 함수 본문이 아니다.
--   운영 코드에서 이 함수를 부르는 곳은 `dev/lib/storage.js` 딱 한 곳
--   (`db.rpc('get_past_unregistered_settlements')`, 화면 전용 조회) 뿐이다.
--   → **DROP 순서 문제 없음.** 다른 함수의 몸체가 이 함수 이름을 참조하고 있어도
--   PostgreSQL 은 함수 본문 안의 이름 참조를 pg_depend 에 기록하지 않으므로(뷰·테이블
--   참조와 다름) DROP 자체는 항상 성공하고, 실제로 이 함수가 없는 상태에서 그 참조를
--   "실행"하는 순간에만 오류가 난다 — 이 파일은 DROP 직후 곧바로 CREATE 하므로
--   그 순간 자체가 존재하지 않는다(SQL 편집기 1회 실행은 암묵적 트랜잭션으로 묶임).
--
-- ▶ 이메일은 어디서 오는가 — `public.influencers` 원본 표를 직접 조인
--   `_settlement_cert_candidates()`(계보 …→318→331, 판정·금액의 단일 소스)는
--   **건드리지 않는다**(337 의 원칙 계승). 대신 이 함수가 그 반환값의 `influencer_id`
--   로 `public.influencers` 를 한 번 더 조인해 `email` 칸만 가져온다.
--   ⚠️ 이 함수는 `SECURITY DEFINER` 라 행 단위 보안 정책(RLS)을 우회해 원본 표를 직접
--   읽는다 — 이미 `_settlement_cert_candidates()` 자신도 같은 방식으로
--   `inf.name_kanji`/`inf.name_kana` 를 원본 표에서 직접 읽고 있어(331:158) 이번
--   추가도 **같은 패턴**이다. 인플루언서 민감정보 가림막 뷰
--   (`influencers_admin_view`, 마이그레이션 212·213)는 거치지 않는다 — 그 뷰가 가리는
--   6종은 `phone·line_id·paypal_email·zip·building·address` 뿐이고 **이메일은 가림
--   대상이 아니다**(212 파일 확인 완료, CLAUDE.md 에도 명시).
--   ⚠️ `LEFT JOIN` 을 쓴다(INNER 아님) — `_settlement_cert_candidates()` 자신이 이미
--   `influencers` 를 INNER JOIN 해서 만들어진 결과이므로 이 함수가 받는
--   `influencer_id` 는 항상 그 표에 실제 행이 있다는 게 지금은 보장된다. 그래도
--   INNER 로 또 걸면 "혹시 그 보장이 나중에 깨질 때" 이 목록에서 **행 자체가 조용히
--   사라진다**(관리자가 "미등록 건이 줄었다"고 착각). `LEFT JOIN` 이면 그런 경우에도
--   행은 남고 이메일 칸만 비게 되어(fail-open), `WHERE` 절·건수에 영향이 없다.
--
-- ▶ 개인정보 관점 — 어긋나지 않는다고 판단
--   이 함수는 페이팔 주소를 `has_paypal` 불리언으로만 내려주는 최소 노출 설계다
--   (232 원본 설계). 로그인 이메일을 더하는 건 이 설계와 **다른 층위** — 페이팔
--   주소는 관리자가 어디서도 평문으로 볼 수 없는 값이라 최소 노출이 의미 있지만,
--   로그인 이메일은 이미 관리자가 인플루언서 목록 페인(`#influencers`)과 정산 관리
--   페인(`#settlements`, `fetchSettlements` 경유 — 정산 완료 목록에는 원래부터
--   이메일이 없었지만 인플루언서 상세 모달에서는 이미 보임) 양쪽에서 평문으로 보는
--   값이다. 여기서 이메일을 더한다고 새로 열리는 접근 경로가 아니라고 판단했다.
--   ⚠️ 이 판단에 이견이 있으면 적용 전에 먼저 알려달라(사용자 요청).
--
-- ▶ 42804/42702 위험 — 이 저장소가 두 번 겪은 함정
--   `RETURNS TABLE` 의 항목 목록과 본문 `SELECT` 의 순서·자료형이 어긋나면 **적용은
--   성공하고 첫 호출에서** `42804`(반환 자료형 불일치, 마이그레이션 335 실측)나
--   `42702`(컬럼 모호, 2026-05-20 응모건 메시지 실측)가 난다. 아래에서 항목 순서를
--   `influencer_email text` 삽입 지점(= `influencer_name_kana` 바로 뒤) 하나만 빼고
--   337 과 정확히 같게 맞췄다 — 직접 대조할 것. [검증 2] 가 실제 호출이다.
-- ============================================================

DROP FUNCTION IF EXISTS public.get_past_unregistered_settlements();

CREATE FUNCTION public.get_past_unregistered_settlements()
RETURNS TABLE (
  application_id       uuid,
  influencer_id        uuid,
  influencer_name       text,
  influencer_name_kana  text,
  influencer_email       text,
  has_paypal            boolean,
  campaign_id           uuid,
  campaign_no           text,
  campaign_title        text,
  recruit_type          text,
  amount_jpy            bigint,
  amount_source          text,
  receipt_amount_jpy     bigint,
  amount_cap_jpy          bigint,
  amount_issue           text,
  cert_at               timestamptz,
  is_pre_cutoff          boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_cutoff timestamptz;
BEGIN
  IF NOT public.has_permission('settlement.view', 'read') THEN
    RAISE EXCEPTION 'permission_denied: settlement.view 권한이 없습니다'
      USING ERRCODE = '42501';
  END IF;

  SELECT cutoff_at INTO v_cutoff FROM public.settlement_settings WHERE id = 1;

  RETURN QUERY
  SELECT
    c.application_id,
    c.influencer_id,
    c.influencer_name,
    c.influencer_name_kana,
    inf.email AS influencer_email,
    (c.paypal_email IS NOT NULL AND btrim(c.paypal_email) <> '') AS has_paypal,
    c.campaign_id,
    c.campaign_no,
    c.campaign_title,
    c.recruit_type,
    c.amount_jpy,
    c.amount_source,
    c.receipt_amount_jpy,
    c.amount_cap_jpy,
    c.amount_issue,
    c.cert_at,
    -- [324, H-3 계승] true = 진짜 과거분(컷오프 이전·시각 불명·컷오프 미설정),
    --   false = 컷오프 이후인데 amount_issue 때문에 새로 노출된 건. 337 이후 컷오프
    --   조건 자체는 WHERE 에서 빠졌지만 이 구분값은 화면 안내 문구용으로 그대로 둔다.
    (v_cutoff IS NULL OR c.cert_at IS NULL OR c.cert_at < v_cutoff) AS is_pre_cutoff
  FROM public._settlement_cert_candidates() c
  -- [344] 이메일 칸만 채우기 위한 조인. LEFT JOIN 이유는 위 헤더 설명 참고.
  LEFT JOIN public.influencers inf ON inf.id = c.influencer_id
  -- ★ [337 계승] 컷오프 조건 없음 — 인증에 성공한 후보 전부(「미등록」 탭 = 정산
  --   행이 아직 없는 건 전부). 이 파일에서는 이 줄을 포함해 WHERE 절을 손대지 않았다.
  WHERE c.is_success;
    -- ⚠️ amount_issue 가 있는 행은 화면에서 체크박스 비활성화 대상으로 그대로 반환한다
    -- (300 원본 원칙 유지).
END;
$$;

COMMENT ON FUNCTION public.get_past_unregistered_settlements() IS
  '[344 재정의, 337 원본 대체(반환 컬럼 1개 추가: influencer_email)] 과거 미등록 '
  '인증성공 응모 목록(정산 페인 「미등록」 탭). [344] 관리자 검색을 이름·가나·이메일 '
  '통합으로 넓히기 위해 influencer_email(public.influencers 원본 표 LEFT JOIN, '
  'influencer.sensitive_pii 가림막 미적용 — 이메일은 가림 대상 아님) 을 '
  'influencer_name_kana 바로 뒤에 추가. 판정(_settlement_cert_candidates)·금액 계산·'
  'WHERE 조건(c.is_success)·정렬은 337 과 동일(무변경). 필터·권한 게이트도 337 그대로 '
  '(has_permission(settlement.view, read)).';

REVOKE ALL ON FUNCTION public.get_past_unregistered_settlements() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_past_unregistered_settlements() TO authenticated;

-- ── 적용 후 확인 (⚠️ 「적용 성공」은 「동작 확인」이 아니다 — 1단계씩 실행) ──────
--
-- [검증 1] 반환 서명 확인 — 17개 항목, influencer_email 이 4번째(influencer_name_kana
--   다음)에 있는지. (SQL 편집기에서 실행 가능 — 카탈로그 조회라 권한 가드 안 걸림)
--   SELECT p.parameter_name, p.data_type, p.ordinal_position
--     FROM information_schema.parameters p
--    WHERE p.specific_schema='public'
--      AND p.specific_name LIKE 'get_past_unregistered_settlements%'
--      AND p.parameter_mode='OUT'
--    ORDER BY p.ordinal_position;
--   기대: 17행, 5번째 줄(ordinal_position=5)이 influencer_email/text.
--   (application_id, influencer_id, influencer_name, influencer_name_kana 가 1~4번)
--
-- [검증 2] ★ 실제로 한 번 부른다 — 42804/42702 는 이 호출 전까지 안 드러난다.
--   ⚠️ SQL 편집기는 서비스 키라 has_permission 가드에 막힌다(42501) — 반드시
--   **실제 로그인한 관리자(campaign_admin 이상) 브라우저 콘솔**에서 실행할 것:
--     const {data, error} = await db.rpc('get_past_unregistered_settlements');
--     console.log(error, data?.[0]);
--   기대: error 없음, data[0] 에 influencer_email 키가 존재(값이 있는 행 기준).
--
-- [검증 3] 건수·기존 칸이 그대로인지 — 이 마이그레이션은 WHERE 절을 안 건드렸으므로
--   [검증 2] 의 data.length 가 적용 전과 같아야 한다(적용 전에 한 번 세어 둘 것).
--
-- [검증 4] 권한(GRANT)이 실제로 살아있는지 — DROP 이후 재부여를 빠뜨리지 않았는지
--   카탈로그로 확인(SQL 편집기 가능):
--   SELECT grantee, privilege_type
--     FROM information_schema.routine_privileges
--    WHERE specific_schema='public'
--      AND specific_name LIKE 'get_past_unregistered_settlements%';
--   기대: grantee='authenticated', privilege_type='EXECUTE' 행이 있어야 한다.
--   ⚠️ 이 확인만으로는 부족하다 — 소유자(postgres) 역할로 실행하는 SQL 편집기는
--   GRANT 유무와 무관하게 항상 성공하므로, **[검증 2]가 진짜 증거**다.
--
-- ── 롤백 ─────────────────────────────────────────────────────────────────
-- 337_settlement_unregistered_ignore_cutoff.sql 의 CREATE OR REPLACE 블록을 그대로
-- 다시 실행하면 된다 — 337 은 CREATE OR REPLACE 라 DROP 이 필요 없고, 반환 항목이
-- 337 당시 서명(influencer_email 없는 16개)으로 돌아가므로 **자동으로 서명이
-- 줄어드는 셈**이라 이번에도 실제로는 DROP 후 CREATE 가 일어난다(PostgreSQL 은
-- 반환 서명이 다른 CREATE OR REPLACE 를 내부적으로 거부하지 않고 처리하지만, 안전하게
-- 하려면 아래처럼 명시적으로 DROP 후 337 의 CREATE 블록을 실행할 것):
--   DROP FUNCTION IF EXISTS public.get_past_unregistered_settlements();
--   -- (이어서 337 파일의 "CREATE OR REPLACE FUNCTION public.get_past_unregistered_settlements()"
--   --  부터 "GRANT EXECUTE ON FUNCTION public.get_past_unregistered_settlements() TO authenticated;"
--   --  까지를 그대로 재실행 — 그 GRANT 두 줄이 있으므로 롤백 후에도 권한은 정상 복원된다)
