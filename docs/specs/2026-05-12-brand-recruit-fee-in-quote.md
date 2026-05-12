# 브랜드 서베이 — 예상 견적에 모집비 합산 추가

> **작성일**: 2026-05-12
> **작성 세션**: 메인 폴더 (개발1, 사용자 인계 진행)
> **선행**: PR #177 운영 배포 완료, PR #178 dev 머지

---

## 1. 결정 요약

| 항목 | 결정 |
|---|---|
| 트리거 신규 수식 (reviewer) | `supply = Σ(price×qty×10) + Σ(qty×recruit_fee_krw) + Σ(qty×transfer_fee_krw)` / `vat = floor(supply×0.1)` / `estimated_krw = supply + vat` |
| 모집비 키 | `products[i].recruit_fee_krw`(이미 존재, 클라이언트 인라인 편집 가능) — 미입력 시 NULL/0 |
| 이체수수료 키 | `products[i].transfer_fee_krw`(092 트리거가 reviewer 신청에 기본값 2500 자동 채움) |
| seeding 영향 | 없음 (`estimated_krw = 0` 그대로) |
| 기존 데이터 백필 | 자동 호환 (`recruit_fee_krw` 미입력 시 새 공식이 옛 공식과 결과 동일). 별도 UPDATE 백필 불필요 |
| `final_quote_krw`(확정 견적) 영향 | 없음 (별도 컬럼, 영업이 수동 입력) |
| 후속 상태(quoted 이후) 보호 | 적용 (아래 §3 결정) |
| 클라이언트 표시 | 트리거가 DB 컬럼 갱신 → 화면 자동 동기화. 별도 보정 코드 추가 불필요 |
| 툴팁 텍스트 | 새 공식 + 환율 명시 + 모집비 항 추가 (아래 §4) |
| 마이그레이션 번호 | **111** (현재 dev/main 모두 110까지 점유) |
| 파일명 | `supabase/migrations/111_recalc_with_recruit_fee.sql` |
| PR 분할 | 단일 PR (트리거 마이그레이션 + 툴팁 텍스트 동시) |

---

## 2. 데이터베이스 변경

### 2-1. `recalc_brand_application_totals()` 재정의

`CREATE OR REPLACE FUNCTION` 으로 052의 함수를 같은 시그니처로 교체. 트리거 자체(`trg_brand_app_recalc`)는 재정의 불필요.

```sql
CREATE OR REPLACE FUNCTION public.recalc_brand_application_totals()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_total_jpy       numeric := 0;
  v_total_qty       integer := 0;
  v_recruit_total   numeric := 0;
  v_transfer_total  numeric := 0;
  v_supply          numeric := 0;
  v_vat             numeric := 0;
  v_item            jsonb;
BEGIN
  BEGIN
    FOR v_item IN SELECT jsonb_array_elements(NEW.products)
    LOOP
      v_total_jpy      := v_total_jpy
                         + COALESCE((v_item->>'price')::numeric, 0)
                         * COALESCE((v_item->>'qty')::numeric, 0);
      v_total_qty      := v_total_qty
                         + COALESCE((v_item->>'qty')::integer, 0);
      v_recruit_total  := v_recruit_total
                         + COALESCE((v_item->>'qty')::numeric, 0)
                         * COALESCE((v_item->>'recruit_fee_krw')::numeric, 0);
      v_transfer_total := v_transfer_total
                         + COALESCE((v_item->>'qty')::numeric, 0)
                         * COALESCE((v_item->>'transfer_fee_krw')::numeric, 0);
    END LOOP;

    NEW.total_jpy := v_total_jpy;
    NEW.total_qty := v_total_qty;

    IF NEW.form_type = 'reviewer' THEN
      v_supply := (v_total_jpy * 10) + v_recruit_total + v_transfer_total;
      v_vat    := floor(v_supply * 0.1);
      NEW.estimated_krw := v_supply + v_vat;
    ELSE
      NEW.estimated_krw := 0;
    END IF;

  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[111] recalc_brand_application_totals: 재계산 실패, 클라이언트 값 유지. error=%', SQLERRM;
  END;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.recalc_brand_application_totals IS
  '[111] brand_applications BEFORE INSERT/UPDATE 트리거. products 배열 합계 재계산. 052의 고정 2500 공식을 products[i].recruit_fee_krw + transfer_fee_krw 합산 방식으로 교체.';
```

### 2-2. 기존 데이터 호환 검증

- 기존 reviewer 행: `recruit_fee_krw` 미입력 = NULL → COALESCE(0) → `v_recruit_total = 0`. `transfer_fee_krw` = 2500 (092 트리거가 채움) → `v_transfer_total = total_qty × 2500`. 결과: `supply = total_jpy×10 + 0 + total_qty×2500` = **옛 공식과 동일**. 자동 호환.
- seeding 행: 분기 진입 안 함. 영향 없음.

### 2-3. 검증 SQL (운영 적용 후 SQL Editor 실행)

```sql
-- [V1] 함수 갱신 확인
SELECT prosrc ILIKE '%recruit_fee_krw%' AS has_recruit, prosrc ILIKE '%transfer_fee_krw%' AS has_transfer
FROM pg_proc WHERE proname='recalc_brand_application_totals';
-- 두 컬럼 모두 true

-- [V2] 기존 reviewer 행 1건의 estimated_krw 비교 (UPDATE 전후)
-- WHERE 절에 안전한 테스트용 application_no 또는 id 적용
SELECT id, products, total_jpy, total_qty, estimated_krw
FROM brand_applications WHERE id='<TEST_ID>';
-- 같은 행을 같은 데이터로 UPDATE 트리거 시 estimated_krw 변화 없는지 확인

-- [V3] 모집비 추가 시 합산 확인
-- 테스트용 행에 products[0].recruit_fee_krw = 1000 추가 → UPDATE → estimated_krw 증가 확인
```

