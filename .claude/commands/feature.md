새 기능 구현 (인플루언서 앱):

1. **이해**: 기능 요청 분석 — $ARGUMENTS
2. **파일 식별**: 수정 대상 파일 결정
   - UI 로직: dev/js/ (campaign.js, application.js, auth.js, mypage.js, app.js)
   - 공통 UI: dev/js/ui.js (showToast, showModal, formatDate 등)
   - DB 함수: dev/lib/storage.js (fetchXxx, insertXxx, updateXxx)
   - 전역 상태: dev/lib/shared.js
   - 스타일: dev/css/ (campaign.css, auth.css, mypage.css, components.css)
   - HTML 구조: dev/index.html (페이지 추가/수정)
3. **DB 확인**: Supabase 스키마 변경 필요 시
   - supabase/migrations/에 새 마이그레이션 파일 생성
   - RLS 정책 포함
4. **구현**: 프로젝트 규칙 준수
   - UI 텍스트: 일본어, 코드 주석: 일본어
   - 모바일 레이아웃 (480px, #appShell 내부)
   - db?.from() null-safe 접근
   - .maybeSingle() 사용
   - 에러 처리: showToast()로 사용자 알림
5. **빌드**: `cd dev && bash build.sh` 실행
6. **요약**: 추가된 내용, 수정된 파일 목록
