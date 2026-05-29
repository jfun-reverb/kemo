# 관리자 모달 드래그·리사이즈

**작성일:** 2026-05-28
**상태:** 기획 초안 (개발 미진입)
**작성 세션:** 기획/설계 세션

---

## 1. 배경 / 문제

### 현재 상태
- 관리자 페이지 모달이 화면 가운데에 고정 노출 (`dev/css/components.css` `.modal-overlay` + `.modal`)
- 크기 고정 (max-width 480px, max-height 90vh) — 본문 길면 내부 스크롤만
- 드래그·리사이즈 인터랙션 없음 (CSS `resize:` 는 textarea 만, 모달 자체는 없음)
- overlay (`background:rgba(0,0,0,.4)`) 가 메인 페이지 가림 — 메인 페이지 조작 차단

### 문제 (2026-05-28 사용자 명시)
> "모달이 떴을 때 메인 페이지의 내용을 참고해서 작성할 경우가 있는데 모달에 가려져서 보기 힘들어. 메인 페이지를 이동해서 참고해서 작성할 수도 있고."

- 운영자가 모달 작성 중 메인 페이지의 다른 행·필터를 참고해야 할 경우가 잦음
- 현재는 모달이 가운데에 고정이라 가린 영역을 확인하려면 모달을 닫아야 함
- 모달 닫으면 작성 중인 내용 손실 + 다시 열어서 처음부터

### 목표
- 모달 위치·크기를 마우스로 자유 조절
- 모달이 한쪽으로 비키면 가린 영역 노출되어 메인 페이지 참고 가능
- **overlay 차단·작성 데이터 안전성은 그대로 유지** (모달리스 패턴은 데이터 손실 위험으로 채택 안 함)

---

## 2. 현재 상태 (planning.md 규칙 A — 2026-05-28 검증)

### 코드·CSS 직접 확인 결과

| 영역 | 현재 |
|---|---|
| 모달 공용 CSS | `dev/css/components.css:94-101` `.modal-overlay` + `.modal` 정의 |
| 모달 위치 | `position:fixed` + `inset:0` + `justify-content:center` 가운데 고정 |
| 모달 크기 | `max-width:480px` · `max-height:90vh` 고정 |
| 드래그 핸들러 | **없음** — `mousedown` 처리 0 |
| 리사이즈 | textarea 만 `resize:vertical` (admin.css:1289 · components.css:72) — 모달 자체는 없음 |
| overlay 어두운 배경 | `background:rgba(0,0,0,.4)` — 메인 페이지 시각 차단 |
| 모바일 변형 | `@media` 에서 `align-items:flex-end` 슬라이드업 패턴 |

### 충돌·의존 점검
- 인플 화면 모달(`legalModal`·메시지 모달 등)도 같은 `.modal` 클래스 공유 → 본 변경 시 **관리자 모달만 한정** 분기 필요
- 메모리 `project_admin_js_split.md` — admin.js 페인 분리 완료 → 공용 헬퍼는 `dev/lib/admin-core.js` 또는 `dev/lib/shared.js` 에 두면 모든 페인에서 접근 가능
- `.claude/rules/quality.md` 「모달 닫힌 후 `refreshPane()` 의무」 — 드래그·리사이즈와 무관, 기존 정책 유지

---

## 3. 의심·경우의 수 (planning.md 규칙 B — 2026-05-28 정리)

### 깨질 가능성

| # | 카테고리 | 시나리오 | 대응 |
|---|---|---|---|
| ① | UX — 화면 밖 이탈 | 모달이 화면 밖으로 완전히 나가서 못 돌아옴 | 헤더 일부는 항상 화면 안 — `Math.max(0, ...)` + `window.innerWidth - 100` 클램프 |
| ② | UX — 닫기 버튼 충돌 | 헤더의 닫기 버튼 클릭이 드래그로 인식 | `e.target.closest('.modal-close, input, ...')` 가드 |
| ③ | 데이터 — 위치·크기 저장 | 모달 열림 시 처음 가운데, 두 번째부터 마지막 위치 기억? | **매번 가운데 초기화 권장** (모달 종류 다양해 통일 어려움). localStorage 저장은 v2 |
| ④ | UX — 드래그 중 텍스트 선택 | 헤더 드래그 시 본문 텍스트가 선택돼 깜빡임 | header 에 `user-select:none` |
| ⑤ | 기술 — overlay 동기 이동 | 모달과 overlay 가 같이 움직이면 가린 영역 확인 불가 | overlay 는 `position:fixed` 유지, 모달만 `position:absolute` 분리 |
| ⑥ | UX — resize 핸들 겹침 | 우하단 resize 핸들이 본문 스크롤바와 겹침 | `.modal-body` 우측 padding 추가 또는 핸들 위치 명시 |
| ⑦ | 기술 — 신규 모달 누락 | 새 모달 추가 시 헬퍼 호출 누락으로 드래그 안 됨 | reverb-reviewer 가 모달 open 함수에 헬퍼 호출 누락 점검 |
| ⑧ | UX — 인플 모달 영향 | 인플 화면 모달(`legalModal`·메시지 모달)에도 적용되면 모바일 슬라이드업 깨짐 | 관리자 모달만 한정 — `.modal.draggable` 클래스 명시 + 인플 모달은 미적용 |
| ⑨ | UX — 작은 확인 모달 적용 부적절 | confirm·alert 류 작은 모달은 드래그 불필요 + 오히려 방해 | 「큰 입력 모달만 적용」 가드 — 적용 대상 화이트리스트 명시 |
| ⑩ | 기술 — overlay 클릭 닫기 | overlay 어두운 영역 클릭 시 닫기 동작 유지 | 기존 동작 보존 (overlay 자체 클릭 핸들러는 그대로) |

