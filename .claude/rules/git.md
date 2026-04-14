---
description: 프로젝트 Git/배포 규칙
globs: "*"
---

# Git / 배포 규칙

## 브랜치
- 개발: `dev` 브랜치 → `dev.globalreverb.com` (개발서버) 자동 배포
- 배포: `main` 브랜치 → `globalreverb.com`, `www.globalreverb.com` (운영서버) 자동 배포
- PR 생성 시 dev → main

## 배포 워크플로 (필수)
1. dev/ 수정 → `cd dev && bash build.sh`
2. dev 브랜치 커밋 + 푸시 → 개발서버 자동 배포
3. **개발서버에서 기능 검증** (로그인/DB 쓰기/UI 확인)
4. DB 변경이 있다면 **개발서버 DB에 먼저 적용** 후 코드와 함께 검증
5. PR dev → main 생성
6. 운영서버 DB에 마이그레이션/패치 적용 (SQL Editor)
7. PR merge → 운영서버 자동 배포
8. 운영서버 실데이터/환경에서 최종 검증

## 빌드 필수
- dev/ 수정 후 반드시 `cd dev && bash build.sh` 실행
- 루트 `index.html`, `admin/index.html`는 빌드 산출물 (직접 수정 금지)
- 루트 `js/`, `css/`, `lib/` 폴더는 **존재하지 않음** (2026-04-14 정리 완료)

## Cherry-pick 배포 (개발서버 한정 기능 제외)
- 개발서버만 적용할 커밋(예: i18n Phase 1)은 main에 머지 금지
- 필요한 커밋만 cherry-pick해서 새 브랜치 → PR → merge
- 충돌 발생 시 `dev/` 소스 파일을 가져와서 rebuild하는 방식 권장

## 커밋 컨벤션
- conventional commit: `feat:`, `fix:`, `refactor:`, `docs:`, `chore:`, `build:`
- 영어 한 줄 메시지 선호 (한국어 설명은 body에)
- 본문에 변경 이유(why)와 영향 범위 기록

## 안전 규칙
- main 브랜치 force push 금지
- `.env`, API Key, SMTP Password, Service Role Key 커밋 금지
- `.gitignore`에 `supabase/.temp/`, `supabase/bundle/`, `.DS_Store` 등록 유지
- 대형 dump/log 파일은 커밋 금지 (gitignore 처리)

## 배포 완료 안내 (사용자에게)
- dev push만: "개발서버 배포 완료 — https://dev.globalreverb.com"
- main merge + push: "운영서버(Vercel) 배포 완료 — https://globalreverb.com"

## 긴급 롤백
- 단일 커밋 문제면 `git revert <sha>` 후 `git push origin main`
- DB 변경이 얽혀있으면 백업에서 pg_dump 복원 + code revert 병행
- 롤백 전 사용자 승인 필수

## 배포 전 체크 (필수)
- [ ] 빌드 성공 (`bash build.sh` 에러 없음)
- [ ] 제거한 DOM/함수의 잔존 참조 grep 확인
- [ ] 개발서버에서 시나리오 테스트 완료
- [ ] DB 변경 있으면 개발 DB에 적용 + 검증
- [ ] **`reverb-reviewer` 에이전트 호출 — 모든 commit 직전 예외 없이** (단순 한 줄 오탈자 제외)
- [ ] Supabase/Auth 관련 변경이면 `reverb-supabase-expert` 호출
- [ ] 설계 분기점 2개 이상이면 `reverb-planner`로 경우의 수 탐색 선행

## 에이전트 호출 의무
메인 Claude가 스스로 판단해서 스킵하지 말 것:
- `reverb-reviewer`: commit/push 직전 항상 실행
- `reverb-supabase-expert`: `auth.users`, `auth.identities`, RLS, 마이그레이션, `storage.js`, Supabase 클라이언트 옵션 수정 시
- `reverb-planner`: 기능 추가·개선·리팩토링 시작 전 (규모 무관)
