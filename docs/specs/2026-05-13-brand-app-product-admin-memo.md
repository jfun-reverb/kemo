# 브랜드 서베이 — 내부 메모 제품별 분리 사양서

- **작성일**: 2026-05-13
- **작성**: 기획 세션
- **상태**: 개발 착수 전 (미구현)
- **다음 마이그레이션 번호 후보**: 123 (이전 사양서에서 117~122 예약)
- **위치**: 관리자 페이지 → 브랜드 서베이 신청 목록(`/admin#brand-applications`) 및 상세 모달

---

## 1. 배경 및 목표

### 현재 동작
- `brand_applications.admin_memo` 단일 컬럼 — 신청 1건당 메모 1개
- 신청 목록 표에서 메모 셀이 **첫 제품 행에만** 표시
- 인라인 편집 + 모달 편집 두 진입점

### 변경 후 동작
- 제품별 메모로 분리 — `products[i].admin_memo` (jsonb 내부 필드)
- 신청 목록 표의 메모 셀이 **제품 행마다** 표시
- 상세 모달의 제품 테이블에도 메모 칸 추가
- 입력 방식은 기존과 동일 (인라인 + 모달 둘 다 가능)

### 도입 이유
- 제품마다 특이사항·재고·가격 협의 등 별도 메모 필요
- 첫 행에만 메모가 있으면 어느 제품에 대한 내용인지 모호

---

## 2. 최종 결정 사항

| 항목 | 결정 |
|---|---|
| 저장 위치 | `products[i].admin_memo` (jsonb 내부 필드) |
| 기존 `admin_memo` 컬럼 | 제품별 메모로 백필 후 제거 |
| 백필 방식 | 신청 단위 메모를 **첫 제품(`products[0]`)에 복사**, 나머지 제품은 빈값 |
| 상세 모달 | 제품 테이블에 메모 칸 추가 — 같은 `products[i].admin_memo` 참조 |
| 입력 방식 | 셀 인라인 편집 + 모달 둘 다 유지 |
| 마이그레이션 번호 | 123 |

---

## 3. 데이터 구조

### 변경 전
```json
brand_applications = {
  "admin_memo": "전체 신청 관련 메모",
  "products": [
    { "name": "제품A", "qty": 100, ... },
    { "name": "제품B", "qty": 50, ... }
  ]
}
```

### 변경 후
```json
brand_applications = {
  // admin_memo 컬럼 제거됨
  "products": [
    { "name": "제품A", "qty": 100, "admin_memo": "기존 신청 메모가 첫 제품에 백필됨" },
    { "name": "제품B", "qty": 50, "admin_memo": null }
  ]
}
```

값 정의:
- `null` 또는 키 없음 — 메모 없음 (기본)
- 문자열 — 메모 텍스트

---

## 4. DB 변경 (마이그레이션 123)

**파일**: `supabase/migrations/123_brand_app_product_admin_memo.sql`

```sql
BEGIN;

-- 1. 기존 신청 단위 admin_memo를 각 신청의 첫 제품에 복사
UPDATE public.brand_applications
SET products = jsonb_set(
  products,
  '{0,admin_memo}',
  to_jsonb(admin_memo),
  true
)
WHERE admin_memo IS NOT NULL
  AND admin_memo <> ''
  AND products IS NOT NULL
  AND jsonb_array_length(products) > 0;

-- 2. 신청 단위 admin_memo 컬럼 DROP
ALTER TABLE public.brand_applications DROP COLUMN IF EXISTS admin_memo;

COMMIT;
```

⚠ 주의:
- 운영 DB 백업 후 적용
- `admin_memo` 를 참조하는 다른 함수·트리거·뷰가 있는지 사전 grep
- 엑셀 내보내기, 검색 함수에서도 admin_memo 참조 정리 필요

---

## 5. 클라이언트 변경

### 5-1. 신청 목록 행 렌더 — 제품 행마다 메모 셀

