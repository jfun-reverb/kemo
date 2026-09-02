---
description: UI 레이아웃 및 일본어 규칙
paths:
  - "dev/**/*.html"
  - "dev/css/**"
  - "dev/js/**"
---

# UI/레이아웃 규칙

## 디자인 스킬 사용 (프론트 화면 추가/수정 시)
- `dev/` 폴더의 화면 파일(`.html`/`.css`)을 만지면, 세션 첫 1회 `frontend-skill-reminder.js` 후크가 디자인 스킬 사용을 상기시킨다 (`.claude/settings.json` PreToolUse — **Write|Edit 과 Bash 양쪽** 등록).
  - ⚠️ **파일을 Bash(heredoc·python)로 써도 뜬다**(2026-08-25 추가). 그전에는 `Write`/`Edit` 도구에만 걸려 있어, Bash 로 파일을 쓰는 세션에서는 **이 후크가 한 번도 안 돌았다.**
  - Write/Edit 경로는 잠깐 멈추고(1회), **Bash 경로는 안 멈추고 알림만** 띄운다 — 명령문 판정은 오탐이 날 수 있어 애먼 명령을 막지 않기 위해서다.
- **새 화면을 처음 만들 때** → `Skill("example-skills:frontend-design")` ⚠️ **`document-skills:frontend-design` 이 아니다** — 그 이름은 실재하지 않아(그 플러그인 아래는 엑셀·워드·발표자료·PDF 넷뿐) **부르면 실패한다.** 2026-06-01~09-02 약 3개월간 그 틀린 이름이 적혀 있었고 아무도 눌러 보지 않았다.
- **기존 화면을 고치거나 다듬을 때** → `Skill("ui-ux-pro-max")` (review/improve 관점 우선)
- 🔴 **인플루언서 화면에서는 이 두 스킬보다 아래 「Apple 디자인 지침」 절이 앞선다.** 그 스킬들은 67가지 스타일(글래스모피즘·브루탈리즘 등)·96가지 색 조합을 제안하는 **범용 도구**라, 제약 없이 부르면 세션마다 방향이 갈린다 — **스킬은 「어떻게 만들지」를 돕고, 방향은 Apple 기준이 정한다.** 관리자 화면은 이 제약 없음(아래 참조).
- 기존 컨벤션(모바일 480px·Material Icons·i18n·CSS 변수)을 깨지 않는 선에서 적용. 단순 로직/문구 변경이면 스킬 없이 진행 가능.

## Apple 디자인 지침(HIG) 우선 — 인플루언서 앱 (영구, 2026-05-29 사용자 지시)

> ⚠️ **이 규칙은 2026-06-01 에 쓰였으나 원격에 한 번도 올라가지 않아 3개월간 아무도 못 봤다**(로컬 브랜치 `feature/deliv-filter-redesign` 커밋 `249252c3`, 병합 요청·검토 0건). 2026-09-02 에 복원하며 낡은 부분 셋을 손질했다 — 아래 ⚠️ 표시.

- **인플루언서 모바일 앱**(`dev/index.html`, 480px)은 **Apple 디자인 지침(Human Interface Guidelines)을 최우선 디자인 기준**으로 한다.
- **이유**: 일본 유저 대부분이 아이폰. 🔴 **하이브리드앱(웹뷰 래핑)이 그때는 계획이었으나 지금은 실재한다** — `feature/ios-app`, 2026-08-21 사용자 아이폰 실기기 설치 완료. **쓰였을 때보다 지금 더 유효하다.** (당초 Google Material 제안을 사용자가 Apple 로 정정)
- **적용 범위**(2026-09-02 사용자 결정): 새 화면·크게 고치는 화면은 물론 **기존 화면도 순차적으로 다시 그린다.** ⚠️ 다만 그 순차 재작업은 **화면 재설계**라 [`session-roles.md`](session-roles.md) §3 상 **기획 세션이 사양서로** 만든다 — 개발 세션이 지나가는 길에 임의로 바꾸지 않는다. 한 화면 안에 옛 방식·새 방식이 섞이면 통일 전보다 더 지저분해 보인다(**적용 단위 = 화면 통째**).
- 🔴 **관리자(PC)는 적용 대상 아님** — 모바일 기준이라 PC 대시보드에 안 맞는다. 관리자 화면의 현재 기준은 **흑백(monochrome) 재설계 + 보라 강조색**(2026-06~07 적용, `95fab100` → `1e5bdf2b`).
  - ⚠️ **옛 `docs/specs/2026-05-29-design-system-md3.md`(구글 머티리얼 3 기준)를 관리자 기준으로 삼지 말 것.** 그 사양서는 ①**한 번도 구현되지 않았고**(제안한 간격 토큰·폰트 토큰·관리자 버튼 `.abtn` 전부 **0건**, 2026-09-02 실측) ②**전제가 뒤집혔다** — 「색 토큰은 이미 머티리얼이라 재정의 금지」라 적었는데 그 뒤 색이 통째로 바뀌었다. 그 문서는 `dev` 에 아예 없다(복원 보류 결정).
