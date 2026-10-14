# 📋 작업 분해표 — 브랜드 페이지 로그인 기능 (대표 담당자 계정 1차)

**사양서:** `docs/specs/2026-07-15-brand-portal.md` §16-6(정본, 16-2·16-3 보다 앞섬) + 인수인계 `docs/specs/2026-10-14-brand-login-handoff.md` §3·§5
**분해일:** 2026-10-14 (reverb-planner)
**총 작업 조각:** 11개 · **병렬 가능:** 4개(조각 7·8·9·10) · **순차 필수:** 7개(조각 1·2·3·4·5·6·11)

> 분해 시점 마지막 마이그레이션 번호는 **522**. 번호는 미리 정하지 않는다 — 데이터베이스 조각 착수 때 `ls supabase/migrations | tail -5` 로 확정.
> 결정이 나면 이 문서의 「선결 조건」 표 끝 칸에 결과를 적는다.

---

## 🚦 착수 전 선결 조건

| # | 선결 조건 | 종류 | 근거 | 막는 조각 | 결과 |
|---|---|---|---|---|---|
| P-1 | 🔴 **운영으로 실려 가는 코드를 어떻게 막을지.** §16-6 은 「운영 잠금 스위치는 만들지 않는다」. 그러나 `dev → main` 은 `admin-brand.js`·`auth.js`·`app.js` 변경을 운영으로 같이 가져간다. A) 화면이 개발서버(`IS_STAGING`)에서만 계정 생성·판정을 부름 B) 운영 데이터베이스에도 표·판정 함수 선적용 C) 브랜치로 묶어 둠 | 미결 결정 | B만이면 출시 관문 전 운영에서 계정이 생김(§16-3 9번 위반). 아무것도 안 하면 운영에서 없는 함수를 부르고, 판정 실패 처리에 따라 **운영 회원 전원 로그인이 막힐 수 있다**. `release-timing.md` 4절은 브랜치 분리 기본 | 9·10 (7의 운영 산출물 포함) || ✅ 개발서버에서만 동작 — 화면이 `IS_STAGING` 일 때만 계정 생성·판정 호출, 운영 데이터베이스 미적용, 출시 때 조건 제거 |
| P-2 | **대표 이메일이 이미 있는 기존 브랜드에 계정을 만드는 길.** 「새로·바뀔 때만」 규칙만 있으면 출시 전 채워 둔 대표는 메일을 영영 못 받는다. 「다시 보내기」는 설정 전에만 있고 「계정 없음」 상태 단추는 미정 | 미결 결정 | §16-6 「다시 보내기」·발송 조건 행 | 2·10 || ✅ 「계정 없음」 줄에 「계정 만들고 메일 보내기」 단추(캠페인 관리자 이상) |
| P-3 | **「새로·바뀜」 판정 위치 + 「대표 표시만 옮김」과 가르기.** 브랜드 저장은 브라우저가 표를 직접 고친다(`updateBrand`). 저장 뒤 계정 함수는 옛 값을 못 본다 → 화면이 연 시점의 대표 줄 `id`·이메일을 넘기거나, 서버에 「마지막 처리 대표」 칸 | 미결 결정 | `admin-brand.js` 2184~2250행, 마이그레이션 082 224~227행 | 2·10 || ✅ 화면이 상세를 연 시점의 대표 줄 `id`·이메일을 계정 함수에 전달(서버 칸 없음) |
| P-4 | 대시보드 「Email OTP Expiration」(링크 유효 시간) 현재 값 확인 — 메일 문구의 유효 시간 안내가 걸림 | 외부 계정 | 인수인계 §5 | 4·5(문구), 8 | ✅ 3600초(1시간) — 사용자 확인, 유지. 메일 문구 「1時間」 기준 |
| P-5 | Figma w01-02 에 「계속하기」 단계가 있는지. 없으면 화면 상태 추가 | 미결 결정(디자인) | 인수인계 §5, `admin-setpw.html` 272행 `confirmBtn` | 8 || ✅ 없으면 관리자 방식 「계속하기」 카드를 브랜드 화면 모양으로 추가(Figma 는 기획이 뒤따라) |
| P-6 | 비밀번호 찾기 링크로 들어온 화면 — w01-02 를 약관 칸 없이 재사용할지 | 미결 결정 | 인수인계 §5 | 5·8 || ✅ w01-02 를 약관 칸 없이 재사용 |
| P-7 | **운영 반영 관문** — 브랜드용 이용약관·개인정보처리방침 + `/약관확인`(§16-3 9번). 약관 판 문자열(`terms_version`) 실제 값도 여기서. 개발서버는 임시 판 문자열. 앱에서 띄우려면 `.vercelignore` 에 `!` 줄 필요 | 외부 승인·법률 | §16-6 「운영 반영」, `policy.md` | 운영 반영만 | |
| P-8 | 다른 세션 마이그레이션 작업 여부 | 사용자 확인 | `multi-session.md` | 1 | ✅ 없음(2026-10-14 사용자) — 이 세션이 번호 담당 |
| P-9 | 보관(`archived`) 브랜드 연결을 로그인 「연결된 브랜드 있음」에 셀지(병합 원본은 보관됨) | 미결 결정 | `merge_brands`(467) | 2·3 || ✅ 보관 브랜드는 빼기 — 활성 브랜드 연결이 없으면 `no_active_brand` |
| P-10 | 관리자 초대(`invite_admin` 417)에 브랜드 계정 이메일이 오면 지금은 관리자로 승격됨 — 막을지 | 미결 결정 | 417 570~589행 | 3 || ✅ 초대 거부 — 조각 3 에 `invite_admin`(417 베이스) 포함 |
| P-11 | 비밀값 `PUBLIC_BRAND_URL`(개발·운영 각각) + 개발서버 전용 링크 표시 `BRAND_SETUP_DEV_ECHO`(개발서버만) 등록 | 외부 계정 | 인수인계 §3 2단계 | 4·5 검증 | |
| P-12 | 사양서 §16 본문을 §16-6 에 맞춰 다시 쓰기 + §15 a03-01 정리(규칙 C) | 선행 사양서 | 인수인계 §5 | 막지 않음(병행). 조각 11 전 완료 권장 | |

