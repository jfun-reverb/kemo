# 📋 작업 분해표 — 브랜드 페이지 멤버 관리·여러 브랜드 · 묶음 ① 서버·데이터베이스·메일

**사양서:** `docs/specs/2026-07-15-brand-portal.md` §16-2~16-5, **§16-7(이 작업의 결정 — 정본)**, Figma `[1차] 06 멤버 관리` · `07 마이페이지` · `01 로그인` · `a03 관리자` 설명 카드
**분해일:** 2026-10-15 (reverb-planner 분해 → 사용자 결정 4건 반영)
**범위:** 묶음 ①만. 묶음 ②(브랜드 화면 `dev/brand/`)·③(관리자 화면 `admin-brand.js`)은 「산출 계약을 받아 쓰는 쪽」으로만 적는다.
**총 작업 조각:** 8개 · **병렬 가능:** 2개(조각 6·7, 조건부) · **순차 필수:** 6개

> 분해 시점 마지막 마이그레이션 번호는 **529**(브랜드와 무관). 번호는 미리 박지 않는다 — 조각마다 「새 마이그레이션(번호는 작성 시 확정)」.
> 🔴 묶음 ① 전체가 **개발서버 전용**이다. 운영 데이터베이스에는 526~528 도 아직 없다. 운영 관문은 사양서 「운영 반영 전 남은 관문」을 따르고, 묶음 ①이 더하는 적용 순서는 조각 8 이 그 관문 4번에 넣는다.

---

## 현재 상태 (2026-10-15 코드 확인)

| 항목 | 실제 |
|---|---|
| 표 | `brand_accounts` · `brand_account_links`(역할 owner/member, 상태 active/released, 브랜드당 활성 대표 1명) · `brand_password_reset_requests` (526). **초대 표·상한·마지막 접속 칸은 없다** |
| 함수 | 527 의 9개 + 도우미 `_brand_email_owner`. 관리자 쓰기 함수·메일 함수의 판정은 **`is_campaign_admin()` 고정**(527 350행, `notify-brand-account-setup` 173행), 상태 조회 `admin_get_brand_account_status` 만 `is_admin()`(관리자 전원) |
| 권한 항목 | 「브랜드 페이지 계정 관리」 **없음** — `ADMIN_PERMISSION_CATALOG`(shared.js)엔 `brand.delete_merge` 만, `role_permissions` 시드(214)에도 없음 |
| 설정 링크 방식 | 서버가 이미 있는 인증 계정에 `generateLink({type:'recovery'})` 로 일회용 링크를 만들고 `setup_link_id` 로 우리 쪽 유효성을 판정(`notify-brand-account-setup` 217~237행). 유효 시간은 로그인 체계 공용 설정(지금 1시간) |
| 16-5 14번(「계정 만들기」 확인 창으로 바꾸기) | **개발서버에 아직 구현 안 됨** — `admin-brand.js` 2463·2520·2586·2611·2628행에 「계정 메일은 캠페인 관리자 이상이 보냅니다」·저장 시 자동 발송이 남아 있다 → **묶음 ③ 몫**. ①은 권한 항목과 서버 판정만 준비 |
| 브랜드 로그인 화면 | 모르는 `state` 값은 「확인 실패」로 로그아웃(`dev/js/brand-login.js` 84~90행) |
| 528 삭제·병합 보호 | 활성 연결이 있으면 삭제·병합 거부, 해제 이력만 있어도 삭제 거부 |

---

## 🚦 착수 전 선결 조건

| # | 선결 조건 | 결과 (2026-10-15 사용자 결정) | 막던 조각 |
|---|---|---|---|
| S0-1 | 관리자가 대표를 해제할 때 남은 「초대 대기」 | ✅ **함께 자동 취소 — 그 브랜드의 대기 초대 전부**(누가 보냈든, 만료 전후 무관. 대표를 넘기고 내려간 옛 대표가 보낸 초대도 포함) — 대표 없는 브랜드에 멤버가 생기는 길을 막는다 | 4 |
| S0-2 | 「브랜드 연결 추가」로 이은 계정이 비밀번호 미설정 | ✅ **설정 메일로 대신** — 연결 안내 메일 대신 비밀번호 설정 메일. 대표 줄은 「설정 메일 보냄」 | 4·7 |
| S0-3 | 공용 링크 유효 시간 1시간 → 24시간 적용 시점 | ✅ **개발서버만 지금**, 운영은 브랜드 페이지 출시 때(운영 관문 목록에 추가). 운영의 인플루언서·관리자 링크는 그때까지 1시간 | 7(문구) · ③ 「~까지 유효(예상)」 |
| S0-4 | 새 이메일로 두 브랜드에서 받은 초대 중 하나를 수락해 계정이 생김 | ✅ **남은 초대 살리기** — 남은 초대는 「로그인해서 수락」(ⓑ)으로 바뀌어 메일 링크·마이페이지에서 그대로 수락. 「링크는 보낼 때의 상태에 묶인다」(16-3 1번)의 예외 — 보낼 때 새 이메일이었는데 **지금 비밀번호를 정한 브랜드 계정**이면(계정이 생긴 경로 무관 — 다른 초대 수락이든 관리자 계정 만들기든) 수락 가능. 같은 초대의 재시도 예외는 조각 1 도우미 참조 | 1(판정 도우미)·3 |
| S1 | 다른 세션에서 마이그레이션을 만드는지 | ⏳ 조각 1 작성 직전에 사용자에게 한 번 묻는다(`multi-session.md`) | 1 |
| S2 | 운영 반영: 브랜드용 약관·방침 + `/약관확인`. **초대 표에는 계정이 없는 사람의 이메일이 쌓인다** — 보관 기간도 이 판단에 넣는다(16-5 2번과 함께) | ⏳ 운영 관문 | 운영 반영만 |

---

## ⚠️ 사양서와 코드가 어긋나는 곳

