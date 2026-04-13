구현 계획 수립:

1. **이해** — 요청 분석 및 요구사항 파악: $ARGUMENTS
2. **조사** — 관련 코드 읽기
   - 인플루언서 앱: dev/js/, dev/css/, dev/index.html
   - 관리자 앱: dev/js/admin.js, dev/css/admin.css, dev/admin/index.html
   - DB 함수: dev/lib/storage.js
   - DB 스키마: supabase/migrations/
3. **설계** — 접근 방식 제안:
   - 수정할 파일 목록 (dev/ 경로)
   - UI 변경: 일본어 텍스트, 레이아웃 (인플루언서=480px 모바일, 관리자=PC 전체폭)
   - DB 변경: 테이블/컬럼 추가 필요 여부, RLS 정책
   - localStorage 폴백 처리 필요 여부
   - build.sh 수정 필요 여부 (새 파일 추가 시)
4. **단계** — 순서가 있는 하위 작업으로 분류
5. **확인** — 계획을 제시하고 승인 대기 (구현 시작 전)
