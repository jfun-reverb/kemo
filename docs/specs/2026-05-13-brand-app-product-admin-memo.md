# 브랜드 서베이 — 내부 메모 제품별 분리 사양서

- **작성일**: 2026-05-13
- **작성**: 기획 세션
- **상태**: ✅ **운영 배포 완료 (마이그레이션 122~125, 2026-05-14)** — `brand_application_memos` 테이블 + `product_idx` 컬럼 + 읽음 추적 `brand_application_memo_reads` + 셀 분홍 배지 UI + 메모 모달(제품별 헤더). 코드(admin.js)는 dev 잠재, main merge 보류 중
- **실제 마이그레이션 번호**: 122~125 (122: admin_memo 컬럼 제거, 123: product_idx 추가, 124: 중복 정리, 125: 읽음 추적)
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

---

## 구현 결과

**구현일:** 2026-05-14
**마이그레이션:** 122 (사양서 §1 후보였던 123 대신 실제 다음 번호 122 사용)
**관련 커밋:** (예정 — dev 푸시 후 갱신)

### 초안 대비 변경 사항

#### 빠진 것
- **`brand_application_history.field_name` CHECK 제약 갱신 SECTION 제거** (사양서 §4 SECTION 3 / 변경 범위 (3))
  - 사유 1: `ALTER TABLE ADD CONSTRAINT` 는 기존 행 즉시 검증 → `field_name='admin_memo'` 인 이력 행이 있으면 23514 위반 에러
  - 사유 2: 현재 CHECK 에 `memo_added`/`memo_edited`/`memo_deleted` 도 포함되어 있음 (마이그레이션 080+ 에서 추가). 사양서대로 4개로 줄이면 이 3종 신규 INSERT 가 차단되는 조용한 회귀
  - 결정: CHECK 제약은 손대지 않음. 트리거가 admin_memo INSERT 를 안 하므로 신규 행은 안 생기고, 기존 행은 감사 목적 보존됨

#### 추가된 것
- `admin-brand.js` 의 `BRAND_APP_HISTORY_FIELD_LABELS.admin_memo` 라벨 그대로 유지 (기존 이력 행 표시용 — 사양서 §5 에서 언급 없었음)
- 마이그레이션 파일 검증 SQL 보강: `V0-PRE`(백필 누락 행 사전 점검) + `V0-COUNT`(백필 대상 건수 캡쳐) + `V2-SAMPLE` 분리

#### 달라진 것
- 마이그레이션 번호: 사양서 §1 후보 123 → 실제 122 (사양서 작성 시점에 117~122 가 예약됐다고 가정했으나, 실제로는 121 까지만 사용됨)

### 구현 중 기술 결정 사항

1. **CHECK 제약 보존**: 위 "빠진 것" 항목 참조. 사양서가 `admin_memo` 만 제거하면 된다고 가정했으나, 실제 CHECK 는 `memo_*` 3종도 포함하고 있었음 + 기존 행 영향 확인 누락 → 통째로 미수정 결정.

2. **백필 검증 SQL 강화**: supabase-expert 검토에서 제기된 경고에 따라 V0-PRE / V0-COUNT / V2 건수 대조 추가.

3. **롤백 SQL 보강**: products[0].admin_memo → admin_memo 컬럼 역방향 복사 SQL 추가.

### 검증 결과 (마이그레이션 122)
- **개발 DB (`qysmxtipobomefudyixw`): 2026-05-14 적용 완료 + 검증 통과**
  - V0-PRE: 0 (백필 누락 행 없음)
  - V0-COUNT: 14 (백필 대상)
  - V1: 0 (admin_memo 컬럼 제거)
  - V2: 14 (백필 결과 = V0-COUNT 일치)
  - V3: CHECK 제약 보존 (admin_memo + memo_added/edited/deleted 포함된 8개 ARRAY 그대로)
  - V4: 0 (트리거의 NEW.admin_memo/OLD.admin_memo 식별자 제거 확인 — 주석 단어 잔존은 거짓 양성)
  - V5: 14 파라미터 (p_admin_memo 제거)
  - V6: 15 (기존 admin_memo 이력 행 감사 목적 보존)

---

## 후속 결정 — multi-entry 제품별 메모로 전환 (2026-05-14)

### 배경
122 적용 후 사용자가 운영서버의 `brand_application_memos` (multi-entry) 패턴을 보고 "제품별로 같은 방식이 구동돼야 한다" 요청. 단일 텍스트 `products[i].admin_memo` 로는 운영서버의 작성자·시각·수정/삭제 audit + 모달 UX 가 구현 불가능 → multi-entry 시스템으로 전환 결정.

