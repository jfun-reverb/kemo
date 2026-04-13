버그 수정 (인플루언서 앱):

1. **이해**: 버그 설명 분석 — $ARGUMENTS
2. **파일 탐색**: dev/ 폴더에서 관련 파일 찾기
   - 캠페인 관련: dev/js/campaign.js, dev/js/application.js
   - 로그인/회원가입: dev/js/auth.js
   - 마이페이지: dev/js/mypage.js
   - UI/모달/토스트: dev/js/ui.js
   - 라우팅/초기화: dev/js/app.js
   - DB 함수: dev/lib/storage.js
   - 스타일: dev/css/ 해당 파일
3. **원인 분석**: 코드 읽고 버그 원인 파악
   - 흔한 실수 체크: db null 체크 누락, .single() 사용, localStorage 용량 초과
4. **수정**: 최소한의 변경으로 버그 수정
   - db?.from() null-safe 패턴 확인
   - .maybeSingle() 사용 확인
5. **빌드**: `cd dev && bash build.sh` 실행
6. **요약**: 원인, 수정 내용, 수정된 파일:줄번호
