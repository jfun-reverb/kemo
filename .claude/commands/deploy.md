Vercel에 프로젝트 배포:

1. **빌드**: `cd dev && bash build.sh` 실행
2. **빌드 확인**:
   - ../index.html 생성 확인
   - ../admin/index.html 생성 확인
3. **변경사항 확인**: `git diff --stat`으로 변경 파일 목록 확인
4. **커밋**:
   - dev/ 파일과 루트 index.html, admin/index.html 함께 스테이징
   - conventional commit 메시지 (영어)
   - console.log 등 디버그 코드 잔존 여부 확인
5. **푸시**: 현재 브랜치에 푸시
6. **배포 확인**:
   - Vercel 자동 배포 (푸시 시 트리거)
   - 인플루언서 앱: https://globalreverb.com/
   - 관리자 앱: https://globalreverb.com/admin/