### 변경 범위 (마이그레이션 123·124 + UI 재설계)

#### DB
- **마이그레이션 123**: `brand_application_memos.product_idx integer NOT NULL DEFAULT 0` 컬럼 추가. (application_id, product_idx, created_at DESC) 인덱스. `record_brand_application_memo_history` 트리거 함수 갱신 (jsonb 페이로드에 product_idx). 122 의 `products[i].admin_memo` → `brand_application_memos` 백필 (14건) → `products[i]` 의 admin_memo 키 제거
- **마이그레이션 124**: 080 백필분 (12건) 과 123 백필분 (14건) 의 동일 텍스트 중복 12쌍 정리. 081 트리거 임시 비활성화 → 080 백필분 12건 삭제 → 트리거 재활성화. 결과: legacy 메모 14건, 모두 history 에 매칭

#### 클라이언트
- **셀 표시 변경**: 인라인 textarea 편집 제거. 셀에 최신 메모 1줄 + 개수 배지 + ✎ 모달 진입 버튼
- **모달 재사용 확장**: 기존 `brandAppMemoModal` (운영서버 패턴) 을 그대로 활용. `openBrandAppMemoModal(applicationId, productIdx)` 시그니처 확장. 헤더에 "신청번호 · 제품명 — 내부 메모" 표시. 본문은 그 제품 메모만 필터
- **변경 이력 모달 갱신**: `memo_added`/`memo_edited`/`memo_deleted` 이력 행에 `product_idx` 가 있으면 "[제품 N] 제품명" 라벨 표시 — 신청 단위 변경 이력 모달에서 제품별 메모 변경 이력이 식별 가능

### 영향 파일
- `supabase/migrations/123_brand_app_memo_per_product.sql` (신규)
- `supabase/migrations/124_brand_app_memo_dedup_legacy.sql` (신규)
- `dev/lib/storage.js` — `fetchBrandAppMemos`/`insertBrandAppMemo` 시그니처 확장, `fetchBrandAppMemoSummaries` 페어 키 그룹핑으로 재설계
- `dev/js/admin-brand.js` — 인라인 메모 편집 함수 6종 제거(renderMemoDisplay/_restoreMemoDisplay/enterMemoEdit/handleMemoEditKey/cancelMemoEdit/confirmMemoEdit), `renderMemoCellInner`/`renderProductMemoDisplay`/`openBrandAppMemoModalFromCell` 신규, 모달 함수 product_idx 인식 확장, 변경 이력 모달 분기 추가, 엑셀 export 갱신

### 검증 결과 (마이그레이션 123·124)
- **개발 DB**: 2026-05-14 적용 완료 + 검증 통과
  - 123 V1~V7: product_idx 컬럼/인덱스/트리거 갱신/백필 14건/history 14건 매칭 모두 정상
  - 124 V1~V4: 중복 그룹 0건, legacy 메모 14건, history 링크 14건, memo_deleted 노이즈 0건
- **운영 DB**: 2026-05-15 적용 완료 (122 → 123 → 124 → 125 → 126 한 묶음 SQL Editor 차례로)

---

## 후속 결정 — 미확인 메모 카운트 배지 (2026-05-14)

### 배경
123/124 적용 후 메모 셀의 분홍 카운트가 "총 메모 개수" 였음. 사용자 요청: "메모를 확인하면 배지가 없어지게. 미확인 메모 수로 활용". 운영서버 `admin_notices`/`admin_notice_reads` 패턴(063) 을 미러링하여 메모 단위 읽음 이력 도입.

### 사용자 결정 (분기 3개)
1. 읽음 처리 시점: 모달을 열면 자동 일괄 처리 (추천 A)
2. 변경 안내 방식: 별도 안내 없이 배포 (옵션 C — 의미 변경이 단순)
3. 추천안 그대로 진행: 데이터 소스 `brand_application_memos` 확장, product_idx 단순 사용, 단일 PR

### 마이그레이션 125
- `brand_application_memo_reads` 테이블 (memo_id FK CASCADE, auth_id, read_at, PRIMARY KEY)
- 행 단위 보안 정책 2종 (SELECT 관리자 전체, INSERT 본인만)
- 원격 호출 함수 2종:
  - `mark_brand_app_memos_read(application_id, product_idx)` SECURITY DEFINER — 페어 단위 일괄 UPSERT
  - `get_brand_app_memo_summaries()` SECURITY DEFINER — (application_id, product_idx, total_count, unread_count, latest_text, latest_created_at) 반환

