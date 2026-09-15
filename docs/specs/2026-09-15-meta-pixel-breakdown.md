# 📋 작업 분해표 — 메타 픽셀 도입 + 관리자 「광고 추적」 화면
**사양서:** docs/specs/2026-09-03-meta-pixel.md
**분해일:** 2026-09-15
**총 작업 조각:** 16개 · **병렬 가능:** 7개 · **순차 필수:** 9개

> 이 작업표는 **누가·무엇을·어떤 순서로·어디서 겹치나**만 적는다. 설계의 단일 소스는 사양서다.
> 코드 줄 번호는 `origin/dev` `de840634` 기준으로 확인했다(2026-09-15 메인 세션이 `origin/dev` 에서 표본 재확인). **착수 전에 최신본을 받고 줄 번호를 다시 볼 것.**

---

## 🚦 착수 전 선결 조건 (작업표보다 먼저)

| # | 선결 조건 | 근거 | 막는 조각 |
|---|---|---|---|
| 1 | 작업 폴더를 `origin/dev` 최신으로 받기 | 사양서는 개발 브랜치 판을 본다 | 전부 |
| 2 | **다른 세션이 지금 새 마이그레이션을 만들고 있는지 확인**(2026-09-15 기준 마지막 번호 436) | `multi-session.md` 「마이그레이션 번호」 | 1·2 |
| 3 | **개발서버 시험용 메타 픽셀 아이디 1개**(운영과 따로 만든다) | 사양서 「확인이 필요한 것」 ①, 결정 8 | 7·8 |
| 4 | **메타 이벤트 관리자 「테스트 이벤트」 화면을 열 수 있는 사람** 지정(시험용·운영 둘 다) | 1-검증 ①, 4번 운영 확인 | 8·14 |
| 5 | **운영 픽셀 아이디**와 **reverb.kr 과 같은 픽셀을 쓸지** 결정 | 「확인이 필요한 것」 ①② | 13 |
| 6 | **광고 담당자 공유** — 신청 완료 = `SubmitApplication`, 가입은 상태 값으로 둘로 갈림 | 「확인이 필요한 것」 ③ | 13 |
| 7 | **방침 개정 공고일 결정**(시행일 = 공고일 + 30일) | 「확인이 필요한 것」 ④ | 11b·12 |
| 8 | **「앱 안 공지」 수단 결정**(아래 점검 S5) | 사양서 「단계」 2 에 수단이 없다 | 11b |
| 9 | 운영 4번 확인용 **시험 이메일 주소 1개**(가입 뒤 탈퇴 처리) | 「4번 운영 확인」 | 14 |
| 10 | (선택) 법률 자문으로 부록 문안 확인 — **착수·시행을 막지 않는다** | 「확인이 필요한 것」 ⑤ | 없음 |

---

## ⚠️ 사양서 stale 점검 (코드 대조 — 규칙 D)

설계를 바꾸는 것이 아니라 **사양서가 개발에 맡긴 부분을 실제 코드에 대보니 걸린 자리**다.

| # | 사양서가 적은 것 | 실제 코드 | 영향 조각 |
|---|---|---|---|
| **S1** | ⑯ 민감 주소는 셋: `?code=` · `#unsubscribe?token=` · `?invite=` (「더 있을 수 있다 — 개발이 확정」) | 🔴 **더 위험한 둘이 빠져 있다.** ①`#reset-pw?token_hash=…` — 비밀번호 재설정 토큰(`app.js` 18·74·212행 부근). **이 값이면 남의 계정 비밀번호를 바꿀 수 있다** ②옛 방식 재설정 해시 `#access_token=…&type=recovery`(`app.js` 17행) | 5·8·9 |
| **S2** | 민감 값을 「주소」에서 본다 | 자리가 둘이다. `?code=` 는 **검색부**(`location.search`), 초대 번호·수신거부 토큰·재설정 토큰은 **해시 안**(`#detail-{id}?invite=` 등). **두 곳 모두 봐야 한다** | 5 |
| **S3** | 흐름 6 「로그인할 때(`onAuthStateChange` 의 로그인 사건)」 | ①처리기는 `app.js` 492행 부근이고 **`SIGNED_IN` 과 `TOKEN_REFRESHED` 를 한 조건으로** 받는다 ②로그인 화면의 `handleLogin`(`auth.js`)도 따로 `currentUser` 를 세운다. 🔴 사건을 날것으로 걸면 **켜진 탭이 토큰 갱신마다 재조회**하고, 관리자가 픽셀을 끈 뒤라면 **응모서를 쓰던 회원 화면이 새로고침**된다 → 「로그인 사건」 = **로그인 안 된 상태에서 된 상태로 바뀐 순간 한 번**으로 계약(작업 5). 사양서 「로그인할 때」의 해석 범위 안이다 | 5·8 |
| **S4** | 4번 = 「확인 코드 교환이 이번에 성공한 착지」(판별은 개발이 정함) | 지금 착지 분기는 세션 유무로만 가른다. 후보: 「스크립트 로드 때 코드를 봤고(`_signupConfirmCodeSeen`), 434행이 지우기 **전** 주소에 코드가 이미 없다(라이브러리가 교환 성공 시 지운다)」. ⚠️ 이미 쓴 링크일 때 라이브러리가 지우는지는 1-검증 ④ 「로그인된 창」 시험이 가른다 | 6·8 |
| **S5** | 단계 2 「앱 안 공지」 | 수단이 없다. 이미 코드 상수 **`POLICY_NOTICE`**(`shared.js` 1501행, 로그인 직후 팝업 + 홈 배너)와 회원 메일 함수 `notify-policy-change` 가 있다. **팝업·배너만 / 메일까지**는 사용자 결정(메일이면 전 회원 발송 — 되돌릴 수 없다) | 11b |
| **S6** | 권한 두 개를 카탈로그에 더한다 | 한 곳 더 — `PERM_SUPER_SERVER_ENFORCED`(`shared.js` 2001행)에 기능 열쇠말을 안 넣으면 권한 관리 화면 배지가 서버가 막는 설정인데 「화면에서만」으로 틀리게 뜬다 | 3 |
| **S7** | (새 관리자 JS 파일 등록) | 페인 파일은 `dev/admin/index.html` 에 script 태그를 **넣지 않는 것이 관례**(`admin-reports.js` 머리 주석) → `ADMIN_JS_FILES` 한 곳이면 된다. 인플루언서 쪽 배열 이름은 **`CLIENT_JS_FILES`**(`build.sh` 27행) | 3 |
| **S8** | 흐름 2 「방문자 집계와 같은 자리 — `app.js` 466행」 | 맞다. 4번 착지 판정(432행)은 그보다 앞이라 4번은 반드시 판정 전 줄에 쌓인다 — 사양서 흐름 5와 일치 | 5·6 |

