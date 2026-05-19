# 브랜드 서베이 입금여부 — 제품별 4플래그 재설계 사양서

- **작성일**: 2026-05-13
- **작성**: 기획 세션
- **상태**: ✅ **운영 배포 완료 (마이그레이션 114~116, 2026-05-12)** — `payment_flags jsonb` 컬럼 + 자동 재계산 트리거 + `recalc_brand_app_payment_flags()` 원격 호출 함수 + 신청 목록 입금여부 칩 토글 UI. 코드(admin.js)는 dev 잠재, main merge 보류 중
- **실제 마이그레이션 번호**: 114~116 (117~121이 다른 기능에 먼저 사용됨)

---

## 1. 배경 및 목표

**현재 문제**: 브랜드 서베이 신청 1건의 입금여부(payment_flags)가 전체를 대표하는 1세트(4개 칩)만 존재.  
한 신청에 제품이 2개 이상일 때 제품별로 입금 상태가 다를 수 있는데, 구분해서 관리할 수 없음.

**목표**: 각 제품별로 독립된 4개 플래그(모집비·상품비·이체수수료·무료모집)를 관리하고,  
신청 목록 셀에 제품 수만큼 줄을 나눠 표시한다.

---

## 2. 최종 결정 사항

| 항목 | 결정 |
|---|---|
| 저장 위치 | `products` 배열 각 항목 안에 `payment_flags` 삽입 |
| 표시 방식 | 현재 4칩 스타일 유지, 제품별로 반복 (제품 이름 헤더 + 4칩) |
| 제품 개수 | 대부분 1~3개 (자연 노출 OK) |
| 무료모집(free) | 제품별 독립 토글 |
| 기존 컬럼 | 백필 후 즉시 DROP |

---

## 3. 데이터 구조 변경

### 변경 전

```json
brand_applications = {
  "payment_flags": { "recruit": true, "product": false, "transfer": true, "free": false },
  "products": [
    { "name_ko": "제품A", "qty": 2, "price": 15000, "recruit_fee_krw": 5000, "transfer_fee_krw": 500 },
    { "name_ko": "제품B", "qty": 1, "price": 0,     "recruit_fee_krw": 0,    "transfer_fee_krw": 0   }
  ]
}
```

### 변경 후

```json
brand_applications = {
  // payment_flags 컬럼 제거됨
  "products": [
    {
      "name_ko": "제품A", "qty": 2, "price": 15000, "recruit_fee_krw": 5000, "transfer_fee_krw": 500,
      "payment_flags": { "recruit": true, "product": false, "transfer": true, "free": false }
    },
    {
      "name_ko": "제품B", "qty": 1, "price": 0, "recruit_fee_krw": 0, "transfer_fee_krw": 0,
      "payment_flags": { "recruit": false, "product": false, "transfer": false, "free": true }
    }
  ]
}
```

---

## 4. DB 변경 (migration 117)

**파일**: `supabase/migrations/117_brand_app_product_payment_flags.sql`

### 4-1. 기존 백필 → products 각 항목에 복사

마이그레이션 적용 시점에 이미 존재하는 신청 행(약 47건)의 `payment_flags` 값을  
해당 신청의 **모든 제품에 동일하게 복사**.

```sql
-- 각 제품에 신청 단위 payment_flags 그대로 복사
UPDATE public.brand_applications
SET products = (
  SELECT jsonb_agg(
    item || jsonb_build_object('payment_flags', 
      COALESCE(payment_flags, '{"recruit":false,"product":false,"transfer":false,"free":false}'::jsonb)
    )
  )
  FROM jsonb_array_elements(products) AS item
)
WHERE products IS NOT NULL AND jsonb_array_length(products) > 0;
```

운영자가 이미 수동으로 토글해둔 상태를 모든 제품에 동일하게 보존.  
백필 후 `brand_applications.payment_flags` 컬럼 DROP.

### 4-2. 기존 함수 제거 및 신규 함수 정의

#### 제거 대상
- `calc_brand_app_payment_flags(jsonb)` — 신청 전체 단위 산출 함수 → DROP
- `recalc_brand_app_payment_flags(uuid)` — 신청 전체 단위 새로고침 → DROP (새 이름으로 교체)

#### 신규: 제품 1개 플래그 계산 헬퍼

```sql
CREATE OR REPLACE FUNCTION calc_brand_app_product_payment_flag(item jsonb)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
  -- item: products 배열의 단일 원소
  -- item.qty * item.recruit_fee_krw > 0 이면 recruit = true
  -- item.qty * item.price > 0 이면 product = true
  -- item.qty * item.transfer_fee_krw > 0 이면 transfer = true
  -- free: 호출자가 별도 처리 (항상 false 반환, 클라이언트 또는 상위에서 보존)
$$;
```

