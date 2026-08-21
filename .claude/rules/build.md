---
description: 빌드 워크플로우 규칙
globs: "dev/**"
---

# 빌드 규칙

## 빌드 필수 실행 (누락 금지)
- dev/ 파일 수정 후 반드시 `cd dev && bash build.sh` 실행
- 빌드 없이 커밋하면 루트 index.html과 dev/ 코드가 불일치
- 빌드는 2개 파일 생성: `../index.html` (인플루언서), `../admin/index.html` (관리자)

## 빌드 순서 (build.sh)
### 인플루언서 빌드 (→ ../index.html)
- CSS: base.css → components.css → campaign.css → auth.css → mypage.css
- JS: **`dev/build.sh` 의 `JS_FILES` 배열이 단일 소스다.** (관리자 쪽과 같은 이유로 여기에 나열하지 않는다. 이 문서는 실제 19개 중 **10개가 빠진** 옛 9개 목록으로 오래 남아 있었다.)
- 순서 규칙: `lib/*` 가 `js/*` 보다 앞, `js/app.js` 가 맨 마지막.

### 관리자 빌드 (→ ../admin/index.html)
- CSS: base.css → components.css → admin.css
- JS: **`dev/build.sh` 의 `ADMIN_JS_FILES` 배열이 단일 소스다.** 2026-08 기준 30개이고 계속 늘어나므로 여기에 베껴 적지 않는다 — 베껴 적으면 반드시 갈린다(실제로 2026-05-25 에 `admin.js` 가 여러 파일로 쪼개진 뒤 이 문서만 옛 3개 목록으로 남아 있었다).
- 순서 규칙만 기억하면 된다: `admin-core.js` 가 다른 `admin-*` 보다 **앞**, `admin.js` 가 페인 파일들보다 **뒤**, `admin/app.js` 가 **맨 마지막**.

## 새 파일 추가 시
- CSS/JS 파일 추가 시 반드시 build.sh에 파일 경로 등록
- dev/index.html에 `<link>` 또는 `<script>` 태그 추가
- 빌드 순서(의존성) 고려하여 적절한 위치에 삽입

### ⚠️ build.sh 는 **두 곳**을 함께 고쳐야 한다
`ADMIN_JS_FILES` 배열에 파일을 넣는 것만으로는 부족하다. 바로 아래에 **원본 `<script>` 태그를 지우는 정규식**이 따로 있는데, 거기에 파일 이름을 빠뜨리면 **죽은 태그가 산출물에 남아 없는 경로를 부른다.**

실제 사고 — `image-compress.js` 가 관리자 빌드 목록에 없어서, 관리자가 응모건 메시지에 이미지를 첨부하면 **반드시 실패**했다(그 함수 정의가 관리자 빌드에 아예 없었다). 2026-08-12 에야 발견됐다.

## 주의사항
- 루트 index.html, admin/index.html 직접 수정 금지 (빌드 시 덮어씀)
- 항상 dev/ 폴더에서만 수정
- build.sh는 Python을 사용하므로 python3 필요
