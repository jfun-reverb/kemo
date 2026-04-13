현재 변경사항을 다음 항목으로 리뷰:

1. **정확성**
   - 로직 오류, 엣지 케이스
   - db?.from() null-safe 접근 확인
   - .maybeSingle() 사용 확인 (.single() 금지)
   - DB 함수가 dev/lib/storage.js에 있는지 확인

2. **레이아웃 규칙**
   - 인플루언서 코드에 PC 전체폭 레이아웃 혼입 여부
   - 관리자 코드에 모바일쉘/바텀탭 혼입 여부
   - 인플루언서: dev/index.html + dev/css/(base|components|campaign|auth|mypage).css
   - 관리자: dev/admin/index.html + dev/css/(base|components|admin).css

3. **일본어/UI**
   - UI 텍스트가 일본어인지 확인 (한국어/영어 혼입 금지)
   - 코드 주석이 일본어인지 확인
   - 날짜 포맷 ja-JP 사용 확인

4. **보안**
   - XSS: innerHTML에 사용자 입력값 직접 삽입 여부
   - 민감 데이터 로그 기록 여부

5. **빌드 정합성**
   - dev/ 수정 후 build.sh 실행 여부
   - 새 파일 추가 시 build.sh에 등록 여부

`git diff`로 변경사항을 확인한 후 제공:
- 변경 내용 요약
- 발견된 문제 (심각/경고/정보)
- 구체적인 수정 제안 (파일경로:줄번호 포함)
