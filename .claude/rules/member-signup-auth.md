---
description: 회원 가입·로그인·인증 — 가입 트리거가 폼 값을 저장, 확인 링크 착지, 비밀번호 경고(묶음 규칙)
paths:
  - "dev/js/auth.js"
  - "dev/js/app.js"
  - "dev/js/ui.js"
  - "dev/lib/shared.js"
  - "docs/email-templates/confirm-signup*"
  - "dev/admin-setpw.html"
  - "dev/js/admin-accounts.js"
  - "dev/lib/storage.js"
  - "dev/lib/i18n/ja.js"
  - "dev/lib/i18n/ko.js"
  - "supabase/migrations/*signup*"
  - "supabase/migrations/*strip_signup*"
  - "supabase/functions/signup-code-*/**"
  - "supabase/migrations/*unverified*"
  - "supabase/migrations/*invite_admin*"
  - "supabase/migrations/526_*"
---

# 회원 가입·로그인·인증 (CLAUDE.md 인플루언서 기능 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- **회원가입**: 1단계 폼 (이름 한자·가나 + **생년월일·성별** + 이메일 + 비밀번호 + 약관·개인정보 동의[필수]·마케팅 동의[선택]), SNS·배송지는 마이페이지에서 입력
  - 🔴 **폼 값은 화면이 아니라 가입 트리거가 저장한다**(마이그레이션 382, 현재 원본 **526** — 382 → 420 → 526. 526 은 맨 앞에 브랜드 계정 분기(앱 메타데이터 `account_kind='brand'` 면 인플루언서 행을 안 만든다)만 더했다. 🔴 420 을 베이스로 재정의하면 브랜드 계정에 인플루언서 행이 생긴다. ⚠️ 526 은 개발서버만, 운영 원본은 420). ⚠️ **420 부터 동의 시각 셋은 계정 생성 ±1일 안에서만 브라우저 값을 믿고 밖이면 `now()`, 생년월일은 1900~오늘(일본) 밖이면 NULL** — `signUp` 은 공개 키로 누구나 부른다(I-1). 소급분(381, 동의 시각 = 가입 시각) 구분 유지. 화면은 `signUp` 의 `options.data` 로 넘기고 서버가 `auth.users.raw_user_meta_data` 에서 꺼내 `influencers` 에 넣은 뒤 **그 자리를 지운다**(`email` 키는 남긴다).
  - ⚠️ **화면에서 저장할 수 없는 이유** — 가입 직후에는 세션이 없어 본인 행 쓰기 정책에 막힌다. 그래서 이 경로가 유일하다.
  - 🔴 **지우는 일은 삽입 때 한 번으로 안 끝난다**(마이그레이션 383). 인증 서비스가 계정 생성 직후 자기 사본으로 한 번 더 저장하며 382 가 지운 자리를 되돌린다(`updated_at > created_at`, 트리거 자체는 `age_consent_at` 까지 끝까지 돈다). 그래서 383 이 `auth.users` 에 **`BEFORE UPDATE OF raw_user_meta_data`** 트리거로 **쓰기마다** 그 아홉 개를 떨궈낸다(순서에 기대지 않는다).
    - ⚠️ **열쇠말 목록은 `public._strip_signup_meta(jsonb)` 한 곳**이고 트리거와 기존 행 일괄 정리가 함께 쓴다. 382 안에도 같은 목록이 남아 있는데 **어긋나면 383 쪽이 이긴다**(쓰기마다 돌기 때문).
    - 🔴 **이 함수가 오류를 내면 로그인이 통째로 막힌다**(마지막 로그인 시각 쓰기에도 낀다). 그래서 ①객체가 아니면 통과 ②`EXCEPTION WHEN others THEN RETURN NEW` 로 **오류가 새지 않게** 했다 — 대신 실패는 조용하다(값이 남은 채 지나간다).
    - ⚠️ **이 칸에 `name` 같은 값을 담아 쓰려 하면 조용히 사라진다.** 지금 읽는 곳 0곳, 관리자 초대(245)의 `sub`·`email`·`email_verified`·`phone_verified` 와도 안 겹친다.
    - ⚠️ **적용 뒤 반드시 실제 가입을 한 번 해 볼 것** — 되돌려 쓰는 순간을 재현해야 한다(SQL 편집기로는 안 됨).
  - ⚠️ **가입 뒤 `upsertInfluencer` 를 다시 부르지 말 것** — **행 전체를 대체**해 트리거가 넣은 값을 되돌린다(`created_at` 이 브라우저 시각으로 덮인다). 그 호출은 382 에서 제거했다.
  - ⚠️ 382 이전 가입 폼 값은 **운영에서 저장되지 않았다**(`auth.js` 가 이메일 확인 대기면 `return` — 확인이 꺼진 개발서버와 달랐다). 과거분은 381 로 소급.
