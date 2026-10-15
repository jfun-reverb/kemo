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
- **오류 로그**(`/admin#errors`, 마이그레이션 165, `dev/js/admin-errors.js`): 인플 앱 오류 모음. 상세 모달에서 해결/무시/메모(`resolve_client_error`). 개인정보는 수집 단계 마스킹. 수집은 `error-report.js` · 브라우저 정보·회원 아이디는 한 쌍으로 매 발생마다 최근 값으로 바뀌고, 받은 지 3개월 뒤(탈퇴 확정 회원은 확정 즉시 — 520) 비워진다(522 — 상세 화면 「최근 브라우저」가 「브라우저 정보 없음」인 것은 정상). 기간 필터는 날짜별 횟수(`client_error_daily`, 일본 날짜)로 줄을 고르고 횟수 칸도 그 기간 횟수다 — 「전체」만 누적 횟수(도입 이전 포함). 지문은 맥락 → 우리 코드 함수 이름 → 종전 계산 순(`error-report.js`, 🔴 빌드를 압축하면 함수 이름 갈래가 깨진다)
- **광고 추적**(`/admin#ad-tracking`, 마이그레이션 438·439, `dev/js/admin-ad-tracking.js` — ★**운영 배포 완료**. 🔴 **운영에서 켜져 있다**(켜짐·아이디 있음·시행일 `2026-09-18` — 사용자 결정으로 공고상 시행일 10-17 을 기다리지 않았고, 방침·앱 공지·메일의 10-17 은 그대로 둔다)): 메타 픽셀 켜기·아이디 입력 화면(「관리자 설정」 묶음). 권한 `menu.ad-tracking`(매니저 읽기) + `ad_tracking.manage`(매니저 숨김, **서버 강제**).
  - 🔴 **상태 배지 4종은 서버 `status` 를 그대로 그린다** — 화면이 시행일을 비교하지 않는다(갈리면 「켤 수 있어 보이는데 서버가 거부」). 순서 `policy_locked` → `no_pixel_id` → `disabled` → `active`
  - ⚠️ **스위치는 저장된 아이디로만** — 저장 안 한 입력이 있으면 멈추고 먼저 저장하라고 한다. 켤 때만 확인 창
  - ⚠️ 쓰기 권한이 아니면 **숨기지 않고 비활성** + 「변경 권한이 없습니다」. 거부 사유 넷(`forbidden`·`invalid_input`·`invalid_pixel_id`·`policy_not_in_effect`)과 통신 실패는 **각각 다른 문구**
  - ⚠️ 저장 뒤 안내는 셋 모두 같다 — 이미 열린 탭은 새로고침 전까지 옛 설정으로 보낸다
  - ⚠️ 개발서버에서는 「운영 아이디를 넣지 마세요」 경고(`IS_STAGING`). 🔴 **관리자 앱에는 픽셀을 심지 않는다**(운영자 행동이 전환으로 잡힌다)

---

## CLAUDE.md 에서 옮겨 온 것 (2026-10-15 — 지시 문서 합계 줄이기)

#### 메타 픽셀 (마이그레이션 438·439 — ★**운영 적용 완료** · 🔴 **운영 전송 중**(설정 시행일 `2026-09-18` · 켜짐 · 아이디 입력))
> 방문·가입·신청을 Meta 로 보낸다. 관리 화면은 「광고 추적」, 전송은 `dev/js/meta-pixel.js`. 사양서 `docs/specs/2026-09-03-meta-pixel.md` · 작업표 `…-meta-pixel-breakdown.md`
> 🔴 **잠금 구조** — 설정 시행일이 비었거나 미래면 켜기 거부·앱용 조회 빈 값. **그 날짜 입력이 곧 잠금 해제**. ⚠️ 방침 문서·앱 공지·통지 메일의 시행일 `2026-10-17` 은 어긋남이 아니라 사용자 결정이다. 되돌리지 말 것.
- `meta_pixel_settings` — 한 줄(id=1). `meta_pixel_id`(숫자만) · `enabled` · `policy_effective_date` · `updated_at/by`. 조회 `is_admin()`, **쓰기 정책 없음**. 🔴 **시행일을 바꾸는 함수는 없다** — SQL 편집기로만
- `meta_pixel_settings_history` — 추가만. 🔴 **저장 함수가 아니라 설정 표의 트리거가 쓴다** — SQL 로 넣은 값도 남도록. 로그인 없으면 `actor NULL` →「시스템(직접 입력)」. ⚠️ `updated_by` 를 이력의 `actor` 로 옮겨 적지 않는다(직전 저장자가 찍힌다)
- 🔴 **시행일 판정식은 `_meta_pixel_policy_in_effect(date)` 한 곳**이고 저장 거부·앱용 조회·상태 배지가 그것을 부른다. 식 = `p_date IS NOT NULL AND p_date <= (now() AT TIME ZONE 'Asia/Tokyo')::date`. **다른 함수에 복사하지 말 것**
- `get_meta_pixel_admin()` — 관리자 전원. 설정 + `status` + 최근 이력 50건. `update_meta_pixel_settings(text, boolean)` — 가드는 `is_campaign_admin()` 이 아니라 **`has_permission('ad_tracking.manage','write')`**. ⚠️ **「꺼짐 → 켜짐」 요청만** 시행 전이면 거부 — 아이디 저장·끄기는 항상 허용
- `get_public_meta_pixel_id()` — 비로그인·로그인 모두. ①켜짐 ②아이디 있음 ③시행일 도래 ④관리자·감사용 아님(332 와 같은 판정) — 넷 다 참일 때만 아이디, 아니면 **빈 문자열**(NULL 아님 — 실패와 구분).
- 🔴 **민감 주소 판정은 부팅 때 한 번뿐**(`metaPixelUrlHasSensitiveValue`) — 이미 켜진 탭에서 주소에 붙는 값은 못 막는다. 그래서 **초대 번호는 주소에 남기지 않는다** — 저장소(`reverb.inviteCtx`)가 기억하고 `captureInviteFromHash` 가 주소에서 걷어낸다(`stripInviteFromUrl`, 저장소를 못 쓰면 남김). 주소에 값을 싣는 새 링크를 만들면 같은 처리를. ⚠️ 초대 링크로 처음 들어온 방문은 픽셀이 꺼진 채 시작한다(의도). **iOS 앱(Capacitor 웹뷰)에서는 꺼짐**(앱 추적 투명성 동의 없음)
- ⚠️ **실행 권한은 회수 방향이 둘**(369·370·375) — 앱용 조회만 `anon`·`authenticated`, 관리 함수 둘은 `authenticated`, 헬퍼·트리거 함수는 셋 다 회수
- ⚠️ **관리자·권한·감사용 판정은 SQL 편집기로 재현 못 한다** — 실제 로그인 브라우저로 확인
- 🔴 **배포는 데이터베이스 먼저, 코드 나중** — 반대면 없는 함수를 불러 오류가 쌓인다. ⚠️ 개발에서 앱 코드가 438 보다 먼저 나간 적이 있다. 439 는 438 뒤, **관리 화면과 같은 배포**에(화면은 못 읽으면 열고 서버는 거부 — 방향이 반대)