#### 신규: 신청 전체 새로고침 원격 호출 함수 (RPC)

```sql
CREATE OR REPLACE FUNCTION refresh_brand_app_product_payment_flags(p_application_id uuid)
RETURNS jsonb   -- 갱신된 products 배열 반환
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
  -- is_admin() 가드
  -- 신청의 모든 products[i]에 대해 calc_brand_app_product_payment_flag(item) 계산
  -- free 키: false 로 초기화 (migration 115 결정: 새로고침 = 완전 초기화)
  -- 갱신된 products 배열을 UPDATE 후 반환
$$;
```

GRANT EXECUTE TO authenticated.

#### 변경: 트리거 함수 `auto_recalc_brand_app_payment_flags`

현재 동작 → `NEW.payment_flags`(신청 단위 컬럼) 갱신  
변경 후 동작 → `NEW.products[i].payment_flags.recruit/product/transfer` 갱신, `free`는 `NEW.products[i].payment_flags.free` 그대로 사용

```
BEFORE INSERT OR UPDATE OF products:
  products 배열 각 원소를 순회:
    calc_brand_app_product_payment_flag(item) 로 recruit/product/transfer 계산
    free: NEW.products[i].payment_flags.free 값 그대로 보존
      (클라이언트가 free 토글 → products 배열 업데이트 → 트리거 발동 → NEW에 이미 반영되어 있음)
  NEW.products := 갱신된 배열 반환
```

> **핵심 동작**: 클라이언트가 `free` 토글 시 products 배열 전체를 업데이트 → 트리거가 발동해  
> `NEW.products[i].payment_flags.free` (클라이언트가 방금 설정한 값)을 그대로 유지하면서  
> `recruit/product/transfer`만 수식 재계산. 클라이언트 의도가 그대로 DB에 반영됨.

### 4-3. migration 117 적용 순서 (트랜잭션)

```
BEGIN;
1. 백필: products[i]에 payment_flags 복사
2. DROP COLUMN payment_flags
3. DROP FUNCTION calc_brand_app_payment_flags
4. DROP FUNCTION recalc_brand_app_payment_flags
5. CREATE FUNCTION calc_brand_app_product_payment_flag
6. CREATE FUNCTION refresh_brand_app_product_payment_flags
7. CREATE OR REPLACE FUNCTION auto_recalc_brand_app_payment_flags (트리거 함수)
   -- 트리거 자체(trg_brand_app_auto_recalc_payment_flags)는 이미 있으므로
   -- DROP TRIGGER + CREATE TRIGGER 또는 FUNCTION만 교체
COMMIT;
```

### 4-4. 롤백 절차

```sql
-- 코드 롤백 (PR revert)
-- DB 롤백:
--   1. pg_dump에서 품 brand_applications 복원 (사전 백업 필수)
--   2. migration 114/115/116 다시 적용
--   3. 클라이언트 코드 PR revert
```

---

## 5. 클라이언트 변경

### 변경 파일 목록

| 파일 | 변경 내용 |
|---|---|
| `dev/js/admin-brand.js` | 렌더·토글·새로고침 함수 재작성 |
| `dev/lib/storage.js` | SELECT 컬럼 정리, RPC 이름 교체 |
| `dev/css/admin.css` | 제품 헤더 스타일 추가 |

### 5-1. `renderBrandAppPaymentFlagsCell(a)` 변경

**현재**: `a.payment_flags`(신청 단위 1세트) → 4칩  
**변경 후**: `a.products` 배열 순회 → 제품별 구역 (제품 이름 + 4칩)

```
제품이 0개: "제품 없음" 안내 텍스트
제품이 1개 이상:
  [제품 A 이름]
    모집비용 ✓  상품비용 □  이체수수료 ✓  무료모집 □
  [제품 B 이름]
    모집비용 □  상품비용 □  이체수수료 □  무료모집 ✓
[새로고침 버튼]  ← 신청 전체 단위 1개 유지
```

각 칩의 `onclick`에 `productIndex` 추가: `toggleBrandAppProductPaymentFlag(id, productIndex, flagKey)`

### 5-2. `toggleBrandAppPaymentFlag` → `toggleBrandAppProductPaymentFlag`

**시그니처 변경**:
```js
// 변경 전
toggleBrandAppPaymentFlag(applicationId, flagKey)

// 변경 후
toggleBrandAppProductPaymentFlag(applicationId, productIndex, flagKey)
```

**저장 방식 변경**:  
- 변경 전: `updateBrandApplication(id, {payment_flags: newFlags}, version)` — payment_flags 컬럼 UPDATE  
- 변경 후: `products` 배열에서 `productIndex`번째 항목의 `payment_flags[flagKey]`를 토글한 새 `products` 배열 전체를 UPDATE