---

## 3. 후속 상태(quoted 이후) 보호 정책

**결정**: 보호 분기 없음. 모든 UPDATE 에서 새 공식 자동 재계산.

배경: 사용자 확인 결과 `final_quote_krw` 컬럼이 관리자 페인 컬럼에 노출되지 않아 영업이 활용하지 않음. 따라서 `final_quote_krw` 채워짐 여부로 보호하는 분기(원래 §3 안 C)는 의미 없음. 단순 안 A 채택.

---

## 4. 툴팁 텍스트 갱신

### 위치
- 소스: `dev/admin/index.html` L1360 `data-tooltip` 속성
- 빌드 산출물: `admin/index.html` (자동 갱신)

### Before
```
DB 트리거 자동 계산 (신청 INSERT 시 고정)
reviewer: (∑ 엔가격×수량×10 + ∑ 수량×₩2,500) × 1.1
seeding: 0 (수동 협의)
※ 모집비는 미포함
※ 같은 신청의 모든 제품 행에 동일 값 표시
```

### After
```
DB 트리거 자동 계산 (신청 INSERT/UPDATE 시 재계산)
reviewer: ( ∑(엔가격×수량)×환율₩10 + ∑(수량×모집비) + ∑(수량×이체수수료) ) × VAT 1.1
seeding: 0 (수동 협의)
※ 모집비·이체수수료 미입력 시 0
※ 같은 신청의 모든 제품 행에 동일 값 표시
```

(후속 보호 안 C 채택 시 추가 한 줄: `※ 확정 견적 입력 후엔 자동 갱신 중단`)

### 「신청 INSERT 시 고정」 → 「INSERT/UPDATE 시 재계산」 표현
- 052 트리거는 사실 BEFORE INSERT + UPDATE 양쪽이라 옛 표현이 부정확. 갱신 시 정정.

---

## 5. 결정 분기점 (사용자 확인 필요)

Q1. 새 수식 채택안 — **안 A** (recruit_fee + transfer_fee 모두 sum) 권장. 확인만.

Q2. 후속 상태 보호 정책
- 안 A) 보호 없음 (UPDATE 시 자동 재계산) — 단순
- 안 C) `final_quote_krw` 가 채워지면 estimated_krw 갱신 스킵 — 영업 혼란 방지 (권장)

Q3. 운영 적용 시점
- 즉시 (dev 검증 후 사용자 OK 신호 시 main 머지)
- PR #178(수신 메일 UI)과 묶어서 한 번에 운영

---

## 6. QA 시나리오 (개발서버 → reverb-qa-tester)

1. 신규 reviewer 신청 INSERT (sales 폼) → products 에 recruit_fee_krw 0 → estimated_krw 옛 공식과 동일
2. 신규 reviewer 신청 INSERT → products 에 recruit_fee_krw 1000, qty 5 → estimated_krw 에 +5000 + VAT 반영
3. 기존 행 모집비 인라인 편집 (관리자 페인) → UPDATE → estimated_krw 즉시 갱신
4. seeding 신청 → recruit_fee_krw 입력해도 estimated_krw=0 유지
5. (안 C 채택 시) final_quote_krw 채워진 행에 모집비 변경 → estimated_krw 갱신 안 됨, OLD 유지
6. 「예상 견적」 컬럼 툴팁 새 텍스트로 표시
7. 클라이언트 카드/엑셀/대시보드 합계의 estimated_krw 합 → 트리거 결과 그대로 동기화

---

## 7. 영향 분석

| 영역 | 영향 |
|---|---|
| 운영 DB | 마이그레이션 111 SQL Editor 적용 필요 |
| 클라이언트 코드 | `dev/admin/index.html` 툴팁 1줄 외 변경 없음 |
| 코드 빌드 | `bash dev/build.sh` 필요 (admin/index.html 갱신) |
| 데이터 정합성 | 기존 행 옛 공식과 결과 동일 (자동 호환) |
| 영업 운영 | 안 C 채택 시 quoted 이후 영업 견적 보호 |
| 사양 외 영향 | 없음 |

---

## 8. PR 분할

| PR | 범위 | 의존 |
|---|---|---|
| **단일 PR (예: feature/brand-recruit-fee-in-quote)** | 마이그레이션 111 + 툴팁 텍스트 + 빌드 산출물 | 없음 (dev 직접) |

---

## 9. 시작 절차

```
1. 사용자 §5 Q1·Q2·Q3 확인 → 결정 반영
2. 마이그레이션 111 작성 (§2 본문 + 안 C 추가 여부)
3. dev/admin/index.html 툴팁 텍스트 갱신
4. cd dev && bash build.sh
5. reverb-reviewer 호출
6. dev 푸시 + PR 생성 (base=dev)
7. dev SQL Editor에 111 적용
8. 개발서버 검증 (qa-tester light)
9. 사용자 OK 신호 시 dev → main 통합 (PR #178 묶음 또는 단독 결정)
10. 운영 SQL Editor에 111 적용
11. 운영 검증
```