1. **링크 유효 시간** — 16-6 표는 「1시간 유지」였으나 16-4 ④·16-5 14번 ④는 24시간. 설정 메일 문구 「1시간 동안 유효」(`notify-brand-account-setup` 251행, 비밀번호 찾기 함수에도 사본)를 고친다. 인플루언서 재설정 양식 「1時間後」("1시간 뒤 무효")는 **운영 설정을 바꿀 때**(S0-3) 함께.
2. **527 판정 셋은 「활성 브랜드 연결」만 본다**(셋 중 앞의 둘은 넓히고, 로그인 판정은 4번 방식 — 새 칸) — `get_brand_link_state`(632~641) · `service_issue_brand_account_link`(932~937) · `get_my_brand_login_state`(785~787). 16-4 「비밀번호 재설정」·「로그인은 됐지만 쓸 수 없는 계정」 예외는 **「연결 또는 수락 가능한 대기 초대」** 기준이다. 넓히지 않으면 모두 해제된 뒤 다시 초대받은 사람이 비밀번호 찾기·설정 링크를 못 쓴다. `brand-password-reset-request` 도 같은 판정을 쓴다. 비밀번호를 아직 안 정한 브랜드 계정이 초대를 받으면(관리자가 만든 대표 계정이 설정 전에 해제된 뒤 다른 브랜드가 초대한 경우 등) 이 넓힌 판정으로 설정 링크를 받아 비밀번호를 먼저 정하고, 로그인해서 수락한다.
3. **527 「비로그인 함수는 유효/무효 두 값만」 원칙** — w01-02b·w01-03 은 링크 확인 단계에서 「초대한 대표 이름 · 브랜드 이름」을 보여 준다. 초대 링크 상태 함수가 그 둘을 돌려주는 것은 **의도된 예외**로 기록한다(링크를 가진 사람 = 메일을 받은 사람).
4. **브랜드 로그인 화면은 모르는 상태 값을 실패로 처리** — 로그인 판정에 새 `state` 값을 더하면 ②가 나오기 전까지 그 계정이 막힌다 → `state` 값은 그대로, **새 칸**(`has_pending_invite`)을 더한다.
5. **멤버 상한을 `brands` 표의 칸으로 두면 안 된다** — 브랜드 수정 정책이 `is_admin()` 전원이라 캠페인 매니저가 표를 직접 고쳐 권한 항목을 우회한다 → 쓰기 정책 없는 별도 표.
6. 16-1 의 원본 번호가 낡았다(`invite_admin` 417 → **528**, `handle_new_user` 420 → **526**) — 조각 8 문서에서 고친다. Figma 정리(w06-00 옛 문장 · w07-00b·w07-02 「10/21까지」)는 기획 몫(16-7).
7. **528 은 고칠 필요가 없다** — 초대는 활성 대표가 있어야 만들어지므로 초대 줄이 있는 브랜드엔 연결 이력이 있고 528 이 삭제를 막는다. 병합 원본은 보관 상태가 되고, 「수락 가능」 판정에 「브랜드 활성」을 넣으면 원본의 초대는 자동 무효. 그래서 초대 표의 브랜드 참조는 연쇄 삭제로 둬도 실제로 도달하지 않는다.

---

## 의심·경우의 수 (반대론자)

- **(기술) 새 이메일(ⓐ) 수락 중 끊김** — 인증 계정 삽입 → 비밀번호 저장 → 멤버 연결이 다른 호출이다. 중간 실패 뒤 같은 링크로 재시도하면 「이메일이 이미 계정 → 보낼 때와 상태가 다름 → 무효」로 영영 막힌다 → 계정에 `created_via_invite_id` 를 남겨 **같은 초대의 재시도는 그 계정을 다시 쓴다**(조각 3·6).
- **(데이터) 담당자 목록 덮어쓰기** — 대표 넘기기·바꾸기·연결 추가가 `brands.contacts` 의 대표 표시를 서버에서 옮기는데, 그사이 열려 있던 관리자 편집 폼이 옛 배열을 통째로 저장하면 되돌아간다. 정본 방어선은 ③의 「브랜드 정보 저장은 담당자 칸을 보내지 않는다」. ①은 경고로만 넘긴다. 같은 칸을 쓰는 다른 경로: 광고주 신청서 함수(397) · `merge_brands`(528).
- **(UX) 발송 실패 뒤 대표가 「초대 보내기」를 다시 누름** — 그대로면 「이미 초대 대기 — 다시 보내기를 눌러 주세요」라는 엉뚱한 안내 → 「같은 이메일 + **만료 전** + 지금 링크로 발송 기록이 없는 대기 초대」(`mail_sent_link_id` ≠ `link_id`)면 오류 대신 같은 초대를 돌려준다(멱등 재시도). 다시 보내기 메일만 실패한 초대도 여기에 든다.
- **(권한) 시간 차이로 겹침이 드러남** — ⓐⓑⓒ 모두 메일을 보내고 응답 칸도 같아야 한다. 갈래를 응답에 싣는 순간 대표가 「다른 브랜드 계정」인지 안다. 개발서버 링크 표시도 같은 구조.
- **(법률) 계정 없는 사람의 이메일이 쌓임** — 거절·만료·취소 초대 줄. 보관 기간이 정해질 때까지 정기 삭제는 만들지 않고 S2 에서 판단.
- **가정**: 대표를 넘겨 멤버로 내려간 사람이 보냈던 대기 초대는 **유효**하다(초대는 사람이 아니라 브랜드에 속한다). 다르면 고친다.

**권고:** 데이터베이스는 한 세션이 1→2→3→4 순서. 새 이메일(ⓐ) 수락은 **「일회용 인증 링크 없이, 수락하는 순간 우리 서버가 계정을 만든다」**(조각 6 안 B) — 「수락 전 계정 없음」과 「초대 24시간은 우리 쪽 값」을 둘 다 지키는 길이다. 비밀번호가 우리 서버 함수를 지나가므로 `reverb-supabase-expert` 검토 필수.

---

## 한눈에 보는 의존 순서

```
S1 → 1 기초 → 2 대표 함수 → 3 받는 사람·본인 함수(+527 넓히기) → 4 관리자 함수(+527 권한 교체)
     → 5 초대 메일 → 6 새 이메일 수락 서버 함수  ∥  7 기존 메일 두 함수 확장 → 8 문서
(화살표는 배분 순서다 — 선행 의존은 조각 표의 「선행」 칸이 정본. 병렬 가능은 6·7 둘뿐: 5↔7 은 동기화 스크립트 공유, 5↔6 은 둘 다 3 뒤이나 배분상 순차. 배분 제안은 1명 순차)
묶음 ②·③ 은 1~7 이 개발서버에 들어간 뒤 시작
```

## 작업 조각 표

