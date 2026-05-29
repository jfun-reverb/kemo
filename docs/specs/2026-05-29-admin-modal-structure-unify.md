# 관리자 페이지 모달 구조 통일

**작성일:** 2026-05-29
**상태:** 기획 초안 (개발 미진입)
**작성 세션:** 기획/설계 세션 (reverb-planner)
**선행 사양서:** 관리자 모달 드래그·리사이즈 (docs/specs/2026-05-28-admin-modal-draggable.md) — 운영 배포 완료
**마이그레이션:** 무관 (순수 프론트엔드 — HTML/CSS/JS, DB·RLS·약관 영향 없음)

---

## 1. 배경 / 문제

### 확정된 사실 (2026-05-29 사용자 제공)
- 2026-05-29 관리자 모달에 드래그·리사이즈 추가(`makeModalDraggableResizable` in `dev/js/admin-core.js`, `.modal.draggable` in `dev/css/admin.css`). 운영 배포 + 후속 수정 dev 배포 완료.
- 리사이즈 시 **header(제목 고정) / body(내용 스크롤) / footer(버튼 고정)** 분리 모달은 각 영역이 유지되나, **미분리 모달(제목·내용·버튼이 `.modal-body` 안에 다 섞임)** 은 리사이즈 시 영역 유지가 안 됨.
- **`.modal-footer` 클래스가 CSS에 아예 정의돼 있지 않음** — 분리형도 하단 버튼을 인라인 스타일로 제각각 처리. 모달 구조 표준이 정립 안 됨.
- 사용자 요청: "관리자 페이지 모달 통일 필요함."

### 목표
1. 관리자 모달의 표준 3분할 구조(`.modal-header` / `.modal-body` / `.modal-footer`) 정의 + CSS 규칙 신설
2. `.modal-footer` CSS 신설 (현재 부재 — campBundleModal만 클래스명 사용 중이나 규칙 없음)
3. 미분리 모달(제목·버튼이 body 안에 섞인 것)을 표준 구조로 재구조화 → 리사이즈 시 영역 유지
4. 드래그 헬퍼(`makeModalDraggableResizable`)의 fallback 분기 정합 유지

---

## 2. 현재 상태 (planning.md 규칙 A — 2026-05-29 검증)

### 2-1. 모달 공용 CSS 현황
| 클래스 | 위치 | 정의 |
|---|---|---|
| `.modal-overlay` / `.modal` | components.css:94-96 | `.modal` = max-width:480px; max-height:90vh; overflow-y:auto (모바일 바텀시트 — 인플 공용) |
| `.modal-header` | components.css:97 | padding:24px 24px 0; display:flex; justify-content:space-between |
| `.modal-body` | components.css:101 | padding:16px 24px 24px (스크롤 속성 없음) |
| **`.modal-footer`** | **없음(부재 확인)** | campBundleModal HTML이 클래스명 사용하나 CSS 규칙 없음 → 인라인으로만 동작 |
| `.modal.draggable` | admin.css:1320-1335 | position:absolute; transform:center; display:flex; column + body{flex:1 1 auto;overflow-y:auto} (footer 규칙 없음) |

핵심: `.modal-footer` CSS 규칙이 없다. `.modal.draggable .modal-footer{flex-shrink:0}`도 없어 리사이즈 시 footer 보장 안 됨(현재는 인라인 div가 우연히 flex item으로 동작).

### 2-2. 드래그 헬퍼가 거는 가정 (admin-core.js:582-686)
- 드래그 핸들: `.modal-header` 우선 → 없으면 `.modal-body` firstElementChild(제목 div)에 cursor:move (625-633)
- `.modal.draggable` = display:flex column 강제, body flex:1 1 auto overflow-y:auto. **footer 처리 없음**.
- 화이트리스트 `DRAGGABLE_ADMIN_MODALS` 28개. confirm/alert/lightbox/help 등 소형·읽기전용 제외.

### 2-3. 확정 미분리(B) 5개
lookupEditModal · faqEditModal · psetEditModal · csetEditModal · nsetEditModal — 모두 `.modal-header` 없이 body 안에 `<div id="xxxModalTitle">제목</div>` + 하단 인라인 `<div style="...justify-content:flex-end">취소+저장`.
(전 모달 분류표·"확인 필요" 행은 PR 진입 시 reviewer grep 재확정 — 분리형 다수는 `flex-direction:column` 인라인 보유 추정)

### 2-4. 미분리 모달 저장/렌더 함수의 DOM 참조 (재구조화 영향 — 핵심)
- 제목: `$('lookupModalTitle')`(admin-lookups.js:170/187), `$('faqModalTitle')`(admin-faq.js:254), `$('psetModalTitle')`(376/389), `$('csetModalTitle')`(549/562), `$('nsetModalTitle')`(1098/1111)
- 입력값: 전부 개별 폼 필드 id 직접 접근. 버튼: 전부 onclick 인라인 핸들러(DOM 위치 무관).
- **결론: 함수는 ①제목 div id ②폼 필드 id만 참조. 제목 div를 header/.modal-title로 옮기고 id 보존 + 버튼을 footer로 옮겨도(onclick 인라인) 함수 안 깨짐. id 보존이 절대 조건.**