- **적용 시 따를 것 (iOS)**:
  - 타입: 시스템 폰트(`-apple-system, system-ui` → 아이폰에서 SF Pro 자동). iOS 타입 스케일(본문 17px, Headline 17 bold, Subhead 15, Footnote 13, Caption 11~12, Large Title 34 등)
  - 표면: 평평하게 — 머티리얼식 elevation 그림자 대신 얇은 구분선·은은한 그림자·블러(vibrancy)
  - 모서리: iOS continuous corner 느낌, 카드 약 10~14px
  - 컨트롤: iOS 스타일 버튼·토글 스위치·세그먼트, **최소 터치 타깃 44×44pt**, 하단 시트·스와이프 등 iOS 관습
- **하드 제약 (반드시 인지)**:
  - **SF Symbols 아이콘은 웹/하이브리드(WKWebView)에 라이선스상 사용 불가** → Material Icons 유지하거나 SF 유사 오픈 아이콘셋. (아이콘 세트 결정은 별도)
  - 하이브리드는 네이티브 SwiftUI 가 아니라 **웹뷰 래핑**이므로, 네이티브 컴포넌트가 아니라 **CSS 로 iOS 룩앤필을 재현**한다.
- **사양이 모호하면 `Skill("apple-design")`** — Apple 의 인터페이스·모션 접근법을 웹으로 옮긴 스킬(제스처·스프링 애니메이션·재질과 깊이·타이포그래피·동작 줄이기). ⚠️ 원래 규칙은 「`developer.apple.com/design` 을 직접 받아 확인」이었는데 **그 뒤 이 스킬이 생겼다** — 스킬을 먼저 부르고, 그래도 모자라면 그때 웹을 본다.
- 접근성(WCAG AA) 동시 준수.

## 레이아웃 분리 (절대 혼동 금지)
- **인플루언서 페이지** (dev/index.html): 모바일 전용 max-width 480px, #appShell 내부, GNB + 우측 슬라이드 햄버거 메뉴
- **관리자 페이지** (dev/admin/index.html): PC 전체폭, #appShell 밖, 사이드바 네비게이션
- 관리자 페이지에 모바일 쉘 절대 적용 금지
- 인플루언서 페이지에 PC 전체폭 레이아웃 절대 적용 금지
- 바텀탭은 제거됨 (2026-04 햄버거 메뉴로 대체, 키보드 간섭 제거 목적)