#### 사용자 앱 에러 수집 (마이그레이션 165)
> 인플루언서 앱 에러를 관리자가 모아 본다(실시간 아님). 개인정보 마스킹 필수.
- `client_error_logs` — fingerprint 묶음. `fingerprint`+`status`(open/resolved/ignored) UNIQUE, 같은 에러는 `occurrence_count` 누적. `source`(influencer/admin)·`kind`(unhandled/rejection/handled)·`message`/`stack`/`page_hash`(마스킹)·`error_code`·`user_id`(influencers FK, anon 은 NULL)·`user_agent`·`identity_at`(이 쌍을 받은 시각 — 셋이 한 쌍, 받은 지 3개월 뒤 비움 — 아래 「보관 3개월」)·`first/last_seen_at`·`resolved_by/at/note`. RLS SELECT `is_admin()` 만, 쓰기는 RPC 경유
- `report_client_error(...)` 원격 호출 함수(현재 원본 **522**, 베이스 308 · 🔴 인자 10개 그대로 `CREATE OR REPLACE` 로만 — 비로그인 수집 경로라 틀리면 수집 전체가 조용히 멈춘다) — SECURITY DEFINER, **anon+authenticated**. 빈값·범위·길이 가드 + **서버측 2차 마스킹**(이메일·전화·우편번호 `\d{3}-\d{4}`·Bearer 토큰·PostgreSQL `(col)=(val)`) + open fingerprint UPSERT + 날짜·환경별 횟수 +1(`client_error_daily`, 실패해도 수집은 계속). 🔴 브라우저 문자열·회원 아이디·받은 시각(`identity_at`)은 **한 쌍으로 매 발생마다 함께** 최근 값으로 바꾼다(한쪽만 바꾸지 않는다). 탈퇴 확정(`status='done'`) 계정은 쌍을 비운다
- `resolve_client_error(id, status, note)` 원격 호출 함수(현재 원본 **522**, 베이스 518) — `is_admin()` 가드(open 되돌리기 시 resolved_* 초기화). 🔴 표가 `UNIQUE(fingerprint, status)` 라 재발한 오류를 다시 무시·해결·되돌릴 때 **같은 지문·같은 목표 상태 행으로 합친다**(횟수 합·처음/마지막 발생·최근 원문·날짜별 횟수 옮기기, 지금 행 삭제). 제약을 좁히는 방법은 쓰지 않았다 — 수집 함수(308)의 `ON CONFLICT (fingerprint, status)` 가 그 제약에 기대고, 비로그인 수집 경로라 틀리면 조용히 멈춘다
- **보관 3개월**(522, 베이스 519 · 탈퇴 확정 회원은 520 이 확정 순간 즉시): `purge_old_client_error_identity()` 가 매일(도쿄 03:30, `client-error-logs-identity-retention-daily`) **쌍을 받은 지(`identity_at`) 3개월 지난 행의 `user_agent`·`user_id` 를 함께** 비운다(행·문구는 남김) — 개인정보처리방침 「자동 수집 3개월」. 🔴 기준이 `first_seen_at` 이 아닌 이유는 수집 함수(522)가 쌍을 최근 값으로 갱신하기 때문이다(519 머리말의 「`user_agent` 만 `last_seen_at`」 제안은 폐기)
- **날짜·환경별 횟수**(521·522): `client_error_daily(error_log_id, day 일본 날짜, env, count)` — 분류는 서버 함수 `_client_error_env_label` 한 곳(「OS · 브라우저」 대략값, 🔴 이름을 바꾸면 옛·새 이름이 따로 쌓인다). 도입일은 `client_error_daily_settings`(한 줄 — 그 이전 횟수는 날짜가 없다). 관리자 화면 기간 필터·발생 환경은 `get_client_error_counts(from, to)` 로만 읽는다(🔴 조회 실패 `null` 과 0건을 구분 — 실패를 0 으로 그리지 않는다)
- 클라: `dev/js/error-report.js`(`window.onerror`·`unhandledrejection` + `friendlyErrorJa` 훅 + 1차 마스킹·노이즈필터·60초 디바운스·throw 안 함), `storage.js` `reportClientError()`. 사양서 `docs/specs/2026-06-02-client-error-reporting.md`