| 번호 | 제목 | 담당 파일 | 산출 계약(요지) | 선행 | 병렬? | 담당 |
|---|---|---|---|---|---|---|
| 1 | 기초: 표·칸·권한 시드·판정 도우미 | 새 마이그레이션 | `brand_invites` · `brand_member_limits` · `brand_accounts` 칸 6개 · `brand.account_manage` · `my_brand_role` · `is_my_brand` | S1 | ✗ | 개발 |
| 2 | 대표 함수 | 새 마이그레이션 | `create/resend/cancel/hide_brand_invite` · `transfer_brand_ownership` · `release_brand_member` · `get_brand_members` | 1 | ✗ | 개발 |
| 3 | 받는 사람·본인 함수 + 527 넓히기 | 새 마이그레이션 | `get_brand_invite_link_state` · `respond_brand_invite` · `get_my_brand_invites` · 본인 기록 4종 · 로그인 판정 확장 · 서비스 키 둘 | 2 | ✗ | 개발 |
| 4 | 관리자 함수 + 527 권한 교체 | 새 마이그레이션 | `admin_change_brand_owner` · `admin_set_brand_member_limit` · `admin_release_brand_account` · `admin_link_brand_owner_account` · 상태 조회 확장 | 3 | ✗ | 개발 |
| 5 | 초대 메일 서버 함수 + 양식 3 | `supabase/functions/notify-brand-invite/` · `docs/email-templates/brand-invite-{new,existing,blocked}.html` · `scripts/sync-email-templates.sh` · `docs/email-templates/index.html` | `POST {invite_id}` → `{sent, reason?, dev_mail?}` | 3 | ✗ | 개발 |
| 6 | 새 이메일 수락 서버 함수(비로그인) | `supabase/functions/brand-invite-accept/` | `POST {link_id,password,name,phone,terms_version}` → `{ok,email}` | 3 | △(7과) | 개발 |
| 7 | 기존 메일 두 함수 확장 | `supabase/functions/notify-brand-account-setup/` · `brand-password-reset-request/` · `docs/email-templates/brand-link-notice.html` · 동기화 스크립트 · 양식 목록 | 권한 항목 판정 · `mail_kind:'link'`(연결 안내 + S0-2 갈래) · 24시간 문구 · 보낸 쪽 기록 | 4·5 | △(6과) | 개발 |
| 8 | 문서 | 사양서 「구현 결과」 · `docs/FEATURE_SPEC.md` · `CLAUDE.md` | 실제 번호·결과값 기록 | 1~7 | ✗ | 개발(규칙 파일은 고문에게 넘김) |

> S0-2 결정으로 **「브랜드 연결 안내」 메일 양식이 두 갈래**가 된다 — 비밀번호를 정한 계정은 연결 안내 양식(`brand-link-notice.html`, 16-3 9번 개인정보 이용 안내 포함), 안 정한 계정은 기존 설정 메일. 양식 파일은 조각 7에서 만든다.

---

## 조각별 상세

### 작업 1 — 기초 (표·칸·권한 시드·판정 도우미)

- **하는 일:** 초대 기록·브랜드별 상한 자리를 만들고, 계정에 마지막 접속·마이페이지·마지막 브랜드·비밀번호 변경일 칸을 더한다. 권한 항목을 등록하고, 브랜드 범위 판정과 「수락 가능한 초대」 판정을 **각각 한 곳에** 둔다.
- **담당 파일:** 새 마이그레이션(번호는 작성 시 확정).
- **산출 계약 — 표 `brand_invites`**

  | 칸 | 내용 |
  |---|---|
  | `id` | |
  | `brand_id` | 브랜드 참조, 연쇄 삭제(근거는 어긋남 7번) |
  | `email` | `lower(btrim())` 강제 |
  | `invited_by` | 대표 계정. 참조 걸지 않음 |
  | `inviter_name` | 보낸 순간의 대표 이름 스냅샷 |
  | `status` | `pending` / `accepted` / `declined` / `cancelled`. **만료는 저장하지 않는다** — `pending` 이면서 `expires_at` 이 지난 것 |
  | `recipient_kind` | `new`(ⓐ) / `brand`(ⓑ) / `blocked`(ⓒ) |
  | `sent_owner_auth_id` | ⓑ일 때 그 계정 — 「보낼 때의 상태」 |
  | `link_id` | 유일 |
  | `issued_at` | 링크를 낸 시각. 「받은 날」·빨간 점 기준 |
  | `expires_at` | `issued_at` + 24시간을 **저장**. 화면은 이 값만 읽는다(식 사본을 만들지 않는다) |
  | `mail_sent_at` · `mail_sent_link_id` | 발송 선점용 |
  | `declined_at` · `accepted_at` · `accepted_auth_id` · `cancelled_at` | |
  | `owner_hidden_at` | 대표의 「삭제」 |
  | `created_at` | |

  부분 유일 `(brand_id, email) WHERE status='pending'`. 읽기 정책은 **관리자만** — 대표·멤버·받는 사람은 함수로만 본다(멤버에게 대기 줄을 숨기는 규칙을 서버가 지키게). 쓰기 정책 없음.
- **산출 계약 — 표 `brand_member_limits`**: `brand_id`(기본 키, 연쇄 삭제) · `member_limit`(1~50 정수 검사 — **대표를 포함한 인원**. 상한 1이면 대표만 있고 초대할 수 없다) · `updated_at` · `updated_by`. 행이 없으면 5. 읽기 관리자, 쓰기 함수만.
- **산출 계약 — `brand_accounts` 칸 6개**: `last_seen_on date`(일본 날짜) · `mypage_seen_at` · `last_brand_id`(브랜드 참조, 삭제되면 비움) · `password_changed_at`(기존 행은 `password_set_at` 으로 채움) · `setup_mail_sent_by`(`admin`/`self`) · `created_via_invite_id`.
- **산출 계약 — 권한 시드**: `role_permissions` 에 `brand.account_manage` 세 등급(최고 관리자 쓰기 · 캠페인 관리자 쓰기 · 캠페인 매니저 숨김), `default_level` 도 같은 값. 🔴 행이 없으면 판정이 등급별로 반대가 된다(269) → 같은 마이그레이션에서. 화면 카탈로그(shared.js) 등록은 ③ 몫.
- **산출 계약 — 함수**

  | 함수 | 성격 | 내용 |
  |---|---|---|
  | `my_brand_role(p_brand_id uuid) → text` | 로그인 사용자 | `'owner'` / `'member'` / `NULL`. 활성 연결 + 활성 브랜드 |
  | `is_my_brand(p_brand_id uuid) → boolean` | 로그인 사용자 | ②의 조회 정책이 `(SELECT public.is_my_brand(...))` 형태로 쓴다(415 방식) |
  | `_brand_member_limit(uuid)` | 안쪽 전용 | 상한 |
  | `_brand_seat_usage(uuid)` | 안쪽 전용 | 대표 연결이 있으면 1 + 활성 멤버 + **`pending` 이고 만료 전인 초대**(ⓒ·상태가 바뀐 초대도 센다) |
  | `_brand_invite_acceptable(p_invite_id uuid, p_auth_id uuid, p_via_link boolean)` | 안쪽 전용 | 🔴 이 도우미는 **초대가 유효한가**만 본다 — 받는 계정의 비밀번호 설정 여부는 수락 조건이 아니다(아래 예외 둘의 갈래를 가를 때만 쓴다). 셋째 인자는 **예외 1(재시도)만** 켜고 끈다: `true` = 비로그인 새 이메일 경로(`get_brand_invite_link_state`·`service_brand_invite_*`·`brand-invite-accept`), `false` = 그 밖 전부(받은 초대 목록·대기 초대 표시·빨간 점·`respond_brand_invite`, 그리고 527 을 넓히는 `get_brand_link_state`·`service_issue_brand_account_link`·비밀번호 찾기 판정). 비밀번호 요구는 **수락하는 순간** `respond_brand_invite` 가 따로 본다 — 비밀번호를 안 정한 브랜드 계정이면 `setup_incomplete`(Figma w01-03 「아직 비밀번호를 정하지 않은 계정이면 먼저 받은 설정 메일로 정한 뒤 수락」). 그 사람은 넓힌 527 판정 덕에 설정 링크·비밀번호 찾기를 쓸 수 있고(어긋남 2번), 비밀번호를 정한 뒤 로그인해서 수락한다. 나머지 조건: 대기 · 만료 전 · 브랜드 활성 · ⓒ 아님 · 지금 이메일 소유 상태 = 보낼 때 상태 — **예외 둘**(갈래 기호 ⓐⓑⓒ 와 구분해 「예외 1·2」로 부른다. 「비밀번호를 정했는가」는 두 예외 모두 **`brand_accounts.password_set_at` 하나**로 본다 — 인증 계정의 비밀번호 유무가 아니다): **예외 1(재시도)** — 보낼 때 `new` 였고 지금 그 이메일의 계정이 `created_via_invite_id` = 이 초대 + 비밀번호 미설정이면 수락 가능(`new` 그대로 — 조각 6 의 중간 실패 재시도) **예외 2(S0-4)** — 보낼 때 `new` 였고 지금 그 이메일이 **비밀번호를 정한 브랜드 계정**이면 수락 가능(ⓑ로 취급) · (계정이 주어지면) 계정 이메일 = 초대 이메일 |

  🔴 「자리를 차지하는가」(`_brand_seat_usage`)와 「수락할 수 있는가」(`_brand_invite_acceptable`)는 **다른 판정**이다 — 합치면 겹침이 대표의 숫자로 드러나거나 ⓒ가 자리를 안 차지한다. 잠금 열쇠는 **527 과 같은 열쇠**(`'brand_account_upsert:'||brand_id` · `'brand_account_email:'||email`)를 다시 써서 527 대표 계정 만들기와 직렬화한다.