---

## 한눈에 보는 의존 순서

```
[선결 1·2] ─┬─ 작업 1 (마이그레이션 ①) ──→ 작업 2 (마이그레이션 ② 권한 시드) ─┐
            │                                                              │
            └─ 작업 3 (공용 토대) ──┬─ 작업 4 (관리자 페인) ──────────────────┤
                                     └─ 작업 5 (공용 전송 함수·흐름) → 작업 6 (이벤트 5개) ─┤
                                                                                         ↓
                        작업 7 (1a 개발서버 반영 + 문서) → 작업 8 (1-검증) → 작업 9 (1b 반영)
                                                                                         ↓
작업 11a (방침 문안 확정 — 언제든) ························→ 작업 10 (운영 배포 — 전송 0)
                                                                                         ↓
                        작업 11b (방침 공고 + 앱 안 공지) → 작업 12 (운영 시행일 입력)
                                                                                         ↓
                        [시행일 도래] → 작업 13 (운영 아이디·켜기) → 작업 14 (4번 운영 확인) → 작업 15 (실무자 가이드)
```

---

## 작업 조각 표

| 번호 | 제목 | 담당 파일 | 산출 계약 | 선행 | 병렬? | 담당 |
|---|---|---|---|---|---|---|
| 1 | 신규 마이그레이션 ① 설정 표·이력 표·변경 트리거·함수 셋 | `supabase/migrations/신규①_meta_pixel_settings.sql` | 표 `meta_pixel_settings`·`meta_pixel_settings_history`, 트리거 함수 `record_meta_pixel_settings_history()`, 함수 `get_meta_pixel_admin()`·`update_meta_pixel_settings(text, boolean)`·`get_public_meta_pixel_id()` (제안) | 선결 1·2 | ✓ (3과 동시) | 개발(데이터베이스) |
| 2 | 신규 마이그레이션 ② 권한 시드 | `supabase/migrations/신규②_ad_tracking_permission_seed.sql` | 열쇠말 `menu.ad-tracking`·`ad_tracking.manage` × 3등급 (제안) | 1 | ✓ (3·4와 동시) | 개발(데이터베이스) |
| 3 | 공용 토대 — 상수·권한 카탈로그·조회 함수·빌드 등록 | `dev/lib/shared.js` · `dev/lib/storage.js` · `dev/build.sh` · `dev/index.html` · 빈 파일 `dev/js/admin-ad-tracking.js`·`dev/js/meta-pixel.js` | `META_PIXEL_EVENTS`·`META_PIXEL_REG_STATUS`·`META_PIXEL_EVENT_TABLE`, `PANE_REFRESHERS['ad-tracking']`, storage 함수 3개 (제안) | 선결 1 | ✓ (1·2와 동시) | 개발 1 |
| 4 | 관리자 「광고 추적」 페인 | `dev/js/admin-ad-tracking.js` · `dev/js/admin-core.js`(로더 1줄) · `dev/admin/index.html` | 페인 id `ad-tracking`, DOM `adminPane-ad-tracking`·`adminAdTrackingSi`, 로더 `loadAdTrackingPane` (제안) | 3 (브라우저 확인은 1·2 뒤) | ✓ (5·6과 동시) | 개발 1 |
| 5 | 인플루언서 앱 공용 전송 함수 + 흐름 1~7 + 민감 주소 판정 | `dev/js/meta-pixel.js` · `dev/js/app.js` · `dev/js/auth.js` | `initMetaPixel()`·`trackMetaPixelEvent(name, params)`·`notifyMetaPixelSignedIn()`·`metaPixelUrlHasSensitiveValue()` (제안) | 3 | ✓ (4와 동시) | 개발 2 |
| 6 | 이벤트 호출 5개 | `dev/js/application.js` · `dev/js/auth.js` · `dev/js/app.js` | 5호출 전부 `trackMetaPixelEvent` 경유 | 5 | ✓ (4와 동시) | 개발 2 |
| 7 | 1a 개발서버 반영 + 문서 한 세트 | 개발 데이터베이스(①②) · `CLAUDE.md` · `docs/FEATURE_SPEC.md` · 사양서 「구현 결과」 | 개발서버에 시험용 아이디·과거 시행일 | 2·4·6 + 선결 3 | ✗ | 개발 1 |
| 8 | 1-검증 (①~⑦) | 코드 변경 없음 — 결과 기록 | 사양서 「구현 결과」 결과표 | 7 + 선결 4 | ✗ | 개발(QA 단일 세션) + 사용자 |
| 9 | 1b 반영 — 수동 페이지뷰 자리·민감 주소 누출 막기 | `dev/js/meta-pixel.js` · `dev/js/app.js` · `dev/js/application.js` · (새면) `dev/js/campaign.js` | 8 결과에 따라 확정 | 8 | ✗ | 개발 2 |
| 10 | 운영 배포(1b) — 전송 0 상태 | 운영 데이터베이스(①②) · `dev→main` | 운영 시행일 NULL, 앱용 조회 빈 값 | 9 | ✗ | 개발 + **사용자 승인** |
| 11a | 방침 개정 문안 확정 | 사양서 부록 | 부록 문안 = 「심는 이벤트」 표·결정 9·결정 11 | 없음 | ✓ | 기획 |
| 11b | 방침 개정 공고 + 앱 안 공지 | `docs/PRIVACY_{kr,ja}.md` · (S5 결정) `dev/lib/shared.js` `POLICY_NOTICE` | §8.1 신설 · §5 한 줄 · 부칙 | 10 · 11a + 선결 7·8 | ✗ | 개발 + 사용자 |
| 12 | 운영 설정 표에 시행일 입력 | 운영 SQL 편집기 한 줄 | 이력에 「시스템(직접 입력)」 1행 | 11b | ✗ | 사용자 |
| 13 | 시행일 이후 운영 아이디 저장·켜기 | 운영 관리 화면 | 배지 `켜짐 — 전송 중` | 12 + 시행일 + 선결 5·6 | ✗ | 사용자(캠페인관리자 이상) |
| 14 | 4번 운영 확인 + 시험 계정 탈퇴 | 운영 실제 가입 1건 | 테스트 이벤트에 `CompleteRegistration`(`confirmed`) | 13 + 선결 4·9 | ✗ | 사용자 + 개발 |
| 15 | Notion 실무자 가이드 「광고 추적」 | Notion 「관리자 가이드」 | 화면 이름·배지 4종·잠금 규칙 | 13 | ✗ | 개발 |