### 현재 구현 충돌점 — 없음
- 모달 CSS·JS 가 잘 분리되어 있어 공용 헬퍼 1개로 일괄 적용 가능
- 인플 모달은 `.modal.draggable` 클래스 미부여로 자연 격리

### 의도 모호점 — 사용자 결정 필요 항목
- 모호점 1개 (위치·크기 저장 — 매번 초기화 vs localStorage) → §4 결정 사항에서 「v1 매번 초기화, v2 저장」 명시

---

## 4. 결정 사항 (2026-05-28 사용자 확정)

| 항목 | 결정 |
|---|---|
| 인터랙션 방식 | **드래그·리사이즈만** — 모달리스(Slack Compose 패턴)는 데이터 손실 위험으로 미채택 |
| overlay 차단 | **유지** — 메인 페이지 클릭·스크롤 차단 그대로 |
| 적용 대상 | 관리자 페이지 큰 모달만 (입력 폼·상세 보기·검수 모달). 인플 모달·작은 확인 모달은 제외 |
| 리사이즈 핸들 | **우하단 1개** (CSS `resize:both` 브라우저 기본 핸들). 4모서리·8방향은 v2 |
| 위치·크기 저장 | **매번 가운데 초기화** (v1). localStorage 저장은 v2 |
| 드래그 핸들 위치 | **모달 헤더** 전체 (단 닫기 버튼·input 영역은 가드로 제외) |
| 화면 밖 이탈 방지 | 헤더 일부 (가로 100px·세로 60px)는 항상 화면 안 보임 |
| 더블 클릭 최대화·복원 | v2 백로그 |
| 헬퍼 위치 | `dev/lib/admin-core.js` (관리자 공용) 또는 `dev/lib/shared.js` (전체 공용 — 인플 모달은 `.draggable` 클래스 미부여로 격리) |

---

## 5. 제안 / 설계

### 5-1. CSS 변경 (`dev/css/components.css` 또는 `admin.css`)

```css
/* 드래그·리사이즈 가능한 관리자 모달 */
.modal.draggable {
  position: absolute;     /* 가운데 정렬 해제, 자유 위치 */
  resize: both;           /* 브라우저 기본 리사이즈 핸들 (우하단) */
  overflow: hidden;       /* resize 작동 위해 visible 아니어야 함 */
  min-width: 360px;
  min-height: 240px;
  max-width: none;        /* 기본 480px 제한 해제 */
  max-height: none;
}
.modal.draggable .modal-body {
  overflow-y: auto;       /* 본문은 내부 스크롤 유지 */
  max-height: calc(100% - 80px);  /* 헤더 영역 제외 */
}
.modal.draggable .modal-header {
  cursor: move;
  user-select: none;
}
.modal.draggable .modal-header .modal-close,
.modal.draggable .modal-header input,
.modal.draggable .modal-header button {
  cursor: pointer;        /* 인터랙티브 요소는 드래그 영역 제외 */
}
```

### 5-2. 공용 헬퍼 — `makeModalDraggableResizable(modalEl)`

`dev/lib/admin-core.js` 또는 `dev/lib/shared.js`:

```javascript
function makeModalDraggableResizable(modalEl) {
  if (!modalEl) return;
  modalEl.classList.add('draggable');

  // 초기 위치 — 화면 가운데 (매번 초기화, v2 에서 localStorage 저장)
  const rect = modalEl.getBoundingClientRect();
  const cx = (window.innerWidth - rect.width) / 2;
  const cy = (window.innerHeight - rect.height) / 2;
  modalEl.style.left = Math.max(0, cx) + 'px';
  modalEl.style.top = Math.max(0, cy) + 'px';

  const header = modalEl.querySelector('.modal-header');
  if (!header) return;

  let dragState = null;

  header.addEventListener('mousedown', (e) => {
    // 닫기 버튼·input·button 은 드래그에서 제외 (가드)
    if (e.target.closest('.modal-close, input, textarea, select, button, a')) return;

    const rect = modalEl.getBoundingClientRect();
    dragState = {
      offsetX: e.clientX - rect.left,
      offsetY: e.clientY - rect.top
    };
    document.body.style.userSelect = 'none';
    e.preventDefault();
  });

  document.addEventListener('mousemove', (e) => {
    if (!dragState) return;
    // 화면 밖 이탈 방지 — 헤더 일부는 항상 보임
    const newLeft = Math.max(-100, Math.min(window.innerWidth - 100, e.clientX - dragState.offsetX));
    const newTop = Math.max(0, Math.min(window.innerHeight - 60, e.clientY - dragState.offsetY));
    modalEl.style.left = newLeft + 'px';
    modalEl.style.top = newTop + 'px';
  });

  document.addEventListener('mouseup', () => {
    if (dragState) {
      dragState = null;
      document.body.style.userSelect = '';
    }
  });
}
```

### 5-3. 적용 대상 — 관리자 페이지 큰 모달

각 모달 open 함수 끝에서 헬퍼 호출:

```javascript
function openInfluencerDetailModal(id) {
  // ... 기존 로직 (DOM 생성·데이터 로드)
  const el = document.querySelector('#influencerDetailModal .modal');
  makeModalDraggableResizable(el);
}
```

**대상 모달 분포 (admin-*.js):**
- `admin-influencers.js` — 인플 상세·flag·상태 관리 모달
- `admin-applications.js` — 신청 상세·승인·반려 모달
- `admin-deliverables.js` — 결과물 검수 모달
- `admin-brand.js` / `admin-company.js` / `admin-brand-ops.js` — 브랜드 신청 상세·메모·회사 편집 모달
- `admin-notices.js` — 공지 편집·미리보기 모달
- `admin-faq.js` — FAQ 편집 모달
- `admin-lookups.js` — 기준 데이터·번들 편집 모달 (caution·participation·ng)
- `admin-accounts.js` — 관리자 추가·메일 수신 설정 모달
- `admin-messaging.js` — 메시지 상세·발송 이력 모달 (PR 2 dev 완료)
- `admin.js` — 캠페인 편집·미리보기·삭제 확인 모달

**제외 대상:**
- 인플 화면 모달 (`legalModal`·메시지 모달 — 모바일 슬라이드업)
- 작은 확인 모달 (`confirmModal`·`sensitiveChangeModal` — 알럿 류)
- 엑셀 진행 모달 (작아서 불필요)

---

## 6. PR 분할 (작업 분할 권장안)

| 단계 | 범위 | 비용 |
|---|---|---|
| A — CSS + 공용 헬퍼 | `dev/css/components.css` 또는 `admin.css` 에 `.modal.draggable` 클래스 + `makeModalDraggableResizable` 함수 작성 | 작음 (CSS 15줄 + JS 50줄) |
| B — 관리자 모달 일괄 적용 | admin-*.js 10여 곳 모달 open 함수에 헬퍼 호출 1줄 추가 | 작음 (각 파일 1~2곳) |
| C — qa·문서 | qa-tester full + `FEATURE_SPEC.md` 업데이트 + `CLAUDE.md` Features 보강 + 본 사양서 §구현 결과 작성 | 작음 |

전체 작업 시간: **2~3시간 + qa 1시간**. 본 사양서들 중 가장 작은 일감.

---

## 7. qa 시나리오

- 모달 헤더 드래그로 위치 이동 가능 (PC 환경)
- 닫기 버튼 클릭은 닫기 동작 (드래그 발동 안 함)
- 우하단 모서리 드래그로 크기 조절 (브라우저 기본 핸들)
- 모달 본문 길이가 모달 크기보다 길면 내부 스크롤 정상 동작
- 모달이 화면 밖으로 완전히 나가지 않음 (헤더 일부 항상 화면 안)
- overlay 어두운 영역 클릭 시 모달 닫기 (기존 동작 유지)
- 인플 화면 모달(`legalModal` 등)은 영향 없음 (모바일 슬라이드업 유지)
- 작은 확인 모달(`sensitiveChangeModal` 등)은 영향 없음
- 신규 모달 추가 후 헬퍼 호출 누락 시 드래그 안 됨 (reviewer 가 점검)
- 모달 닫고 다시 열면 가운데 위치로 초기화 (매번 초기화 정책)
- 드래그 중 본문 텍스트 선택되지 않음 (`user-select:none`)
- `.claude/rules/quality.md` 「모달 닫힘 후 `refreshPane()`」 정책 영향 없음

---