---

## ✅ 추가 결정 (2026-10-14 사용자)
- 인플루언서 앱 차단 문구: **기존 키 `authError.checkCredentials` 재사용**(stale 8 — 새 번역 없음)
- 인플루언서 「비밀번호 찾기」로 브랜드 계정 비밀번호가 바뀌는 길(stale 6-ⓑ): **이번엔 기록만** — 알려진 틈, 다음 작업에서 막음. 복구는 관리자 「다시 보내기」

## 🎨 피그마 설명 반영 (2026-10-14 — 섹션 34:1153 「[1차] 01 로그인」, 기획이 화면별 설명 카드 추가)
525(조각 1)는 영향 없음. 아래는 조각 2·8 에 반영한다.
| # | 피그마 | 반영 |
|---|---|---|
| F-1 | **w01-07 새 비밀번호 / w01-07a 완료** — 재설정은 약관 칸 없는 별도 화면, 바꾼 뒤 **로그아웃 → 다시 로그인** | 조각 8: 재설정(`mode=reset`)은 자동 로그인하지 않고 `signOut` → w01-07a → w01-00. 설정(w01-02)은 지금처럼 로그인된 채 첫 화면. P-6(「w01-02 재사용」)은 w01-07 로 대체 |
| F-2 | **링크는 보낸 때의 계정 상태에 묶인다** — 계정 만들기·재설정 링크 모두 「이미 사용」·「상태 바뀜」이면 w01-05 | 조각 2·5: 재설정 메일도 `setup_link_id`(현재 유효한 링크 번호, 칸 하나 공용)를 새로 발급하고, 비밀번호 설정·변경이 끝나면 그 번호를 비운다. 링크 상태 함수는 링크 종류(setup/reset)도 확인. **칸 추가 없음** |
| F-3 | **w01-06 브랜드 계정이 아님** 전용 화면(비밀번호가 맞은 뒤에만) | ✅ 사용자 결정(2026-10-14): 피그마대로. 조각 8: `not_brand` → 로그아웃 후 w01-06(일반 실패 문구가 아님). 비밀번호가 틀렸으면 w01-91 공통 실패 |
| F-4 | **w01-06a 연결된 브랜드 없음** 전용 화면 | 조각 8: `no_active_brand` → 로그아웃 후 w01-06a(피그마 문구) |
| F-5 | **w01-05 문구** — 「이메일 변경」 대신 「재설정 메일이면 「비밀번호 찾기」에서 다시 요청」. **w01-04(이메일 변경) 화면은 섹션에서 빠짐** | 조각 8: 문구 교체, `email-change` 화면은 미리보기 목록에서 제외 |
| F-6 | **w01-08 「계속하기」** — 제목만 메일 종류별(「비밀번호를 설정할까요?」·「초대를 확인할까요?」·「비밀번호를 다시 정할까요?」) | P-5 확정. 조각 8 에서 설정·재설정 두 가지 |
| F-7 | 로그인 뒤 첫 페이지 = 오리엔시트 목록(w04-00) | 이번 범위 밖 — §16-6 대로 **임시 첫 화면 유지**, 나중에 w04-00 으로 교체 |
| F-8 | 피그마 「확인 필요」: 흔한 비밀번호 거부/경고 · 로그인 잠금 · 로그인 유지 시간 · 링크 유효 시간 | 링크 유효 시간은 **3600초 확인 완료(P-4)** — 기획에 전달. 로그인 잠금은 1차에 Supabase 기본 횟수 제한(→ w01-91 ⑥ 문구)만. 흔한 비밀번호·유지 시간은 기획 결정 대기(조각 8 착수 전) |