※ 병렬 가능 7개 = 1·2·3·4·5·6·11a (5→6은 같은 세션에서 순서대로, 둘 다 4와 동시 가능)

---

## 조각별 상세

### 작업 1 — 신규 마이그레이션 ① 설정 표·이력 표·변경 트리거·함수 셋

- **하는 일:** 한 줄짜리 설정 표, 추가만 하는 이력 표, 이력을 쓰는 변경 트리거, 함수 셋.
- **담당 파일:** `supabase/migrations/신규①_meta_pixel_settings.sql` (번호는 만드는 순간 확정)
- **산출 계약** (이름은 전부 제안):
  - **설정 표 `public.meta_pixel_settings`** — `id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1)` · `meta_pixel_id text NULL CHECK (meta_pixel_id IS NULL OR meta_pixel_id ~ '^[0-9]+$')` · `enabled boolean NOT NULL DEFAULT false` · `policy_effective_date date NULL` · `updated_at timestamptz NOT NULL DEFAULT now()` · `updated_by uuid NULL`. 시드 1행(아이디 NULL·꺼짐·시행일 NULL). 🔴 **시행일을 바꾸는 함수는 만들지 않는다**
  - **이력 표 `public.meta_pixel_settings_history`** — `id bigserial` · `at timestamptz DEFAULT now()` · `actor uuid NULL` · `actor_name text NULL` · `prev_/next_meta_pixel_id` · `prev_/next_enabled` · `prev_/next_policy_effective_date`
  - **변경 트리거** `trg_meta_pixel_settings_history`(AFTER UPDATE) → `record_meta_pixel_settings_history()` — 소유자 권한 실행 + `SET search_path = ''`. 세 칸 중 하나라도 바뀌었을 때만 기록. `actor = auth.uid()`(비면 NULL → 화면 「시스템(직접 입력)」). 🔴 `updated_by` 를 옮겨 적지 않는다
  - **행 단위 보안 정책:** 두 표 모두 켜고 조회는 `(SELECT public.is_admin())`, **쓰기 정책 없음**
  - **`get_meta_pixel_admin() RETURNS jsonb`**(관리자) — `{meta_pixel_id, enabled, policy_effective_date, updated_at, status, history:[최근 50건, actor_name 포함]}`. `status` 판정 순서: `policy_locked` → `no_pixel_id` → `disabled` → `active`
  - **`update_meta_pixel_settings(p_meta_pixel_id text, p_enabled boolean) RETURNS jsonb`** — 가드 `has_permission('ad_tracking.manage','write')`(🔴 `is_campaign_admin()` 금지). 빈 문자열은 NULL, 숫자가 아니면 `invalid_pixel_id`. `FOR UPDATE` 잠금. **`OLD.enabled = false AND p_enabled = true AND NOT (판정식)`** 일 때만 `policy_not_in_effect` 거부 — 켜짐 유지 상태의 아이디 저장·끄기는 항상 허용
  - **`get_public_meta_pixel_id() RETURNS text`**(비로그인·로그인) — ①켜짐 ②아이디 있음 ③판정식 참 ④부른 사람이 관리자·감사용 계정 아님(332 방식) — 넷 다 참일 때만 아이디, 아니면 `''`. 설정 표를 통째로 열지 않는다
  - 🔴 **판정식 세 곳 글자 그대로 같게:** `policy_effective_date IS NOT NULL AND policy_effective_date <= (now() AT TIME ZONE 'Asia/Tokyo')::date`
  - **실행 권한:** 앱용 조회만 `REVOKE ALL … FROM PUBLIC` 뒤 `GRANT EXECUTE … TO anon, authenticated`. 나머지 둘은 PUBLIC·anon 회수 + `authenticated` 부여. 트리거 함수는 셋 다 회수
  - 선례: `426_quote_settings.sql` · `353`(`is_withdrawal_open`) · `332`(관리자·감사용 제외)