- **선행 의존:** S1.
- **완료 정의:** 두 표의 행 접근 정책 켜짐 + 읽기 정책 1개씩 · 함수 권한 조회에서 `proacl` 맨 앞에 `=X/` 없음, 도우미 셋은 로그인 사용자도 실행 불가 · `role_permissions` 에 `brand.account_manage` 3행 · 되돌림 묶음 시험(527 V4 방식: `set_config` 로 로그인 흉내 + 끝의 `RAISE EXCEPTION`)에서 대표/멤버/무관 계정의 `my_brand_role` 이 `owner`/`member`/`NULL`, 좌석 수(대표 + 멤버 1 + 대기 1 + 만료 1 + 거절 1 = **3**), 시험 뒤 잔여 0건.
- **필요 검문소:** `reverb-supabase-expert`, `reverb-reviewer`.
- **주의·롤백:** 새 표·칸뿐이라 기존 동작은 안 바뀐다. 되돌리기는 함수 → 칸 → 표 순서로 지우고 권한 시드 3행 삭제.

### 작업 2 — 대표 함수

- **하는 일:** 대표만 하는 초대 관리·넘기기·해제, 역할별로 칸을 걸러 돌려주는 멤버 목록. 쓰기 함수 여섯(`create`·`resend`·`cancel`·`hide`·`transfer`·`release`)은 「지금 이 브랜드의 대표인가」를 다시 판정하고 브랜드 잠금 안에서 처리한다. 목록 조회 `get_brand_members` 는 「활성 연결이 있는가」만 보고 역할에 따라 칸을 거른다.
- **산출 계약** (전부 로그인 사용자, `SECURITY DEFINER` + `search_path=''`)

  | 함수 | 반환 | 결과 값 / 동작 |
  |---|---|---|
  | `create_brand_invite(p_brand_id uuid, p_email text)` | jsonb `{result, invite_id, seat_used, member_limit}` | `ok` · `not_owner` · `brand_inactive` · `invalid_email` · `self_email` · `already_member` · `already_pending` · `seat_full` |
  | `resend_brand_invite(p_invite_id uuid)` | jsonb `{result, invite_id}` | `ok` · `not_owner` · `not_found` · `not_resendable` · `seat_full`(만료된 초대일 때만) |
  | `cancel_brand_invite(p_invite_id uuid)` | text | `ok` · `not_owner` · `not_pending` |
  | `hide_brand_invite(p_invite_id uuid)` | text | `ok` · `not_owner` · `not_hideable`. 만료·거절만 「삭제」 → `owner_hidden_at` |
  | `transfer_brand_ownership(p_brand_id uuid, p_new_owner_auth_id uuid)` | text | `ok` · `not_owner` · `not_member` |
  | `release_brand_member(p_brand_id uuid, p_auth_id uuid)` | text | `ok` · `not_owner` · `not_member` |
  | `get_brand_members(p_brand_id uuid)` | jsonb | 아래 |

  - `create_brand_invite`: ⓐⓑⓒ 갈래는 서버가 고르지만 **응답에 싣지 않는다**. 판정 순서: ① 같은 이메일의 대기 초대가 **만료됐으면**(발송 기록과 무관) 아래 「만료 초대」 갈래 ② **만료 전**이고 지금 링크로 발송 기록이 없으면(`mail_sent_link_id` ≠ `link_id`) `ok` + 같은 `invite_id`(멱등 재시도) — 이때도 `resend_brand_invite` 와 같이 **링크·시각·갈래·보낼 때 상태·보낸 사람을 새로 정한다**(자리 검사는 하지 않는다 — 만료 전 대기라 이미 한 자리를 차지하고 있다) ③ 만료 전이고 발송 기록이 있으면 `already_pending`(16-7 — 「다시 보내기」로 안내). 「만료 초대」 갈래: 같은 이메일의 **만료 초대**가 있으면 그 줄로 다시 보내기(자리 검사 포함) — 대표가 「삭제」해 둔 줄이면 `owner_hidden_at` 을 비워 되살린다. 거절함 줄은 다시 쓰지 않고 새 줄을 만든다(거절한 초대는 살리지 않는다 — w07-02).
  - `resend_brand_invite`: 새 `link_id`·`issued_at`·`expires_at`, 갈래와 「보낼 때 상태」를 다시 판정, `mail_sent_*` 비움, **`invited_by`·`inviter_name` 을 지금 누른 대표로 바꾼다**(대표를 넘긴 뒤 다시 보내면 새 대표 이름이 메일·링크 화면에 뜬다). 만료 줄 되살리기와 멱등 재시도도 같다.
  - `transfer_brand_ownership`: **옛 대표 연결을 해제하고 멤버 연결을 새로 만들고, 새 대표 쪽도 같은 방식**(역할을 덮어쓰지 않는다 → 연결 표에 이력). 대표가 0명·2명인 순간이 없게 한 트랜잭션. 담당자 목록 대표 표시 이동은 안쪽 전용 `_brand_contacts_mark_primary(brand, auth_id)`(이메일로 같은 사람 판정, 없으면 계정 이름·이메일·연락처로 한 줄 추가, 옛 줄은 표시만 뗌). 메일 없음.
  - 대표 전환 본체는 안쪽 전용 `_brand_transfer_owner(p_brand_id uuid, p_new_owner_auth_id uuid)` 로 둔다(옛 대표 해제 + 멤버 연결, 새 대표 쪽 같은 방식, 담당자 표시 이동까지). `transfer_brand_ownership`(대표 판정 뒤)과 조각 4 `admin_change_brand_owner`(권한 판정 뒤)가 둘 다 이것을 부른다.