## ⚠️ 사양서 stale 점검 (인수인계·§16-6 과 실제 코드가 어긋나는 곳)

1. **`delete_brand` 현재 원본은 191 이 아니라 325**(174 → 191 → **325**, 보관 삭제 캠페인 제외). 191 베이스로 쓰면 325 수정이 사라진다. `invite_admin` 417 · `merge_brands` 467 · `handle_new_user` 420 · `submit_brand_application` 397(153~179행)은 맞다.
2. **설정 화면 연결 방식** — 인수인계는 「`pkce` + `persistSession:false`」. 실제 `admin-setpw.html` 설정 모드는 **`implicit`**(399행). 서버 생성 링크는 `#access_token=…` 으로 돌아와 `pkce` 면 못 읽는다(2026-07-20 실측). 브랜드 설정 화면도 `implicit` + `persistSession:false` + 별도 저장 칸. 로그인 연결만 `pkce`.
3. **링크 착지 주소와 해시 전환 충돌** — 「계속하기」 → 검증 뒤 해시가 `#access_token=…` 이 되어 `brand-app.js` `currentBrandScreen()` 이 `login` 으로 떨어진다. `redirectTo` 에 `?link=…&mode=setup|reset` 쿼리로 화면을 정한다.
4. **메일 양식 동기화는 두 곳 등록** — `scripts/sync-email-templates.sh` 의 `SYNC_GROUPS`(35~49행)와 `templates.ts` 생성 `if` 분기(98~109행). 카탈로그 `docs/email-templates/index.html` 도. 그 폴더는 운영에서도 공개(`!docs/email-templates`).
5. **인플루언서 삽입 정책(137)은 본인 행보다 넓다** — `WITH CHECK (is_admin() OR auth.uid() = id OR auth.uid() IS NOT NULL)`. 거부 트리거는 `auth.uid()` 가 아니라 **`NEW.id`** 로 판정.
6. **인플루언서 앱으로 들어오는 길이 더 있다** — ⓐ `admin-setpw.html?mode=login` 이 비관리자 세션을 기본 저장 칸에 남김 ⓑ 인플루언서 「비밀번호 찾기」에 브랜드 이메일 → 설정 링크 무효화 + 동의 없이 비밀번호 설정 ⓒ 가입 인증번호(499 `signup_email_registered`) → 브랜드 담당자에게 인플루언서용 「이미 가입」 메일.
7. **프로필 자동 생성은 `handleLogin`(594행) 하나뿐** — 부팅(546~555)·로그인 이벤트(612~621)는 조회만. 그 두 자리의 차단은 **세션 정리(로그아웃)**. 판정 실패(`null`) 처리 필수 — 함수 없는 운영에선 모든 호출이 실패(P-1).
8. **§16-6 실패 문구 ≠ 화면 실제 문구** — 결정 `メールアドレスまたはパスワードが正しくありません`("…올바르지 않습니다"), 실제 키 `authError.checkCredentials` = `メールアドレスまたはパスワードをご確認ください`("…확인해 주세요", ja.js 942행).
9. **대표 이메일 두 벌** — `contacts[].is_primary` 와 옛 칸 `primary_email`. 계정 함수는 `contacts` 대표 줄(`id`·`email`)이 정본.
10. **`notify-admin-invite` 복제 시** — 호출자 검사가 최고 관리자 전용(170행), 대상이 `admins`. 브랜드는 캠페인 관리자 이상 + 브랜드 계정 표.
11. **CLAUDE.md 「8개 HTML」 → 9개**, 브랜드 화면은 `storage.js` 를 안 싣는 **자립형 화면** — 자립형 목록에 추가.
12. **497·498 통과 판단은 맞다** — 충돌 없음.

---

## 한눈에 보는 의존 순서