## 인플루언서 앱 구조
- SPA 라우팅: `navigate()` 함수로 페이지 전환 (dev/js/app.js)
- 페이지: #page-home, #page-campaigns, #page-legal, #page-detail, #page-activity, #page-login, #page-forgot, #page-reset-pw, #page-signup, #page-mypage
- GNB: 상단 네비게이션 (로그인/회원가입 버튼 + 우측 햄버거 ☰)
- 햄버거 메뉴 패널(#navPanel, 렌더: `renderNavMenu()` in dev/js/notifications.js)
  - 헤더: Admin 버튼(관리자만) + 언어 토글(日本語/한국어) + 닫기
  - 로그인 시: 계정 카드(이름·핸들·이메일 + 우측 알림 벨 아이콘·미읽음 배지, 아바타 없음) / 홈 / 캠페인 / 「마이페이지」 접기·펼치기 아코디언(기본 펼침, `toggleMypageAccordion`, 서브 7종 응모이력·기본정보·SNS·배송지·PayPal·비밀번호·메일수신설정 각 `min-height:48px` + 미입력 항목 「未登録」 배지) / 로그아웃 / 회원탈퇴(작은 링크, `margin-top` 간격). 메시지 메뉴 항목은 제거(응모이력과 목적지 중복 — 응모건 카드 메시지 버튼으로 진입). 알림은 별도 항목이 아니라 계정 카드 우측 벨로 통합. 폼 화면에는 백버튼 없음(햄버거/브라우저 뒤로가기). 마이페이지 랜딩 화면 제거로 햄버거가 목차 역할 (2026-05-22)
  - 비로그인 시: 홈 / 캠페인 / 로그인 / 회원가입
  - flex 레이아웃 주의: `.nav-menu>*{flex-shrink:0}` 필수 — 메뉴가 길 때 1px 구분선·항목이 0px로 찌부러지는 것 방지(넘치면 nav-menu 스크롤). 아코디언 펼침 높이는 `.nav-accordion.open{max-height}`

## 관리자 앱 구조
- 2단 고정 레이아웃: 좌측 사이드바 + 우측 메인 (각각 독립 스크롤, 상단 GNB 없음)
- 사이드바 상단: Reverb 로고 + 접기 토글
- 사이드바 메뉴 영역(스크롤 가능, 단일 영역) — **항목 목록은 `dev/admin/index.html` 의 `data-pane` 속성이 단일 소스다.** 여기에 베껴 적지 않는다(2026-08 기준 20개이고 계속 늘어난다. 실제로 이 문서는 정산·오류 로그·자주 묻는 질문·메시지·오리엔시트·회사 관리·오픈 예정 항목이 빠진 채 오래 남아 있었다).
- 구조 규칙만 기억한다: 공지 → 대시보드 → 업무 그룹들 → 관리자 설정 → **접속자 프로필**(`#sidebarAdminProfile` → my-account) → 인플루언서 화면 → 로그아웃. 인플루언서 화면·로그아웃 두 항목은 2026-05-07 이후 별도 고정 푸터가 아니라 스크롤 영역에 포함된다.
- 항목 노출은 등급별 권한(`menu.*`)에 따라 달라지므로, 「이 항목이 있다/없다」를 문서로 단정하지 않는다.
- 관리자 페인: #adminPane-dashboard, #adminPane-campaigns 등 (add-campaign/edit-campaign은 서브 페인)
- **목록 페인**: `admin-pane-list` 클래스를 붙인다. flex column 구조로 제목+필터 고정, 카드 헤더 고정, thead sticky, tbody만 스크롤. **어느 페인이 목록 페인인지는 `dev/admin/index.html` 에서 그 클래스가 붙은 페인이 단일 소스다**(2026-08 기준 17개이고 계속 는다 — 여기에 나열하지 않는다).
- **목록 페인 HTML 구조 통일 필수**: 구조(admin-sticky-header → admin-card → admin-card-header → admin-table-wrap → table)가 **모든 목록 페인에서 동일**해야 한다. 래퍼 div 를 추가·제거하면 `admin-pane-list` 가 붙은 페인을 전부 확인한다:
  ```bash
  grep -o 'id="adminPane-[a-z-]*"[^>]*admin-pane-list' dev/admin/index.html
  ```
- 대시보드(adminPane-dashboard)와 상세/폼 페인(add-campaign/edit-campaign/influencer-detail/my-account)은 목록이 아니므로 admin-pane-list 미적용 — 자연 스크롤
- **필터 줄 컨트롤은 전용 클래스만 사용 (높이 32px 고정)**: 드롭다운·날짜/텍스트 입력 = `admin-filter`, 돋보기 아이콘 붙은 검색칸 = `admin-filter-search`, 다중 선택 버튼 = `mf-btn`, 감싸는 줄 = `admin-filter-bar` + 항목마다 `admin-filter-group`. **폼 화면용 `form-input` 에 인라인 padding·height 를 붙여 필터를 만들지 말 것** — 화면마다 자연 높이가 달라져 28·31·38px 로 어긋난다(2026-07-24 전수 정정, 운영 배포 완료). 새 필터를 만들 땐 옆 화면과 렌더 높이가 같은지 확인

## UI 텍스트 언어 규칙
- 인플루언서 페이지: 일본어 (한국어/영어 금지)
- 관리자 페이지: 한국어 (일본어/영어 금지)
- 코드 주석: 한국어 (일본어 금지)
- HTML lang="ja" 유지
- 날짜 포맷: `ja-JP` 로케일 사용
- 상태 표시 예시: 募集中(active), 準備中(draft), 近日公開(scheduled), 締切(closed)

## 인플루언서 안내 문구 (쉬운 말 + 번호 단계, 영구)
- 인플루언서는 시스템·개발 이해도가 매우 낮다고 전제 (2026-05-21 사용자 명시)
- 자동응답(FAQ)·앱 안내·인플루언서 대상 메일 문구는 **초등학생 눈높이**로: 전문용어·영어 약어 금지, 부득이하면 동작으로 풀이(「URL」→「リンク（URL）」)
- 처리 방향은 **번호 단계(1·2·3)**로 끊어서. 한 문장 = 한 동작. 누르는 버튼 이름은 「」로 정확히
- 마지막은 안전망(「直接お問い合わせ」)으로 닫기 (handoff 항목 제외)
- 한국어·일본어 문안은 의미·단계 수 동일
- 작성 템플릿·예시: 사양서 `docs/specs/2026-05-21-message-faq.md` §7 + 답변 문서 `docs/research/2026-05-21-message-faq-answers.md`
- (관리자 공지의 쉬운 한국어 규칙과 짝 — 그쪽은 관리자, 이쪽은 인플루언서)

## 아이콘 규칙
- 이모지 사용 금지 — OS별로 다르게 보이므로 Material Icons Round 사용
- 아이콘에는 반드시 `translate="no"` + `notranslate` 클래스 추가 (브라우저 번역 시 깨짐 방지)
- 예시: `<span class="material-icons-round notranslate" translate="no">icon_name</span>`
- 토스트 메시지에 이모지/아이콘 넣지 않기 (텍스트만)
- DB에 저장된 emoji 필드(캠페인 카테고리 등)는 예외로 허용

## CSS 파일 대응
- 공통 스타일: dev/css/base.css (변수, 리셋), dev/css/components.css (버튼, 카드, 모달)
- 기능별 스타일: campaign.css, auth.css, mypage.css
- 관리자 전용: dev/css/admin.css
- 새 CSS 추가 시 build.sh에 파일 등록 필요
