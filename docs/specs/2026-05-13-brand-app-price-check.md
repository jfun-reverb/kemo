# 브랜드 서베이 — 가격체크 컬럼 추가 사양서

- **작성일**: 2026-05-13
- **작성**: 기획 세션
- **상태**: 개발 착수 전 (미구현)
- **위치**: 관리자 페이지 → 브랜드 서베이 신청 목록(`/admin#brand-applications`)

---

## 1. 배경 및 목표

신청서에 적힌 상품 금액과 실제 마켓에 등록된 가격이 일치하는지 관리자가 빠르게 확인·기록할 수 있도록, 신청 목록 표에 **가격체크 컬럼**을 추가한다. 컬럼은 제품별(행별)로 독립 선택 가능.

상태 3종:
- **가격높음** — 마켓 가격 > 신청 금액
- **가격낮음** — 마켓 가격 < 신청 금액
- **가격동일** — 마켓 가격 = 신청 금액
- 미선택 — 아직 확인 안 함 (기본 상태)

---

## 2. 최종 결정 사항

| 항목 | 결정 |
|---|---|
| 위치 | 신청 목록 표, 「진행 수량」 다음 + 「상품 가격(엔)」 앞 |
| 입력 단위 | 제품별(행별) 독립 선택 |
| 입력 방식 | 드롭다운 |
| 기준 방향 | 마켓 가격 > 신청 가격 = 「가격높음」 |
| 색 구분 | 가격높음 = 주황 / 가격낮음 = 파랑 / 가격동일 = 회색 / 미선택 = 옅은 테두리 |
| 저장 위치 | `brand_applications.products[i].price_check` (jsonb 내부 필드) |
| 마이그레이션 | 불필요 (jsonb에 새 키 추가만) |

---

## 3. 데이터 구조

### products[i] 내부 신규 필드

```json
{
  "name": "제품 A",
  "qty": 100,
  "price": 5000,
  "recruit_fee_krw": 5000,
  "transfer_fee_krw": 500,
  "payment_flags": { ... },
  "price_check": "higher" | "lower" | "equal" | null
}
```

값 정의:
- `"higher"` — 가격높음 (마켓 > 신청)
- `"lower"` — 가격낮음 (마켓 < 신청)
- `"equal"` — 가격동일
- `null` 또는 키 없음 — 미선택 (기본 상태)

기존 제품 행은 키가 없으므로 자동으로 미선택 상태로 표시. 백필 마이그레이션 불필요.

---

## 4. UI 디자인

### 컬럼 추가 위치

```
| 진행 수량 | [신규] 가격체크 | 상품 가격(엔) | 상품 가격(원) | 모집비 | ... |
```

### 드롭다운 형식

각 제품 행마다 작은 드롭다운 1개. 폭은 약 90~100px.

```
미선택 상태 (옅은 회색 점선 테두리, 「확인 필요」 같은 안내 텍스트):
┌─────────────┐
│ 확인 필요 ▾  │
└─────────────┘

선택 후 (선택값에 따라 배경색 + 텍스트색 변경):
┌─────────────┐
│ 가격높음 ▾  │  (주황 배경 #FFF4E0, 텍스트 #C8650A)
└─────────────┘

┌─────────────┐
│ 가격낮음 ▾  │  (파랑 배경 #E4F0FF, 텍스트 #1F5DBF)
└─────────────┘

┌─────────────┐
│ 가격동일 ▾  │  (회색 배경 #EEEEEE, 텍스트 #555555)
└─────────────┘
```

드롭다운 옵션:
- (기본) — 확인 필요 (선택 시 null로 되돌림)
- 가격높음
- 가격낮음
- 가격동일

---

## 5. 변경 파일 목록

| 파일 | 변경 내용 |
|---|---|
| `dev/admin/index.html` (line 1372 부근) | thead 에 「가격체크」 th 추가 (진행 수량 다음, 상품 가격(엔) 앞) |
| `dev/js/admin-brand.js` | 행 렌더 함수에 가격체크 셀 추가, 드롭다운 변경 핸들러 작성 |
| `dev/css/admin.css` | 가격체크 드롭다운 스타일 (4상태 색 구분 포함) |
| `dev/js/admin-brand.js` (엑셀 내보내기, line 320~) | 엑셀 컬럼에도 가격체크 항목 추가 (선택 사항 — §10 참조) |

DB 마이그레이션 없음.

---

## 6. 상세 변경 내용

### 6-1. thead 변경 (`dev/admin/index.html`)

line 1372 다음에 새 th 1줄 삽입:
```html
<th style="width:80px">진행 수량 ...</th>
<th style="width:100px">가격체크 <span class="col-help" data-tooltip="마켓 등록 가격과 신청 금액 비교 — 마켓가가 더 높으면 「가격높음」">...</span></th>  <!-- 신규 -->
<th style="width:100px">상품 가격(엔)</th>
<th style="width:100px">상품 가격(원) ...</th>
```