```
선결(P-1·P-2·P-3·P-9·P-10)
  ├─▶ [1 데이터베이스 기초] ─▶ [2 데이터베이스 함수] ─▶ [3 기존 함수 수정]      (한 세션 순차)
  │                                  ├─▶ [4 설정 메일 함수] ─▶ [5 비밀번호 찾기 함수]
  │                                  └─▶ [6 저장소 함수 묶음(storage.js)]
  └─▶ [7 공용 연결 조건 + 빌드]   ∥ (1~3 과 병렬)

  {2,4,5,7} ─▶ [8 브랜드 화면]  ∥  {1,6} ─▶ [9 인플루언서 앱 차단]  ∥  {2,4,6} ─▶ [10 관리자 화면]
                                                      ▼
                                              [11 문서 마무리]
```

---

## 작업 조각 표

| 번호 | 제목 | 담당 파일 | 산출 계약(요지) | 선행 | 병렬? | 담당 |
|---|---|---|---|---|---|---|
| 1 | 데이터베이스 기초 | `supabase/migrations/<번호>_brand_accounts_*.sql` | 표 `brand_accounts`·`brand_account_links`·`brand_password_reset_requests` · `handle_new_user()`(420 베이스) · `trg_block_influencer_row_for_brand` · `get_my_account_kind()` | P-1·P-8 | ✗ | 데이터베이스 세션 |
| 2 | 데이터베이스 함수 | `supabase/migrations/<번호>_brand_account_functions.sql` | `admin_upsert_brand_owner_account` · `admin_get_brand_account_status` · `get_brand_setup_link_state` · `complete_brand_account_setup` · `get_my_brand_login_state` · `check_brand_password_reset_rate_limit` · `purge_old_brand_password_reset_requests` + 예약 작업 | 1·P-2·P-3·P-9 | ✗ | 데이터베이스 세션 |
| 3 | 기존 함수 수정 | `supabase/migrations/<번호>_brand_delete_merge_account_guard.sql` | `delete_brand`(**325** 베이스) · `merge_brands`(467) `brand_has_account_links` · (P-10) `invite_admin`(417) | 2·P-10 | ✗ | 데이터베이스 세션 |
| 4 | 설정 메일 서버 함수 | `supabase/functions/notify-brand-account-setup/*` · `docs/email-templates/brand-account-setup.html` · 동기화 스크립트 · 카탈로그 | `{brand_id, mode}` → `{sent, recipient}` / `{sent:false, reason}` · 개발서버 두 겹 잠금 시 `dev_link` | 2·P-4·P-11 | ✗ | 개발 |
| 5 | 비밀번호 찾기 서버 함수 | `supabase/functions/brand-password-reset-request/*` · `docs/email-templates/brand-password-reset.html` · 같은 스크립트·카탈로그 | `{email}` → 항상 `{ok:true}` 200, 최소 2,500밀리초 | 4·P-6 | ✗ | 개발 |
| 6 | 저장소 함수 묶음 | `dev/lib/storage.js`(핫스팟) | `upsertBrandOwnerAccount` · `sendBrandAccountSetupMail` · `fetchBrandAccountStatus` · `fetchMyAccountKind` | 2·4 | ✗ | 개발 |
| 7 | 공용 연결 조건 + 브랜드 빌드 | `dev/lib/supabase.js` · `dev/build.sh`(핫스팟) · `dev/brand/index.html` · `.vercelignore`(확인) | `window.REVERB_SKIP_GLOBAL_DB` · 루트 `brand/index.html` | P-1 | ✅(1~3과) | 개발 |
| 8 | 브랜드 화면 실제 연결 | `dev/js/brand-core.js`·`brand-login.js`·`brand-app.js` · `dev/brand/index.html` · `dev/css/brand.css` | 로그인·찾기·설정·쓸 수 없는 링크·임시 첫 화면 `data-screen="home"` · `brandFakeRequest` 제거 | 2·4·5·7·P-5·P-6 | ✅(9·10과) | 개발 |
| 9 | 인플루언서 앱 차단 | `dev/js/auth.js` · `dev/js/app.js` | `handleLogin` 관리자 확인 다음·프로필 조회 전 판정 · 부팅·`SIGNED_IN` 정리 | 1·6·P-1 | ✅(8·10과) | 개발 |
| 10 | 관리자 브랜드 상세 연동 | `dev/js/admin-brand.js`(필요 시 `dev/css/admin.css`) | 저장 뒤 계정 함수 → 메일 → 결과별 안내 · `#brandAccountStatusRow` | 2·4·6·P-1·P-2·P-3 | ✅(8·9와) | 개발 |
| 11 | 문서 마무리 | 사양서 「구현 결과」 · `FEATURE_SPEC.md` · `CLAUDE.md` · (고문/기획) `.claude/rules/brand-admin.md` | 원본 번호 · 「9개 HTML」 · 자립형 목록 · 운영 보류 상태 | 8·9·10 | ✗ | 개발(+규칙 파일은 고문/기획) |