- `release_brand_member`: 대표·본인·이미 해제된 사람은 `not_member`.
  - `get_brand_members` 반환 `{my_role, seat_used, member_limit, rows[]}`, 행 `{kind:'account'|'invite', auth_id, invite_id, name, email, role, status:'active'|'pending'|'expired'|'declined', issued_at, expires_at, declined_at, last_seen_on}`. 🔴 **멤버가 부르면** `kind='account'` 행만, `auth_id`·`last_seen_on` 은 뺀다(16-7). 연결이 없으면 `{result:'not_linked'}`. 초대 행의 `name` 은 늘 비운다(겹침 비노출). 숨김·취소·수락된 초대는 싣지 않는다.
- **선행 의존:** 1.
- **완료 정의:** 되돌림 묶음 시험에서 — ⓐⓑⓒ 세 이메일로 `create` 한 **응답 jsonb 의 키 집합이 같고 `result` 가 모두 `ok`, `seat_used` 는 매번 1씩 증가**(갈래를 짐작할 값이 없다) · 상한 5에서 대표 + 초대 4건 뒤 **다섯째 초대** `seat_full` · 만료 초대 `resend` 는 자리 있으면 `ok`/없으면 `seat_full`, 대기 초대 `resend` 는 가득 차도 `ok` · 멤버의 `create` → `not_owner` · 멤버 호출 `get_brand_members` 에 초대 행 0 + `last_seen_on` 키 없음 · 넘기기 뒤 `brands.contacts` 대표 표시가 새 대표 이메일 줄 · 잔여 0.
- **필요 검문소:** `reverb-supabase-expert`, `reverb-reviewer`.
- **주의·롤백:** 함수만 추가. `brands.contacts` 를 서버가 고치는 첫 경로라 「공유 지점 경고」의 덮어쓰기 위험을 병합 요청 본문에 적는다.

### 작업 3 — 받는 사람·본인 함수 + 527 넓히기

- **하는 일:** 메일 링크 판정, 수락·거절, 받은 초대 목록과 빨간 점, 마지막 접속·마이페이지·마지막 브랜드·이름/연락처·비밀번호 변경 기록. 527 판정 둘(`get_brand_link_state`·`service_issue_brand_account_link`)을 「연결 또는 수락 가능한 대기 초대」로 넓히고, 로그인 판정은 `state` 를 그대로 두고 새 칸으로 알린다(어긋남 4번). 설정·재설정을 **마치는** 함수 둘(`complete_brand_account_setup`·`complete_brand_password_reset`)은 지금도 연결을 보지 않고 링크 번호 일치만 본다(527 확인) — 그대로 둔다.
- **산출 계약 — 새 함수**

  | 함수 | 반환 | 결과 값 / 동작 |
  |---|---|---|
  | `get_brand_invite_link_state(p_link_id uuid)` | jsonb `{state:'valid'|'invalid', recipient:'new'|'existing', brand_name, inviter_name, expires_at}` | 비로그인·로그인 모두. 무효면 `state` 만. 판정은 조각 1 `_brand_invite_acceptable` 그대로 — ⓒ 줄은 무효, `new` 인데 이메일이 계정이 된 줄은 무효이되 재시도 예외면 `recipient:'new'`, S0-4 예외면 `recipient:'existing'` 으로 유효 |
  | `respond_brand_invite(p_invite_id uuid, p_link_id uuid, p_action text)` | jsonb `{result, brand_id}` | `ok` · `already_member` · `invalid` · `not_brand` · `setup_incomplete`. 메일 링크는 `p_link_id`, 마이페이지는 `p_invite_id` 로 지목 — **같은 함수**. `p_action` 은 `'accept'`/`'decline'`. 무효 사유는 나누지 않는다. 수락은 비밀번호 설정을 마친 계정만, 자리는 다시 검사하지 않는다(보낼 때 막는다) |
  | `get_my_brand_invites()` | jsonb 배열 `[{invite_id, brand_id, brand_name, inviter_name, issued_at, expires_at}]` | 수락 가능한 초대만 |
  | `mark_my_brand_mypage_seen()` | | 빨간 점 끄기 |
  | `set_my_brand_last_viewed(p_brand_id uuid)` | text | `ok` · `not_linked` |
  | `update_my_brand_profile(p_name text, p_phone text)` | text | `ok` · `name_required` · `not_brand`. 앞뒤 공백 제거. 담당자 목록과 맞추지 않는다 |
  | `mark_my_brand_password_changed()` | text | 마이페이지 비밀번호 변경 뒤 화면이 부른다 |

- **산출 계약 — `get_my_brand_login_state()` 재정의(베이스 527)**: **`state` 값은 그대로**(`ok`·`not_brand`·`setup_incomplete`·`no_active_brand`). 칸 추가 `last_brand_id` · `has_pending_invite` · `new_invite_dot` · `password_changed_at`. **마지막 접속 하루 한 번 기록도 이 안에서**(`last_seen_on < 오늘(일본 날짜)` 일 때만) — 화면이 부르기를 잊을 수 없게.
- **산출 계약 — 527 재정의**(베이스 527, `CREATE OR REPLACE`): `get_brand_link_state` · `service_issue_brand_account_link` → 「활성 연결 **또는** 수락 가능한 대기 초대」 · `complete_brand_account_setup` · `complete_brand_password_reset` → `password_changed_at` 기록 · `service_mark_brand_setup_mail_sent(p_auth_id uuid, p_link_id uuid, p_sent_to text, p_sent_by text DEFAULT 'admin')` — 🔴 인자가 늘어 **옛 3인자를 `DROP` 후 만들고 실행 권한 회수를 다시 건다**(두 벌이면 호출이 모호).
- **산출 계약 — 서비스 키 전용(조각 6이 씀)**
  - `service_brand_invite_create_account(p_link_id uuid, p_name text, p_phone text, p_terms_version text)` → `{ok, auth_id, email, reason}` — 초대 잠금 + 이메일 잠금 → 수락 가능 확인 **그리고 지금 갈래가 `new`(재시도 예외 포함)** — S0-4 갈래(이미 비밀번호를 정한 계정)면 `invalid_link` 로 거부(로그인해서 수락할 길이다) → 인증 계정 직접 삽입(527 방식, 비밀번호 빈칸, `account_kind='brand'`) + `brand_accounts`(이름·연락처·약관 동의 시각·판, `created_via_invite_id`). 같은 초대로 이미 만든 계정(비밀번호 미설정)이 있으면 다시 쓴다.
  - `service_brand_invite_finalize(p_link_id uuid, p_auth_id uuid)` → `{ok, brand_id, reason}` — 인증 계정에 비밀번호가 실제로 있는지 확인 → `password_set_at`·`password_changed_at` → 멤버 연결 → 초대 `accepted`.