### 6-2. 행 렌더 함수 변경 (`dev/js/admin-brand.js` line 1942 부근)

기존:
```js
// 14. 진행 수량 (제품 단위)
html += '<td style="...">' + ... + '</td>';

// 15. 상품 가격(엔) (제품 단위)
html += '<td style="...">' + ... + '</td>';
```

변경 후:
```js
// 14. 진행 수량 (제품 단위)
html += '<td style="...">' + ... + '</td>';

// 14.5. 가격체크 (제품 단위, 신규)
html += '<td><div class="brand-app-pricecheck-cell" data-id="' + esc(a.id) + '" data-product-idx="' + idx + '">' 
      + renderBrandAppPriceCheckCell(a, idx, p) 
      + '</div></td>';

// 15. 상품 가격(엔) (제품 단위)
html += '<td style="...">' + ... + '</td>';
```

### 6-3. 새 함수: `renderBrandAppPriceCheckCell(a, productIndex, product)`

```js
function renderBrandAppPriceCheckCell(a, productIndex, p) {
  var val = (p && p.price_check) || '';
  var opts = [
    { val: '',        label: '확인 필요', cls: 'pc-empty'  },
    { val: 'higher',  label: '가격높음',  cls: 'pc-higher' },
    { val: 'lower',   label: '가격낮음',  cls: 'pc-lower'  },
    { val: 'equal',   label: '가격동일',  cls: 'pc-equal'  }
  ];
  var cur = opts.find(o => o.val === val) || opts[0];
  var optionsHtml = opts.map(o =>
    '<option value="' + o.val + '"' + (o.val === val ? ' selected' : '') + '>' + o.label + '</option>'
  ).join('');
  return '<select class="brand-app-pricecheck-select ' + cur.cls + '" '
       + 'onchange="onBrandAppPriceCheckChange(\'' + esc(a.id) + '\',' + productIndex + ',this.value)"'
       + ' onclick="event.stopPropagation()">'
       + optionsHtml
       + '</select>';
}
```

### 6-4. 새 함수: `onBrandAppPriceCheckChange(applicationId, productIndex, newVal)`

```js
async function onBrandAppPriceCheckChange(applicationId, productIndex, newVal) {
  var cur = _findBrandApp(applicationId);
  if (!cur || !Array.isArray(cur.products)) return;

  var oldVal = (cur.products[productIndex] && cur.products[productIndex].price_check) || null;
  var newProducts = cur.products.slice();
  newProducts[productIndex] = Object.assign({}, newProducts[productIndex]);

  // 빈 문자열은 null 로 저장
  if (newVal === '') {
    delete newProducts[productIndex].price_check;
  } else {
    newProducts[productIndex].price_check = newVal;
  }

  // 낙관적 UI 갱신
  cur.products = newProducts;
  _rerenderBrandAppPriceCheckCell(applicationId, productIndex);

  var res = await updateBrandApplication(applicationId, { products: newProducts }, cur.version);
  if (res && res.conflict) {
    // 롤백
    cur.products[productIndex].price_check = oldVal;
    _rerenderBrandAppPriceCheckCell(applicationId, productIndex);
    toast('이미 다른 곳에서 변경됐습니다. 새로고침 후 다시 시도하세요','error');
    return;
  }
  if (!res || !res.ok) {
    cur.products[productIndex].price_check = oldVal;
    _rerenderBrandAppPriceCheckCell(applicationId, productIndex);
    toast('가격체크 저장 실패: ' + ((res && res.error) || 'unknown'), 'error');
    return;
  }
  if (res.data) {
    if (typeof res.data.version === 'number') cur.version = res.data.version;
    if (res.data.products) cur.products = res.data.products;
  }
  _rerenderBrandAppPriceCheckCell(applicationId, productIndex);
}

function _rerenderBrandAppPriceCheckCell(applicationId, productIndex) {
  var cell = document.querySelector(
    '.brand-app-pricecheck-cell[data-id="' + applicationId + '"][data-product-idx="' + productIndex + '"]'
  );
  if (!cell) return;
  var cur = _findBrandApp(applicationId);
  if (!cur) return;
  cell.innerHTML = renderBrandAppPriceCheckCell(cur, productIndex, cur.products[productIndex]);
}
```

### 6-5. CSS 추가 (`dev/css/admin.css`)