> 각 조각은 **자기 커밋 안에** `FEATURE_SPEC.md`·`CLAUDE.md`·사양서 「구현 결과」 자기 몫을 함께 넣는다. 조각 11은 맞추고 빈 곳 채우는 자리.

---

## 조각별 상세

### 조각 1 — 데이터베이스 기초
- **하는 일**: 표 셋 + 정책, 가입 트리거 브랜드 분기, 브랜드 계정의 인플루언서 행 삽입 거부, 「내 계정 종류」 판정 함수.
- **산출 계약**
  - `brand_accounts` — `auth_id uuid PK REFERENCES auth.users ON DELETE CASCADE` · `email text NOT NULL`(소문자, `UNIQUE (lower(email))`) · `name` · `phone` · `password_set_at` · `terms_agreed_at` · `privacy_agreed_at` · `terms_version text` · `setup_link_id uuid` · `setup_mail_sent_at` · `setup_mail_sent_to` · `created_at` · `created_by`
  - `brand_account_links` — `id` · `auth_id → brand_accounts` · `brand_id → brands ON DELETE RESTRICT` · `role CHECK (owner|member)` · `status CHECK (active|released)` · `source_contact_id text` · `created_at` · `released_at`. 부분 유일 `(brand_id) WHERE role='owner' AND status='active'` · `(auth_id, brand_id) WHERE status='active'`
  - `brand_password_reset_requests` — 243 복제(`email_hash`·`requested_at`·`matched`, 원문 이메일 없음)
  - 정책: 세 표 모두 쓰기 정책 없음. 읽기는 본인(`auth_id = (SELECT auth.uid())`) 또는 `(SELECT public.is_admin())`(415 방식). 요청 기록 표는 `is_super_admin()`
  - `handle_new_user()` — **420 본문 글자 그대로** `CREATE OR REPLACE` + 맨 앞 `IF NEW.raw_app_meta_data->>'account_kind' = 'brand' THEN RETURN NEW; END IF;` (🔴 앱 메타데이터)
  - `trg_block_influencer_row_for_brand` — `influencers` `BEFORE INSERT`, `EXISTS(SELECT 1 FROM brand_accounts WHERE auth_id = NEW.id)` 면 `RAISE 'brand_account_not_influencer'`
  - `get_my_account_kind()` → `'brand'|'other'` — `SECURITY DEFINER` + `SET search_path=''`, `authenticated` 만(부여 먼저, PUBLIC·anon 회수)
- **완료 정의**: 표 셋 존재 + `p.proacl::text` 맨 앞 `=X/` 없음 · 앱 메타데이터 brand 로 `auth.users` 삽입 시 `influencers` 0건/아니면 1건(되돌림 시험) · 🔁 인플루언서 신규 가입 1회 · 🔁 관리자 초대 1회 · 로그인 브라우저 콘솔에서 `get_my_account_kind()` → `'other'`
- **검문소**: reverb-supabase-expert · reverb-reviewer · `/약관확인`(결과는 P-7로)
- **롤백**: 420 재실행 + 거부 트리거 `DROP` + 새 표 `DROP`(데이터 0건일 때만)

### 조각 2 — 데이터베이스 함수
- **산출 계약(이름은 제안 — 데이터베이스 세션이 확정)**
  - `admin_upsert_brand_owner_account(p_brand_id uuid, p_prev_contact_id text, p_prev_email text) → jsonb` — 안쪽 `is_campaign_admin()` 재확인(아니면 `forbidden`) · 브랜드 단위 `pg_advisory_xact_lock` · `lower(btrim())` · 대표 줄은 `contacts` 의 `is_primary` · `result` ∈ `created`·`noop`·`email_replaced`·`password_already_set`·`primary_moved`·`conflict_influencer`·`conflict_admin`·`conflict_brand`·`no_primary_email` · 반환 `needs_mail`·`email`·`auth_id` · 계정은 417 방식 직접 삽입(`email_confirmed_at=now()`, 앱 메타데이터 `{"provider":"email","providers":["email"],"account_kind":"brand"}`, 토큰 칸 빈 문자열)
  - `admin_get_brand_account_status(p_brand_id uuid) → jsonb` — `{status:'none'|'mail_pending'|'mail_sent'|'active', email, setup_mail_sent_at, password_set_at}`(`is_admin()`)
  - `get_brand_setup_link_state(p_link_id uuid) → text` — `'valid'|'invalid'`, 비로그인 가능, 이메일 반환 안 함
  - `complete_brand_account_setup(p_link_id uuid, p_terms_version text) → text` — `'ok'|'link_mismatch'|'already_set'|'not_brand'`, 동의 시각 서버 `now()`
  - `get_my_brand_login_state() → jsonb` — `{state:'ok'|'not_brand'|'setup_incomplete'|'no_active_brand', name, email, brands:[{id,name,role}]}`
  - `check_brand_password_reset_rate_limit(p_email_hash text, p_matched boolean) → boolean` — 서비스 키 전용, 243 3층 제한
  - `purge_old_brand_password_reset_requests()` + 예약 작업(30일)
  - 실행 권한: 회수 방향 둘 다, 부여 먼저(375 순서)
