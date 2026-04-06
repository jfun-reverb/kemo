# REVERB JP — 인플루언서 체험단 플랫폼

## Overview
일본 시장 대상 인플루언서 체험단(모니터/기프팅) 모집 플랫폼.
브랜드가 캠페인을 등록하고, 인플루언서가 신청하는 구조.

## Tech Stack
- Language: HTML/CSS/JavaScript
- Backend: Supabase (BaaS) + localStorage 폴백
- Deployment: Vercel (이전: Netlify)
- Package Manager: 없음 (CDN 기반)

## Key URLs
- GitHub: github.com/jfun-reverb/kemo
- Supabase: https://twofagomeizrtkwlhsuv.supabase.co
- Admin: admin@kemo.jp / admin1234
- LINE: @586mnjoc

## Architecture
- 배포용: 루트 index.html (단일 파일, ~3300줄)
- 개발용: dev/ 폴더 (CSS/JS/HTML 분리)
  - dev/css/ — base, components, campaign, auth, mypage, admin
  - dev/js/ — app, ui, campaign, application, auth, mypage, admin
  - dev/lib/ — supabase, storage
  - dev/build.sh — dev/ → 루트 index.html 빌드
- 모바일 앱쉘: max-width 480px, 바텀탭바
- 관리자 페이지: appShell 밖, PC 전체폭
- Supabase 미연결 시 localStorage로 동작 (DEMO_MODE)

## Dev Workflow
- 개발: dev/ 폴더에서 수정 → 브라우저에서 dev/index.html 열어서 확인
- 배포: `cd dev && bash build.sh` → 루트 index.html 자동 업데이트
- 수정할 파일 찾기: 파일명이 기능과 일치 (캠페인=campaign, 로그인=auth 등)

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