- **설계 메모 — 마이페이지 현재 비밀번호 확인(w07-01)**: 서버 함수 안에서 비밀번호 원문 비교는 **권하지 않는다**(원문이 호출 인자로 들어가고 횟수 제한이 없다). 권고: ②가 저장하지 않는 별도 연결로 「현재 비밀번호 로그인」을 한 번 해 확인한 뒤 `updateUser` — 로그인 체계 횟수 제한을 그대로 받는다. ①은 `mark_my_brand_password_changed` 만 낸다. 로그인 체계에 「현재 비밀번호 요구」 설정이 있는지는 `reverb-supabase-expert` 가 확인.
- **선행 의존:** 2.
- **완료 정의:** `get_brand_invite_link_state(무작위 번호)` → `{"state":"invalid"}` · 되돌림 묶음 시험에서 ⓑ 계정 흉내 `respond_brand_invite(link,'accept')` → `ok` + 연결 생김, 재호출 `invalid`, 다른 계정 흉내 `invalid`, 거절 → 좌석 1 감소 · 연결 모두 해제된 계정 + 대기 초대 → 로그인 판정 `no_active_brand` + `has_pending_invite=true`, 같은 계정 `service_issue_brand_account_link(...)` → `ok`, `get_brand_link_state` → `valid`, 그 링크 번호로 `complete_brand_password_reset` 까지 `ok`(재설정을 끝까지 마침) · 다시 보내기 뒤 `new_invite_dot=true`, `mark_my_brand_mypage_seen` 뒤 `false` · **S0-4**: 새 이메일로 두 브랜드 초대 → 하나 수락(`service_brand_invite_create_account` → **SQL 로 그 인증 계정의 비밀번호를 채운 뒤**(조각 6 ③ 대신) → `service_brand_invite_finalize`) → 남은 초대의 `get_brand_invite_link_state` 가 `recipient:'existing'` 으로 `valid` · 회귀: 기존 대표 설정 → 로그인 → 비밀번호 찾기 시험 묶음(527 V5) 통과.
- **필요 검문소:** `reverb-supabase-expert`, `reverb-reviewer`.
- **주의·롤백:** 🔴 527 함수 **여섯**을 재정의한다(`get_my_brand_login_state` + 위 다섯) — 되돌리려면 **먼저 4인자 `service_mark_brand_setup_mail_sent` 를 `DROP`** 한 뒤 527 해당 구문 여섯을 재실행하고 실행 권한 회수도 다시 건다(4인자를 남긴 채 3인자를 되살리면 기본값 때문에 3인자 호출이 모호 오류). 🔴 **조각 7 배포 뒤에** 조각 3 을 되돌리려면 조각 7(두 메일 함수 — 넷째 인자를 넘긴다)을 **먼저** 되돌린다. `service_mark_brand_setup_mail_sent` 는 넷째 인자 `p_sent_by` 에 **기본값 `'admin'`** 을 준다 — 옛 3인자를 지우고 4인자를 만들어도 지금 서버 함수 둘의 3인자 호출이 그대로 돈다. 그래서 조각 7(두 함수가 `'self'` 를 넘기게 고치는 것)과 같은 날 배포할 필요가 없다. 조각 7 전까지 비밀번호 찾기 재발송도 `admin` 으로 기록되는 것은 개발서버에서만 생기는 일이라 받아들인다.

### 작업 4 — 관리자 함수 + 527 권한 교체

- **산출 계약** — 쓰기 함수 다섯(`admin_change_brand_owner` · `admin_set_brand_member_limit` · `admin_release_brand_account` · `admin_link_brand_owner_account` · `admin_upsert_brand_owner_account`)은 `has_permission('brand.account_manage','write')`, 거부는 `forbidden`. 상태 조회 `admin_get_brand_account_status` 만 **관리자 전원**(527 그대로 — 관리자가 아니면 권한 오류)이고 `can_manage` 로 쓰기 권한 여부를 알려 준다

  | 함수 | 반환 | 결과 값 / 동작 |
  |---|---|---|
  | `admin_change_brand_owner(p_brand_id uuid, p_new_owner_auth_id uuid, p_expected_owner_auth_id uuid)` | text | `ok` · `forbidden` · `owner_changed`(a03-02b) · `not_member`. 작업 2의 안쪽 전용 `_brand_transfer_owner` 를 그대로 쓴다 |
  | `admin_set_brand_member_limit(p_brand_id uuid, p_limit int)` | jsonb `{result, member_limit, seat_used}` | `ok` · `forbidden` · `invalid_limit`(1~50 밖) · `brand_not_found`. 지금 인원보다 작아도 받는다. 이력 없음 |
  | `admin_release_brand_account(p_brand_id uuid, p_auth_id uuid)` | jsonb `{result, cancelled_invites}` | `ok` · `forbidden` · `not_linked` · `owner_has_members`(활성 멤버가 있는 대표). **S0-1: 대표를 해제하면 그 브랜드의 대기 초대를 함께 `cancelled`** — 취소한 수를 돌려준다 |
  | `admin_link_brand_owner_account(p_brand_id uuid, p_email text)` | jsonb `{result, auth_id, password_set, email_kind}` | `ok` · `forbidden` · `owner_exists` · `not_brand_account` · `brand_archived` · `invalid_email`. 대표 없는 브랜드에만, 대표로만. 다른 브랜드에 연결된 계정 허용(527 `conflict_brand` 를 이 경로에서만 푼다). `email_kind` 는 a03-04a 문구용 `none`/`influencer`/`admin`(관리자에겐 숨길 이유가 없다). 담당자 표시 이동. 연결 뒤 화면은 메일 함수를 `mail_kind:'link'` 하나로 부르고 **양식은 서버가 고른다**(조각 7 — S0-2). `password_set` 은 표시용 |
  | `admin_get_brand_account_status(p_brand_id uuid)` 확장 | jsonb | 기존 칸 유지 + `setup_mail_sent_by` · `owner_auth_id` · `members[]`(이름·이메일·연락처·`last_seen_on`·`password_set_at`) · `invites[]`(대기·만료·거절, `owner_hidden_at` 포함 — 보일지는 ③ 결정 16-5 11번) · `seat_used` · `member_limit` · `can_manage`. jsonb 그대로라 `CREATE OR REPLACE` |
  | `admin_upsert_brand_owner_account` | | 본문은 527 그대로, 가드만 `is_campaign_admin()` → 권한 항목. 🔴 **16-3 1번 겹침**: 「계정 만들기」의 이메일이 다른 브랜드 계정이면 527 대로 `conflict_brand` 를 돌려주고, **③ 화면이 이어서 `admin_link_brand_owner_account` 로 연결 + 연결 안내 메일**로 처리한다(이 함수 본문은 바꾸지 않는다) |