### 클라이언트
- `storage.js`: `fetchBrandAppMemoSummaries()` 가 RPC 호출로 전환 (페어 키 + unreadCount 포함). `markBrandAppMemosRead(applicationId, productIdx)` 신규
- `admin-brand.js`: 셀 배지가 `unreadCount > 0` 일 때만 분홍. 모달 진입 시 mark read + 셀 즉시 갱신

### 검증 결과 (마이그레이션 125)
- 개발 DB: 2026-05-14 적용 완료. SQL Editor 검증 V1~V4 통과. V5/V6 은 auth.uid()=NULL 때문에 SQL Editor 컨텍스트에선 권한 거부 (정상)
- 운영 DB: 2026-05-15 적용 완료

---

## 후속 결정 — 「오리엔시트 전달」 → 「입금 날짜」 컬럼 분리 (2026-05-15)

### 배경
운영자가 「오리엔시트 전달」 셀에 입력해온 날짜가 실제로는 입금일 의미였음. 사용자 요청: 오리엔시트 전달 셀은 URL 만 + 입금 날짜 별도 컬럼.

### 사용자 결정 (분기 3개)
1. 컬럼 처리: 데이터 이전 후 컬럼 DROP (추천 A) — 모델 깔끔, 회귀 위험 최소
2. 백필 범위: 전체 데이터 이전 (추천 A)
3. PR 묶음: 단일 PR (추천 A)

### 마이그레이션 126
- `paid_at timestamptz NULL` 컬럼 추가
- 백필: `paid_at = orient_sheet_sent_at` (NULL 도 그대로 보존)
- `orient_sheet_sent_at` 컬럼 DROP (`orient_sheet_sent_url` 은 보존)
- 변경 이력 트리거는 두 컬럼 모두 미추적 (091/122 시점 결정 유지)

### 클라이언트
- `storage.js`: SELECT 컬럼에서 `orient_sheet_sent_at` 제거, `paid_at` 추가
- `admin-brand.js`:
  - 오리엔시트 셀: URL 만 (날짜 입력 영역 제거). `renderOrientSheetSentDisplay(urlOrNull, locked)` 시그니처 축소
  - 입금 날짜 셀 신규: `renderPaidAtDisplay` + enter/cancel/confirm + syncPaidAtEditDate (견적서 셀 패턴 미러)
  - thead 「입금 정보」 뒤로 「입금 날짜」 컬럼 추가 + colspan 29→30
- `BRAND_APP_HISTORY_FIELD_LABELS` 에 `paid_at: '입금 날짜'` 라벨 추가

### 검증 결과
- 개발 DB: 2026-05-15 적용 완료 (단, 검증 주석 블록 `/*` 닫힘 문제로 첫 시도 부분 적용 → 사실 동작은 정상, 본문 모두 적용됨)
- 운영 DB: 2026-05-15 적용 완료 (수동 4 statement 분리 실행)

---

## 후속 폴리시 (2026-05-14 ~ 05-15)

### 메모 셀 UX
- ✎ 아이콘 통일: `edit_note(15px)` → `edit(13px)` + 수직 중앙 정렬 (옆 셀 모집비/이체수수료와 매칭)
- 셀 컨테이너 `display:flex;align-items:center` — 상하 중앙 정렬
- 작성자 표기: `(legacy)` → `(자동 이전)` — 한국어 친화

### 변경 이력 모달 화이트리스트 확장
- `BRAND_APP_PRODUCT_SUBFIELDS` 에 4종 추가: recruit_fee_krw / price_check / name_ja / category
- `_expandBrandAppProductsHistoryRow` 가 0건 반환 시 "메타 변경" 가상 행 push 제거 — 마이그레이션 자동 키 추가/제거 노이즈 숨김

### URL 자동 prefix
- 신규 헬퍼 `normalizeBrandUrlInput(raw)` — `safeBrandUrl` 와 짝
- 빈 문자열 → null, http/https 시작 → 그대로 검증, protocol-relative → `https:` prefix, 스킴 없음 → `https://` 자동, 위험 스킴 → 차단
- 견적서·오리엔시트 셀 양쪽 적용

### 라벨 변경
- 컬럼 헤더 「입금여부」 → 「입금 정보」 (2026-05-15)

---

## 운영 배포 완료 (2026-05-15)

- 운영 DB 마이그레이션 122 → 123 → 124 → 125 → 126 순차 적용 + 통합 검증 통과
- dev → main PR #204 머지 (354e446)
- Vercel 자동 배포 완료 — 운영 빌드 마커 `v1778809512` (커밋 b8487c1)
- reverb-qa-tester light: 개발서버 PASS 5 / FAIL 0 (운영서버 검증은 사용자 직접)
