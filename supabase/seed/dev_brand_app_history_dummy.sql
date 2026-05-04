-- ============================================================
-- dev_brand_app_history_dummy.sql
-- 변경 이력(brand_application_history) UI 검증용 더미 데이터
--
-- 대상 DB: 개발(qysmxtipobomefudyixw) 전용. 운영 DB 실행 금지!
-- 사용법: Supabase SQL Editor에 전체 붙여넣기 → Run
--
-- 전제: migration 079 이미 적용 완료 + dev_brand_app_dummy.sql 신청 row가 들어가 있음
-- 동작: 신청별로 1~5건씩 다양한 필드 변경 history 생성
--   - 트리거를 우회하지 않고 INSERT (트리거가 INSERT 대상 아니라 무관)
--   - changed_by_name 만 채워서 시각 검증 (changed_by uuid는 NULL)
--   - changed_at 을 의도적으로 흩어서 정렬 검증
-- ============================================================

-- 변경 이력 추가 (신청 5건에 다양한 history 케이스)
WITH apps AS (
  SELECT id, application_no, status, admin_memo, quote_sent_at, products
  FROM public.brand_applications
  ORDER BY created_at DESC
  LIMIT 6
),
target AS (
  SELECT id, application_no FROM apps WHERE application_no LIKE 'JFUN-%' LIMIT 6
)
INSERT INTO public.brand_application_history
  (application_id, changed_by_name, changed_at, field_name, old_value, new_value)