### 2-5. 충돌 가능 동작
- **운영 배포된 드래그**: 미분리 모달에 header 생기면 헬퍼의 `.modal-header` 우선 분기로 전환 → 동작 더 정상화(헤더가 표준 드래그 핸들). fallback은 남겨도 무해.
- `.modal` 공용 CSS는 인플 모바일도 사용 → 관리자 footer/header 규칙은 `#page-admin` 또는 `.modal.draggable` 스코프 한정 필수.

### 2-6. 미해결 백로그
- faqEditModal은 message-faq 보류 기능 영역(운영 미배포, 개발만) → 재구조화 시 머지 순서 조율 필요(§8).

---

## 3. 의심·경우의 수 (planning.md 규칙 B)

### 3-1. 깨질 가능성
1. **(기술) `$('xxxModalTitle')` 참조 끊김** — 제목 div 이동 시 id 미보존하면 null 참조로 제목 안 바뀜. → id 보존 + reviewer grep.
2. **(기술) footer 버튼 다양성** — adminNoticeEditModal은 버튼 6개 + 좌측 status pill. 단순 우정렬이면 pill 밀림. → 표준 footer는 우정렬 + 좌측 보조요소 `margin-right:auto`.
3. **(기술) flex-shrink 미지정 footer 찌부러짐** — body flex:1만 있고 footer 규칙 없어 세로 짧게 리사이즈 시 버튼 0px. → `.modal-footer{flex-shrink:0}` 필수.
4. **(환경) 인플 모바일 모달 회귀** — `.modal-header`/`.modal-body` 공용. footer 전역 정의 시 인플 모달 영향. → 관리자 스코프 한정 + 인플 `.modal-footer` 사용처 grep 확인.
5. **(UX 필수) 미분리 모달 제목이 스크롤로 사라짐** — 현재 제목이 body 안이라 긴 폼 스크롤 시 제목 사라짐. 표준화하면 제목·버튼 고정 → UX 개선. 단 외관 변화라 룩앤필(여백·폰트) 보존.
6. **(UX) 드래그 핸들 영역 변화** — header로 바꾸면 가로 전체가 드래그 영역(개선). X 버튼 추가 시 기존 X 없던 모달에 신규 등장.
7. **(기술) flexbox 미적용 모달** — `.modal.draggable`이 display:flex 강제. 화이트리스트 외 모달 표준화 시 flex 강제 안 됨 → footer flex-shrink 안 먹음. → 표준 모달은 인라인 display:flex column 함께 부여.

### 3-2. 현재 구현 충돌점
- 운영 드래그와 충돌 없음 — 오히려 정합 개선. 단 flex-shrink/flex 강제 누락은 CSS 보강.
- 저장/렌더 함수 충돌 없음 — id 보존 조건 하 확인 완료.
- 인플 공용 CSS 충돌 가능 — 스코프 한정으로 차단.

### 3-3. 의도 모호점 (사용자 확인)
- "통일" 범위: ①미분리 5개만 ②5개+footer CSS+분리형 인라인 footer 점진교체 ③36개 전면 재작성
- 표준 footer에 닫기 X 포함 여부 (미분리는 현재 X 없음)
- 읽기 전용 모달(footer 없는 것)도 통일 대상인지

---

## 4. 권고
**중간 범위(옵션 ②) 권고**: ①`.modal-footer` CSS 신설(관리자 스코프, flex-shrink:0 + 우정렬 + 좌측 보조 margin-right:auto) + `.modal.draggable .modal-footer{flex-shrink:0}` ②미분리 5개 표준 3분할 재구조화(id 보존) ③분리형 인라인 footer는 별 PR 점진 교체. 36개 전면 재작성은 읽기형·특수 모달 회귀 위험 대비 이득 작아 비권고.

---

## 5. 표준 구조 정의

### 5-1. HTML 패턴
```html
<div class="modal-overlay" id="xxxModal" style="z-index:NNN">
  <div class="modal" style="max-width:WWWpx;border-radius:20px;margin:auto;max-height:90vh;display:flex;flex-direction:column">
    <div class="modal-header">
      <div class="modal-title" id="xxxModalTitle">제목</div>
      <div class="modal-close" onclick="closeModal('xxxModal')">
        <span class="material-icons-round notranslate" translate="no" style="font-size:18px">close</span>
      </div>
    </div>
    <div class="modal-body"><!-- 폼 필드 (기존 id 전부 그대로) --></div>
    <div class="modal-footer">
      <span class="modal-footer-aux"><!-- 좌측 보조(상태 pill·삭제), 없으면 생략 --></span>
      <button class="btn btn-ghost" onclick="closeModal('xxxModal')">취소</button>
      <button class="btn btn-primary" onclick="saveXxx()">저장</button>
    </div>
  </div>
</div>
```