**기존** (`dev/js/admin-brand.js` line 1947~1949 부근):
```js
// 17. 내부 메모 (액션 — 첫 행만)
html += isFirst
  ? '<td><div class="brand-app-memo-cell" data-id="..."> renderMemoCellInner(a.id) </div></td>'
  : emptyAction;
```

**변경 후**:
```js
// 17. 내부 메모 (제품 단위 — 모든 행)
html += '<td><div class="brand-app-memo-cell" data-id="' + esc(a.id) + '" data-product-idx="' + idx + '">'
      + renderMemoCellInner(a, idx, p)
      + '</div></td>';
```

### 5-2. `renderMemoCellInner` 시그니처 변경

기존: `renderMemoCellInner(applicationId)` → `cur.admin_memo` 사용  
변경 후: `renderMemoCellInner(a, productIndex, product)` → `product.admin_memo` 사용

### 5-3. 저장 함수 변경

기존: `updateBrandApplication(id, {admin_memo: nextValue}, version)`  
변경 후: `updateBrandApplication(id, {products: newProducts}, version)` — products 배열 전체 UPDATE  
(입금여부·가격체크와 동일 패턴)

낙관적 락: `version` 체크 그대로 유지.

### 5-4. 메모 편집 모달 (`brandAppMemoModal`)

기존: 신청 단위로 1개 모달, 신청 메모 1개 편집  
변경 후: 모달 헤더에 **어느 제품의 메모인지 명시**

```
┌─────────────────────────────────────────────────┐
│  내부 메모 편집                          [✕]    │
│ ──────────────────────────────────────────────  │
│  신청 번호: B0026-A001                          │
│  제품: [제품 A 이름]                            │  ← 신규
│  ─────────────────────────────────────────────  │
│  [textarea]                                     │
│  ─────────────────────────────────────────────  │
│  [취소] [저장]                                  │
└─────────────────────────────────────────────────┘
```

모달 변수에 `_brandAppMemoModalCurrentProductIdx` 추가.

### 5-5. 상세 모달의 제품 테이블 — 메모 칸 추가

상세 모달의 제품 정보 테이블에 「내부 메모」 컬럼 추가. 인라인 편집 가능.

**현재 컬럼 예시**: 제품명 / URL / 수량 / 가격(엔) / 가격(원) / 모집비 / 이체수수료 / 소계  
**변경 후**: ... / 모집비 / 이체수수료 / 소계 / **내부 메모** (신규)

### 5-6. 메모 셀의 인라인 편집 동작

기존과 동일하게:
- 클릭 시 인라인 편집 모드 진입 (셀 안에서 직접 입력)
- 텍스트가 일정 길이를 초과하거나 사용자가 「상세 편집」 클릭 시 모달로 전환
- 저장은 즉시 (blur 시 자동 저장 또는 Ctrl+Enter)

---

## 6. 회귀 체크 목록

- [ ] 기존 신청 단위 메모가 첫 제품으로 정확히 백필됨 (운영 DB SQL로 확인)
- [ ] 신청 목록 표에서 제품 행마다 메모 셀이 보임
- [ ] 한 제품의 메모를 인라인 편집 → 다른 제품에 영향 없음
- [ ] 모달 편집 시 헤더에 정확한 제품명 표시
- [ ] 상세 모달의 제품 테이블에 메모 컬럼 표시 + 인라인 편집 가능
- [ ] 신청 목록과 상세 모달이 같은 데이터(`products[i].admin_memo`) 공유
- [ ] 낙관적 락 — 두 탭 동시 편집 시 충돌 토스트
- [ ] 엑셀 내보내기에서 메모 컬럼 처리 (선택 — 사용자 확인 필요)
- [ ] 검색·필터에서 메모 텍스트 매칭 동작 (기존 동작이 있다면 유지)
- [ ] 기존 `admin_memo` 컬럼 참조 코드 모두 정리 (grep 전수 조사)

---

## 7. 사전 조사 (개발 세션 작업 시작 시)

```bash
grep -rn "admin_memo\|adminMemo\|brand-app-memo" \
  dev/ supabase/migrations/ supabase/functions/
```

