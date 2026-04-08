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
- 캠페인 목록: 채널필터(동적 생성), 모집유형 필터(모니터/기프팅)
- 캠페인 상세: 이미지 캐러셀(최대9장), 상품정보, 모집조건, 참가방법(3단계), 가이드라인, NG사항, LINE/Instagram CTA
- 캠페인 신청: 필수정보 사전체크(채널별 SNS/주소/전화/은행) → 동기메시지 + 배송지 + PR태그 동의, 중복신청 방지
- 마이페이지: 프로필 편집(기본/SNS/주소/전화/은행), 신청내역 확인, 비밀번호 변경
- 바텀탭: 홈 / キャンペーン / マイページ

## Features — 관리자 (PC)
- 대시보드: KPI 카드(캠페인수/인플루언서수/신청수/승인수), 최근 신청 테이블
- 캠페인 관리: CRUD + 복제 + 삭제(확인모달) + 순서변경(order_index)
- 캠페인 상태: draft(準備) → scheduled(近日公開) → active(募集中) → paused(一時停止) → closed(마감)
- 이미지 관리: 드래그앤드롭 업로드, 크롭, 미리보기, Supabase Storage 저장
- 신청 관리: 캠페인별 신청자 목록, 승인/거절 처리
- 인플루언서 관리: 채널별 필터, 상세 프로필 조회
- 관리자 계정: 3단계 권한 (super_admin > campaign_admin > campaign_manager)
- 내 계정: 이름/비밀번호 변경

## Database Schema (Supabase)
- `campaigns` — 캠페인 정보 (title, brand, product, type, channel, category, reward, slots, status, img1~img8 등)
- `influencers` — 인플루언서 프로필 (name, SNS계정+팔로워, 주소, 은행정보 등)
- `applications` — 캠페인 신청 (user_id, campaign_id, message, address, status)
- `admins` — 관리자 계정 (auth_id, email, name, role)
- RLS 정책: 캠페인 SELECT 공개, 나머지는 본인 데이터 or 관리자만 접근
- 트리거: auth.users 생성 시 influencers 레코드 자동 생성

## Test Accounts
- 관리자: admin@kemo.jp / admin1234
- 테스트 인플루언서: sakura.test@reverb.jp, yui.test@reverb.jp, haruka.test@reverb.jp (비밀번호: test1234)

## Dev Workflow
- 개발: dev/ 폴더에서 수정 → 브라우저에서 dev/index.html 열어서 확인
- 배포: `cd dev && bash build.sh` → 루트 index.html 자동 업데이트
- 수정할 파일 찾기: 파일명이 기능과 일치 (캠페인=campaign, 로그인=auth 등)
- DB API: dev/lib/storage.js에 모든 DB 함수 집중 (fetchCampaigns, upsertInfluencer 등)

## Conventions
- UI 텍스트: 일본어
- 코드 주석: 일본어 (한국어 금지)
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

## Mobile Layout Rules
- #appShell은 position:fixed + top:0/bottom:0 (body 스크롤 차단, 뷰포트 고정)
- html,body에 height:100% + overflow:hidden 유지
- 페이지 콘텐츠 스크롤은 .page.active 내부에서만 (flex:1 + overflow-y:auto)
- GNB/바텀탭은 flex-shrink:0으로 고정, 페이지가 나머지 공간 차지
- 모바일 키보드 대응: visualViewport API로 appShell 높이 동적 조절
- input/textarea/select의 font-size는 반드시 16px 이상 (모바일 자동 확대 방지)
- 100vh/100dvh 대신 position:fixed + top:0/bottom:0 사용 (키보드 열림/닫힘 안정성)
- 캠페인 상세 URL은 #detail-{id} 형식 (새로고침 시 복원 가능)