```js
// 예시 (코드가 아닌 로직 설명)
var newProducts = cur.products.slice(); // 얕은 복사
newProducts[productIndex] = Object.assign({}, newProducts[productIndex]);
newProducts[productIndex].payment_flags = Object.assign({}, newProducts[productIndex].payment_flags || {});
newProducts[productIndex].payment_flags[flagKey] = !newProducts[productIndex].payment_flags[flagKey];
await updateBrandApplication(applicationId, {products: newProducts}, cur.version);
```

> ⚠ products 전체 UPDATE → 트리거 발동 → recruit/product/transfer 자동 재계산됨.  
> 클라이언트가 `free` 토글 시 NEW.products에 이미 새 free 값이 있으므로 트리거가 그 값을 보존.

### 5-3. `refreshBrandAppPaymentFlags` 변경

**RPC 이름 변경**:
- 변경 전: `recalcBrandAppPaymentFlags(applicationId)` → RPC `recalc_brand_app_payment_flags`
- 변경 후: `refreshBrandAppProductPaymentFlags(applicationId)` → RPC `refresh_brand_app_product_payment_flags`

반환값: 갱신된 `products` 배열 → `cur.products = res.products; _rerenderBrandAppPaymentCell(applicationId)`

### 5-4. `_rerenderBrandAppPaymentCell` — 변경 없음

### 5-5. storage.js 변경

- `updateBrandApplication` SELECT 컬럼 목록에서 `payment_flags` 제거  
  (products 배열 안에 포함되어 있으므로 `products` SELECT 시 자동으로 따라옴)
- `recalcBrandAppPaymentFlags` 함수 이름 → `refreshBrandAppProductPaymentFlags`로 변경, RPC 이름도 교체

### 5-6. CSS 변경 (admin.css)

`.brand-app-pay-cell` 안에 제품 구역 헤더 스타일 추가:
- `.pay-product-header` — 제품 이름 작은 텍스트 (예: 회색 10px, `border-bottom` 구분선)
- `.pay-product-section` — 제품 1개 구역 감싸는 div
- 기존 `.pay-row`, `.pay-rows-wrap`, `.pay-refresh-btn` 등 스타일 유지

---

## 6. 낙관적 락 동작

**기존**: `{payment_flags: newFlags}` 단일 키 업데이트 → version 체크  
**변경 후**: `{products: newProducts}` 전체 배열 업데이트 → version 체크 (동일 패턴)

충돌 시 동작: 기존과 동일 ("이미 다른 곳에서 변경됐습니다" 토스트 + 롤백)

---

## 7. 회귀 체크 목록

- [ ] 브랜드 서베이 엑셀 다운로드 — `payment_flags` 컬럼이 엑셀에 포함되어 있었는지 grep 확인
- [ ] 브랜드 서베이 상세 모달 — `payment_flags` 직접 참조 여부 확인
- [ ] 대시보드 KPI·깔때기 — `payment_flags` 참조 없음 확인
- [ ] `estimated_krw` 재계산 트리거 (migration 111) — products UPDATE 시 정상 발동 확인
- [ ] migration 116 트리거 `trg_brand_app_auto_recalc_payment_flags` 사용 여부 — 함수만 교체, 트리거 이름 유지

---

## 8. 검증 시나리오

### DB 검증 (개발 DB 적용 후)

```sql
-- payment_flags 컬럼이 사라졌는지 확인
SELECT column_name FROM information_schema.columns
WHERE table_name = 'brand_applications' AND column_name = 'payment_flags';
-- → 결과 없음이어야 함

-- 모든 제품에 payment_flags 키가 생겼는지 확인
SELECT id, products->0->'payment_flags' AS first_product_flags
FROM brand_applications WHERE products IS NOT NULL AND jsonb_array_length(products) > 0;
-- → 모든 행에 payment_flags 객체 존재

-- 새로고침 RPC 테스트 (개발 DB 관리자 계정으로)
SELECT refresh_brand_app_product_payment_flags('<테스트 신청 id>');
-- → 모든 제품의 recruit/product/transfer가 재계산, free=false 초기화
```

### UI 검증 (개발서버)

- [ ] 제품 1개 신청: 셀에 1줄 + 4칩
- [ ] 제품 2개 신청: 셀에 2줄, 각각 4칩 독립 토글
- [ ] 무료모집 ON: 해당 제품만 3칩 숨김, 다른 제품 정상
- [ ] 새로고침 버튼: 모든 제품 4종 초기화
- [ ] 상세 모달에서 qty 수정 저장 → 셀 자동 동기화 (트리거 확인)
- [ ] 제품 없는 신청: "제품 없음" 안내 표시
- [ ] 낙관적 락 충돌: 다른 탭에서 같은 신청 토글 시 토스트

---

## 9. 작업 시작 절차 (개발 세션용)