영향 범위 점검 항목:
- `dev/js/admin-brand.js` — 메모 렌더·인라인 편집·모달
- `dev/lib/storage.js` — `updateBrandApplication` 호출 시 admin_memo 키
- `dev/admin/index.html` — `nbaAdminMemo` 입력 필드 (상세 모달)
- 엑셀 내보내기 — 메모 컬럼 정의
- 검색 함수 — admin_memo 매칭 (있다면)
- 다른 페인에서 admin_memo 참조 (대시보드 등)

---

## 8. 영향 파일 목록

### DB
- `supabase/migrations/123_brand_app_product_admin_memo.sql` (신규)

### 클라이언트
- `dev/admin/index.html` — 메모 모달 헤더에 제품 표시 영역 추가, 상세 모달 제품 테이블에 메모 컬럼 추가
- `dev/js/admin-brand.js` — 렌더·편집·저장 함수 시그니처 변경, 모달 변수 추가
- `dev/lib/storage.js` — `updateBrandApplication` SELECT 컬럼에서 admin_memo 제거 (products 안에 포함)
- `dev/css/admin.css` — 셀 스타일 조정 (제품 행마다 표시되므로 간격 재조정)

### 빌드
- `dev/build.sh` — 신규 파일 없음, 변경 불필요

---

## 9. 문서 동기화 (필수)

`.claude/rules/git.md` §배포 전 체크 의무 사항 — 같은 커밋에 포함:
- `docs/FEATURE_SPEC.md` — 브랜드 서베이 메모 섹션 갱신 (제품별 분리 명시)
- `CLAUDE.md` — `brand_applications.admin_memo` 컬럼 설명 제거, `products[i].admin_memo` 추가

---

## 10. 작업 시작 절차 (개발 세션용)

1. `git pull origin dev` — 최신 동기화
2. `ls supabase/migrations/ | tail -5` — 다음 가용 마이그레이션 번호 확인 (예상 123)
3. **사전 grep 영향 조사** — §7 명령 실행 후 영향 범위 정리
4. migration 123 작성 → 개발 DB 적용 → 백필 결과 검증
5. `dev/js/admin-brand.js` 렌더·편집·모달 함수 수정
6. `dev/lib/storage.js` SELECT 컬럼 정리
7. `dev/admin/index.html` 모달 헤더·상세 모달 제품 테이블 수정
8. `dev/css/admin.css` 셀 스타일 조정
9. **FEATURE_SPEC.md + CLAUDE.md 동시 업데이트**
10. `cd dev && bash build.sh`
11. 개발서버 검증 — §6 회귀 체크 모두
12. reverb-reviewer + reverb-supabase-expert 호출
13. dev 머지 → 사용자 확인 후 운영 배포 절차

---

## 11. 다른 사양서와의 의존성

| 사양서 | 관계 |
|---|---|
| `2026-05-13-brand-app-product-payment-flags.md` | 동일 패턴 (products jsonb 내부 분리) — 작업 순서 무관 |
| `2026-05-13-brand-app-price-check.md` | 동일 패턴 — 작업 순서 무관 |
| `2026-05-13-brand-ops-redesign.md` | 무관 |
| `2026-05-13-campaign-visibility-toggle.md` | 무관 |
| `2026-05-13-application-cancel-daily-email-fix.md` | 무관 |

이 사양서는 다른 사양서와 독립적이라 PR을 따로 진행 가능. 다만 다음 가용 마이그레이션 번호는 이전 사양서들이 117~122 예약했다고 가정.

---

## 12. 제외 항목 (이번 작업 범위 밖)

- 메모 변경 audit 이력 (누가 언제 메모 수정했는지) — 필요해지면 별도 사양
- 메모 텍스트에 멘션·태그·이미지 등 리치 텍스트 기능 — 단순 텍스트만
- 메모 검색 기능 강화 — 기존 동작 유지 (없으면 추가 안 함)
- 신청 전체 단위 메모 별도 보존 — 결정 사항대로 첫 제품에 백필 후 제거
