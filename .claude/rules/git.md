---
description: 프로젝트 Git/배포 규칙
globs: "*"
---

# Git / 배포 규칙

## 브랜치
- 개발: dev 브랜치
- 배포: main 브랜치
- PR 생성 시 dev → main

## 빌드 필수
- dev/ 수정 후 반드시 `cd dev && bash build.sh` 실행
- 루트 js/css/lib/ 파일도 dev/와 동기화 필수

## 배포 완료 안내
- dev push만: "dev 서버 배포 완료"
- main merge + push: "운영 서버(Vercel) 배포 완료 — https://kemo-liart.vercel.app"