- **선행 의존:** 3.
- **완료 정의:** 되돌림 묶음 시험(최고 관리자·캠페인 관리자·매니저 흉내)에서 매니저 → 쓰기 함수 다섯 모두 `forbidden`(상태 조회는 `can_manage=false` 로 성공), 캠페인 관리자 → `ok` · 멤버가 있는 대표 해제 → `owner_has_members` · 멤버 없는 대표 + 대기 초대 2건 해제 → `ok` + `cancelled_invites=2` · 다른 브랜드 대표 계정 연결 → `ok` + 담당자 표시 이동 · 대표가 있는 브랜드에 연결 → `owner_exists` · 상한 0 → `invalid_limit` · 매니저 권한을 SQL 로 「쓰기」로 바꾸면 같은 호출이 `ok`(서버가 설정을 실제로 따른다) · 로그인한 관리자 브라우저에서 상태 조회 1회.
- **필요 검문소:** `reverb-supabase-expert`, `reverb-reviewer`.
- **주의·롤백:** 가드 교체로 지금 개발서버의 「저장 시 자동 발송」 경로(③이 걷을 예정)는 판정 기준만 바뀌고 계속 돈다. 되돌리려면 527 구문 재실행.

### 작업 5 — 초대 메일 서버 함수 + 양식 3

- **하는 일:** 대표 화면이 `create`·`resend` 성공 뒤 부르는 함수. 브라우저 직접 호출 → **교차 출처 허용 헤더와 사전 요청(`OPTIONS`) 처리 필수**, 공개 키 거부는 걸지 않는다.
- **절차:** ① 로그인 토큰으로 호출자 확인 ② 「호출자 = 그 초대 브랜드의 현재 대표」 재확인 ③ 받는 사람·갈래·링크는 **요청이 아니라 초대 줄에서** 다시 읽는다 ④ **선점 먼저** — `mail_sent_link_id` 가 지금 `link_id` 가 아닐 때만 그 값으로 바꾸고 보낸다, 실패하면 선점을 되돌린다 ⑤ 양식 셋 — ⓐ 비밀번호 설정 링크 / ⓑ 로그인해 수락 링크 / ⓒ 링크 없음 「다른 이메일로 초대를 요청해 주세요」, 셋 모두 「누가·왜·모르면 무시」(16-3 2번) ⑥ 링크 착지 `PUBLIC_BRAND_URL/brand/?link=…&kind=invite` — 일회용 인증 링크가 없어 감출 토큰도 없다. 「계속하기」(w01-08)는 화면 몫.
- **산출 계약:** `POST {invite_id}` → `{sent:true}` · `{sent:false, reason:'send_failed'|'forbidden'|'not_pending'|'already_sent'|'invalid_request'|'unauthorized'}`. **갈래는 응답에 싣지 않는다.** 개발서버 두 겹 잠금(`BRAND_SETUP_DEV_ECHO=1` **그리고** 개발 프로젝트 주소)일 때만 메일 대신 `dev_mail`(제목 + 본문 텍스트 — 링크가 있으면 그 안에)을 싣는다. **ⓐⓑⓒ 모두 같은 키**라 개발서버에서도 응답 모양으로 갈래가 드러나지 않는다(내용을 읽는 것은 시험자뿐). 새 비밀값 없이 같은 스위치. 발송 성공 시 `mail_sent_at`, 실패해도 대기 줄 유지(16-7).
- **선행 의존:** 3(링크 착지가 조각 3 의 링크 상태 함수를 전제로 한다 · 조각 7 과 동기화 스크립트를 공유하므로 순차).
- **완료 정의:** 개발서버 배포 뒤 `OPTIONS` 200 + 허용 헤더 · 토큰 없음 401 · 멤버 토큰 403 · 대표 토큰으로 ⓐⓑⓒ 응답 키 집합이 같다 · 같은 링크 두 번째 호출 `already_sent` · 양식 동기화 뒤 `templates.ts` 에 세 양식 · 실제 발송 시험은 운영에서만(`supabase.md`).
- **필요 검문소:** `reverb-reviewer`(교차 출처 허용·선점·잠금 둘), `reverb-supabase-expert`.

### 작업 6 — 새 이메일(ⓐ) 수락 서버 함수 (비로그인 공개)

- **방식 비교**

  | 안 | 내용 | 판정 |
  |---|---|---|
  | A | 초대를 보낼 때 계정을 만들고 지금의 설정 링크를 그대로 쓴다 | ✗ — 「수락 전에는 계정 없음」(w06-01 주의, 16-4 재설정 ⓒ) 위반 |
  | **B (채택)** | 수락 순간 서버가 계정을 만든다. 일회용 인증 링크 없이 우리 링크 번호만 | ✓ — 24시간이 공용 설정과 무관하게 우리 값 · 메일 보안 프로그램의 미리 열기에 안 소진 · 계정 생성과 비밀번호가 한 화면에서 끝 |
  | C | 「계속하기」 순간 계정을 만들고 복구 링크를 응답으로 돌려줘 기존 설정 화면을 쓴다 | △ — 화면 재사용이 장점이나 떠나면 반쪽 계정, 공용 링크 시간(S0-3)에 묶임 |