- **완료 정의**: 함수마다 실제 호출 1회 · `created`·`noop`·`conflict_influencer`·`email_replaced` 관찰 · PUBLIC 없음
- **주의**: `raw_user_meta_data` 를 고치면 383 정리 트리거가 돈다 — 그 칸에 값을 담지 않는다

### 조각 3 — 기존 함수 수정
- `delete_brand(uuid)` — **325 베이스**, 활성 연결 수 ≠ 0 이면 22023 + 「계정 연결 N건」
- `merge_brands(uuid, uuid)` — **467 베이스**, 원본에 활성 연결이면 `RAISE 'brand_has_account_links'`
- (P-10) `invite_admin` — 417 베이스, 브랜드 계정이면 `RAISE 'brand_account_email'`
- **완료 정의**: 연결된 브랜드 삭제·병합 거부, 연결 없는 브랜드는 지금처럼 · 325 「보관 캠페인 제외」 유지
- **롤백**: 🔴 175·191 베이스 금지. `CREATE OR REPLACE` 로만. 되돌리기는 325·467(·417) 재실행

### 조각 4 — 설정 메일 서버 함수
- 요청 `POST {brand_id, mode:'setup'|'resend'}` + 관리자 토큰 · 캠페인 관리자 미만이면 `403 {sent:false, reason:'forbidden'}`
- 받는 사람은 `brand_id` 로 서버가 다시 읽음
- 발송마다 `setup_link_id` 교체 → `generateLink({type:'recovery', redirectTo: PUBLIC_BRAND_URL + '/brand/?link=<id>&mode=setup'})` → 메일 링크 `…/brand/?link=<id>#confirm=<encodeURIComponent(원래 링크)>`
- 성공 `{sent:true, recipient}` + 발송 시각·주소 기록 · 실패 `reason` ∈ `no_account`·`password_already_set`·`send_failed`
- 두 겹 잠금(`BRAND_SETUP_DEV_ECHO==='1'` **그리고** `SUPABASE_URL` 이 `qysmxtipobomefudyixw`)일 때만 `{sent:true, dev_link}`
- 교차 출처 허용 + `OPTIONS`. 공개 키 거부 안 검
- 양식: §16-3 2번 문장 + 9번 용도 안내 자리 + 유효 시간(P-4)
- **완료 정의**: 개발서버 콘솔 호출 → `dev_link` · `OPTIONS` 200 · 매니저 토큰 403 · `templates.ts` 생성
- 🔴 두 겹 잠금 중 하나라도 지우면 운영에서 링크가 응답에 실린다

### 조각 5 — 비밀번호 찾기 서버 함수
- `POST {email}`(비로그인) → 항상 `200 {ok:true}`, 최소 2,500밀리초 · 해시 → 요청 제한 · 설정 완료면 재설정 링크(`mode=reset`), 설정 전이면 설정 메일 재발송, 브랜드 아니면 무동작 · 교차 출처 허용 + `OPTIONS`, 공개 키 거부 안 검
- **완료 정의**: 없는 이메일·인플루언서·브랜드 세 경우 응답·소요 시간 동일 · 기록 세 줄 · `OPTIONS` 200

### 조각 6 — 저장소 함수 묶음 (핫스팟)
- `upsertBrandOwnerAccount(brandId, prevContactId, prevEmail) → {ok, data:{result, needs_mail, email}} | {ok:false, error}`(`retryWithRefresh`)
- `sendBrandAccountSetupMail(brandId, mode) → {sent, recipient?, reason?, dev_link?}`(`sendAdminInviteMail` 패턴)
- `fetchBrandAccountStatus(brandId) → object | null` — 🔴 실패 `null`, 계정 없음 `{status:'none'}`
- `fetchMyAccountKind() → 'brand' | 'other' | null`
- **완료 정의**: 관리자·인플루언서 빌드 성공 + 콘솔에서 넷 다 1회