## 8. 영향 범위

| 영역 | 변경 |
|---|---|
| CSS | `dev/css/components.css` 또는 `dev/css/admin.css` — `.modal.draggable` 클래스 신규 (15줄) |
| 공용 JS | `dev/lib/admin-core.js` 또는 `dev/lib/shared.js` — `makeModalDraggableResizable()` 함수 신규 (50줄) |
| admin-*.js 10개 파일 | 모달 open 함수 끝에 헬퍼 호출 1줄 추가 (각 파일 1~3곳, 총 15~20곳) |
| `FEATURE_SPEC.md` | 관리자 모달 자유 위치·크기 기능 명시 |
| `CLAUDE.md` Features — 관리자 | 관리자 페이지 모달 인터랙션 보강 |
| 인플 화면 | **영향 없음** (`.draggable` 클래스 미부여) |
| 약관·개인정보 | 영향 없음 |

---

## 9. v2 백로그 (PR 범위 외)

- 모달별 마지막 위치·크기 localStorage 저장 (사용자가 매번 다시 옮길 필요 없음)
- 「가운데 정렬」 단축 버튼 (헤더 우측 작은 아이콘)
- 더블 클릭으로 최대화·복원 토글 (창처럼)
- 모달 N개 동시 열림 시 z-index 자동 정렬 (활성 모달 최상위)
- 4모서리·8방향 리사이즈 핸들 (현재는 우하단 1개)
- 키보드 단축키 — Esc 닫기 외 화살표 키로 모달 위치 미세 조정

---

## 10. 우선순위 — 다른 사양서들과 비교

| 사양서 | 비용 | 운영 가치 |
|---|---|---|
| PR 3 메시지 일괄 발송 | 큼 (작업 분할 6단계 + 약관 30일 통지) | 큼 (운영 자주 사용 기능) |
| 감사용 인플 계정 | 중간 (PR 7단계) | 큼 (운영서버 검증 도구 — 다른 기능 검증에 활용) |
| 약관 버전 관리 | 큼 (PR 7단계 + TERMS 제25조 신설 자기 참조 의무) | 중간 (법적 안전성 ↑, 즉시성 낮음) |
| **본 사양서 — 모달 드래그·리사이즈** | **작음 (PR 3단계, 2~3시간)** | **중간 (운영자 일상 작업 편의)** |

→ 본 사양서는 가장 작은 일감. 다른 사양서들 운영 사이클 사이에 끼워넣기 좋음. 약관 통지 의무도 없어 단독 운영 배포 가능.

---

## 구현 결과

**구현일:** 2026-05-29
**관련 커밋/PR:** dev — 초판(afa6244) + 수정 PR #377·#378(정중앙·폭튐·헤더없는모달·8방향) → 운영 dev→main PR #383(main 9e26ae5).

### 초안 대비 변경 사항
- **추가**: 8방향 리사이즈(초안은 우하단 `resize:both` 1방향, v2 백로그였으나 사용자 요청으로 상하좌우+4모서리 핸들 + 방향별 커서로 구현). 가로 폭 확장(드래그/리사이즈 시 max-width/height 해제, dataset.origMaxW 백업·재열림 복원).
- **달라진 것**:
  - 초안 "현재 상태: 화면 가운데 고정"은 부정확 — 실제는 하단 바텀시트(`align-items:flex-end`). 정중앙은 `transform:translate(-50%,-50%)`로 구현(초안의 rect 측정 방식은 렌더 타이밍에 중앙 하단 치우침 발생 → transform으로 교체).
  - 초안 CSS `width:480px` 강제 제거 → 각 모달 인라인 max-width(480~1280px) 존중(width 강제 시 전 모달이 480으로 좁아지는 버그).
  - 적용 방식: 초안의 "open 함수마다 헬퍼 호출" 대신 MutationObserver(overlay .open 감지) 단일 지점 — open 방식(openModal/classList) 혼재 대응. 단 display 직접 조작 모달은 미감지(adminProxy 별도 .open 전환, [[project_deliverable_channel_assign]] 후속 통일에서 처리).
- **빠진 것**: 위치·크기 localStorage 저장, 더블클릭 최대화 — v2 백로그.

### 구현 중 기술 결정 사항
- `pinPosition()`: 드래그/리사이즈 시작 시 현재 크기 px 고정 → 그 다음 max 해제(순서 중요, 안 그러면 width:94vw 튐). transform 조건 `!== 'none'`(빈 문자열 포함, 안 하면 왼쪽 튐).
- 드래그 핸들: `.modal-header` 우선 → 없으면 `.modal-body` 첫 요소 fallback.
- 인플 빌드 격리(admin.css/admin-core.js 관리자 빌드 전용). [[project_admin_modal_ux]] 통합 기록.
