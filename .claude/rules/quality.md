---
description: 프로젝트별 코드 품질 규칙
globs: "dev/**/*.js,dev/**/*.css,dev/**/*.html"
---

# 프로젝트 코드 규칙

## 코드 중복
- UI 유틸리티: dev/js/ui.js에 추가 (toast, formatDate, esc 등)
- DB 함수: dev/lib/storage.js에 추가
- 전역 상태: dev/lib/shared.js에 추가

## 네이밍
- 함수명: camelCase (fetchCampaigns, renderCampaignCard)
- CSS 클래스: kebab-case (campaign-card, bottom-tab)
- ID: camelCase 또는 kebab-case (page-home, #appShell)
- 상수: UPPER_SNAKE_CASE (SUPABASE_URL, ADMIN_EMAIL)

## 관리자 모달 페인 갱신 (필수)
- 관리자 페이지에서 **수정·편집·삭제·토글** 동작이 가능한 모달의 저장 함수는 끝에서 반드시 해당 페인 목록·집계를 다시 그려야 한다.
- `dev/lib/shared.js`의 공통 헬퍼 **`refreshPane(paneId)`** 사용. **어떤 페인 ID를 쓸 수 있는지는 같은 파일의 `PANE_REFRESHERS` 가 단일 소스다**(여기에 베껴 적지 않는다 — 2026-08 기준 21개이고 계속 는다).
  ```bash
  sed -n '/const PANE_REFRESHERS/,/^};/p' dev/lib/shared.js | grep -oE "^  '?[a-z-]+'?:"
  ```
- ⚠️ **등록 안 된 ID로 부르면 아무 일도 안 일어난다.** 오류가 아니라 `console.warn` 한 줄 남기고 조용히 끝나서, 화면은 「저장했는데 목록이 그대로」인 상태가 된다 — 이 헬퍼가 막으려던 바로 그 증상이다. 새 페인을 만들면 `PANE_REFRESHERS` 등록을 먼저 한다.
- 새 페인을 만들면 `PANE_REFRESHERS`에 한 행 추가 + 모든 신규 모달 저장 함수에 `await refreshPane(...)` 호출 한 줄 추가.
- 직접 `loadXxx()` / `renderXxx()` 호출도 허용하지만, 새 모달이 생길 때마다 누락 패턴이 반복되었으므로 신규 코드는 헬퍼를 우선한다.
- reverb-reviewer 에이전트는 모달 저장 함수에 `refreshPane` 또는 동등한 list 재렌더 호출 누락 여부를 체크한다.

**Why:** 모달이 닫혀도 뒤의 목록·배지가 stale 상태로 남아 「방금 변경한 게 안 보이는」 사용자 보고가 반복 발생. 헬퍼 통일로 회귀 방지.

---

## 🔴 새 화면·새 기능은 **먼저 기존 것을 보고 맞춘다** (영구, 2026-09-03 사용자 지시)

새 페인·새 모달·새 표를 만들 때 **자기 방식으로 새로 쓰지 않는다.** 이 저장소에 같은
일을 하는 자리가 **거의 항상 이미 있고**, 그것과 어긋나면 화면마다 모양·동작이 갈린다.

⚠️ **이건 취향 문제가 아니다.** 이 저장소가 반복해서 겪은 사고의 유형이 「같은 판정이
여러 벌 있는데 한 곳만 고쳤다」이고(`CLAUDE.md` 에 그런 경고가 40건 넘는다), 새로
쓰는 순간 그 사본이 하나 더 생긴다.

### 코딩 전에 확인할 것 (의무)

| 무엇 | 어디를 보나 | 안 보면 생기는 일 |
|---|---|---|
| **날짜·시각 표기** | `dev/js/ui.js` — `formatDate`(`2026/09/03`) · `formatDateTime`(`2026/09/03 22:11`) · `formatTimeHm` | 화면마다 날짜 모양이 다르다 |
| **이미지 열기** | `openImageLightbox(url)` (`admin-core.js`) — 확대·드래그 되는 창 | 새 탭으로 튕겨 나간다 |
| **금액 표기** | `¥` + `toLocaleString('ja-JP')` (정산·검수 화면) | 자릿수 구분이 없거나 통화가 다르다 |
| **모달** | `modal-overlay open` + `modal-header/body/footer`. **동적 생성**(오리엔시트 모달 선례) | 클래스가 달라 모양이 어긋나거나 핫스팟 HTML 을 또 만진다 |
| **표** | `admin-card` → `admin-table-wrap` → `data-table` | 머리글 고정·가로 스크롤이 안 먹는다 |
| **저장 뒤 목록 갱신** | `refreshPane(paneId)` + `PANE_REFRESHERS` 등록 | 「저장했는데 목록이 그대로」 |
| **긴 목록** | IntersectionObserver 점진 렌더(관리자 8개 페인) | 1,000건에서 화면이 멈춘다 |
| **전건 조회** | `range(from, from+999)` 반복(`fetchAllPaged`) | 1,000건에서 조용히 잘린다 |
| **권한** | `ADMIN_PERMISSION_CATALOG` + `isHidden`/`canWrite` | 매니저가 버튼을 보고 눌렀다가 오류를 본다 |
| **아이콘** | Material Icons + `translate="no"` | 번역기가 아이콘 이름을 번역해 글자가 뜬다 |
| **되돌릴 수 없는 동작** | 확인 창. **강도는 잃는 것에 맞춘다** — 원본이 사라지면 이름 재입력, 다시 만들 수 있으면 확인만 | 과해도 덜해도 문제다 |

### 찾는 방법 — 「비슷한 화면」을 먼저 연다

새 기능이 **무엇을 닮았는지** 정하고 그 파일을 **먼저 읽는다.**
목록+상세면 `admin-deliverables.js`, 발급+상세 모달이면 `admin-orient.js`,
표+엑셀이면 `admin-excel.js`.

```bash
# 같은 일을 하는 함수가 이미 있는지
grep -rn "function format\|function fmt" dev/js/ui.js dev/lib/shared.js
grep -rn "openImageLightbox\|refreshPane\|fetchAllPaged" dev/js/ | head
```

### ⚠️ 「비슷한 걸 찾았다」에서 멈추지 않는다

찾은 것이 **공용인지 그 화면 전용인지** 가른다. `admin-brand.js` 의 `fmtDate` 는
`formatDate` 를 감싼 **그 화면 전용**이라 다른 페인이 쓰면 안 된다.
공용은 `dev/js/ui.js` · `dev/lib/shared.js` · `dev/lib/storage.js` 에 있다.

**Why:** 2026-09-03 리포트 화면을 만들면서 **한 조각에서 네 번** 이 실수를 했다 —
①시각 표기를 `toLocaleString` 으로 직접 만들어 **초까지 나오고 다른 화면과 달랐다**
②「열기」를 `target="_blank"` 로 해서 **이미 있는 확대 창**을 안 썼다
③다른 페인에 다 있는 **「삭제」 버튼을 빠뜨렸다**(서버 함수는 있는데 진입점이 없어
개발자 도구로만 지울 수 있었다) ④목록 날짜에 브랜드 화면 전용 감싸개를 썼다.
넷 다 **기존 코드를 5분만 봤으면** 안 생겼고, 넷 다 사용자가 화면을 보고 지적해서야
드러났다. 사용자 지시: 「새 페이지를 만들거나 새 기능을 만들 때 우리가 기존에 어떤
방식으로 구성했는지를 검토하고 맞춰서 해줘, 다시 실수 없게 해줘」.