- ✅ **구현됨(2026-10-14)** — `storage.js` insertBrand 뒤. 🔴 운영 보류 판정은 `_brandAccountEnabled()`(= `IS_STAGING`) **한 곳** — 운영에서는 서버를 부르지 않는다(`fetchMyAccountKind` 는 `'other'`, 나머지는 `brand_account_disabled`/`null`). 출시 때 이 판정만 걷는다
- 🔴 **부르는 쪽 주의 셋**(supabase-expert 검토): ①`upsertBrandOwnerAccount` 는 `ok:true` 여도 서버가 거부했을 수 있다 — **`data.result` 로 분기**, 메일은 **`data.needs_mail === true` 일 때만**(`created` 라도 해제된 기존 계정 재사용이면 `needs_mail=false`) ②`fetchBrandAccountStatus` 의 `null`(실패·운영) ≠ `{status:'none'}`(계정 없음) ③`fetchMyAccountKind` 는 로그인 뒤에만, `null` 을 차단으로 쓰지 않는다

### 조각 7 — 공용 연결 조건 + 브랜드 빌드 (핫스팟)
- `supabase.js`: 전역 연결 두 개 생성 조건을 `if (window.supabase && !window.REVERB_SKIP_GLOBAL_DB)` 로
- `dev/brand/index.html`: `supabase.js` 앞에 `window.REVERB_SKIP_GLOBAL_DB = true` + `@2.116.0/dist/umd/supabase.js`
- `build.sh`: 브랜드 절(`BRAND_CSS_FILES`·`BRAND_JS_FILES`) + 🔴 원본 태그 지우는 정규식 두 곳
- **완료 정의**: 빌드 성공 · 산출물에 `../` 원본 태그 0건 + `bootBrand` 1건 · `curl -sL https://dev.globalreverb.com/brand/` 200 · 🔁 인플루언서 비밀번호 찾기 1회 · 양쪽 화면 콘솔 오류 0 · CLAUDE.md 「8개」→「9개」 같은 커밋

### 조각 8 — 브랜드 화면 실제 연결
- 로그인 연결 `brandDb`: `storageKey:'reverb.brandAuth'` · `pkce` · `persistSession:true` · `detectSessionInUrl:false`
- 설정 연결 `brandSetupDb`: `implicit` · `persistSession:false` · 저장 칸 `'reverb.brandSetup'`
- 로그인: `signInWithPassword` → `get_my_brand_login_state()` — `ok` → `data-screen="home"` · `not_brand`·`setup_incomplete` → `signOut` + `BRAND_MSG.loginFail` · `no_active_brand` → 「연결된 브랜드가 없습니다 — 운영팀에 문의」(문구 사용자 확정)
- 찾기: 함수 호출 → 결과 무관 `#forgot-sent`
- 설정: `?link=` → 링크 상태 → `invalid` 면 `#link-invalid` / `valid` 면 「계속하기」 → 검증 → `?link=&mode=` 착지 → 세션 → `updateUser({password})` → `complete_brand_account_setup` → 설정 연결 `signOut()` → 로그인 연결로 자동 로그인. `mode=reset` 은 약관 칸 없이
- 미리보기 막대는 미연결 화면(초대·이메일 변경)에만
- **완료 정의**: `dev_link` → 설정 → 첫 화면에 브랜드 이름 + 서버 시각 동의 기록 · 같은 링크 재사용 「쓸 수 없는 링크」 · 틀린 비밀번호·인플루언서 이메일 같은 실패 문구 · 🔁 두 탭 간섭 없음 · 콘솔 오류 0 · 600px 이하 입력 16px
- **주의**: `#confirm=` 목적지는 현재 환경 프로젝트 주소 + `/auth/v1/verify` 정확 일치(`admin-setpw.html` 501~519행) · 메타 픽셀·방문자 집계·오류 수집 싣지 않음

### 조각 9 — 인플루언서 앱 차단
- `handleLogin`: 관리자 확인(560행) 다음, 프로필 조회(567행) 전 `fetchMyAccountKind()` — `'brand'` → `signOut({scope:'local'})` + 실패 문구 + 종료 · `null` → 로그인 계속하되 594행 자동 생성으로 안 들어가게 + `logAppError('handleLogin.accountKind', …)`
- `init()`·`SIGNED_IN`: 비관리자 + `'brand'` 면 `signOut({scope:'local'})` + `currentUser=null` + `updateGnb()`. `null` 이면 무동작
- **완료 정의**: 브랜드 계정 `/#login` → 실패 문구 + `influencers` 0건 · `admin-setpw.html?mode=login` 경로 → 로그아웃 상태 · 🔁 신규 가입 + sakura.test 로그인 · 🔁 두 탭 간섭
- 🔴 판정 실패를 「차단」으로 처리하면 함수 없는 서버에서 전원 로그인 불가

