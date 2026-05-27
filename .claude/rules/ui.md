---
description: UI 레이아웃 및 일본어 규칙
globs: "dev/**/*.html,dev/css/*.css,dev/js/*.js"
---

# UI/레이아웃 규칙

## 디자인 스킬 사용 (프론트 화면 추가/수정 시)
- `dev/` 폴더의 화면 파일(`.html`/`.css`)을 만지면, 세션 첫 1회 `frontend-skill-reminder.js` 후크가 잠깐 멈춰 디자인 스킬 사용을 상기시킨다 (`.claude/settings.json` PreToolUse Write|Edit 등록).
- **새 화면을 처음 만들 때** → `Skill("document-skills:frontend-design")`
- **기존 화면을 고치거나 다듬을 때** → `Skill("ui-ux-pro-max")` (review/improve 관점 우선)
- 기존 컨벤션(모바일 480px·Material Icons·i18n·CSS 변수)을 깨지 않는 선에서 적용. 단순 로직/문구 변경이면 스킬 없이 진행 가능.

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
- 사이드바 메뉴 영역(스크롤 가능, 단일 영역): 공지사항 → 대시보드 → 캠페인(관리/신청/결과물) → 브랜드 서베이(현황/브랜드 관리/신청 목록) → 회원관리(인플루언서) → 관리자설정(기준데이터[super_admin 한정]/관리자계정) → 접속자 프로필(#sidebarAdminProfile → my-account) → 인플루언서 화면 → 로그아웃 (이전에 별도 고정 푸터로 분리되어 있던 인플루언서 화면/로그아웃 두 항목은 2026-05-07 이후 스크롤 영역에 포함)
- 관리자 페인: #adminPane-dashboard, #adminPane-campaigns 등 (add-campaign/edit-campaign은 서브 페인)
- **목록 페인 (campaigns/applications/deliverables/camp-applicants/influencers/lookups/admin-accounts)**: `admin-pane-list` 클래스 사용. flex column 구조로 제목+필터 고정, 카드 헤더 고정, thead sticky, tbody만 스크롤
- **목록 페인 HTML 구조 통일 필수**: 7개 페인의 HTML 구조(admin-sticky-header → admin-card → admin-card-header → admin-table-wrap → table)가 반드시 동일해야 함. 래퍼 div 추가/제거 시 7개 모두 확인
- 대시보드(adminPane-dashboard)와 상세/폼 페인(add-campaign/edit-campaign/influencer-detail/my-account)은 목록이 아니므로 admin-pane-list 미적용 — 자연 스크롤

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
