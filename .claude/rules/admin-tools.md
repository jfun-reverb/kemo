---
description: 관리자 오류 로그·광고 추적(메타 픽셀 설정) 화면(묶음 규칙)
paths:
  - "dev/js/admin-errors.js"
  - "dev/js/error-report.js"
  - "dev/js/admin-ad-tracking.js"
  - "dev/js/meta-pixel.js"
  - "dev/lib/supabase.js"
  - "dev/admin/app.js"
  - "dev/lib/storage.js"
  - "supabase/migrations/*client_error*"
  - "supabase/migrations/*meta_pixel*"
  - "supabase/migrations/*ad_tracking*"
---

# 관리자 오류 로그·광고 추적 (CLAUDE.md 기준 데이터·번들·관리자 계정 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- **오류 로그**(`/admin#errors`, 마이그레이션 165, `dev/js/admin-errors.js`): 인플 앱 오류 모음. 상세 모달에서 해결/무시/메모(`resolve_client_error`). 개인정보는 수집 단계 마스킹. 수집은 `error-report.js`
- **광고 추적**(`/admin#ad-tracking`, 마이그레이션 438·439, `dev/js/admin-ad-tracking.js` — ★**운영 배포 완료**. 🔴 **운영에서 켜져 있다**(켜짐·아이디 있음·시행일 `2026-09-18` — 사용자 결정으로 공고상 시행일 10-17 을 기다리지 않았고, 방침·앱 공지·메일의 10-17 은 그대로 둔다)): 메타 픽셀 켜기·아이디 입력 화면(「관리자 설정」 묶음). 권한 `menu.ad-tracking`(매니저 읽기) + `ad_tracking.manage`(매니저 숨김, **서버 강제**).
  - 🔴 **상태 배지 4종은 서버 `status` 를 그대로 그린다** — 화면이 시행일을 비교하지 않는다(갈리면 「켤 수 있어 보이는데 서버가 거부」). 순서 `policy_locked` → `no_pixel_id` → `disabled` → `active`
  - ⚠️ **스위치는 저장된 아이디로만** — 저장 안 한 입력이 있으면 멈추고 먼저 저장하라고 한다. 켤 때만 확인 창
  - ⚠️ 쓰기 권한이 아니면 **숨기지 않고 비활성** + 「변경 권한이 없습니다」. 거부 사유 넷(`forbidden`·`invalid_input`·`invalid_pixel_id`·`policy_not_in_effect`)과 통신 실패는 **각각 다른 문구**
  - ⚠️ 저장 뒤 안내는 셋 모두 같다 — 이미 열린 탭은 새로고침 전까지 옛 설정으로 보낸다
  - ⚠️ 개발서버에서는 「운영 아이디를 넣지 마세요」 경고(`IS_STAGING`). 🔴 **관리자 앱에는 픽셀을 심지 않는다**(운영자 행동이 전환으로 잡힌다)
