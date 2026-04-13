새 기능 구현 (관리자 앱):

1. **이해**: 기능 요청 분석 — $ARGUMENTS
2. **파일 식별**: 관리자 앱 수정 대상
   - JS 로직: dev/js/admin.js (48K, 캠페인/인플루언서/신청/관리자계정 관리)
   - 앱 초기화: dev/admin/app.js (라우팅, 사이드바 네비게이션)
   - 공통 UI: dev/js/ui.js (showToast, showModal 등 — 인플루언서 앱과 공유)
   - DB 함수: dev/lib/storage.js (인플루언서 앱과 공유)
   - 스타일: dev/css/admin.css (관리자 전용), dev/css/components.css (공용)
   - HTML: dev/admin/index.html (관리자 페이지 구조)
3. **레이아웃 확인**:
   - 반드시 PC 전체폭 레이아웃 (모바일 쉘/바텀탭 절대 금지)
   - 사이드바 + 메인 콘텐츠 구조 유지
   - 새 페인 추가 시: #pane-xxx 형태, 사이드바에 네비게이션 항목 추가
4. **권한 확인**:
   - super_admin 전용 기능인지, campaign_admin도 접근 가능한지 확인
   - 권한 체크: admins 테이블 role 컬럼 기반
5. **구현**: 프로젝트 규칙 준수
   - UI 텍스트: 일본어
   - db?.from() null-safe 접근
   - .maybeSingle() 사용
6. **빌드**: `cd dev && bash build.sh` (admin/index.html도 함께 빌드됨)
7. **요약**: 추가된 내용, 수정된 파일 목록