- **선행 의존:** 선결 1·2
- **완료 정의:** 개발 데이터베이스 적용 후 표 2개·시드 1행 / 앱용 조회가 `''` / 관리자 브라우저 콘솔에서 `get_meta_pixel_admin()` 이 `status='policy_locked'` / SQL 편집기로 시행일을 넣으면 이력에 `actor IS NULL` 1건(확인 뒤 NULL로 되돌림) / **함수 셋 각각 1회 실제 호출**
- **필요 검문소:** reverb-supabase-expert(권한 회수 방향 둘·판정식 3곳·트리거 경로) · reverb-reviewer
- **주의·롤백:** 적용 성공 ≠ 동작 확인. 관리자 가드는 SQL 편집기로 재현되지 않는다. 롤백은 함수 셋 → 트리거 → 표 둘 순서로 삭제(읽는 코드가 없으면 영향 0)

### 작업 2 — 신규 마이그레이션 ② 권한 시드

- **하는 일:** 권한 열쇠말 두 개를 세 등급에 넣는다.
- **담당 파일:** `supabase/migrations/신규②_ad_tracking_permission_seed.sql`
- **산출 계약:** `INSERT INTO public.role_permissions (role, feature_key, access_level, default_level) … ON CONFLICT (role, feature_key) DO NOTHING;` + `NOTIFY pgrst, 'reload schema';`
  - `menu.ad-tracking` — 슈퍼관리자 write/write · 캠페인관리자 write/write · 캠페인매니저 **read/read**
  - `ad_tracking.manage` — 슈퍼관리자 write/write · 캠페인관리자 write/write · 캠페인매니저 **hidden/hidden**
  - 선례: `355_withdrawal_proxy_permission_seed.sql` · `404_report_permission_seed.sql`
- **선행 의존:** 1
- **완료 정의:** 6행 조회 / 등급별 로그인 콘솔에서 `has_permission('ad_tracking.manage','write')` = 슈퍼·캠페인관리자 true, 캠페인매니저 false
- **필요 검문소:** reverb-supabase-expert · reverb-reviewer
- **주의·롤백:** **작업 4 화면과 같은 배포에** — 화면은 설정을 못 읽으면 쓰기로 열고 서버는 거부하므로 시드가 빠지면 「버튼은 보이는데 누르면 거부」. 롤백은 해당 열쇠말 삭제(작업 1 저장 함수를 먼저 막은 뒤)

### 작업 3 — 공용 토대 (핫스팟 파일 한 번에)

- **하는 일:** 두 앱이 함께 쓰는 상수·권한·조회 함수·빌드 등록을 한 조각에서 끝낸다 — 뒤 조각이 핫스팟 파일을 다시 열지 않게.
- **담당 파일:** `dev/lib/shared.js` · `dev/lib/storage.js` · `dev/build.sh` · `dev/index.html` · 빈 뼈대 `dev/js/admin-ad-tracking.js`·`dev/js/meta-pixel.js`
- **산출 계약** (이름은 전부 제안):
  - `shared.js`
    - `META_PIXEL_EVENTS = { PAGE_VIEW:'PageView', VIEW_CONTENT:'ViewContent', COMPLETE_REGISTRATION:'CompleteRegistration', SUBMIT_APPLICATION:'SubmitApplication' }`
    - `META_PIXEL_REG_STATUS = { PENDING_EMAIL:'pending_email', CONFIRMED:'confirmed' }`
    - `META_PIXEL_EVENT_TABLE` — 관리 화면 표용 5행 `{event, when_ko, params_ko}`. 사양서 「심는 이벤트」 표·방침 부록 「송신되는 정보」와 **같은 목록**
    - `ADMIN_PERMISSION_CATALOG` 두 줄: `{ key:'menu.ad-tracking', label_ko:'광고 추적', category:'관리자 설정', server_enforced:false }` · `{ key:'ad_tracking.manage', label_ko:'광고 추적 켜기·끄기·픽셀 아이디 저장', category:'관리자 설정', server_enforced:true }` — 머리 주석 개수도 함께
    - `PERM_SUPER_SERVER_ENFORCED` 에 `'ad_tracking.manage'` (S6)
    - `PANE_REFRESHERS['ad-tracking'] = async () => { if (typeof loadAdTrackingPane === 'function') await loadAdTrackingPane(); }`
  - `storage.js` — `fetchMetaPixelAdmin()`(실패 `null`) · `updateMetaPixelSettings(pixelId, enabled)` → `{ok, error_code}` · `fetchPublicMetaPixelId()`(문자열, `''` 포함, 실패 `null`) 🔴 실패와 빈 값 구분
  - `build.sh` — `ADMIN_JS_FILES` 에 `js/admin-ad-tracking.js`(`admin-core.js` 뒤·`admin.js` 앞) · `CLIENT_JS_FILES` 에 `js/meta-pixel.js`(`lib/storage.js` 뒤·`js/campaign.js` 앞)
  - `dev/index.html` 에 `<script src="js/meta-pixel.js"></script>` 한 줄. 🔴 `dev/admin/index.html` 에는 태그를 넣지 않는다(S7)