1. `git pull origin dev` — 최신 dev 브랜치 동기화
2. `ls supabase/migrations/ | tail -5` — 마이그레이션 번호 최신값 확인 (현재 예상: 117)
3. `supabase/migrations/117_brand_app_product_payment_flags.sql` 작성
4. 개발 DB SQL Editor에 적용 → 검증 SQL 실행
5. `dev/lib/storage.js` → `recalcBrandAppPaymentFlags` 함수 이름·RPC 이름 교체, SELECT 컬럼 정리
6. `dev/js/admin-brand.js` → 렌더·토글·새로고침·재렌더 함수 재작성
7. `dev/css/admin.css` → 제품 헤더 스타일 추가
8. `cd dev && bash build.sh`
9. 개발서버 배포 후 UI 검증 시나리오 수행
10. **reverb-reviewer** 호출 후 커밋
11. 사용자에게 개발서버 확인 요청 → 이상 없으면 운영 배포 절차 진행

---

## 10. 제외 항목 (이번 작업 범위 밖)

- 신청 단위 입금 완료 배지 (모든 제품이 완료일 때 신청 전체 표시) — 현재 사용 사례 없음, 추후 추가
- 제품 10개 이상 케이스 스크롤 처리 — 대부분 1~3개라 일단 자연 노출

---

## 11. 구현 결과

**구현일**: 2026-05-12 (단일 세션)
**운영 적용일**: 2026-05-12 (양 DB)
**관련 커밋 (시간순)**:
- `0ad9f29 feat(brand-survey): per-product payment_flags (migration 117)` — 사양서 작성 시점엔 「migration 117」 이 다음 번호였으나 실제 적용 시 다른 기능 먼저 117 사용 → 본 작업은 마이그레이션 114~116 으로 분리 배정
- `776c243 fix(brand-survey): auto-sync payment_flags when products change` — 트리거 시점 보강
- `87cd6fb fix(brand-survey): refresh resets all 4 flags + REVERB pink chip color` — 새로고침 RPC 동작 변경 + UI 색상
- `0d5a636 feat(brand-survey): add 입금여부 column with toggle chips + auto-fill` — UI 칩 토글 컬럼 완성

**관련 마이그레이션**:
- 114: `payment_flags jsonb NOT NULL DEFAULT '{}'` 컬럼 추가 + 헬퍼 `calc_brand_app_payment_flags(products)` + 원격 호출 함수 `recalc_brand_app_payment_flags(application_id)` + 기존 행 백필
- 115: 새로고침 원격 호출 함수 동작 변경 — free 보존 → false 리셋 (4종 모두 products 합계로 완전 초기화)
- 116: `trg_brand_app_auto_recalc_payment_flags BEFORE INSERT OR UPDATE OF products` 트리거 — products 변경 시 recruit/product/transfer 자동 재계산, free 키는 OLD 값 보존(관리자 명시 토글 보호)

### 초안 대비 변경 사항
- **추가된 것**:
  - 트리거(116) 추가 — 초안의 「products 변경 시 입금여부 자동 재계산」 결정에 따른 정착. free 키 보존 로직은 사양서 §3 「관리자 명시 토글 보호」 결정대로
  - 입금여부 칩 색상 — 무료모집 칩만 초록 톤(#E8F5E9/#16A34A) 차별화, 나머지 3종은 REVERB pink (sa사용자 결정)
- **빠진 것**:
  - 신청 단위 입금 완료 배지 (§10 제외 항목으로 명시) — 현재 사용 사례 없어서 미구현 유지
- **달라진 것**:
  - 마이그레이션 번호 분할 — 사양서엔 「migration 117」 단일로 설계했으나 실제는 114(테이블+백필) + 115(refresh RPC) + 116(트리거) 3단계로 분리 적용. 함수 정의·트리거 등록을 단계별로 검증하면서 안전하게 적용

### 구현 중 기술 결정 사항
- `payment_flags` 가 jsonb 구조라 4종 (`recruit`/`product`/`transfer`/`free`) 키 모두 boolean. 신청 단위 1세트 vs 제품 단위 4세트의 트레이드오프 → 초안의 제품 단위 결정 유지
- `auto_recalc_brand_app_payment_flags` 트리거가 BEFORE INSERT OR UPDATE — products jsonb 변경 시 자동 재계산
- `free` 키는 자동 재계산 시 보존됨 — 관리자 명시 토글로만 변경 가능 (자동 false 리셋 방지)
- 컬럼명 「입금여부」 → 「입금 정보」 라벨 변경 (2026-05-15 mig 126 의 paid_at 추가 시 통일)

### 후속 작업
- 마이그레이션 126 (2026-05-15): 「입금여부」 컬럼이 실제로는 입금일 의미로 쓰여서 별도 `paid_at` 컬럼 분리. 본 사양의 4플래그와 별개로 입금 날짜 명시화