SELECT * FROM (
  -- 신청 1: status 흐름 (new → reviewing → quoted)
  SELECT (SELECT id FROM target ORDER BY application_no LIMIT 1 OFFSET 0)::uuid,
         '김영근1', (now() - interval '5 days'),
         'status', to_jsonb('new'::text), to_jsonb('reviewing'::text)
  UNION ALL
  SELECT (SELECT id FROM target ORDER BY application_no LIMIT 1 OFFSET 0)::uuid,
         '김영근1', (now() - interval '4 days'),
         'admin_memo', 'null'::jsonb, to_jsonb('초도 검수 진행. 5/6 견적 발송 예정'::text)
  UNION ALL
  SELECT (SELECT id FROM target ORDER BY application_no LIMIT 1 OFFSET 0)::uuid,
         '박영업', (now() - interval '3 days'),
         'status', to_jsonb('reviewing'::text), to_jsonb('quoted'::text)
  UNION ALL
  SELECT (SELECT id FROM target ORDER BY application_no LIMIT 1 OFFSET 0)::uuid,
         '박영업', (now() - interval '3 days'),
         'quote_sent_at', 'null'::jsonb, to_jsonb((now() - interval '3 days')::text)
  UNION ALL

  -- 신청 2: 메모 여러번 갱신
  SELECT (SELECT id FROM target ORDER BY application_no LIMIT 1 OFFSET 1)::uuid,
         '김영근1', (now() - interval '7 days'),
         'admin_memo', 'null'::jsonb, to_jsonb('첫 메모: 견적 검토 중'::text)
  UNION ALL
  SELECT (SELECT id FROM target ORDER BY application_no LIMIT 1 OFFSET 1)::uuid,
         '김영근1', (now() - interval '6 days'),
         'admin_memo', to_jsonb('첫 메모: 견적 검토 중'::text), to_jsonb('견적 1차 ₩1,200,000 검토 완료'::text)
  UNION ALL
  SELECT (SELECT id FROM target ORDER BY application_no LIMIT 1 OFFSET 1)::uuid,
         '박영업', (now() - interval '2 days'),
         'admin_memo', to_jsonb('견적 1차 ₩1,200,000 검토 완료'::text),
                       to_jsonb('견적 1차 ₩1,200,000 검토 완료\n클라이언트 재견적 요청. 5/4 회신 예정'::text)
  UNION ALL

  -- 신청 3: 견적서 전달일 변경
  SELECT (SELECT id FROM target ORDER BY application_no LIMIT 1 OFFSET 2)::uuid,
         '김영근1', (now() - interval '10 days'),
         'status', to_jsonb('new'::text), to_jsonb('reviewing'::text)
  UNION ALL
  SELECT (SELECT id FROM target ORDER BY application_no LIMIT 1 OFFSET 2)::uuid,
         '김영근1', (now() - interval '8 days'),
         'quote_sent_at', 'null'::jsonb, to_jsonb('2026-04-25T10:00:00+09:00'::text)
  UNION ALL
  SELECT (SELECT id FROM target ORDER BY application_no LIMIT 1 OFFSET 2)::uuid,
         '박영업', (now() - interval '6 days'),
         'quote_sent_at', to_jsonb('2026-04-25T10:00:00+09:00'::text),
                          to_jsonb('2026-04-28T14:30:00+09:00'::text)
  UNION ALL

  -- 신청 4: status 깔때기 끝까지 (new → quoted → paid → done)
  SELECT (SELECT id FROM target ORDER BY application_no LIMIT 1 OFFSET 3)::uuid,
         '김영근1', (now() - interval '20 days'),
         'status', to_jsonb('new'::text), to_jsonb('reviewing'::text)
  UNION ALL
  SELECT (SELECT id FROM target ORDER BY application_no LIMIT 1 OFFSET 3)::uuid,
         '김영근1', (now() - interval '18 days'),
         'status', to_jsonb('reviewing'::text), to_jsonb('quoted'::text)
  UNION ALL
  SELECT (SELECT id FROM target ORDER BY application_no LIMIT 1 OFFSET 3)::uuid,
         '박영업', (now() - interval '15 days'),
         'status', to_jsonb('quoted'::text), to_jsonb('paid'::text)
  UNION ALL
  SELECT (SELECT id FROM target ORDER BY application_no LIMIT 1 OFFSET 3)::uuid,
         '박영업', (now() - interval '12 days'),
         'status', to_jsonb('paid'::text), to_jsonb('orient_sheet_sent'::text)
  UNION ALL
  SELECT (SELECT id FROM target ORDER BY application_no LIMIT 1 OFFSET 3)::uuid,
         '박영업', (now() - interval '8 days'),
         'status', to_jsonb('orient_sheet_sent'::text), to_jsonb('campaign_registered'::text)
  UNION ALL
  SELECT (SELECT id FROM target ORDER BY application_no LIMIT 1 OFFSET 3)::uuid,
         '박영업', (now() - interval '2 days'),
         'status', to_jsonb('campaign_registered'::text), to_jsonb('done'::text)
  UNION ALL

  -- 신청 5: products 변경 (이체수수료 추가)
  SELECT (SELECT id FROM target ORDER BY application_no LIMIT 1 OFFSET 4)::uuid,
         '김영근1', (now() - interval '4 days'),
         'products',
         to_jsonb('[{"name":"테스트","qty":50,"price":2800}]'::jsonb),
         to_jsonb('[{"name":"테스트","qty":50,"price":2800,"transfer_fee_krw":5000}]'::jsonb)
  UNION ALL
  SELECT (SELECT id FROM target ORDER BY application_no LIMIT 1 OFFSET 4)::uuid,
         '김영근1', (now() - interval '4 days' + interval '5 minutes'),
         'admin_memo', 'null'::jsonb, to_jsonb('이체수수료 ₩5,000 일괄 적용'::text)
  UNION ALL

  -- 신청 6: rejected 후 되돌리기 흐름
  SELECT (SELECT id FROM target ORDER BY application_no LIMIT 1 OFFSET 5)::uuid,
         '김영근1', (now() - interval '14 days'),
         'status', to_jsonb('new'::text), to_jsonb('reviewing'::text)
  UNION ALL
  SELECT (SELECT id FROM target ORDER BY application_no LIMIT 1 OFFSET 5)::uuid,
         '박영업', (now() - interval '10 days'),
         'status', to_jsonb('reviewing'::text), to_jsonb('rejected'::text)
  UNION ALL
  SELECT (SELECT id FROM target ORDER BY application_no LIMIT 1 OFFSET 5)::uuid,
         '박영업', (now() - interval '10 days' + interval '2 minutes'),
         'admin_memo', 'null'::jsonb, to_jsonb('컴플라이언스 이슈로 보류'::text)
  UNION ALL
  SELECT (SELECT id FROM target ORDER BY application_no LIMIT 1 OFFSET 5)::uuid,
         '김영근1', (now() - interval '3 days'),
         'status', to_jsonb('rejected'::text), to_jsonb('new'::text)
  UNION ALL
  SELECT (SELECT id FROM target ORDER BY application_no LIMIT 1 OFFSET 5)::uuid,
         '김영근1', (now() - interval '3 days' + interval '1 minute'),
         'admin_memo', to_jsonb('컴플라이언스 이슈로 보류'::text),
                       to_jsonb('컴플라이언스 이슈 해소 — 재진행'::text)
) AS rows
WHERE rows IS NOT NULL;


-- ============================================================
-- 검증 SQL
-- ============================================================
/*
-- 신청별 history 건수
SELECT b.application_no, COUNT(h.*) AS history_cnt
FROM public.brand_applications b
LEFT JOIN public.brand_application_history h ON h.application_id = b.id
GROUP BY b.id, b.application_no
ORDER BY b.created_at DESC LIMIT 20;

-- 최근 10건 history 확인
SELECT application_id, field_name, changed_by_name, changed_at,
       LEFT(old_value::text, 50) AS old_v, LEFT(new_value::text, 50) AS new_v
FROM public.brand_application_history
ORDER BY changed_at DESC LIMIT 10;
*/
