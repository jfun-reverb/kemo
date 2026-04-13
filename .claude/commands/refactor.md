코드 리팩토링:

1. **분석**: dev/ 폴더에서 대상 코드 읽기 — $ARGUMENTS
   - JS: dev/js/ (기능별), dev/lib/ (DB/공통)
   - CSS: dev/css/ (기능별)
   - HTML: dev/index.html 또는 dev/admin/index.html
2. **문제점 식별**:
   - 중복 코드 (3회 이상 → 공통 함수 분리)
   - 50줄 초과 함수 → 분리
   - 3단계 초과 중첩 → 조기 반환
   - DB 직접 쿼리 (dev/lib/storage.js로 이동)
   - 미사용 코드/변수 제거
3. **리팩토링 계획**: 단계별 변경 내용 제시
4. **실행**: 점진적으로 리팩토링
   - 기존 동작 유지 확인
   - 함수명/변수명은 camelCase
   - CSS 클래스명은 kebab-case
5. **빌드**: `cd dev && bash build.sh` 실행
6. **요약**: 변경 내용, 개선된 점