- **B 절차:** ① 화면이 `{link_id, password, name, phone, terms_version}` 전송 ② `service_brand_invite_create_account` ③ `auth.admin.updateUserById(auth_id, {password})` ④ `service_brand_invite_finalize` ⑤ `{ok:true, email}` ⑥ 화면이 그 이메일·비밀번호로 로그인(② 몫).
- **걸리는 장치 대조:** 497 가입 관문 — 삽입은 정의자 권한(소유자 postgres)이라 통과, 비밀번호 저장은 `email_confirmed_at` 이 채워진 행이라 고쳐 쓰기 관문 첫 줄에서 통과 · 526 가입 트리거 — `account_kind=brand` 라 인플루언서 행 없음 · 498 미인증 정리 — 대상 아님.
- **위험:** 비밀번호 원문이 우리 서버 함수를 지나감 → 로그에 요청 본문을 남기지 않는다 · 단계 사이 실패 → `created_via_invite_id` 로 멱등 재시도 · 비밀번호 규칙(8자·소문자·기호)은 지금처럼 화면에서만, 서버는 로그인 체계 최소값만(셋째 사본을 만들지 않는다).
- **산출 계약:** `POST {link_id, password, name, phone, terms_version}` → `{ok:true, email}` | `{ok:false, reason:'invalid_link'|'password_rejected'|'server_error'}`. 교차 출처 허용·`OPTIONS` 있음, 공개 키 거부 없음. 응답·로그에 링크·비밀번호를 싣지 않는다. 무효 사유는 나누지 않는다.
- **선행 의존:** 3.
- **완료 정의:** 개발서버에서 시험 초대(ⓐ)의 `link_id` 로 호출 → `ok`, 데이터베이스에 인증 계정 1 + `brand_accounts`(이름·동의 시각) + 멤버 연결 + 초대 `accepted` + 인플루언서 행 0 · 같은 링크 재호출 `invalid_link` · `updateUserById` 단계를 일부러 실패시킨 뒤 재호출 → 같은 계정으로 완료 · ④ 마무리 단계만 실패시킨 뒤(비밀번호는 저장됨, `password_set_at` 은 빈칸) 재호출 → 재시도 예외로 같은 계정이 완료(로그인 경로로 새지 않는다).
- **필요 검문소:** `reverb-supabase-expert`(필수 — 인증 계정 직접 삽입·관문 대조), `reverb-reviewer`.
- **주의·롤백:** 시험 계정은 528 가드 때문에 **연결부터** SQL 로 지운 뒤 인증 계정을 지운다. 함수는 개발서버에서 삭제·재배포로 되돌린다.

### 작업 7 — 기존 메일 두 함수 확장 + 연결 안내 양식

- **`notify-brand-account-setup`:** 호출자 역할 목록 판정 → `has_permission('brand.account_manage','write')` 를 사용자 연결로 묻는다 · 요청 칸 `mail_kind:'link'` 추가(기존 호출은 칸 없음 = 설정 메일) — 「브랜드 연결 추가」 뒤 화면이 부른다. **양식은 서버가 고른다** — 비밀번호를 정한 계정이면 연결 안내 양식, 아니면 S0-2 갈래로 기존 설정 메일(대표 줄 「설정 메일 보냄」) · 유효 시간 문구 24시간(개발서버 설정 변경 뒤 — S0-3) · 발송 기록 `p_sent_by='admin'`.
- **`brand-password-reset-request`:** 갈래 판정은 조각 3 의 함수가 이미 넓혀 주므로 판정 쪽 변경은 없다 · 설정 메일 재발송 기록 `p_sent_by='self'` · 유효 시간 문구 24시간(어긋남 1번의 사본) · ⚠️ 「다시 보냄」 문구 사본이 두 함수에 있다 — 둘 다 고친다.
- **양식:** `docs/email-templates/brand-link-notice.html`(16-3 9번 개인정보 이용 안내 포함). 인플루언서 `reset-password.html` 의 「1時間後」("1시간 뒤 무효")·양식 목록 「1시간 만료」는 **운영 설정을 바꿀 때**(S0-3 — 출시 관문) 고친다.
- **선행 의존:** 4·5(5 와 동기화 스크립트·양식 목록을 공유).
- **완료 정의:** 개발서버에서 매니저 토큰 → 403, 권한 설정을 「쓰기」로 바꾸면 200 · `mail_kind:'link'` → 비밀번호 정한 계정은 연결 안내, 안 정한 계정은 설정 메일(`dev_link` 또는 `sent:true`) · `brand_accounts.setup_mail_sent_by` 값 확인.
- **필요 검문소:** `reverb-reviewer`.

### 작업 8 — 문서

- 사양서 「구현 결과」에 실제 번호·결과 값 목록·달라진 것 · `FEATURE_SPEC.md` · `CLAUDE.md`(브랜드 계정 절 함수 목록·현재 원본 번호 — `get_my_brand_login_state` 등 527 → 새 번호, 16-1 낡은 번호).
- 고문에게 넘길 것: `.claude/rules/brand-account.md` 함수 목록, `mail-webhooks.md` 에 서버 함수 둘(`notify-brand-invite`·`brand-invite-accept` — **둘 다 공개 키 거부 대상 아님**).
- 사양서 「운영 반영 전 남은 관문」에 **S0-3 운영 링크 유효 시간 24시간 변경**(+ 인플루언서 재설정 문구)을 추가(7번 — 이미 들어감). 그리고 관문 4번 적용 순서에 묶음 ①을 넣는다: 526 → 527 → 528 → **묶음 ① 마이그레이션들** → 서버 함수 넷(기존 둘 + `notify-brand-invite`·`brand-invite-accept`) + 비밀값 → 화면 판정 걷기. 🔴 **운영 링크 시간 설정을 24시간으로 바꾼 뒤에** 24시간 문구를 담은 함수를 배포한다(반대면 운영 메일이 「24시간」이라고 거짓 안내한다).

---

## ⚠️ 공유 지점 경고

- **527 함수 재정의(조각 3·4)** — 이후 원본이 바뀐다. 사양서·`CLAUDE.md` 「현재 원본 번호」를 같은 커밋에서.
- **`brands.contacts`** — 서버(조각 2·4)·관리자 편집 폼·광고주 신청서 함수(397)·`merge_brands`(528)가 함께 쓴다. ③의 「브랜드 정보 저장은 담당자 칸을 보내지 않는다」 전까지 덮어쓰기 위험.
- **`scripts/sync-email-templates.sh` · `docs/email-templates/index.html`** — 조각 5·7이 함께 → 한 세션에서 순서대로.
- **`get_my_brand_login_state` 반환 모양** — ②의 `brand-login.js`·`brand-app.js` 가 쓴다. 키를 지우거나 이름을 바꾸지 않는다.
- **`dev/lib/shared.js` `ADMIN_PERMISSION_CATALOG`(핫스팟)** — ③ 몫. ①은 데이터베이스 시드만.
- **범위 밖(다른 묶음·사양):** 브랜드 화면 조회 정책에 `is_my_brand` 적용(오리엔시트·캠페인 등 — ②) · 회사 정보 네 칸 함수 · 오리엔시트 「마지막 저장자」 · 관리자 담당자 줄 단위 저장 함수(16-5 6번 별도 사양) · 🔴 **16-5 11번에서 「관리자가 초대 대기를 대신 취소」를 「예」로 정하면 ③ 앞에 관리자 초대 취소 함수 조각을 하나 더 둔다**(①의 `cancel_brand_invite` 는 대표 전용).

## 🧭 배분 제안

- **개발 1명이 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 순서로.** 데이터베이스 조각은 번호 충돌 때문에 한 세션.
- 6·7은 파일이 안 겹쳐 이론상 병렬이지만, 7이 동기화 스크립트를 5와 공유하고 6은 데이터베이스 전문 검토가 무거워 이득이 작다 → **1명 순차**.
- ②·③은 ①이 개발서버에 반영된 뒤. ②·③끼리는 파일이 갈려 병렬 가능(③은 `storage.js`·`shared.js` 핫스팟 — 다른 작업과 겹치지 않게).
