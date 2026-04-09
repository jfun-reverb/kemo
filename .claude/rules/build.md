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
- JS: lib/supabase.js → lib/shared.js → lib/storage.js → js/ui.js → js/campaign.js → js/auth.js → js/application.js → js/mypage.js → js/app.js

### 관리자 빌드 (→ ../admin/index.html)
- CSS: base.css → components.css → admin.css
- JS: lib/supabase.js → lib/shared.js → lib/storage.js → js/ui.js → js/admin.js → admin/app.js

## 새 파일 추가 시
- CSS/JS 파일 추가 시 반드시 build.sh에 파일 경로 등록
- dev/index.html에 `<link>` 또는 `<script>` 태그 추가
- 빌드 순서(의존성) 고려하여 적절한 위치에 삽입

## 주의사항
- 루트 index.html, admin/index.html 직접 수정 금지 (빌드 시 덮어씀)
- 항상 dev/ 폴더에서만 수정
- build.sh는 Python을 사용하므로 python3 필요