- **가입 이메일 인증번호 화면**(사양서 `docs/specs/2026-10-01-signup-email-code-verification.md` 설계 ③ — 🔴 **개발서버 반영 대기, 운영은 방침 시행일·10/6 창구 뒤**): 「認証する」 → 6자리 → 「確認」 → 확인증 → 그때만 「登録する」 활성. 상태는 `_signupCode` 한 곳, 시각은 **서버 응답 값만**(화면에 유효 시간 숫자 금지). `signUp` 은 확인증을 받은 **정규화 주소**(`trim().toLowerCase()`)와 `options.data.signup_ticket` 으로 보낸다 — 주소를 고치면 인증이 풀린다. 가입 뒤 갈래 넷(신원 목록 빔 → 일반 실패+로그인 안내·픽셀 없음 / 세션 → 로그인 / 세션 없고 인증 완료 → 자동 로그인, 실패면 로그인 화면 / 미인증 → `#signupConfirmMsg`). 픽셀은 인증 완료면 `confirmed` 한 번. 🔴 **`signUp` 앞뒤 픽셀 새로고침 보류 짝**(`metaPixelHoldReload`/`Release`) — 빼면 가입 직후 화면이 새로고침될 수 있다. 비밀번호 찾기는 「잠시 후 다시」 외 오류도 **성공 문구**(계정 열거 방지 — 결정 6)
- **가입 이메일 도메인 점검**(`signupEmailCheck`, auth.js — 화면에서만): **「認証する」을 누를 때** 한다. `@` 뒤에 점이 없거나 끝이 글자 2자 미만이면 **막고**(`authError.emailInvalid`), 흔한 오타(`SIGNUP_EMAIL_TYPO_DOMAINS` — `gmail.co`·`i.softbank.jo` 등, `.con`)는 **한 번 알리고 같은 주소로 다시 누르면 통과**(`authError.emailTypoVerify`). ⚠️ `type="email"` 은 `a@gmail` 을 통과시키고 인증 서비스도 안 막는다 — 운영에 그렇게 가입해 확인 메일을 영영 못 받은 계정이 있었다(2026-10-01)
- **흔한 비밀번호 경고**(가입·재설정·마이페이지 변경): 새 비밀번호 칸 아래 노란 줄(`auth.pwCommonWarn`)만 띄우고 **버튼은 막지 않는다**. 판정은 관리자 거부와 같은 `commonPasswordCheck`(`bindCommonPasswordWarning` 이 `app.js` 부팅 때 세 칸에 붙인다). ⚠️ 경고를 보고 진행했는지는 기록하지 않는다(새 정보 수집). 약관 판단은 「방침 개정 불필요 — 해시 앞 5글자만, 우리 서버 함수 경유」에 기대므로 **브라우저가 외부 서비스에 직접 묻게 바꾸면 다시 본다**
- **로그인/로그아웃**: 이메일+비밀번호, 세션 복원, 관리자 로그인 시 admin 페이지 자동 오픈
- **비밀번호 재설정**: 이메일 → 재설정 메일 → 앱 내 새 비밀번호 설정 (`#page-forgot`, `#page-reset-pw`)
- **GNB**: 비로그인 시 Log In/Sign Up 버튼, 로그인 시 우측 햄버거 메뉴 (계정 카드[우측 알림 벨] + 홈/캠페인/마이페이지 아코디언/로그아웃/회원탈퇴), 관리자는 Admin 버튼
- **회원가입 이메일 확인**: 운영서버 한정 Supabase Confirm sign-up 활성, 가입 후 확인 메일 안내 화면 표시, 미확인 시 로그인/신청 차단. 개발서버는 Confirm email OFF. auth.js 는 `data.session` 유무로 자동 분기
  - 🔴 **확인 링크는 `?code=` 로 착지하고, 그것은 재설정 신호가 아니다**. `detectRecoveryUrlEarly` 가 재설정으로 읽으면 새 회원이 **「새 비밀번호 설정」 화면**에 떨어지고, 다른 브라우저면(검증값 없음 — supabase-js 는 교환을 시도조차 안 한다) 「Auth session missing」. 착지는 **세션 있으면 홈 + 「メール認証が完了しました」 토스트 / 없으면 로그인 화면 + `#loginNotice` 안내**. ⚠️ `?code=` 는 **스크립트 로드 때** `_signupConfirmCodeSeen` 에 봐 둔다(교환 성공 시 주소에서 지워져 `init()` 에서는 놓친다). ⚠️ `?error=…expired` 착지는 **로그인 화면**(`auth.confirm.linkExpired`). ⚠️ 재설정 신호는 `#reset-pw?`·`PASSWORD_RECOVERY`·옛 implicit 해시(`type=recovery`·`access_token=`)뿐 — `?code=` 조건을 되살리지 말 것. `handleLogin` 의 「프로필 없으면 만든다」는 **조회 실패(error)와 0건을 가른다**(실패면 `handleLogin.profileFetch` 기록만). 🔴 **0건이어도 접근 토큰(`getSession()`)이 없으면 삽입하지 않는다** — 비로그인 조회는 오류가 아니라 0건으로 와서 「프로필 없음」으로 읽힌다(운영 9/10·9/13). 그때는 `handleLogin.sessionNotAttached` 기록 + 로컬 로그아웃 + 「다시 로그인」 안내. 사양서 `docs/specs/2026-09-10-signup-confirm-link-routing-fix.md`

