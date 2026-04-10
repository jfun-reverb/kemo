# REVERB JP — 인플루언서 체험단 플랫폼

## Overview
일본 시장 대상 인플루언서 체험단(모니터/기프팅) 모집 플랫폼.
브랜드가 캠페인을 등록하고, 인플루언서가 신청하는 구조.

## Tech Stack
- Language: HTML/CSS/JavaScript (vanilla, 프레임워크 없음)
- Backend: Supabase (Auth + Database + Storage) + localStorage 폴백
- Deployment: Vercel (이전: Netlify)
- Package Manager: 없음 (CDN 기반)

## Key URLs
- GitHub: github.com/jfun-reverb/kemo
- Supabase: https://twofagomeizrtkwlhsuv.supabase.co
- Admin: admin@kemo.jp / admin1234
- LINE: @586mnjoc

## Architecture
- 인플루언서 앱: dev/index.html (모바일 480px, 바텀탭바)
- 관리자 앱: dev/admin/index.html (PC 전체폭, 별도 페이지)
- 배포용: 루트 index.html (build.sh로 생성)
- 개발 폴더 구조:
  - dev/js/ — app, ui, campaign, application, auth, mypage, admin
  - dev/css/ — base, components, campaign, auth, mypage, admin
  - dev/lib/ — supabase(설정), shared(전역변수), storage(DB/Storage API)
  - dev/build.sh — dev/ → 루트 index.html 빌드
- Supabase 미연결 시 localStorage로 동작 (DEMO_MODE)