### 5-2. CSS 제안 (관리자 스코프 한정)
```css
#page-admin .modal-header{padding:18px 22px 12px;border-bottom:1px solid var(--line);display:flex;align-items:center;justify-content:space-between;flex-shrink:0}
#page-admin .modal-body{padding:20px 22px}
#page-admin .modal-footer{padding:14px 22px;border-top:1px solid var(--line);display:flex;gap:8px;align-items:center;justify-content:flex-end;flex-shrink:0}
#page-admin .modal-footer-aux{margin-right:auto}
.modal.draggable .modal-footer{flex-shrink:0}
```
폭(max-width)·border-radius는 모달마다 다르므로 인라인 유지. header/footer만 클래스 규칙.

### 5-3. 드래그 헬퍼 정합
- **헬퍼 코드 변경 없이 동작 개선**: header 생기면 `.modal-header` 우선 분기 탐. fallback(body 첫 요소)은 남겨두기 권장(비표준 안전망).
- `.modal-footer{flex-shrink:0}` 신설로 리사이즈 시 footer 고정.

---

## 6. 미분리 모달 재구조화 목록 + 영향 함수

| 모달 id | 작업 | 보존 필수 id | 영향 함수 |
|---|---|---|---|
| lookupEditModal | 제목→header/.modal-title, 하단 취소·저장→.modal-footer | lookupModalTitle, 폼필드 전부, lookupEditError | openLookupEditModal/saveLookupEdit (admin-lookups.js:170,187) |
| faqEditModal | 동일 | faqModalTitle, faqLabelKo 등, faqEditError | openFaqEditModal/saveFaqNode (admin-faq.js:254) |
| psetEditModal | 동일 | psetModalTitle, psetStepsWrap 등 | admin-lookups.js:376,389 |
| csetEditModal | 동일 | csetModalTitle, csetItemsWrap 등 | admin-lookups.js:549,562 |
| nsetEditModal | 동일 | nsetModalTitle 등 | admin-lookups.js:1098,1111 |
| campBundleModal | footer 이미 클래스 사용 — CSS 신설로 인라인 일부 제거(선택) | campBundleModalTitle | openCampBundleModal |

공통: 미리보기 토글·에러 메시지(xxxEditError)는 body에 남김. footer엔 취소·저장 버튼만.

---

## 7. PR 분할
- **PR 1 — `.modal-footer` CSS 신설 + 드래그 footer 정합** (admin.css `#page-admin` 스코프). 인플 `.modal-footer` 사용처 없음 grep 확인. 단독 머지 가능.
- **PR 2 — 미분리 5개 표준 3분할** (dev/admin/index.html). id 전부 보존. faqEditModal은 운영 미배포 → 운영 배포는 message-faq 동반(§8).
- **PR 3(후순위) — 분리형 인라인 footer 클래스 교체** (전수 재확정 후). 외관 동일·구조만 통일, 회귀 낮음.

각 PR: reviewer GO + build + dev 머지(Claude) → 운영은 사용자 확인.

---

## 8. 멀티 세션·머지 순서
- admin.js 핫스팟 아님. index.html(HTML) + admin.css(CSS) 중심, 헬퍼 미변경, admin-lookups/faq.js는 읽기만(id 보존).
- index.html은 message-faq·multichannel 등 보류 PR과 같은 파일 → worktree 분리 + 머지 순서 조율. faqEditModal은 message-faq와 충돌 가능 → message-faq 운영 배포 이후로 미루거나 통합.

## 9. qa 시나리오
1. 미분리 5개 추가 진입 → 제목 정확 표시(`$('xxxModalTitle')` 정상)
2. 편집 진입 → 기존 값 로드 + 제목
3. 저장 → 정상 + refreshPane
4. 드래그 → header 잡고 이동, 입력 클릭 시 드래그 안 됨
5. 세로 짧게 리사이즈 → footer 안 찌부러지고 고정
6. 세로 길게 → 제목 상단·버튼 하단 고정, 본문만 스크롤
7. 긴 폼(faq/cset) 스크롤 시 제목·버튼 항상 보임
8. 인플 앱 모달 외관 회귀 없음(스코프 한정)
9. campaign_manager 권한 가드 유지
10. confirm/alert/lightbox 등 제외 대상 회귀 없음

## 10. 약관·법률 영향
없음 (순수 UI 구조).

## 11. 구현 결과 (개발 세션이 채울 것)
```
구현일:
관련 커밋/PR:
초안 대비 변경:
구현 중 기술 결정:
```