- **선행 의존:** 선결 1 (작업 1과는 이름 계약만 공유)
- **완료 정의:** `bash dev/build.sh` 무오류 / 두 산출물에 새 파일이 이어 붙고 죽은 script 태그 0 / 권한 관리 화면에 두 항목, 기능 항목 배지 「서버 차단」
- **필요 검문소:** reverb-reviewer
- **주의·롤백:** 핫스팟 파일 — **다른 세션과 병렬 금지**, 병합 직전 `origin/dev` 받기. **이 조각이 먼저 `dev` 에 병합돼야** 4·5가 작업 폴더를 나눌 수 있다

### 작업 4 — 관리자 「광고 추적」 페인

- **하는 일:** 사양서 「관리 화면 — 화면 구성」 1~6.
- **담당 파일:** `dev/js/admin-ad-tracking.js` · `dev/js/admin-core.js`(`switchAdminPane` 로더에 `'ad-tracking': loadAdTrackingPane`) · `dev/admin/index.html`(「관리자 설정」 묶음에 `<div class="admin-si" data-pane="ad-tracking" id="adminAdTrackingSi" onclick="navAdminPaneReload('ad-tracking')">` + 머티리얼 아이콘 `translate="no"` / 빈 페인 `<div id="adminPane-ad-tracking" class="admin-pane"></div>`)
- **맞출 기존 화면:** 뼈대 `admin-reports.js` · 설정값+이력 `admin-lookups.js` `renderQuoteSettingsTable` · 실패 사유 코드별 문구 `admin-influencers.js` 탈퇴 대행 카드 · 시각 `formatDateTime` · 표 `admin-card` → `admin-table-wrap` → `data-table`
- **산출 계약:**
  - 상태 배지 4종 — 서버 `status` 그대로(🔴 화면이 날짜 비교 안 함): `방침 시행 전 — 전송 안 됨 (시행일: 미정 또는 날짜)` / `아이디 없음` / `꺼짐` / `켜짐 — 전송 중`
  - 개발서버 경고 「운영 아이디를 넣지 마세요 — 시험용 픽셀만」 — `IS_STAGING` 으로 판정(새로 만들지 않는다)
  - 켜기 확인 창 문구 · `policy_locked` 이면 켜는 방향만 비활성(켜짐 값이면 끄기 허용) · 끄기는 확인 없이
  - 저장 뒤 공통 안내(켜기·끄기·아이디 저장): 「새로 들어오는 방문부터 적용됩니다. 이미 열려 있는 화면은 새로고침 전까지 이전 설정으로 동작할 수 있습니다」
  - `canWrite('ad_tracking.manage')` 거짓이면 입력·스위치·저장 **비활성** + 「변경 권한이 없습니다」(숨기지 않는다)
  - 이벤트 표는 `META_PIXEL_EVENT_TABLE` / 확인 방법 안내 / 변경 이력(누가 NULL → 「시스템(직접 입력)」)
  - 저장 뒤 `await refreshPane('ad-tracking')`
  - 거부 코드 `policy_not_in_effect`·`invalid_pixel_id`·권한 거부는 **각각 다른 문구**
  - `fetchMetaPixelAdmin()` 이 `null` 이면 「불러오지 못했습니다」, 스위치 안 그림
- **선행 의존:** 3 (브라우저 확인은 1·2 적용 후)
- **완료 정의(개발서버, 등급별 로그인):** 슈퍼·캠페인관리자 편집 가능 / 캠페인매니저 비활성+문구 / 시행일 NULL이면 켜기 비활성 / 아이디 저장 시 이력 1행·안내·다시 그리기 / 사이드바 클릭 시 빈 화면 아님
- **필요 검문소:** reverb-reviewer · reverb-qa-tester(권장, 단일 세션)
- **주의·롤백:** `admin-core.js`·`admin/index.html` 핫스팟 — 다른 관리자 작업 세션과 동시에 열지 않는다. 🔴 관리자 앱에 픽셀 코드를 넣지 않는다(사양서 ⑥)

### 작업 5 — 인플루언서 앱 공용 전송 함수 + 흐름 1~7 + 민감 주소 판정

