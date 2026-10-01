# 📋 작업표 — 회원가입 이메일 인증번호 먼저 확인 후 가입

- **사양서:** `docs/specs/2026-10-01-signup-email-code-verification.md` (병합 #1837 → 정정 #1849 반영 2026-10-01)
- **분해일:** 2026-10-01 · **분해:** reverb-planner(개발 세션 요청)
- **조각:** 14개 — 병렬 가능 1개(P1), 순차 13개
- 🔴 **마이그레이션 번호는 미리 정하지 않는다.** 분해 시점 마지막 번호 492. 아래 ①~⑦은 개수와 상대 순서만 뜻한다

---

## 🚦 착수 전 선결 조건

| # | 조건 | 누가 | 막는 조각 | 상태 |
|---|---|---|---|---|
| 0 | 단계 0 실측(삽입 역할 `supabase_auth_admin` · 관문이 `email_confirmed_at=now()` 넣으면 확인 메일 안 감 · `signUp` 응답에 세션 바로 옴) + 약관 점검 | 개발 | — | ✅ 완료 |
| 1 | 관문의 「인증 서비스 삽입」 판별 방식 — 트리거 함수 `SECURITY INVOKER` + `current_user='supabase_auth_admin'`(492 선례), 표 접근은 그 역할에만 실행 권한을 준 정의자 권한 도우미 | 개발 | D5 | ✅ 이 방식으로 확정 |
| 2 | 확인증 열쇠 지우는 자리 — 사양서 「382 안 목록도 맞춘다」와 「가입 트리거(420) 무변경」이 부딪힘(stale ②) | 기획 확인 → 개발 | D5 | ✅ 420 무변경 · 관문이 직접 지움 + 383 목록 추가(사양서 반영) |
| 3 | 미인증 삭제 때 「다른 기록」 표 목록 + 방침 통지 기록(`policy_notice_log`, 연쇄 삭제)을 다른 기록으로 볼지(stale ⑦) | 기획·사용자 | D3·D6 | ✅ 통지 기록은 「다른 기록」 아님(함께 삭제) — 사양서 설계 ⑤ |
| 4 | 이미 있는 **미인증** 주소로 다시 가입할 때 인증 서비스 동작 실측(삽입이 아니라 수정이면 관문이 안 돈다 — stale ⑧) | 개발 | D5 설계 확정 | ✅ 수정 경로 확인 + 재설정 링크로도 인증 완료 확인(2026-10-01) → 사양서 설계 ①·② 반영 |
| 5 | 전역 발송 상한(`global_hourly_limit`) — 운영 시간당 최대 가입 건수 조회로 정함 | 개발 | D1 | ✅ **120**(사용자 결정 2026-10-01). 운영 최근 180일 최대는 2026-04-16 오픈 시각 238·120·91건/시 — 그날 같은 몰림이면 상한에 걸린다(설정 표 값이라 행사 전 SQL 로 올린다) |
| 6 | Brevo 남은 발송량 — 「Usage and plan」 직접 확인(문서는 월 20,000통, 메모리는 「5,000통 플랜 < 월 6,300통」) | 사용자 | O2 | 미확인 |
| 7 | 방침 개정·공지 일정 — 앱 안 공지 틀 하나를 일반 문의 창구 공지(`inquiryDesk2026`, 10/6)가 쓰는 중. 메일 통지 여부 | 사용자 | P1·O2 | 미정 |
| 8 | 개발서버에서 본인 주소로 인증번호 메일 시험 발송 가부 | 사용자 | F1·Q1 | 미정 |
| 9 | 예약 실행 시각 — 대시보드 등록 예약도 있으므로 양쪽 서버 `select jobname, schedule from cron.job` | 개발 | D4·O3 | ✅ 2026-10-01 양쪽 조회 — 세계시 18:45·19:00·19:15·19:30(셋)·19:45·20:00·20:15·20:30·00:00 사용 중. **번호 기록 정리 18:15(도쿄 03:15)** · **미인증 삭제 20:45(도쿄 05:45)** 빈 자리 |
| 10 | 같은 기간 다른 세션의 마이그레이션 생성 여부(번호 충돌) | 개발 → 사용자 | D1 | ✅ 493부터 이 세션(reverb-jp-29 「없음」 확인, 2026-10-01) |
| 11 | 🔴 가입 화면 파일(`dev/index.html`·`dev/js/auth.js`·`dev/lib/i18n/ja.js`·`ko.js`)이 일반 문의 창구(475~482)와 같은 파일 — S1 운영 반영은 창구 10/6 운영 반영 **뒤** | — | O2 | 날짜 조건 |

---

## ⚠️ 사양서와 실제 코드가 어긋나는 곳 (규칙 A)

| # | 사양서 | 실제 | 처리 |
|---|---|---|---|
| ① | `auth.js:188` `_isNewSignup` | 지금 `dev/js/auth.js:190`(픽셀 192, 메일 안내 갈래 195~200) | 줄 번호만 다름 |
| ② | 「383 목록 추가 + 382 안 목록도 맞춘다」 / 「420 무변경」 | 382 판은 420 으로 덮였고 사본은 `420:149~154`(+ 일회성 `383:119`). 맞추려면 420 재정의 필요 → 「무변경」과 충돌 | 권고: 420 무변경. 관문이 `BEFORE INSERT` 에서 `NEW.raw_user_meta_data - 'signup_ticket'` 로 직접 지우고 `_strip_signup_meta` 목록에도 추가(두 겹). 문장 정정은 기획(선결 2) |
| ③ | 거부 코드를 `friendlyErrorJa` 에 등록 | 인증 서비스는 트리거 예외를 일반 오류로 덮는다(`auth.js:142~146` 주석, 362 때 확인). 오류는 `logAppError` 로 관리자 오류 로그에 쌓임 | ✅ 사양서 반영(#1849). 거부 코드는 서버 로그 식별용. 화면은 확인증 만료 시각으로 미리 단추 비활성, 그래도 거부되면 `showSignupFailure` |
| ④ | 인증 여부 보는 자리는 응모 화면 한 곳 | `application.js:1154` 한 곳 ✅ | 일치 |
| ⑤ | 판별은 접속 역할 `supabase_auth_admin` | 정의자 권한 함수 안에서는 `current_user` 가 소유자로 바뀐다(492 가 같은 이유로 `SECURITY INVOKER` 사용, `492:34~38`). 단계 0 실측은 실행자 권한 상황 | 선결 1. 정의자 권한 도우미(`_signup_ticket_consume`)는 `supabase_auth_admin` 에만 실행 권한, PUBLIC·`anon`·`authenticated` 회수(369·370) |
| ⑥ | 픽셀은 `confirmed` 한 번으로 | 관리자 「광고 추적」 설명표 `META_PIXEL_EVENT_TABLE`(`shared.js:1962~1963`)이 「가입 폼 제출(이메일 확인 전)」·「확인 링크를 열어…」로 적힘. `shared.js:1943` = 상수·메타 픽셀 사양서 표·방침 §8.1 세 곳 한 세트. 방침 문구(가입 신청·메일 인증 완료)는 그대로 맞음 | S1 에 포함: 설명표 두 줄 + `docs/specs/2026-09-03-meta-pixel.md` 표. 이벤트 이름·상태 값 불변 |
| ⑦ | 「응모·결과물·정산 등 다른 기록이 있으면 건너뜀」 | 회원·인증 계정을 가리키는 외래 키(FK)가 42개 파일에 65건, 대부분 연쇄 삭제. `policy_notice_log`(`153:99`)도 연쇄 삭제 — 미인증 주소로 보낸 법적 통지 기록이 함께 사라짐 | 선결 3. 함수 본문에 건너뛸 표 목록 명시, 나머지는 부속 기록으로 분류해 주석에 |
| ⑧ | 「강제면 확인증 없는 가입은 서버가 거부」 | 이미 있는 **미인증** 주소로 `signUp` 하면 인증 서비스가 새 행 대신 기존 행을 수정하고 확인 메일을 다시 보내는 것으로 알려짐(미실측). 그러면 관문을 안 거치고, 번호까지 확인한 사람도 「메일 확인 안내」로 떨어짐. 기존 40건·대기 구간 미인증이 지워지기 전(최대 7일)만 해당 | ✅ 실측 = 수정 경로. 사양서 반영(#1849): 확인 함수가 옛 미인증 계정 삭제(D3) + 고쳐 쓰기 관문(D5) |
| ⑨ | 단계 1·3 「운영에서 옛 화면으로 실제 가입 1회」 | 메모리 「실제 가입 없이 운영 검증」과 부딪힘(회원 행·통계·홍보 대상이 남음) | 시험 주소로 하고 `delete_admin_completely` 로 정리. O1·O3 완료 정의에 포함 |
| ⑩ | 완료 기준 11 「픽셀 `confirmed` 1건」 | 🔴 **메타 쪽에 「Meta를 통한 전환 API」가 켜져 있다**(2026-10-01 이벤트 관리자 확인 — 2026-02-27 대행사 비즈니스 단위 옵트인, 우리 코드 무관). 같은 이벤트가 브라우저·전환 API 두 경로로 들어와 **「총 이벤트」가 2건으로 보인다**(등록 완료 9/3~9/30 = 브라우저 137 + 전환 API 105 = 242) | Q1·O2 확인은 **「이벤트 테스트」 탭** 또는 이벤트 행을 펼쳐 **브라우저 경로 건수만** 센다. 「총 이벤트」 2건을 실패로 읽지 않는다 |
| ⑪ | 가입 뒤 「세션 있음 → 로그인 상태」 갈래 | 🔴 세션이 생기는 순간 `SIGNED_IN` → `notifyMetaPixelSignedIn`(`app.js:551`)이 픽셀 **로그인 재조회**를 돌린다. 조회가 실패하면 `_metaPixelApplyResult` 가 **곧바로 `location.reload()`** — 가입 직후 화면이 새로고침되고 줄에 쌓인 `confirmed` 도 사라진다. 로그인 화면은 `metaPixelHoldReload`/`metaPixelReleaseReload`(`auth.js:250·299`)로 보류하지만 **가입 화면엔 없다**. 지금 운영은 가입 때 세션이 안 생겨(확인 메일 필수) 안 드러났던 갈래 — 새 방식에선 **주 경로**가 된다 | S1 에서 `signUp` 직전 `metaPixelHoldReload()`, 일반 회원 가입 완료 처리 뒤 `metaPixelReleaseReload()`(로그인 화면과 같은 짝). 오류로 끝나는 갈래는 보류가 15초 뒤 저절로 풀린다 |
| ⑫ | 「`confirmed` 1회」로 바뀌는 시점의 숫자 | 과도기엔 두 방식이 섞인다 — 전환 전 가입한 미인증 계정이 메일 링크로 인증하면 여전히 `pending_email` + `confirmed` 2건. 광고 세트 2개가 「등록 완료」를 학습 기준으로 쓴다 → 전환 직후 가입 이벤트 수가 **약 절반으로 줄어 보인다**(실제 가입 감소 아님) | O2 운영 반영 때 광고 담당에게 미리 알린다. 전후를 같은 기준으로 보려면 메타 「맞춤 전환」에 `status = confirmed` 만 세는 전환을 미리 만들어 둔다(메타 화면 작업, 코드 무관) |
| ⑬ | 완료 기준 13-⑤ 「재설정 요청이 거부돼도 비밀번호 찾기 화면 문구는 성공」 | 🔴 관문이 재설정 요청을 거부하면 인증 서비스는 오류를 돌려주고, 화면(`auth.js:369~397`)은 「잠시 후 다시」가 아니면 **`authError.genericError`(일반 오류)** 를 띄운다. 없는 주소는 오류 없이 성공 문구 → **강제 상태에서 「미인증 계정이 있는 주소」가 문구로 드러난다**. 거부 오류와 진짜 장애는 화면에서 구분이 안 된다(일반 데이터베이스 오류로 덮임) | S1 에서 처리 방법 결정 필요 — 기획에 전달(2026-10-01). 강제(O3) 전까지는 관문이 통과라 영향 없음 |

---

## 한눈에 보는 의존 순서

```
[선결 1~10]
   │
D1 설정 표 ─► D2 번호 표·실행 기록 표 ─► D3 서버 전용 도우미 ─► D4 번호 기록 정기 삭제 + 예약
                                              │
                                              ├─► F1 발송·확인 서버 함수 + 메일 양식
                                              └─► D5 관문 트리거 + 383 목록 ─► D6 미인증 삭제 함수(예약 없음)
                                                            │
                                     O1 단계 1 운영 적용(대기) ◄┘
P1 방침 개정 + 공지(10/6 뒤 공지 교체, 병렬) ─┐
                                              ▼
                     S1 가입 화면 ─► Q1 개발서버 검증 ─► O2 단계 2 운영 반영(10/6 뒤 + 방침 시행일 뒤)
                                                              ─► O3 단계 3 강제 + 정기 삭제 켜기 ─► M1 단계 4 측정(2~4주)
```

---

## 작업 조각 표

| 번호 | 제목 | 담당 파일 | 산출 계약(요지) | 선행 | 병렬? |
|---|---|---|---|---|---|
| D1 | 설정 표 + 스위치 변경 시각 트리거 | 마이그레이션 ① | `signup_code_settings`(한 줄) · `mode` · `mode_changed_at` · 수치 8칸 | 선결 5·10 | ✗ |
| D2 | 번호 표 + 미인증 삭제 실행 기록 표 | 마이그레이션 ② | `signup_email_codes` · `unverified_account_purge_runs` | D1 | ✗ |
| D3 | 서버 전용 도우미(발급·취소·대조) | 마이그레이션 ③ | `signup_code_issue` · `signup_code_cancel` · `signup_code_verify` | D2 | ✗ |
| D4 | 번호 기록 정기 삭제 + 예약 | 마이그레이션 ④ | `purge_old_signup_email_codes()` · 예약 `signup-email-codes-retention-daily` | D3, 선결 9 | ✗ |
| F1 | 발송·확인 서버 함수 + 메일 양식 | `supabase/functions/signup-code-send/`·`signup-code-verify/` · `docs/email-templates/signup-code.html`(+카탈로그) · `scripts/sync-email-templates.sh` | 요청·응답 형식(상세) | D3, 선결 8 | ✗ |
| D5 | 가입 관문 트리거 + 383 목록 | 마이그레이션 ⑤ | `_signup_ticket_gate()` · `_signup_ticket_consume(text,text)` · `trg_signup_ticket_gate` · 열쇠 `signup_ticket` · `_strip_signup_meta` 열쇠 10개 | D3, 선결 1·2·4 | ✗ |
| D6 | 미인증 계정 정기 삭제 함수(예약 없음) | 마이그레이션 ⑥ | `purge_unverified_accounts()` → jsonb | D2·D5, 선결 3 | ✗ |
| O1 | 단계 1 운영 적용(대기) | 운영 SQL 편집기 · 서버 함수 운영 배포 | 운영에 표 3·함수·트리거·번호 기록 예약 1 | D1~D6·F1 개발 검증 | ✗ |
| P1 | 방침 두 줄 개정 + 시행 7일 전 공지 | `docs/PRIVACY_{kr,ja}.md` · `dev/lib/shared.js`(`POLICY_NOTICE`) · `dev/lib/i18n/{ja,ko}.js` · (메일 통지 시 `notify-policy-change`) | 방침 문구·시행일 | 선결 7 | ✅(D·F 와) / ✗(S1 과) |
| S1 | 가입 화면 | `dev/index.html` · `dev/js/auth.js` · `dev/lib/storage.js` · `dev/lib/i18n/{ja,ko}.js` · `dev/lib/shared.js` · `docs/specs/2026-09-03-meta-pixel.md` · 빌드 | DOM id·번역 키·storage 함수 | F1·D5 개발 적용 | ✗ |
| Q1 | 개발서버 검증 | — | 완료 기준 1~11 관찰 기록 | S1 | ✗ |
| O2 | 단계 2 운영 반영 | dev → main | 새 화면 운영 | Q1 · P1 시행일 경과 · 10/6 창구 뒤 · 선결 6 | ✗ |
| O3 | 단계 3 강제 + 정기 삭제 켜기 | 운영 SQL 편집기 · 마이그레이션 ⑦(예약만) | `mode='enforce'` · 예약 `unverified-accounts-purge-daily` | O2(하루 이상 뒤) | ✗ |
| M1 | 단계 4 측정 → 수치 조정 | 운영 조회 + 설정 UPDATE | 걸린 시간 분포·만료 재발송 비율 | O3 + 2~4주 | ✗ |

---

## 조각별 상세

### D1 — 설정 표 + 스위치 변경 시각 트리거
- **산출 계약(이름은 제안, 확정은 「구현 결과」에):** `public.signup_code_settings` — `id smallint PK CHECK (id=1)` · `mode text NOT NULL DEFAULT 'standby' CHECK (mode IN ('standby','enforce'))` · `mode_changed_at timestamptz`(트리거만) · 수치 8칸 `integer NOT NULL CHECK (>0)`: `code_ttl_seconds`=600 · `resend_cooldown_seconds`=60 · `max_attempts`=5 · `per_email_hourly_limit`=5 · `global_hourly_limit`=(선결 5) · `ticket_ttl_seconds`=900 · `code_retention_days`=30 · `unverified_purge_days`=7 · `updated_at`. 트리거 `trg_signup_code_settings_mode_changed`(BEFORE UPDATE, `mode` 바뀔 때만). 행 단위 보안 정책 켜고 정책 없음
- **완료 정의:** 1행·`standby`. `mode` 를 바꾸면 `mode_changed_at` 이 찍히고 수치만 바꾸면 안 찍힌다. 대기로 되돌린다
- **주의:** 🔴 보관 30일·삭제 7일은 방침에 일수가 적히는 값 → 방침 개정·7일 전 공지·시행일 뒤에만 변경(칸 주석에 적는다)
- **검문소:** reverb-supabase-expert · reverb-reviewer · **롤백:** 표 삭제

### D2 — 번호 표 + 미인증 삭제 실행 기록 표
- **산출 계약:** `public.signup_email_codes` — `id uuid PK` · `email_hash`(정규화 = 앞뒤 공백 제거 + 소문자, sha256) · `code_hash` · `expires_at` · `attempts DEFAULT 0` · `verified_at` · `ticket_hash` · `ticket_expires_at` · `ticket_used_at` · `invalidated_at` · `created_at DEFAULT now()`. 색인 `(email_hash, created_at DESC)` · `(created_at)` · 부분 유일 `(ticket_hash) WHERE ticket_hash IS NOT NULL`. 원문 이메일·번호 칸 없음, 정책 없음. `public.unverified_account_purge_runs` — `id` · `run_at` · `deleted_count` · `skipped_count` · `skipped_ids uuid[]` · `error_message`. 조회 `(SELECT public.is_admin())`(415 방식), 쓰기 정책 없음
- **완료 정의:** 공개 키·로그인 회원으로 조회하면 0행 또는 거부
- **주의:** 6자리 번호 해시는 쉽게 되돌려진다 — 서버 비밀값(`SIGNUP_CODE_PEPPER`) 섞을지 개발이 정하고 기록
- **검문소:** reverb-supabase-expert · **롤백:** 두 표 삭제

### D3 — 서버 전용 도우미
- **산출 계약:** `signup_code_issue(p_email_hash text, p_code_hash text) RETURNS jsonb` → `{"status":"sent","code_id","code_expires_at","resend_available_at"}`(이전 살아 있는 행에 `invalidated_at`, 새 행) / `{"status":"rate_limited","resend_available_at"}`(재발송 대기·주소별·전역 중 하나, 행 안 만듦). `signup_code_cancel(p_code_id uuid)` — 메일 발송 실패 시 무효 표시. `signup_code_verify(p_email_hash, p_code_hash, p_ticket_hash, p_email text) RETURNS jsonb` → `{"ok":true,"ticket_expires_at"}` / `{"ok":false,"reason":"mismatch","attempts_left":n}`(+1, 상한이면 무효) / `reason` `expired`·`locked`·`no_code`·**`contact_support`**. 🔴 **번호가 맞으면 같은 주소의 옛 미인증 계정(`email_confirmed_at IS NULL`)을 지운다**(사양서 설계 ① · 경우의 수 12-②) — 다른 기록이 없으면 회원 행 + 인증 계정 둘 다(연쇄 삭제 아님 — 실측), 있으면 확인증을 안 내주고 `contact_support`. 「다른 기록」 판정은 공용 도우미 `_signup_unverified_has_records(uuid) RETURNS boolean` 한 곳(D6 이 같은 것을 쓴다). 원문 이메일은 인증 계정을 찾을 때만 쓰고 저장하지 않는다. 셋 다 정의자 권한 + `search_path=''` + 같은 주소 `pg_advisory_xact_lock`(243 방식). 실행 권한 `service_role` 먼저 부여 → PUBLIC·`anon`·`authenticated` 회수(375 순서)
- **완료 정의:** 서비스 역할로 **각 함수 실제 호출** — 연속 발급 두 번째 `rate_limited`, 틀린 번호 5회 뒤 `locked`, 만료 뒤 `expired`, 옛 미인증 계정(기록 없음)은 삭제·(응모 붙임)은 `contact_support`. `proacl` 맨 앞 `=X/` 없음
- **주의:** 수치는 매번 설정 표에서 읽는다(완료 기준 4-2) · **검문소:** reverb-supabase-expert · reverb-reviewer

### D4 — 번호 기록 정기 삭제 + 예약
- **산출 계약:** `purge_old_signup_email_codes() RETURNS integer`(`postgres` 전용). 예약 `signup-email-codes-retention-daily`, 시각은 선결 9로 빈 자리(제안 03:15 = UTC 18:15). unschedule 후 schedule(166)
- **완료 정의:** 호출 결과 숫자, `cron.job` 1줄, 시각 겹침 없음, **개발·운영 양쪽** 등록
- **롤백:** unschedule 후 함수 삭제

### F1 — 발송·확인 서버 함수 + 메일 양식
- **하는 일:** 비로그인 서버 함수 둘(243 패턴). 발송: 형식 검사 → 정규화 → 해시 → 6자리 암호학적 난수 → `signup_code_issue` → `sent` 일 때만 Brevo → 실패면 `signup_code_cancel` 후 `send_failed`. 확인: 해시 → 확인증 난수 → `signup_code_verify` → 맞으면 확인증 원문 응답
- **산출 계약:** 발송 `{email}` → `{ok:true,status:'sent',code_expires_at,resend_available_at}` / `{ok:true,status:'rate_limited',resend_available_at}` / `{ok:false,error:'invalid_email'|'send_failed'}`. 확인 `{email,code}` → `{ok:true,ticket,ticket_expires_at}` / `{ok:false,reason:'mismatch'|'expired'|'locked'|'no_code',attempts_left?}`. 🔴 **발송 함수는 인증 계정·회원·탈퇴 표를 조회하지 않는다**(완료 기준 10을 구조로 보장). 교차 출처 허용 헤더 + `OPTIONS` 분기 필수. 메일 일본어 + 🔴 회원 메일 4줄 푸터. 동기화 스크립트 **두 자리**(`SYNC_GROUPS` + `templates.ts` 생성 대상)
- **완료 정의:** 개발서버 `supabase functions deploy`(병합으로 반영 안 됨). `OPTIONS` 허용 헤더. 본인 주소로 6자리 메일 + 푸터. 틀림·만료·5회·연속 응답이 계약대로. 함수 로그에 이메일 원문·번호·확인증 없음
- **주의:** Brevo 직접 발송이라 인증 서비스 발송 한도의 보호가 없다 — 전역 상한이 유일한 보호. 🔴 「공개 키 거부」(`rejectPublicKeyCaller`)는 **걸지 않는다**(브라우저가 공개 키로 부르는 함수). 문구는 `reverb-ui-copy`, 한국어 뜻 병기
- **검문소:** reverb-reviewer(교차 출처) · reverb-supabase-expert

### D5 — 가입 관문 트리거(삽입·고쳐 쓰기) + 383 목록 + 비상 끄기 SQL
- **하는 일:** ① `auth.users` BEFORE INSERT. 인증 서비스 역할 삽입만 검사. `NEW.raw_user_meta_data->>'signup_ticket'` 해시 일치·미만료·미사용·같은 이메일(정규화). 맞으면 `ticket_used_at` + `NEW.email_confirmed_at := now()`. 없거나 틀리면 대기 → 통과 / 강제 → RAISE. 대조 중 예외: 대기 → 통과 / 강제 → 거부. 어느 경우든 `signup_ticket` 열쇠 제거. `_strip_signup_meta` 목록에도 추가. 설정 표를 못 읽으면 대기로 보고 통과. ② `auth.users` **BEFORE UPDATE**(고쳐 쓰기 관문 — 경우의 수 12-①·③): `OLD.email_confirmed_at IS NOT NULL` 이면 **아무것도 보지 않고 첫 줄에서 통과**. 미인증 행 + `current_user='supabase_auth_admin'` + (`confirmation_sent_at` 변경 **또는** `recovery_sent_at` 변경)일 때만 강제 → 거부 / 대기 → 통과. 설정 표 못 읽음·판정 중 예외 → **강제여도 통과**(로그인 보호). ③ 비상 끄기·켜기 SQL 4개(`supabase/patches/`) — 고쳐 쓰기 관문 끄기/켜기, 삽입 관문 끄기(🔴 **스위치 대기로 먼저** — 같은 파일 안에서)/켜기
- **산출 계약:** `public._signup_ticket_gate()`(실행자 권한, `current_user = 'supabase_auth_admin'`) · `public._signup_ticket_consume(p_ticket text, p_email text) RETURNS boolean`(정의자 권한, 실행 권한 `supabase_auth_admin` 만) · `trg_signup_ticket_gate` · 열쇠 `signup_ticket`(S1 과 같은 글자) · 서버 로그용 거부 코드 `signup_ticket_required` · `_strip_signup_meta` 재정의(베이스 383, 열쇠 10개) · `public._signup_resend_gate()`(실행자 권한) · `trg_signup_resend_gate`(BEFORE UPDATE) · 거부 코드 `signup_resend_blocked` · 비상 SQL 4개 경로
- **완료 정의(개발서버):** 대기 — 옛 화면 실제 가입 성공, 관리자 초대·감사용·관리자 비밀번호 찾기·회원 재설정·로그인 정상, 초대·감사용 계정은 인증 완료(`417:609`·`179:536~538`), 메타데이터에 `signup_ticket` 없음. 강제 — 확인증 없는 `signUp` 거부·다른 주소 확인증 거부·재사용 거부·초대·감사용·로그인 정상. 대기로 되돌림. 고쳐 쓰기 관문 — 완료 기준 13(①~⑤ · 거부 뒤 옛 계정 비밀번호 해시 불변)·14(설정 표 못 읽을 때 가입·재가입·재설정 요청 통과 + 인증 회원 로그인)·15(비상 끄기·켜기 SQL 이 실제로 듣는다). 🔴 14·15 는 **개발서버 적용 뒤·운영 적용(O1) 전**
- **주의:** 🔴 고쳐 쓰기 관문은 **로그인·토큰 갱신마다 도는 자리**다 — 조건이 틀리면 스위치로 안 풀리고 비상 SQL 로 끈다. 🔴 틀리면 **가입 전면 중단** — 실제 가입으로 확인(SQL 편집기로는 인증 서비스 역할 재현 불가, 383 선례). 🔴 `auth.uid() IS NULL` 통과 조항 금지(362 관례). 362 적용 시 BEFORE INSERT 트리거 둘 — 주석에 적음. 420 무변경
- **검문소:** reverb-supabase-expert(필수) · reverb-reviewer · **롤백:** 1차 `mode='standby'`, 2차 트리거 삭제

### D6 — 미인증 계정 정기 삭제 함수(예약 없음)
- **하는 일:** `COALESCE(confirmation_sent_at, created_at)` 뒤 `unverified_purge_days` 경과·`email_confirmed_at IS NULL` 계정(🔴 생성 시각만 보면 재가입으로 방금 링크를 받은 사람이 지워진다 — 사양서 설계 ⑤). 다른 기록 있으면 건너뜀, 없으면 회원 행 + 인증 신원 + 인증 계정 삭제(253:139~141 순서). 실행마다 실행 기록 1행
- **산출 계약:** `purge_unverified_accounts() RETURNS jsonb` → `{deleted_count, skipped_count, skipped_ids}`(정의자 권한, `postgres` 만). 「다른 기록」 판정은 D3 의 `_signup_unverified_has_records` 를 그대로 쓴다(최소 `applications`·`deliverables`·`settlements`·`application_messages`·`event_tickets`·`withdrawal_requests`·`influencer_flags`. 🔴 `policy_notice_log` 는 넣지 않는다 — 함께 지워진다, 선결 3). 관리자·감사용 제외. 한 계정 실패해도 계속(실패 건은 건너뛴 목록)
- **완료 정의:** 시험 미인증 계정 2개(하나는 응모 붙임, 가입 시각 과거로) → 하나 삭제·하나 건너뜀·실행 기록 1행. 예약 등록 안 함
- **주의:** 🔴 「인증」은 이메일 인증만(관리자 인증/위반/블랙리스트와 무관). 지운 주소는 재가입 가능(361 표에 넣지 않음)
- **검문소:** reverb-supabase-expert(필수) · reverb-reviewer

### O1 — 단계 1 운영 적용
- D1~D6 운영 순서 적용(파일마다 확인 조회, 편집기 경고 판정 함께 안내) → F1 운영 배포 → 대기 유지 → 옛 화면 운영 가입 1회(시험 주소, 끝나면 `delete_admin_completely`)
- **완료 정의:** 운영 `cron.job` 에 번호 기록 예약 1줄만, 옛 화면 가입은 확인 메일 → 링크 인증(지금과 같음), 관리자 로그인·비밀번호 찾기 정상
- **주의:** 화면이 안 바뀌어 10/6 창구와 무관하게 먼저 가능. 🔴 개발서버는 「확인 메일」 꺼짐·운영은 켜짐 — 운영 확인이 진짜 검증 · **롤백:** 트리거 삭제

### P1 — 방침 두 줄 개정 + 시행 7일 전 공지
- 방침 한·일에 ①인증번호 처리(해시만 30일) ②인증 안 마친 가입 신청 7일 뒤 파기 — 🔴 다른 기록 있는 계정은 남긴다(D6 와 어긋나지 않게). 갱신일·시행일·부칙. 앱 안 공지 `POLICY_NOTICE` 새 `id`(10/6 창구 공지 뒤). 메일 통지는 선결 7
- **산출 계약:** 시행일 = 공지 시작일 + 7일 이상
- **검문소:** `/약관확인` · reverb-reviewer · 사용자 문구 확인(일본어에 한국어 뜻)
- **병렬:** D·F 와 ✅, S1 과 ✗(`shared.js`·번역 파일) — S1 착수 전에 dev 병합

### S1 — 가입 화면
- 사양서 설계 ③ 전부. 「認証する」(인증하기) → 번호 칸(`inputmode="numeric"`·`autocomplete="one-time-code"`·16픽셀 이상) + 「確認」(확인) + 남은 시간. 만료 → 비활성 + 「再送信」(재발송), 대기 중 남은 초. 발송 제한 → 「しばらくしてから再送信してください」(잠시 후 다시 보내 주세요) + 시각까지 비활성(열린 칸 유지·처음이면 안 엶). 확인 → 「認証済み」(인증됨) + 이메일 잠금 + 「変更」(변경). 「登録する」(가입하기)는 확인증 있고 만료 전만. 가입 뒤 갈래 넷(신원 목록 빔 → 일반 실패 + 「ログイン」·「パスワードを忘れた方」 안내·픽셀 없음 / 세션 있음 → 로그인 상태 / 세션 없고 인증 완료 → `signInWithPassword`, 실패 시 「登録が完了しました。ログインしてください」(가입 완료, 로그인해 주세요) / 세션 없고 미인증 → `#signupConfirmMsg`). 픽셀 인증 완료면 `confirmed` 1회, 그 밖 `pending_email`. 픽셀 설명표 두 줄. **픽셀 새로고침 보류 짝**(위 어긋남 ⑪ — `signUp` 직전 `metaPixelHoldReload()`, 일반 회원으로 끝나면 `metaPixelReleaseReload()`)
- **산출 계약:** storage `requestSignupCode(email)` → `{status,codeExpiresAt,resendAvailableAt}` · `{error}` · 통신 실패 `null` / `verifySignupCode(email, code)` → `{ok,ticket,ticketExpiresAt,reason,attemptsLeft}` · 통신 실패 `null`. `signUp` `options.data.signup_ticket`. DOM id `signupEmailVerifyBtn`·`signupCodeArea`·`signupCodeInput`·`signupCodeConfirmBtn`·`signupCodeTimer`·`signupCodeResendBtn`·`signupCodeMsg`·`signupEmailVerified`·`signupEmailChangeBtn`(기존 `signupEmail`·`signupBtn`·`signupError`·`signupConfirmMsg`·`signupFormArea` 유지). 번역 키 `auth.signup.code.verifyBtn`·`.resendBtn`·`.resendWait`·`.placeholder`·`.confirmBtn`·`.remaining`·`.expired`·`.verified`·`.changeBtn`·`.mismatch`·`.locked`·`.rateLimited`·`.sent`·`.sendFailed`·`.ticketExpired`·`auth.signup.doneLogin`·`authError.alreadyRegisteredHint`
- **완료 정의:** 완료 기준 1·2·3·5·5-2·8·9·11 화면 재현(Q1), 화면 코드에 유효 시간 숫자 없음
- **주의:** 🔴 탈퇴 재가입 대조(`isEmailWithdrawalBlocked`)는 **가입 직전 그대로**. 도메인 오타 점검은 「認証する」 앞에서도 권고. 🔴 문의 창구가 고친 dev 판 위에서. 핫스팟 병렬 금지. 새 파일이면 `build.sh` 두 자리 — 권고는 `auth.js` 안에
- **검문소:** `reverb-ui-copy` · 디자인 스킬(Apple 지침, 44pt) · reverb-reviewer · reverb-supabase-expert(storage.js)

### Q1 — 개발서버 검증
- 완료 기준 1~11 차례로. 8·9는 「확인 메일」 잠깐 켜고 끈다. 8 대조 실패 갈래는 대기에서 확인증 일부러 틀리게. 4-2는 수치 SQL 변경 후 되돌림. 6은 강제·대기·강제
- **완료 정의:** 11개 관찰 기록(12는 O3), 대기·「확인 메일」 꺼짐 복구 · **검문소:** reverb-qa-tester 권장(단일 세션) · 크롬은 마우스 이동 · SQL 편집기 탭은 `force` 이동 후 닫기

### O2 — 단계 2 운영 반영
- **선행:** Q1 · 10/6 창구 운영 반영 뒤 · P1 시행일 경과 · 선결 6 · 사용자 확인
- **완료 정의:** 운영 시험 주소로 새 화면 가입 → 추가 동작 없이 로그인, 픽셀 `confirmed` 1건(**브라우저 경로 기준** — 어긋남 ⑩), 생년월일·동의 시각 있음, 메타데이터 깨끗(완료 기준 8·11). `curl -sL` + md5. 시험 계정 정리
- **주의:** 골라 담기 구간(9/29~10/5)에는 병합하지 않는다

### O3 — 단계 3 강제 + 정기 삭제 켜기
- `mode='enforce'` → 운영 가입 1회 → 7일 지난 미인증 조회(①전부 미인증 ②기간 경과 ③다른 기록 건수 — ③이 있어도 멈추지 않음) → 예약 등록(마이그레이션 ⑦, `unverified-accounts-purge-daily`, 제안 03:30 = UTC 18:30) → 첫 실행 확인
- **완료 정의:** 완료 기준 6·7·12. 첫 실행 뒤 「기간 지난 미인증 − 건너뜀」 = 0, 실행 기록 1행
- **주의:** 대상이 40건보다 많을 수 있음(정상). 🔴 문제 나면 즉시 대기 · **롤백:** 대기 + unschedule

### M1 — 단계 4 측정
- `verified_at - created_at` 중앙값·상위 95%, 만료 재발송 비율 보고 → 사용자 결정 시 설정 값만 변경. 보관 30일·삭제 7일은 방침 절차 없이 변경 금지

---

## ⚠️ 공유 지점 경고
1. 핫스팟 `dev/lib/storage.js`·`dev/lib/shared.js` — S1·P1 이 고친다. 다른 세션과 병렬 금지
2. 가입 화면 파일 = 일반 문의 창구 파일 — 운영 반영은 창구(10/6) → 이 기능
3. `auth.users` 트리거 — 개발서버 지금 둘(`on_auth_user_created`·`on_auth_user_updated_strip_signup_meta`). D5 가 셋째, 362(미적용)가 넷째 후보. 실수하면 가입·로그인이 통째로 멈추는 자리
4. 지우는 열쇠 목록 — 정본 `_strip_signup_meta`(383), 사본 `420:149~154`·`383:119`. D5 는 정본과 관문에만
5. 메일 동기화 스크립트 두 자리 + 양식 카탈로그
6. 메타 픽셀 세 곳 한 세트(상수·설명표 ↔ 사양서 표 ↔ 방침 §8.1)
7. 앱 안 공지 틀 하나(`POLICY_NOTICE`) — 창구 공지와 시간 순으로만 공유
8. 예약 시각 — 새벽 붐빔, 대시보드 등록 예약도 확인
9. 서버 함수 배포는 git 병합과 따로 — 데이터베이스 → 함수 → 화면

## 🧭 배분 제안
- **개발 세션 1곳 순차**: D1 → D2 → D3 → D4 → F1 → D5 → D6 → O1 → S1 → Q1 → O2 → O3 → M1(데이터베이스 조각 번호 충돌 방지, S1 은 F1·D5 계약을 그대로 써야 함)
- **P1** 만 병렬 가능(파일이 D·F 와 안 겹침). 단 S1 착수 전에 dev 병합. 공지 교체는 10/6 뒤
- 날짜 경로: O1 은 사용자 확인 뒤 언제든 → P1 공지 10/6 뒤 → 시행 = 공지 + 7일 이상(가장 이르면 10/14 무렵) → O2 → O3(다음 날 이후) → M1(2~4주)
- 기획으로: 선결 2(문장 정정) · 선결 3(다른 기록 목록) · 선결 4 실측 결과 판단

## 매핑표 — 사양서 단계 → 조각
| 단계 | 조각 |
|---|---|
| 0(완료) | 선결 0 |
| 1 서버(대기) | D1·D2·D3·D4·F1·D5·D6·O1 |
| 2 화면 | P1·S1·Q1·O2 |
| 3 운영 전환 | O3 |
| 4 측정 | M1 |

## 매핑표 — 완료 기준 → 조각
| 완료 기준 | 구현 | 검증 |
|---|---|---|
| 1 인증 → 번호 → 확인 → 인증됨, 가입 단추 활성 | F1·S1 | Q1·O2 |
| 2 확인 전·확인증 만료 뒤 비활성 | S1 | Q1 |
| 3 유효 시간 경과 → 재발송, 옛 번호 거부 | D3·F1·S1 | Q1 |
| 4 틀린 횟수 상한 → 무효 | D3·F1·S1 | Q1 |
| 4-2 설정 수치 변경이 배포 없이 반영 | D1·D3·F1·S1 | Q1 |
| 5 변경 → 인증 풀림 | S1 | Q1 |
| 5-2 발송 제한 응답·단추 비활성 | D3·F1·S1 | Q1 |
| 6 강제·대기 동작과 전환 | D1·D5 | Q1·O3 |
| 7 초대·감사용·비밀번호·로그인 정상 | D5 | Q1·O1·O3 |
| 8 새 화면 가입 → 바로 로그인 / 대조 실패 갈래 | D5·S1 | Q1·O2 |
| 9 이미 가입된 주소 안내 | F1·S1 | Q1 |
| 10 발송 응답으로 존재·탈퇴 구분 불가 | F1 | Q1 |
| 11 픽셀 `confirmed` 1건 | S1 | Q1·O2 |
| 12 정기 삭제 첫 실행·실행 기록 | D2·D6·O3 | O3 |
| 13 미인증 주소 재가입·재설정(①옛 계정 정리 ②강제 거부 ③인증 회원 무관 ④문의 안내 ⑤재설정 요청 거부) | D3·D5·S1(⑤ 화면 문구 — 어긋남 ⑬) | Q1(① ④) · D5 개발서버(② ③ ⑤) · O3 |
| 14 설정 표를 못 읽을 때 통과 | D5 | D5 개발서버(O1 전) |
| 15 비상 끄기·켜기 SQL | D5 | D5 개발서버(O1 전) |
