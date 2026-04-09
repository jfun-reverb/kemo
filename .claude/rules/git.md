---
description: Git 워크플로우 규칙
globs: "*"
---

# Git 규칙

## 커밋 메시지
- conventional commit 형식: feat:, fix:, refactor:, docs:, chore:
- 영어로 작성 (예: `feat: add campaign duplicate feature`)
- 본문 없이 한 줄 메시지 선호

## 커밋 전 체크리스트
- `git diff`로 변경사항 반드시 확인
- dev/ 수정 시 `cd dev && bash build.sh` 실행했는지 확인
- 루트 index.html과 dev/ 코드가 일치하는지 확인
- console.log, debugger 등 디버그 코드 제거

## 금지사항
- main/master에 force push 금지
- 대용량 바이너리 파일 커밋 금지
- node_modules, __pycache__, .DS_Store, 빌드 산출물 커밋 금지
- .env, API 키, 시크릿 커밋 금지
- 관련 없는 변경사항 혼합 금지 (기능별 분리 커밋)

## 브랜치
- 개발: dev 브랜치
- 배포: main 브랜치
- PR 생성 시 dev → main

## 배포 완료 안내
- 배포 완료 시 어디에 배포되었는지 명시
  - dev push만: "dev 서버 배포 완료"
  - main merge + push: "운영 서버(Vercel) 배포 완료 — https://kemo-liart.vercel.app"
- 루트 js/css/lib/ 파일도 dev/와 동기화했는지 함께 안내