- **하는 일:** 사양서 「인플루언서 앱 쪽 흐름」 1~7과 ⑯을 한 파일의 상태 기계로.
- **담당 파일:** `dev/js/meta-pixel.js` · `dev/js/app.js`(466행 방문자 집계 바로 뒤 `initMetaPixel()` · 로그인 전이 훅) · `dev/js/auth.js`(`handleLogin` 의 `currentUser` 설정 직후 같은 훅 1줄)
- **산출 계약** (이름은 전부 제안):
  - 상태 `_metaPixelState` ∈ `'pending'`/`'on'`/`'off'` · 줄 `_metaPixelQueue` · 로그인 순번 `_metaPixelLoginSeq`
  - `initMetaPixel()` — 흐름 1(`preview-mode` → `'off'`) → 흐름 2(`metaPixelUrlHasSensitiveValue()` 참이면 조회 없이 `'off'`) → 아니면 `fetchPublicMetaPixelId()` 1회
  - `metaPixelUrlHasSensitiveValue()` — **판정은 이 함수 한 곳.** `location.search` 와 `location.hash` **둘 다**(S2). 대상: `code` · `invite` · `unsubscribe` 해시의 `token` · **`reset-pw?token_hash`** · **`access_token`/`type=recovery`**(S1)
  - 흐름 3·4 — 아이디면 픽셀 불러오기·초기화(페이지뷰 1회) → `'on'` → 줄 보냄 / `''`·`null` 이면 `'off'` → 줄 비움. 🔴 고급 매칭 인자 없음(결정 11)
  - `trackMetaPixelEvent(name, params)` — `'pending'` 줄 / `'on'` 보냄 / `'off'` 버림
  - `notifyMetaPixelSignedIn()` — 흐름 6. 🔴 **「로그인 안 된 상태 → 된 상태」 전이 순간 한 번만**(`TOKEN_REFRESHED`·반복 `SIGNED_IN` 제외, S3). 흐름 2 전이면 무시 / 조회 중이면 순번만 올림 / `'off'` 무시 / `'on'` 이면 `'pending'` 으로 돌리고 재조회 → 아이디면 `'on'`, 빈 값·실패면 `location.reload()`
  - 흐름 7 — 응답(성공·실패)을 받았을 때 보낸 뒤 로그인 순번이 올랐으면 결과를 쓰지 않고 한 번 더 조회
  - 🔴 어떤 실패도 화면을 막지 않는다 — `try/catch` 로 삼키고 필요하면 `logAppError`
- **선행 의존:** 3
- **완료 정의(시험 아이디 없이):** 시행일 NULL에서 네트워크 탭에 `get_public_meta_pixel_id` 1회·`connect.facebook.net` 0건 / `?preview=1` 이면 조회 0건 / `#unsubscribe?token=x`·`#reset-pw?token_hash=x` 로 열면 조회 0건 / 탭을 오래 띄워 토큰이 갱신돼도 재조회·새로고침 없음
- **필요 검문소:** reverb-reviewer(흐름 1~7 대조·실패와 빈 값 구분·전역 이름 충돌) · reverb-supabase-expert(비로그인 호출 경로)
- **주의·롤백:** `app.js`·`auth.js` 는 6·9도 만진다 — **같은 세션에서 순서대로**. 호출부는 전부 `typeof trackMetaPixelEvent === 'function'` 가드(작업 6)

### 작업 6 — 이벤트 호출 5개

- **담당 파일:** `dev/js/application.js` · `dev/js/auth.js` · `dev/js/app.js`
- **산출 계약** (모두 `typeof trackMetaPixelEvent === 'function'` 가드 안):
  1. `PageView` — 수동 호출 **넣지 않는다**(1-검증 ② 뒤 작업 9에서 필요한 자리만)
  2. `ViewContent` — `application.js` `openCampaign()` 557행 `navigate('detail-' + id)` 직후, `{content_name, content_ids:[id]}`. 🔴 107행 초대 게이트에는 넣지 않는다
  3. `CompleteRegistration` — `auth.js` `signUp()` 성공 직후, `{status: META_PIXEL_REG_STATUS.PENDING_EMAIL}`
  4. `CompleteRegistration` — `app.js` 432행 착지 블록 안, 434행이 코드를 지우기 **전에** 「교환 성공」 판정일 때만(S4 후보), `{status: CONFIRMED}`, 같은 탭 한 번
  5. `SubmitApplication` — `application.js` `insertApplication()` **성공 뒤**, `{content_name, content_ids}`, 금액 인자 없음
- **선행 의존:** 5
- **완료 정의:** 산출물에서 이벤트 이름 문자열이 `META_PIXEL_EVENTS` 정의 한 곳에만 있다 / 시행일 NULL에서 가입·상세·신청해도 오류 로그 0·동작 변화 0
- **필요 검문소:** reverb-reviewer
- **주의:** 신청 실패 경로(마감·정원 거부)에서 5번이 나가면 안 된다 — 성공 분기 안에만

### 작업 7 — 1a 개발서버 반영 + 문서 한 세트

