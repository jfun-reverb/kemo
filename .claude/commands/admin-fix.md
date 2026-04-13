버그 수정 (관리자 앱):

1. **이해**: 버그 설명 분석 — $ARGUMENTS
2. **파일 탐색**: 관리자 앱 관련 파일
   - 관리자 로직: dev/js/admin.js (대부분의 관리자 기능)
   - 앱 초기화/라우팅: dev/admin/app.js
   - 공통 UI: dev/js/ui.js
   - DB 함수: dev/lib/storage.js
   - 관리자 스타일: dev/css/admin.css
   - HTML 구조: dev/admin/index.html
3. **원인 분석**:
   - 흔한 실수: 모바일 쉘 CSS 혼입, db null 체크 누락, 권한 체크 누락
   - 관리자 페인 전환: 사이드바 네비게이션 동작 확인
   - KPI 데이터 로딩: 비동기 처리 확인
4. **수정**: 최소한의 변경으로 버그 수정
   - PC 레이아웃 유지 확인
   - db?.from() null-safe 패턴 확인
5. **빌드**: `cd dev && bash build.sh` 실행
6. **요약**: 원인, 수정 내용, 수정된 파일:줄번호
