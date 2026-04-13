프로젝트 빌드:

1. `cd dev && bash build.sh` 실행
2. 빌드 결과 확인:
   - `../index.html` (인플루언서 앱) 생성 여부
   - `../admin/index.html` (관리자 앱) 생성 여부
3. 에러 발생 시:
   - Python 미설치: `python3 --version` 확인
   - 파일 누락: build.sh에 등록된 CSS/JS 파일 존재 여부 확인
   - 경로 오류: dev/ 디렉토리에서 실행했는지 확인
4. 빌드 후 `git diff --stat`으로 변경된 파일 목록 보고

참고: 루트 index.html, admin/index.html은 직접 수정 금지. 항상 dev/ 에서 수정 후 빌드.