- **하는 일:** 개발 데이터베이스에 ①→② 적용, 1~6 병합, 시험 설정 입력, 문서 반영.
- **담당 파일:** `CLAUDE.md`(Features — 관리자 「광고 추적」 + Database Schema 짧게, 한도 150,000자 주의) · `docs/FEATURE_SPEC.md` · 사양서 「구현 결과」(실제 마이그레이션 번호)
- **산출 계약:** 개발 SQL 편집기 `UPDATE public.meta_pixel_settings SET policy_effective_date = '2000-01-01' WHERE id = 1;` → 관리 화면에서 **시험용 아이디** 저장·켜기
- **선행 의존:** 2·4·6 + 선결 3
- **완료 정의:** 개발 배지 `켜짐 — 전송 중` / 인플루언서 앱 네트워크 탭에 `connect.facebook.net`·`facebook.com/tr` 요청 / 이력에 시행일 입력 행(「시스템(직접 입력)」)과 켜기 행
- **필요 검문소:** reverb-reviewer · reverb-supabase-expert
- **주의:** 🔴 운영 아이디를 개발서버에 넣지 않는다. 문서 파일은 이 조각에서만 고친다

### 작업 8 — 1-검증 (①~⑦)

- **하는 일:** 사양서 「단계」 1-검증 ①~⑦을 그대로 실행하고 결과를 사양서 「구현 결과」에 기록.
- **확인 방법 보강:** 증거는 테스트 이벤트 화면 캡처 또는 네트워크 탭 `facebook.com/tr` 요청 인자 — 특히 **전송 주소 `dl`**. ④에 **재설정 토큰 주소**(S1)를 추가하고, ⑥에 **토큰 갱신·탭 재진입에 새로고침이 없는지**(S3)를 추가한다
- **선행 의존:** 7 + 선결 4
- **완료 정의:** ①~⑦ 결과가 사양서에 기록되고 실패 항목이 작업 9 입력으로 목록화됨
- **필요 검문소:** reverb-qa-tester — ⑥의 응답 붙잡기는 자동화 도구의 경로 가로채기. 🔴 크롬 단일 자원이라 한 세션만
- **주의:** 4번 **실제 전송**은 여기서 재현하지 않는다 → 작업 14

### 작업 9 — 1b 반영

- **담당 파일:** `dev/js/meta-pixel.js` · `dev/js/app.js` · `dev/js/application.js` · 누출 시 `dev/js/campaign.js` 490·573행
- **산출 계약:** ②에서 빠진 자리에만 수동 `PAGE_VIEW` / ④에서 초대 번호가 새면 「픽셀이 켜진 탭에서는 초대 번호를 주소에 쓰지 않고 브라우저 저장소 기억만」으로 기록 방식 변경(사양서 ⑯) / 민감 값 목록 최종본을 함수 주석·사양서 「구현 결과」에 기록
- **선행 의존:** 8
- **완료 정의:** 8의 실패 항목 재시험 전부 통과 / 초대 전용 캠페인 **새로고침 복원이 여전히 동작**
- **필요 검문소:** reverb-reviewer · reverb-qa-tester(재시험 항목만)
- **주의:** 초대 경로는 오프라인 행사 기능(`event-ticketing.md`)과 맞물린다 — 초대 링크 착지·가입 후 복귀(`consumeInviteReturn`) 함께 확인

### 작업 10 — 운영 배포(1b) — 전송 0 상태

- **하는 일:** 운영 데이터베이스에 ①→② 적용 후 `dev→main` 병합.
- **선행 의존:** 9 · **사용자 운영 배포 승인**
- **완료 정의(운영 관찰):** 네트워크 탭 `get_public_meta_pixel_id` 응답 `''`·`connect.facebook.net` 0건 / 운영 관리 화면 배지 `방침 시행 전 — 전송 안 됨 (시행일: 미정)`·켜기 비활성 / 산출물 확인은 `curl -sL` + md5
- **필요 검문소:** reverb-supabase-expert · reverb-qa-tester(권장)
- **주의·롤백:** 🔴 **데이터베이스 먼저, 코드 나중**(반대면 화면이 없는 함수를 부른다). 롤백은 코드 되돌리기 → 함수·표 삭제

### 작업 11a — 방침 개정 문안 확정 (기획)

- 사양서 부록 「어긋나면 안 되는 자리 셋」(이벤트 목록·회원 정보 미송신·거부 방법) 점검. 🔴 작업 9에서 민감 주소 목록·초대 번호 기록 방식이 바뀌면 부록 「송신되는 정보」 칸이 여전히 사실인지 다시 본다. 검문소 `/약관확인`

### 작업 11b — 방침 개정 공고 + 앱 안 공지

- **담당 파일:** `docs/PRIVACY_kr.md` · `docs/PRIVACY_ja.md` · (S5 결정이 팝업·배너면) `dev/lib/shared.js` `POLICY_NOTICE`
- **산출 계약:** §8.1 신설(부록 원문) · §5 첫 문단 끝 한 줄 · 부칙(공고일·시행일 = +30일). 🔴 §4·§5 표·§2.1 에는 넣지 않는다
- **선행 의존:** 10 · 11a · 선결 7·8
- **완료 정의:** 운영 푸터 약관 화면에서 8.1이 **눈으로** 보인다(`legal.js` 가 실행 중에 불러오므로 상태 코드만으로는 부족) / 앱 안 공지가 뜬다
- **주의:** 메일 통지를 고르면 **전 회원 발송 — 되돌릴 수 없다**