## Features — 인플루언서 (모바일)
- 회원가입: 1단계 폼 (이름 한자/가나 + 이메일 + 비밀번호), 추가정보는 마이페이지에서 입력
- 로그인/로그아웃: 이메일+비밀번호, 세션 복원, 관리자 로그인 시 admin 페이지 자동 오픈
- 비밀번호 재설정: 이메일 입력 → Supabase 재설정 메일 발송 → 앱 내 새 비밀번호 설정 (#page-forgot, #page-reset-pw)
- GNB: 비로그인 시 Log In/Sign Up 버튼, 로그인 시 버튼 없음 (Admin만 관리자용), 마이페이지/로그아웃은 바텀탭에서 접근
- 캠페인 목록: 채널필터(동적 생성), 모집유형 필터(모니터/기프팅)
- 캠페인 목록 노출: active + scheduled + closed(게시기한 남은 경우, 募集締切 오버레이)
- 캠페인 상세: 이미지 캐러셀(최대9장), 상품정보, 모집조건, 참가방법(3단계), 가이드라인, NG사항, LINE/Instagram CTA, 조회수 자동 카운트, closed 시 신청버튼 비활성(募集締切)
- 캠페인 신청: 이메일 인증 필수, 필수정보 사전체크(채널별 SNS/주소/전화/은행) → 동기메시지 + 배송지 + PR태그 동의, 중복신청 방지
- 회원가입 이메일 확인: Supabase Confirm sign-up 활성화, 가입 후 확인 메일 안내 화면 표시, 미확인 시 로그인/신청 차단
- 마이페이지: 리스트 → 상세 페이지 네비게이션 (탭 방식 아님), 메뉴: 応募履歴/基本情報/SNSアカウント/配送先/振込口座/パスワード変更/ログアウト, 대표SNS 선택 가능
- 활동관리: 승인된 캠페인에서 구매 영수증 등록 (이미지+구매일+금액), receipts 테이블에 저장
- 응모이력: 상태별 탭 필터(전체/심사중/승인/비승인), 승인 캠페인 클릭→활동관리, 기타→캠페인 상세
- 바텀탭: 홈 / キャンペーン / マイページ

## Features — 관리자 (PC)
- 사이드바: Material Icons, 접기/펼치기 토글 (햄버거 버튼), data-pane 속성 기반 라우팅, 신규등록 메뉴 제거, pending 배지 항상 표시
- 페이지 새로고침: visibility:hidden cloak 기법 (깜빡임 완전 방지), 서브패널 새로고침 시 부모 패널로 리다이렉트
- 대시보드: KPI 카드(캠페인수/인플루언서수/신청수/승인수), 회원가입 추이 차트(Chart.js, 7일/30일/전체 필터), 오늘/이번주 가입 KPI, 프로필 완성률(SNS별/배송지/계좌), 최근 신청 테이블
- 로딩 UX: 테이블/대시보드 KPI/차트 영역에 인라인 스피너 (전체화면 오버레이 제거)
- 캠페인 관리: CRUD + 복제 + 삭제(확인모달) + 순서변경 모드(버튼 토글)
- 캠페인 목록: 썸네일+이미지수 표시, 상태/타입 드롭다운 필터, 검색(캠페인명+브랜드), 헤더 정렬(조회/신청/등록일/수정일 ▲▼), D-day 라벨(게시마감/모집마감), 타입 라벨 통일([타입] 제목 형식)
- 캠페인 미리보기: 캠페인 제목 클릭 시 모바일 크기 프리뷰 모달 (편집 버튼 포함)
- 캠페인 상태: draft(준비) → scheduled(모집예정) → active(모집중) → paused(일시정지) → closed(종료), 드롭다운으로 변경
- 캠페인 자동 종료: deadline 경과 시 active → closed 자동 변경 (클라이언트 체크)
- 마감일 검증: post_deadline >= deadline 필수, 인라인 경고 + 저장 차단
- 마감일 경과 active/scheduled 차단: deadline 지난 캠페인은 모집중/모집예정 상태로 저장/변경 불가 (편집, 드롭다운 모두)
- 모집인원 초과 승인 차단: 승인 수가 slots에 도달하면 알럿 모달로 차단
- 조회수: campaigns.view_count 컬럼, 캠페인 상세 열 때 +1, 관리자 목록에 표시
- 이미지 관리: 드래그앤드롭 업로드, 크롭, 미리보기, Supabase Storage 저장
- 신청 관리: 테이블 UI (캠페인 썸네일, 타입/상태/검색 필터, 상태 정렬), 인플루언서 상세 모달
- 신청 처리: reviewed_by, reviewed_at 기록, 되돌리기(pending 복귀) 기능
- 에러 처리: friendlyError() 한국어 에러 메시지 + 에러 코드 표시
- 상태 뱃지: getStatusBadgeKo() 한국어 상태 표시
- 인플루언서 관리: 채널별 필터, 상세 프로필 조회
- 관리자 계정: 3단계 권한 (super_admin > campaign_admin > campaign_manager), create_admin으로 기존 인플루언서 계정도 관리자 추가 가능
- 내 계정: 이름/비밀번호 변경

## Database Schema (Supabase)
- `campaigns` — 캠페인 정보 (title, brand, product, type, channel, category, reward, slots, status, view_count, img1~img8 등)
- `influencers` — 인플루언서 프로필 (name, SNS계정+팔로워, 주소, 은행정보 등)
- `applications` — 캠페인 신청 (user_id, campaign_id, message, address, status, reviewed_by, reviewed_at)
- `admins` — 관리자 계정 (auth_id, email, name, role)
- `receipts` — 구매 영수증 (application_id, user_id, campaign_id, receipt_url, purchase_date, purchase_amount)
- RLS 정책: 캠페인 SELECT 공개, 나머지는 본인 데이터 or 관리자만 접근
- `is_admin()` 함수: admins 테이블에서 auth.uid() 조회 (JWT email 하드코딩 아님)
- 트리거: auth.users 생성 시 influencers 레코드 자동 생성
- 세션 만료 대응: retryWithRefresh()로 RLS/JWT 에러 시 세션 갱신 후 1회 재시도

## Test Accounts
- 관리자: admin@kemo.jp / admin1234
- 테스트 인플루언서: sakura.test@reverb.jp, yui.test@reverb.jp, haruka.test@reverb.jp (비밀번호: test1234)

## Dev Workflow
- 개발: dev/ 폴더에서 수정 → 브라우저에서 dev/index.html 열어서 확인
- 배포: `cd dev && bash build.sh` → 루트 index.html 자동 업데이트
- 수정할 파일 찾기: 파일명이 기능과 일치 (캠페인=campaign, 로그인=auth 등)
- DB API: dev/lib/storage.js에 모든 DB 함수 집중 (fetchCampaigns, upsertInfluencer 등)
- 세션 관리: onAuthStateChange로 SIGNED_IN/TOKEN_REFRESHED/SIGNED_OUT/SESSION_EXPIRED 처리 (인플루언서+관리자 양쪽)
- URL 정제: cleanUrl()로 마크다운 링크 형식 자동 변환 (product_url 등)

## Conventions
- 인플루언서 페이지 UI 텍스트: 일본어
- 관리자 페이지 UI 텍스트: 한국어
- 코드 주석: 한국어 (일본어 금지)
- 날짜 포맷: ja-JP
- lang="ja"

## Rules
- 관리자 페이지는 반드시 PC 레이아웃 유지 (모바일 쉘 적용 금지)
- 인플루언서 페이지만 모바일 전용 (480px)
- db 참조 시 항상 db?.from() 사용 (null-safe)
- .single() 대신 .maybeSingle() 사용
- localStorage 저장 시 이미지 base64는 별도 키로 분리 (용량 초과 방지)
- 캠페인 삭제 시 관련 applications도 함께 삭제 (cascading)
- 이미지 업로드는 Supabase Storage (campaign-images 버킷) 사용
- 비밀번호 재설정 시 Supabase Redirect URL 설정 필수: Authentication → URL Configuration → Redirect URLs에 https://kemo-liart.vercel.app 등록
- 아이콘은 Material Icons 사용 (이모지 사용 금지), translate="no" 속성 필수
- 하드코딩 DOM 인덱스 금지 (querySelector 등에서 :nth-child 인덱스 직접 사용 금지)

## Mobile Layout Rules
- #appShell은 position:fixed + top:0/bottom:0 (body 스크롤 차단, 뷰포트 고정)
- html,body에 height:100% + overflow:hidden 유지
- 페이지 콘텐츠 스크롤은 .page.active 내부에서만 (flex:1 + overflow-y:auto)
- GNB/바텀탭은 flex-shrink:0으로 고정, 페이지가 나머지 공간 차지
- 모바일 키보드 대응: visualViewport API로 appShell 높이 동적 조절
- input/textarea/select의 font-size는 반드시 16px 이상 (모바일 자동 확대 방지)
- 100vh/100dvh 대신 position:fixed + top:0/bottom:0 사용 (키보드 열림/닫힘 안정성)
- 캠페인 상세 URL은 #detail-{id} 형식 (새로고침 시 복원 가능)