## 가입 인증번호 관문 (CLAUDE.md 에서 옮겨 옴 — 2026-10-20 · ⚠️ 상태 서술은 옮길 때 그대로라 낡았을 수 있다 — 10/13 운영 시행 뒤 확인 필요)
- 🔴 **`auth.users` 가입 인증번호 관문 둘**(마이그레이션 493~499 — **개발·운영 적용(스위치 대기 — 2026-10-01 운영 반영, 함수 2개 포함)**. 가입 화면 운영은 **10/13 시행일**(가입 화면 운영 묶음 #1892, 초안 — 🔴 병합하는 순간 스위치가 대기여도 화면이 인증번호를 필수로 만든다). 🔴 **미인증 계정 정기 삭제 예약은 503**(UTC 20:45) — 방침이 「7일 경과 파기」를 약속하므로 10/13 운영 전환(스위치 강제) 때 함께, 순서는 503 머리말. 사양서 `docs/specs/2026-10-01-signup-email-code-verification.md`): BEFORE INSERT `trg_signup_ticket_gate` · BEFORE UPDATE `trg_signup_resend_gate`(미인증 행의 확인 메일 재발송·재설정 메일 요청). 스위치 `signup_code_settings.mode`(기본 `standby` = 둘 다 통과). 🔴 **고쳐 쓰기 관문은 로그인·토큰 갱신마다 돈다** — 첫 줄 `OLD.email_confirmed_at IS NOT NULL → 통과` 를 옮기지 말 것. 코드가 틀려 로그인이 막히면 스위치로 안 풀린다 → `supabase/patches/2026-10-01-signup-{resend,ticket}-gate-off.sql`(삽입 관문 끄기는 스위치를 대기로 먼저). 🔴 **끄기 = 트리거 지우기 · 켜기 = 다시 만들기** — `ALTER TABLE auth.users DISABLE TRIGGER` 는 「must be owner」로 **안 된다**(2026-10-01 개발서버 실측). 트리거 함수 둘은 **반드시 `SECURITY INVOKER`**(정의자 권한이면 `current_user` 판정이 조용히 무력화). `_strip_signup_meta` 현재 원본 **497**(열쇠 10개). 발송·확인 서버 함수 `signup-code-send`·`signup-code-verify`(비공개 키 없이 브라우저가 부른다 — 공개 키 거부 걸지 말 것) — 🔴 비밀값 `SIGNUP_CODE_PEPPER` 를 **개발·운영 각각** 넣어야 하고 없으면 두 함수가 항상 오류. 바꾸면 이미 보낸 번호가 전부 무효. 🔴 **개발서버 전용 「메일 대신 화면」** — 개발서버엔 메일 키가 없어 `SIGNUP_CODE_DEV_ECHO=1`(개발서버에만) + 함수 주소가 개발 프로젝트일 때만 발송 대신 응답에 메일 본문을 싣고, 가입 화면이 `IS_STAGING` 일 때만 새 창에 띄운다. **두 겹 잠금을 하나라도 지우면 운영에서 번호가 응답에 실려 인증이 무력해진다**