### 조각 10 — 관리자 브랜드 상세 연동
- 상세 열 때 `_brandFormPrimaryOriginal = {contactId, email}` 스냅샷(P-3 화면 방식이면)
- `saveBrandDetail`: `updateBrand` 성공 → 「저장되었습니다」 → (캠페인 관리자 이상) `upsertBrandOwnerAccount` → `needs_mail` 이면 `sendBrandAccountSetupMail` → **결과별 별도 안내**(겹침 / 다른 브랜드 계정 / 로그인 이메일 안 바뀜 / 대표 옮김 경고 / 메일 실패 「브랜드는 저장됐지만…」)
- 매니저: 브랜드만 저장 + 「계정 메일은 캠페인 관리자 이상이 보냅니다」
- `submitNewBrand`: 같은 흐름, 안내는 토스트
- 계정 줄 `#brandAccountStatusRow` 만 다시 그림(`renderBrandAccountRow`) — 🔴 편집 폼 본문 재그리기 금지 · 「다시 보내기」 `#brandAccountResendBtn`(설정 전에만, 매니저는 비활성 + 이유) · 개발서버 `#brandAccountDevLink`
- 끝에 `refreshPane('brands')`
- **완료 정의**: 새 브랜드 등록 → 계정 + `dev_link` · 같은 값 재저장 → `noop` · 설정 전 이메일 수정 → 옛 링크 무효·새 링크 동작 · 대표 옮김 → 경고·메일 없음 · 매니저 저장 안내 · 인플루언서 이메일 겹침 안내 · 다른 칸 값 유지

### 조각 11 — 문서 마무리
- CLAUDE.md 원본 번호(`handle_new_user`·`delete_brand`·`merge_brands`·새 함수) · 「supabase-js 9개 HTML」 · 자립형 목록 · 운영 보류 + 관문(P-7)
- 사양서 「구현 결과」 실제 번호·배포 상태·회귀 4종 결과 · Notion 은 운영 반영 뒤(지금은 「할 일」)
- **완료 정의**: 세 문서가 같은 번호·상태 · 「8개 HTML」 0건

---

## ⚠️ 공유 지점 경고

| 공유 지점 | 누가 | 위험 | 대응 |
|---|---|---|---|
| `dev/lib/storage.js`(핫스팟) | 6만 | 9·10 이 따로 추가하면 충돌 | 조각 6 한 번에, 9·10 은 호출만 |
| `dev/lib/supabase.js` | 7만 | 양쪽 빌드에 실림 | 표시가 **있을 때만** 안 만든다 |
| `dev/build.sh`(핫스팟) | 7만 | 목록 + 정규식 두 곳 | 같은 커밋 + 양성 대조 |
| `dev/js/auth.js`·`app.js` | 9만 | 판정 실패 의미 틀리면 전원 로그인 불가 | 실패 = 진행하되 자동 생성 금지 |
| `dev/js/admin-brand.js` | 10만 | 편집 폼 재그리기로 값 소실 | 계정 줄만 |
| 동기화 스크립트 + 카탈로그 | 4·5 | 같은 배열·분기 | 4 → 5 순차 |
| 문서 3종 | 전부 | 병렬 시 충돌 | 조각마다 자기 절, 병합 전 `origin/dev` 반영 |
| `handle_new_user` | 1 | 모든 계정 생성 경로 | 회귀 2종 |
| `admin-setpw.html` | (안 고침) | 로그인 모드 세션 넘어감 | 조각 9 시험 |
| 운영 배포 | 7·9·10 | 화면이 운영 데이터베이스보다 먼저 | P-1 전 운영 병합 금지 |

---

## 🧭 배분 제안

- **데이터베이스 세션**: 1 → 2 → 3 → 4 → 5 순차(번호·비밀값·함수 배포 한곳)
- **개발 A**: 7 을 1~3 과 동시에 → 6 → 8
- **개발 B**(6 병합 뒤): 9 · **개발 C**(6 병합 뒤): 10 — 9 와 파일 안 겹침
- 회귀 4종 배치: 신규 가입(1·9) · 관리자 초대(1) · 인플루언서 비밀번호 찾기(7) · 두 탭 간섭(8·9)
- **고문/기획**: P-12 · 조각 11 규칙 파일 · P-7