### 작업 12 — 운영 설정 표에 시행일 입력 (사용자)

- 운영 SQL 편집기 `UPDATE public.meta_pixel_settings SET policy_effective_date = '<시행일>' WHERE id = 1;`
- **완료 정의:** 배지에 그 날짜 / 이력에 「시스템(직접 입력)」 1행 / 시행일 전날까지 앱용 조회 `''`
- **주의:** 날짜를 틀리게 넣으면 잠금이 일찍 풀린다 — 배지 날짜를 공고문과 대조. 편집기 탭은 쓰고 바로 닫는다

### 작업 13 — 시행일 이후 운영 아이디 저장·켜기 (사용자, 캠페인관리자 이상)

- **완료 정의:** 배지 `켜짐 — 전송 중`, 새 브라우저로 인플루언서 사이트를 열면 `facebook.com/tr` 요청

### 작업 14 — 4번 운영 확인 + 시험 계정 탈퇴

- 시험 이메일로 운영 실제 가입 1건 → 같은 브라우저에서 확인 링크 → 테스트 이벤트에 `CompleteRegistration`(`confirmed`) → 계정 탈퇴
- **주의:** 🔴 감사용 계정은 쓸 수 없다. 운영 숫자에 섞이는 유일한 예외. 실패해도 픽셀을 끄지 않는다 — 버그로 고친다

### 작업 15 — Notion 실무자 가이드

- 「관리자 가이드」 데이터베이스에 「광고 추적」 페이지(배지 4종·시행일 전 잠금·「새 방문부터 적용」·운영 아이디를 개발서버에 넣지 말 것·테스트 이벤트 확인법·권한별 비활성 표시). 정확성 게이트(`notion-sync.md`) 통과

---

## ⚠️ 공유 지점 경고 (충돌 주의)

1. **핫스팟 파일은 작업 3에 몰았다**(`shared.js`·`storage.js`·`build.sh`). 예외는 11b 의 `POLICY_NOTICE`(나중에 순서대로)와 4의 `admin-core.js`·`admin/index.html`. 다른 작업 폴더도 이 파일들을 만질 수 있으니 **병합 직전 `origin/dev` 를 받는다**
2. **로더와 페인 갱신 표** — `PANE_REFRESHERS['ad-tracking']`(3)과 `loaders['ad-tracking']`(4)이 `loadAdTrackingPane` **이름**으로 이어진다. 한쪽만 있으면 「오류 없이 빈 화면」 또는 「저장했는데 목록이 그대로」
3. **권한 열쇠말 네 곳** — 시드(2) · 카탈로그 · `PERM_SUPER_SERVER_ENFORCED`(3) · 서버 가드(1). 철자 하나만 달라도 캠페인관리자가 조용히 거부당한다
4. **시행일 판정식 세 곳**(1 안) — 한 곳만 `<` 이면 시행 당일 「켤 수는 있는데 전송 안 됨」
5. **이벤트 목록 세 곳** — `META_PIXEL_EVENTS`·`META_PIXEL_EVENT_TABLE` ↔ 사양서 「심는 이벤트」 표 ↔ 방침 부록 「송신되는 정보」
6. **인플루언서 `app.js`·`auth.js`** — 5·6·9가 모두 만진다. **같은 세션에서 순서대로**
7. **민감 주소 판정은 한 함수** — `metaPixelUrlHasSensitiveValue()` 밖에서 따로 만들지 않는다. 재설정 토큰을 빠뜨리면 **계정 탈취 가능한 값이 외부로 나간다**
8. **문서 파일** — `CLAUDE.md`·`FEATURE_SPEC.md`·사양서 「구현 결과」는 작업 7에서만
9. **크롬 단일 자원** — 8·9 재시험·14는 한 번에 한 세션. 운영 SQL 편집기 탭(10·12)은 쓰고 그 자리에서 닫는다(저장 안 된 편집이 있으면 `navigate` 에 `force:true` 로 먼저 옮긴 뒤)

---

## 🧭 배분 제안

| 세션 | 조각 | 이유 |
|---|---|---|
| **개발 1** | 1 → 2(데이터베이스, 순서대로) 와 **동시에** 3 → `dev` 병합 → 4 → 7 → 10 | 데이터베이스와 핫스팟 파일을 한 사람이 쥐어 번호·충돌을 없앤다 |
| **개발 2** (작업 3 병합 **뒤** 작업 폴더 생성) | 5 → 6 → (8 뒤) 9 | 인플루언서 `app.js`·`auth.js` 를 한 사람이 순서대로. 작업 4와 파일이 안 겹쳐 동시 진행 가능 |
| **QA 단일 세션** | 8 · 9 재시험 · (권장) 10 | 크롬 단일 자원 |
| **기획** | 11a | 코드와 무관, 지금 가능 |
| **사용자** | 선결 3~9 · 10 승인 · 11b 공고 결정 · 12 · 13 · 14 | 외부 계정·법적 공고·운영 스위치 |
| **개발 1** | 11b 파일 반영 · 15 | 배포 뒤 |

⚠️ 개발 2는 **작업 3이 `dev` 에 병합된 뒤에** 작업 폴더를 만든다 — 먼저 만들면 공용 함수·상수가 없는 판에서 시작한다.