```css
.brand-app-pricecheck-select {
  width: 100%;
  min-width: 90px;
  font-size: 11px;
  padding: 4px 6px;
  border-radius: 6px;
  border: 1px solid var(--border);
  cursor: pointer;
  background: #fff;
  font-weight: 600;
  appearance: auto;
}
.brand-app-pricecheck-select.pc-empty   { color: var(--muted);  border: 1px dashed var(--border); background: #fafafa; font-weight: 400; }
.brand-app-pricecheck-select.pc-higher  { background: #FFF4E0;  color: #C8650A;  border-color: #FFD9A8; }
.brand-app-pricecheck-select.pc-lower   { background: #E4F0FF;  color: #1F5DBF;  border-color: #B6D3F7; }
.brand-app-pricecheck-select.pc-equal   { background: #EEEEEE;  color: #555555;  border-color: #D0D0D0; }
.brand-app-pricecheck-select:focus      { outline: 2px solid var(--accent); outline-offset: 1px; }
```

---

## 7. 동작 흐름

1. 관리자가 신청 목록 표에서 어떤 제품 행의 가격체크 드롭다운을 변경
2. 클라이언트가 낙관적 UI 갱신 (드롭다운 색·라벨 즉시 반영)
3. `updateBrandApplication(id, {products: newProducts}, version)` 호출
4. 서버 응답 정상이면 그대로 유지, 충돌이면 토스트 + 롤백
5. 다른 셀(가격, 입금여부 등) 영향 없음

---

## 8. 낙관적 락 동작

- 기존 `updateBrandApplication` + `version` 체크 패턴 그대로 사용
- 두 탭에서 같은 신청을 동시에 편집하면 후순위 토글이 충돌 → 토스트 + 롤백

---

## 9. 변경 이력 추적 (참고 사항)

가격체크 변경을 `campaign_caution_history` 같은 audit 테이블에 기록할지는 이번 작업 범위 밖. 필요해지면 별도 사양으로 분리.

---

## 10. 엑셀 내보내기 (선택 — 사용자 확인 필요)

브랜드 서베이 엑셀 내보내기(`dev/js/admin-brand.js` line 320 부근)에 가격체크 컬럼을 추가할지 여부는 미정. 추가한다면:

```js
{ header: '진행 수량',     key: 'qty',         width: 10 },
{ header: '가격체크',      key: 'priceCheck',  width: 12 },  // 신규
{ header: '상품 가격(엔)', key: 'priceJpy',    width: 14 },
{ header: '상품 가격(원)', key: 'priceKrw',    width: 14 },
```

값 변환: `'higher' → '가격높음', 'lower' → '가격낮음', 'equal' → '가격동일', null → ''`

> 개발 세션은 사용자에게 「엑셀에도 추가할지」 한 번 더 확인 후 진행.

---

## 11. 회귀 체크 목록

- [ ] 입금여부 컬럼이 가격체크 변경의 영향 없이 그대로 동작
- [ ] 모집비·이체수수료 인라인 편집은 가격체크 변경의 영향 없음
- [ ] 견적 총액 계산(estimated_krw)에 price_check 가 들어가지 않음을 확인
- [ ] 신청 상세 모달의 제품 테이블에는 가격체크 표시 안 함 (이번 작업 범위 밖)
- [ ] thead 컬럼 추가로 인한 sticky header / 스크롤 영역 깨짐 없는지 확인

---

## 12. 작업 시작 절차 (개발 세션용)

1. `git pull origin dev` — 최신 상태 동기화
2. **가격체크 컬럼 추가 (사양서 §6-1)** — `dev/admin/index.html` thead 1줄 추가
3. **행 렌더 함수 수정 (사양서 §6-2)** — `dev/js/admin-brand.js` 가격체크 셀 삽입
4. **드롭다운 렌더/변경 함수 작성 (사양서 §6-3, §6-4)** — admin-brand.js 하단에 신규 함수 추가
5. **CSS 추가 (사양서 §6-5)** — `dev/css/admin.css` 가격체크 드롭다운 스타일
6. **엑셀 내보내기 (사양서 §10)** — 사용자에게 추가할지 확인 후 반영
7. **빌드** — `cd dev && bash build.sh`
8. **개발서버 배포 후 검증** — §11 회귀 체크 + 가격체크 토글·새로고침·다른 탭 충돌 시나리오
9. **reverb-reviewer 호출** — 모든 commit 직전 의무
10. **사용자에게 개발서버 확인 요청** → 이상 없으면 운영 배포

---

## 13. 제외 항목 (이번 작업 범위 밖)

- 신청 상세 모달의 제품 테이블에 가격체크 표시 — 추후
- 가격체크 변경 audit 기록 — 추후
- 가격체크 통계(가격높음 비율 등 대시보드 카드) — 추후
- 자동 가격 비교(외부 마켓 API 연동 등) — 마켓 가격 시스템 미존재로 불가
