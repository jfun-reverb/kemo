# 브랜드 「연결 요청」 — 관리자가 기존 브랜드 계정을 대표로 이을 때 본인 수락 (2026-10-21)

> **무엇:** 관리자가 **이미 있는 브랜드 계정**을 대표 담당자가 없는 브랜드에 대표로 이을 때, 지금처럼 바로 잇지 않고 **「연결 요청」**을 보낸다. 본인이 **24시간 안에** 메일 링크나 브랜드 페이지 마이페이지 「받은 초대」에서 수락해야 연결된다.
> **근거:** 사양 `docs/specs/2026-07-15-brand-portal.md` §16-8 1번 · §16-3 1번 · §16-5 18번 · 브랜드 이용약관 초안 `docs/TERMS_brand_kr.md` 제5조 5항(「이미 계정이 있는 사람은 본인이 수락해야 다른 브랜드에 연결됩니다(대표 담당자의 초대와 회사의 연결 요청 모두). 수락은 그때 시행 중인 이 약관과 개인정보처리방침에 대한 동의가 됩니다」).
> **출시:** 브랜드 페이지 1차·관리자 브랜드 상세 탭 재구성(`docs/specs/2026-10-21-admin-brand-detail-tabs.md`)과 **같은 날**. 이 기능이 없으면 약관 제5조 5항과 동작이 어긋나 출시 관문 1(`/약관확인`)을 못 넘는다.
> **짝 문서:** 관리자 쪽 화면(「브랜드 연결 추가」 a03-04 · 겹침 창 「연결」 a03-01c · 「연결 요청 보냄」 a03-91a)은 관리자 작업표 `docs/specs/2026-10-21-admin-brand-detail-tabs-breakdown.md` **조각 13**이 이 문서의 서버 계약(4-2)으로 붙인다. 그 작업표 「작업 4」는 이 문서로 대체된다. 착수용 인계: `docs/specs/2026-10-21-brand-link-request-handoff.md`.
> **환경:** 전부 **개발서버만**. 운영은 브랜드 페이지 묶음(526 → … → 533 → 534 → …)과 함께 들어간다.

---

## 1. 범위

**넣는 것**
1. 서버: 연결 요청 만들기·취소·수락·거절, 관리자 계정 상태 조회에 요청 상태
2. 메일: 「브랜드 연결 요청」(Figma bw01-98) 한 통
3. 브랜드 화면: 메일 링크 착지 · 로그인 뒤 수락 화면 · 마이페이지 「받은 초대」 줄 · **비밀번호를 아직 안 정한 계정은 링크에서 비밀번호를 정하며 바로 수락**
4. 수락할 때 약관 동의 기록 — 연결 요청과 **멤버 초대 둘 다**(L3)
5. 걷어낼 것: 즉시 연결 함수 `admin_link_brand_owner_account`(533) · 설정 메일 함수의 「연결 안내」 갈래(`mail_kind:'link'`)와 양식 `brand-link-notice`

**넣지 않는 것**
- 관리자 화면 그 자체(관리자 작업표 조각 13)
- 같은 브랜드 안에서 대표를 바꾸는 길 — 이미 있는 「대표 바꾸기」(`admin_change_brand_owner`)
- 멤버 초대를 비밀번호 안 정한 계정이 링크에서 바로 수락하는 길(지금처럼 「먼저 설정 메일로 비밀번호를 정하세요」 안내 — 사양 §16-8 1번은 연결 요청만 정했다. 후속 후보)
- 이메일 바꾸기·관리자가 멤버 초대를 대신 취소하기(사양 §16-5 11번 — 관리자는 멤버 초대를 대신 취소하지 않는다)

---

## 2. 확정된 결정

| # | 결정 | 근거 |
|---|---|---|
| L1 | 연결 요청은 **멤버 초대 표 `brand_invites` 에 종류 칸을 더해** 저장한다(새 표를 만들지 않는다) | 2026-10-21 사용자. 「받은 초대」·빨간 점·메일 링크 판정·비밀번호 찾기 열림이 모두 이 표 하나를 본다 — 표를 나누면 그 판정이 두 벌이 된다 |
| L2 | 요청 대상 이메일이 이미 그 브랜드에 연결된 계정이면 요청을 **거부**한다(`already_linked`, 안내 「이미 이 브랜드에 연결된 계정입니다」) | 2026-10-21 사용자(「거부 + 「대표 바꾸기」 안내」를 골랐다). ⚠️ 이 결과는 대표가 없는 브랜드에서만 나오는데 「대표 바꾸기」는 지금 대표가 있어야 동작한다(533 `owner_changed`) — 그래서 안내에서 그 단추 이름은 뺐다. 정상 경로로는 생기지 않는다(대표가 없는 브랜드엔 활성 멤버가 없다 — 멤버가 있으면 대표 해제가 거부된다, 533 `owner_has_members`). 방어용 |
| L3 | **수락하는 순간 그때의 약관 버전·시각을 계정에 기록**한다 — 연결 요청과 멤버 초대 **둘 다** | 2026-10-21 사용자. 약관 제5조 5항 「수락은 … 동의가 됩니다」. 지금 기존 계정의 멤버 초대 수락은 동의를 남기지 않는다(532 `respond_brand_invite`) |
| L4 | 메일·「받은 초대」에서 보낸 사람은 **「REVERB 운영팀」** | 2026-10-21 사용자. 관리자 실명을 고객사에 드러내지 않는다 |
| L5 | 길 셋(「브랜드 연결 추가」 · 겹침 창 「연결」 · 대표 이메일 바꿔 저장)은 화면에서 **둘**(a03-04 · a03-01c)이고, 둘 다 같은 서버 함수 하나를 부른다 | 관리자 사양 D11 — 셋째 길은 저장이 계정 동작을 일으키지 않게 되어 a03-01c 로 합쳐졌다 |
| L6 | 기한 **24시간**. 지나면 관리자가 같은 길로 다시 보낸다 | 사양 §16-8 1번 · §16-5 18번 |
| L7 | 계정 관리 권한(`brand.account_manage` 쓰기)이 있는 관리자는 **누구나** 관리자가 보낸 연결 요청을 취소할 수 있다(보낸 사람이 아니어도) | 관리자 사양 5-6 |
| L8 | 비밀번호를 아직 안 정한 계정은 **메일 링크에서 비밀번호를 정하며 바로 수락**(Figma bw01-02b 모양) | 사양 §16-8 1번 |
| L9 | 대표 표시(담당자 목록의 대표 줄)는 **수락한 때** 바뀐다 | 사양 §16-8 1번 |

## 2-1. 가정 (사용자 결정 없이 이 문서가 정한 것 — 바꾸려면 말해 달라)

| # | 가정 | 이유 |
|---|---|---|
| B1 | 연결 요청은 **브랜드당 대기 하나**. 대기 줄이 있을 때 — **같은 이메일**이면 만료 전후 상관없이 그 줄을 **다시 발급**(새 링크·새 24시간, 옛 링크는 죽는다 — 「다시 보내기」가 이것) · **다른 이메일**이면 만료 전은 거부(`request_exists`), 만료 뒤는 옛 줄을 취소하고 새로 만든다 | 대표는 한 명이라 요청도 하나. 관리자 둘이 동시에 보내도 하나만 남는다. 메일이 실패했을 때 다시 보내는 길도 같은 함수 하나 |
| B2 | 연결 요청은 **멤버 자리 계산에 넣지 않고**, 수락 때 자리 검사도 하지 않는다 | 대표가 없는 브랜드에는 활성 멤버가 없다(L2 의 이유와 같다). 대표 한 명은 늘 들어간다 |
| B3 | 대기 중인(만료 전) 연결 요청이 있는 동안 그 브랜드의 「계정 만들기」(`admin_upsert_brand_owner_account`)는 서버가 거부(`request_exists`). 만료된 대기 줄만 있으면 계정 만들기는 되고, **같은 거래에서 그 줄을 취소**한다 | 같은 브랜드에 대표가 두 길로 동시에 생기지 않게 · 대표와 대기 연결 요청이 함께 남는 상태를 없앤다. 화면은 요청 중 「계정 만들기」를 안 보인다(관리자 사양 — 요청 중은 「계정이 있는 동안」) |
| B4 | 수락 순간 그 브랜드에 이미 대표가 있으면 수락을 거부(`owner_exists`) — 줄은 바꾸지 않는다. **방어용**: 대표가 생기는 다른 길(「계정 만들기」)은 B3 가 막거나 대기 줄을 함께 취소하고, 즉시 연결은 지운다. 「대표 바꾸기」는 대표가 있어야 동작한다 — 그래서 대표와 대기 연결 요청이 함께 있는 상태가 생기지 않는다 | 526 의 「브랜드당 활성 대표 하나」 색인에 부딪혀 오류로 끝나는 대신 사람이 읽는 결과를 준다 |
| B5 | 브랜드가 보관(비활성)되면 대기 요청은 수락할 수 없다(목록에서도 안 보인다) — 지금 멤버 초대와 같은 판정(`_brand_invite_acceptable` 의 브랜드 활성 조건) | 기존 규칙 재사용 |
| B6 | 링크는 「보낼 때의 계정에 묶인다」(사양 §16-3 1번) — 받는 계정을 보낼 때 기록하고, 수락 때 같은 계정인지 본다 | 지금 멤버 초대의 기존 계정 갈래(`recipient_kind='brand'` + `sent_owner_auth_id`)를 그대로 쓴다 |
| B7 | 비밀번호를 정하며 수락하는 화면은 **비밀번호·비밀번호 확인·약관 동의만** 받는다(이름·연락처 칸 없음) | 계정이 이미 있고 이름·연락처는 계정 만들 때 들어갔다. 새 이메일 초대 화면(bw01-02b)과 모양만 같다 |
| B8 | 메일은 멤버 초대 메일 함수 `notify-brand-invite` 에 **연결 요청 갈래를 더한다**(새 함수를 만들지 않는다). 그 갈래만 호출자 판정이 「계정 관리 권한이 있는 관리자」 | 선점 → 발송 → 기록, 개발서버 두 겹 잠금, 링크 형식을 그대로 쓴다. 판정은 종류별로 갈라 서로 넘나들지 않는다 |
| B9 | 로그인한 상태로 메일 링크를 열면 나오는 수락 화면은 멤버 초대 화면(bw01-03)을 **문구만 바꿔** 쓴다 | Figma 에 연결 요청 전용 로그인 뒤 화면이 없다(10절 ①) |

---

## 3. 현재 상태 (2026-10-21, 코드 확인)

**서버**
- 즉시 연결: `admin_link_brand_owner_account(p_brand_id, p_email)` — 현재 원본 **533**(`supabase/migrations/533_brand_admin_member_functions.sql:933`). 수락 없이 대표를 넣는다(이미 멤버면 `_brand_transfer_owner`) + `_brand_contacts_mark_primary`. 🔴 **화면 호출 0건인데 서버에 살아 있고 로그인 사용자에게 실행 권한이 열려 있다**(533:1016 — 함수 안에서 권한을 보긴 한다). 운영엔 아직 없다(533 과 같은 묶음으로 들어갈 예정 — 이 변경이 같은 묶음에서 지운다, 운영 실사용 0).
- 계정 만들기 `admin_upsert_brand_owner_account` 현재 원본 **573**(`573_…:36`) — 기존 브랜드 계정 갈래는 무조건 `conflict_brand`(573:130-133, 즉시 재연결 닫힘).
- 겹침 확인 `admin_check_brand_account_email` 현재 원본 **573**(`573_…:233`).
- 담당자 잠김 판정 `_brand_contacts_locked(p_brand_id)` **574**(`574_…:101`) = 「활성 대표 연결 있음」. 주석이 「연결 요청이 살아 있으면 OR 로 더해 재정의」를 예고(574:13-14, 113). 부르는 곳: `admin_save_brand_contact`(574:172)·`admin_delete_brand_contact`(574:312).
- 표 `brand_invites`(530:167-209) — `invited_by uuid NOT NULL`·`inviter_name text NOT NULL`·`status`(pending·accepted·declined·cancelled — 만료는 「대기 + `expires_at` 지남」, 저장값 아님)·`recipient_kind`(new·brand·blocked, 검사 제약 530:176)·`sent_owner_auth_id`·`link_id`(유일)·`issued_at`·`expires_at`·`mail_sent_link_id` 등. 색인 `brand_invites_one_pending_per_email`(브랜드·이메일당 대기 하나, 530:202). 정책 0개 — 정의자 권한 함수와 서비스 키만 읽는다(530:227). 정기 정리 없음. 표를 고친 뒤 마이그레이션 없음(530~534 만 이 표를 다룬다).
- 기한 식 `_brand_invite_expires_at` = 발급 + 24시간, 한 곳(531:265-273).
- **이 표의 함수가 모두 「대표가 보낸 멤버 초대」를 가정한다** — 그대로 연결 요청 줄을 넣으면 깨지는 곳 넷:
  1. 보낸 사람 이름을 계정 표에서 가져온다(`_brand_invite_inviter_name` 531:316-326) — 관리자는 없어서 NULL → 이름 칸 NOT NULL 위반(`_brand_invite_reissue` 531:331)
  2. 수락이 늘 멤버로 넣는다(`respond_brand_invite` 532:680 · `service_brand_invite_finalize` 532:1340)
  3. 대기 하나 색인이 멤버 초대와 연결 요청을 섞어 센다(530:202)
  4. 대표가 같은 이메일로 멤버 초대를 만들면 대기 줄을 집어 다시 발급한다 — 연결 요청 줄을 멤버 초대로 덮어쓴다(`create_brand_invite` 531:543-558)
- 종류 구분만 더하면 되는 곳: `_brand_seat_usage`(530:342) · `resend_brand_invite`·`cancel_brand_invite`·`hide_brand_invite`(531:585·647·683 — 대표 판정만) · `get_brand_members`(531:787 — 초대 줄을 `member` 로 내보냄) · `_brand_acceptable_invites_for`(532:526 — 「받은 초대」·빨간 점·비밀번호 링크 열림이 쓴다) · `get_brand_invite_link_state`(534:71 — 종류 없음) · `get_my_brand_invites`(532:695) · `admin_get_brand_account_status`(533:647 — 대기 숫자 둘 704·706).
- 그대로 두고 확인만 할 곳: `_brand_invite_acceptable`(530:367 — 대기·만료 전·브랜드 활성·보낼 때 계정 상태 대조. 대표 유무·자리 검사 없음) · `get_my_brand_login_state`(532:864 — 「받은 초대」 목록 판정을 그대로 따른다) · `admin_release_brand_account`(533:874 — 대표 해제 때 대기 전부 취소, 909-911).
- 수락 `respond_brand_invite`(532:614-688): 잠금 브랜드 → 이메일 → 줄 다시 읽기 → `_brand_invite_acceptable` → 거절은 상태만 / 수락은 `already_member` → 비밀번호 안 정함 `setup_incomplete` → 멤버 넣기. 반환 `ok`·`already_member`·`invalid`·`not_brand`·`setup_incomplete`. 약관 기록 없음.
- 약관 기록 자리: `brand_accounts.terms_agreed_at`·`privacy_agreed_at`·`terms_version` — 설정 완료(`complete_brand_account_setup` 532:1027, 버전 없으면 `terms_version_required`)와 새 이메일 초대 가입(532:1258)만 쓴다.
- 대표 바꾸기 `admin_change_brand_owner`(533:789) — 지금 대표가 없으면 `owner_changed`. 본체 `_brand_transfer_owner`(531:440).

**메일**
- `notify-brand-invite`: 입력 `{invite_id}` + 브랜드 계정 토큰. 호출자가 그 브랜드의 활성 대표가 아니면 403(index.ts:181-191, 선점 뒤 한 번 더 292-308). 갈래 new·brand·blocked 외에는 예외(206-209). 양식 `brand-invite-new`·`-existing`·`-blocked`(224), 문구 전부 「대표 담당자 {{inviter_name}} 님」. 링크 `${PUBLIC_BRAND_URL}/brand/?link=<link_id>&kind=invite`(215). 선점 `mail_sent_link_id`(264-277). 두 겹 잠금 `BRAND_SETUP_DEV_ECHO=1` + 개발 프로젝트(53, 97-100).
- `brand-invite-accept`(공개): 새 이메일 갈래 전용 — `service_brand_invite_create_account`(532:1176, `recipient_kind='new'` 아니면 `invalid_link`) → 비밀번호 저장 → `service_brand_invite_finalize`. 기존 계정의 비밀번호를 정하는 길은 없다.
- `notify-brand-account-setup` 의 `mail_kind:'link'`(index.ts:17-27, 233-333): 비밀번호 정한 계정엔 `brand-link-notice`, 안 정한 계정엔 「운영팀이 연결」 문장을 붙인 설정 메일. **화면 호출 0건**(533:930 주석만).
- 연결 요청 양식(bw01-98)은 `docs/email-templates/` 에 없다.

**브랜드 화면**
- 링크 착지 `?kind=invite` → `handleBrandInviteLanding`(brand-app.js:351-355, brand-invite.js:165-223). 판정 `get_brand_invite_link_state` 의 `recipient` new/existing. new → bw01-02b(`showInviteNewSetpw` 245-257) → `brand-invite-accept`. existing → 로그인 → bw01-03(`showInviteScreen` 40-50).
- 마이페이지 「받은 초대」 `get_my_brand_invites`(brand-mypage.js:60, 줄 138-149, 수락·거절 248-290). 빨간 점 `get_my_brand_login_state.new_invite_dot`(brand-shell.js:88, 253-255).
- 「멤버 초대」를 전제한 문구: brand-invite.js:6-11·44·109-110·250 · brand-mypage.js:141·277-279 · `dev/brand/index.html`:256(「브랜드 초대」)·267(「초대 수락」).

**관리자 화면(오늘 병합된 조각 5~12)**
- 「브랜드 연결 추가」·「연결 요청 보냄」 칩은 아직 안 그림(admin-brand-detail.js:598 — 조각 13 몫). 겹침 확인이 `brand`·`conflict_brand` 면 임시 토스트 「「연결 요청」 기능은 준비 중입니다」(987·1132-1135·1151).
- 대표 줄 잠금 `bdOwnerLocked`(1403-1406) = 계정 상태가 `none` 이 아님 — 연결 요청 중은 아직 판정에 없다(1394).

---

## 4. 설계

### 4-1. 데이터 — `brand_invites` 확장

| 바꾸는 것 | 내용 |
|---|---|
| 새 칸 `invite_kind text NOT NULL DEFAULT 'member'` | 검사 `invite_kind IN ('member','owner_link')`. 기존 줄은 모두 `member` |
| 검사 제약 하나 더 | `owner_link` 이면 `recipient_kind = 'brand'` 그리고 `sent_owner_auth_id IS NOT NULL`(받는 계정이 늘 정해져 있다 — B6) |
| 대기 하나 색인 둘로 | 옛 `brand_invites_one_pending_per_email` 을 **멤버 초대 한정**(`WHERE status='pending' AND invite_kind='member'`)으로 다시 만들고, 새 색인 **브랜드당 대기 연결 요청 하나**(`(brand_id) WHERE status='pending' AND invite_kind='owner_link'`) |
| `invited_by` · `inviter_name` | 연결 요청은 `invited_by` = 보낸 관리자 계정(기록용 — 브랜드에게 안 보인다), `inviter_name` = `'REVERB 운영팀'`(L4) |

### 4-2. 서버 함수

🔴 모두 **가장 최근 정의를 베이스로** 고친다 — 530·531·532·534 는 아래 번호, 533 계열은 573·574 를 먼저 본다. 반환 칸·인자를 바꾸는 함수는 `DROP` 후 `CREATE` 라 **실행 권한 회수를 다시 건다**(`CLAUDE.md` 「함수 실행 권한」). 비로그인 실행 권한이 있는 `get_brand_invite_link_state`(534)는 `CREATE OR REPLACE` 로만. 새 함수는 모두 `SECURITY DEFINER` + `SET search_path = ''`(`.claude/rules/security.md`).

**새 함수 (관리자)**

| 함수 | 하는 일 | 반환 |
|---|---|---|
| `admin_request_brand_owner_link(p_brand_id uuid, p_email text)` | 권한 `brand.account_manage` 쓰기. 잠금 브랜드(`brand_account_upsert:`) → 이메일(`brand_account_email:`) — 533 과 같은 순서. 검사 순서: 브랜드 있음·활성 → 이메일 형식 → 활성 대표 있음이면 `owner_exists` → 브랜드 계정 아님이면 `not_brand_account`(+`email_kind`) → 그 계정이 이 브랜드에 이미 활성 연결이면 `already_linked`(L2) → 대기 연결 요청이 있으면 B1 대로(같은 이메일 = 다시 발급 / 다른 이메일 = 만료 전 `request_exists`, 만료 뒤 취소하고 새로). 줄은 `invite_kind='owner_link'`·`recipient_kind='brand'`·`sent_owner_auth_id`=그 계정·기한 `_brand_invite_expires_at` | `{result: ok\|forbidden\|owner_exists\|request_exists\|already_linked\|not_brand_account\|brand_archived\|brand_not_found\|invalid_email, request_id, email_kind, expires_at}` |
| `admin_cancel_brand_owner_link(p_brand_id uuid, p_request_id uuid)` | 권한 같음(L7). 그 줄이 **이 브랜드의 연결 요청 줄**이고 대기(만료 포함)면 `cancelled`, 아니면 `not_pending` | `{result: ok\|forbidden\|not_pending}` |

**고치는 함수**

| 함수 (현재 원본) | 바꾸는 것 |
|---|---|
| `admin_get_brand_account_status` (533) | 새 칸 `owner_link_request` = 그 브랜드의 가장 최근 연결 요청 하나(`issued_at` 내림차순 — 다시 발급하면 그 줄이 최근이 된다) `{request_id, status: pending\|expired\|declined\|cancelled, email, sent_at, expires_at}` 또는 null. 🔴 **활성 대표가 있거나, 그 요청의 `issued_at` 뒤에 이 브랜드에 대표 연결이 생긴 적이 있으면 null**(수락·계정 만들기 어느 길이든 — 사용 중 계정 옆에, 또 그 대표를 해제한 뒤에도 옛 요청 칩을 그리지 않게). 대기 숫자 둘(`pending_invite_count`·`release_cancel_count`)은 **멤버 초대만** 센다 |
| `admin_upsert_brand_owner_account` (573) | 만료 전 대기 연결 요청이 있으면 `request_exists` · 만료된 대기 줄은 계정을 만드는 같은 거래에서 `cancelled`(B3) |
| `_brand_contacts_locked` (574) | 「활성 대표 **또는** 만료 전 대기 연결 요청」 |
| `_brand_invite_acceptable` (530) | 바꾸지 않는다 — 「보낼 때 계정 상태 대조」는 받는 쪽 갈래(브랜드 계정인지)와 `sent_owner_auth_id` 같은 계정인지만 본다(비밀번호를 정했는지는 안 본다 — 그래서 L8 마지막 단계가 통과한다. 개발이 착수 전 코드로 확인) · 자리 검사가 없어 B2 와 맞고, 대표 유무는 여기 넣지 않는다(넣으면 수락이 `invalid` 로 끝나 B4 의 `owner_exists` 안내에 닿지 못한다) |
| `respond_brand_invite` (532) | 인자에 `p_terms_version text DEFAULT NULL` 추가(L3 — 비면 수락은 `terms_version_required`, 거절은 필요 없음. 기본값이 있어 옛 화면의 두 인자 호출도 함수를 찾는다 — 5절 9번. 🔴 옛 2인자 판은 `DROP` 하고 실행 권한 회수를 다시 건다 — 남기면 호출이 모호해지거나 옛 판으로 가 L3 을 건너뛴다). 약관 버전 검사는 종류와 상관없이 맨 앞(수락일 때). 멤버 초대 줄은 수락 성공 때 같은 거래 안에서 계정의 `terms_agreed_at`·`privacy_agreed_at`·`terms_version` 갱신 — 연결 요청 줄은 본체 ⑤가 기록(L3 은 두 종류 다). 🔴 연결 요청 줄의 수락은 **줄을 다시 읽은 직후 곧바로** 공용 본체 `_brand_accept_owner_link` 로 넘긴다(이 함수 자체의 `_brand_invite_acceptable`·`already_member` 검사를 거치지 않는다 — 본체가 한다). 반환에 `owner_exists`·`terms_version_required` 추가 |
| `_brand_invite_reissue` (531) | 연결 요청 줄이면 보낸 사람 이름을 계정 표에서 다시 읽지 않는다(`'REVERB 운영팀'` 유지) |
| `create_brand_invite` · `resend_brand_invite` · `cancel_brand_invite` · `hide_brand_invite` (531) | **멤버 초대 줄만** 본다 — 대표는 연결 요청 줄을 집거나 바꾸지 못한다 |
| `get_brand_members` (531) · `_brand_seat_usage` (530) | 멤버 초대 줄만(B2) |
| `_brand_acceptable_invites_for` (532) · `get_my_brand_invites` (532) · `get_brand_invite_link_state` (534) | 응답에 `invite_kind` 추가(셋 다 jsonb 반환이라 키 추가는 `CREATE OR REPLACE` 로 된다 — 반환형이 바뀌지 않는다). 링크 판정은 연결 요청이고 받는 계정의 비밀번호가 안 정해졌으면 `recipient: 'existing_setpw'`(새 값 — L8 화면으로 보낸다) |
| `service_brand_invite_finalize` (532) | 연결 요청 줄이면 거부(방어 — 새 이메일 갈래 전용) |
| `admin_change_brand_owner` · `admin_release_brand_account` (533) | 바꾸지 않는다. 대표 해제의 「대기 전부 취소」에 연결 요청이 섞여도 무해하다(대표가 있는 동안 연결 요청은 생기지 않는다) |

**새 함수 (비밀번호 정하며 수락 — L8)**

| 함수 | 하는 일 | 반환 |
|---|---|---|
| `service_brand_link_request_setpw(p_link_id uuid, p_terms_version text)` (서비스 키 전용) | 비밀번호를 저장하기 **전** 검사만(쓰지 않는다) — 약관 버전 있음 → 공용 본체 ①~③과 **같은 순서·같은 판정**(줄 대기·연결 요청 → `_brand_invite_acceptable` → 활성 대표 없음) → ④ 자리는 **반대 판정**: 받는 계정 비밀번호가 **안 정해졌어야** 통과(정했으면 `password_already_set`) → 받는 계정 아이디(비밀번호 저장은 서버 함수가 인증 서비스로) | `{result: ok\|terms_version_required\|invalid_link\|owner_exists\|already_member\|password_already_set, auth_id}` |
| `service_brand_link_request_finalize(p_link_id uuid, p_terms_version text)` (서비스 키 전용) | 비밀번호 저장 뒤: 잠금 안에서 받는 계정 `password_set_at` 이 **비어 있을 때만** 기록(이미 있으면 기록하지 않고 `password_already_set` — 5절 7번) → 공용 본체 `_brand_accept_owner_link`(④ 비밀번호 검사는 방금 기록으로 통과 · 약관 기록은 수락이 성공할 때만) | `{result: ok\|terms_version_required\|invalid_link\|owner_exists\|already_member\|password_already_set}` |

- 🔴 **잠금은 하나의 이름 짝** — 요청·취소·수락(두 길)·계정 만들기 모두 533 과 같은 브랜드 열쇠(`brand_account_upsert:`) → 이메일 열쇠(`brand_account_email:`) 순서. 그래야 5절 4·5·6번이 서로를 기다린다.
- 🔴 **공용 본체 `_brand_accept_owner_link(invite, auth_id, terms_version)`** — 연결 요청 수락의 유일한 본체. `respond_brand_invite`(수락 갈래)와 `service_brand_link_request_finalize` 가 부른다(사본 금지). 🔴 받는 계정 아이디를 인자로 받고 호출자 검사가 없으니 **내부 전용** — `PUBLIC`·비로그인·로그인 사용자 실행 권한을 모두 회수(실행 권한이 유일한 방어선). 잠금 안에서 순서: ①줄을 다시 읽어 `pending`·연결 요청·받는 계정이 맞는지(아니면 `invalid` — 이미 수락·취소된 줄, 두 번 누르기, 다른 계정 호출은 여기서 끝나 아무것도 바꾸지 않는다) ②`_brand_invite_acceptable`(만료·브랜드 활성 — 아니면 `invalid`) ③활성 대표가 있으면 `owner_exists`(B4 — 줄은 그대로) · 받는 계정이 이미 이 브랜드에 활성 연결이면 `already_member`(L2 와 같은 방어 — 줄은 그대로) ④비밀번호 안 정함이면 `setup_incomplete` ⑤**대표로 넣기**(같은 계정의 해제된 옛 연결이 있어도 새 줄) → `_brand_contacts_mark_primary` → 대표 줄 아이디를 연결의 `source_contact_id` 로(533 즉시 연결 999-1007 과 같은 처리) → 약관 기록 → 줄 `accepted`. 거절은 이 본체를 거치지 않는다(지금처럼 상태만). 공개 함수 쪽 이름 `invalid_link` = 여기의 `invalid`.
- 비밀번호를 정하면 그 계정의 **다른 브랜드 설정 링크도 소용없어진다**(같은 계정의 비밀번호다). 설정 링크 판정이 `password_set_at` 을 보므로 따로 손댈 것 없다 — 확인만(6절 ④).

**지우는 함수**
- `admin_link_brand_owner_account`(533) — `DROP FUNCTION`. 화면 호출 0건 · 운영 실사용 0(운영에는 533 묶음과 함께 들어가 같은 묶음 안에서 지운다 — 운영에서 쓰인 적 없음) · 남기면 약관을 우회하는 즉시 연결 길이 서버에 남는다.

### 4-3. 메일

- `notify-brand-invite` 에 갈래 하나: 줄이 `invite_kind='owner_link'` 이면
  - 🔴 순서: 줄을 읽을 때 `invite_kind` 칸도 함께 읽고(지금 조회 칸에 없다), **종류로 먼저 가른 뒤** 호출자 판정을 한다(지금은 읽자마자 대표 확인이라 관리자는 403 에 걸린다).
  - 호출자 판정 = 호출자 토큰으로 `has_permission('brand.account_manage','write')`(`notify-brand-account-setup` 의 판정과 같은 방식) — 선점 전과 선점 뒤 **두 번**(멤버 초대 갈래의 대표 확인과 같은 자리). 대표 판정 갈래와 **섞지 않는다** — 멤버 초대 줄은 지금처럼 대표만, 연결 요청 줄은 관리자만.
  - 양식 새로 `brand-link-request`(Figma bw01-98) — 받는 사람이 비밀번호를 정했든 안 정했든 **같은 메일·같은 링크**(갈래는 링크를 연 뒤 화면이 가른다 — 메일이 계정 상태를 드러내지 않게).
  - 제목·본문의 보낸 사람 「REVERB 운영팀」, 브랜드 이름, 기한 「24시간」(브랜드 메일 「24시간」 문구 전제 — `CLAUDE.md` 「브랜드 메일 링크 24시간 문구」), 링크 `?link=<link_id>&kind=invite`.
  - 선점·기록·두 겹 잠금은 그대로.
- 부르는 쪽: 관리자 화면이 `admin_request_brand_owner_link` 성공 뒤 이 함수를 부른다(멤버 초대와 같은 「만들기 → 메일」 순서). 메일 실패면 요청은 남고 화면이 「메일을 보내지 못했습니다 — 다시 보내기」(다시 보내기 = 같은 이메일로 `admin_request_brand_owner_link` 다시 → 같은 줄 다시 발급, B1)
- 걷는 것: `notify-brand-account-setup` 의 `mail_kind:'link'` 갈래 · 양식 `brand-link-notice`(원본·미러·카탈로그 줄) · 533:930 주석.
- 양식 원본 `docs/email-templates/brand-link-request.html` + 미리보기 + 카탈로그 `index.html` 줄 → `scripts/sync-email-templates.sh`.

### 4-4. 브랜드 화면

| 자리 | 바꾸는 것 |
|---|---|
| 링크 착지(`brand-invite.js`) | `invite_kind='owner_link'` 면 문구를 연결 요청으로. `recipient: 'existing_setpw'` 면 **비밀번호 정하며 수락** 화면(B7 — 비밀번호·확인·약관 동의 「보기」) → 새 공개 서버 함수(4-5) → 성공하면 로그인까지 하고 그 브랜드로 |
| 로그인 뒤 수락 화면(bw01-03 재사용 — B9) | 제목 「브랜드 연결 요청」, 본문 「REVERB 운영팀이 회원님을 「{브랜드}」의 대표 담당자로 연결하려 합니다」, 단추 「수락」·「거절」. 수락 = 약관 동의(아래 줄 한 줄 + 「보기」). 거절 확인 문구는 마이페이지와 같다 |
| 마이페이지 「받은 초대」(bw07-00c) | 연결 요청 줄은 「보낸 곳 REVERB 운영팀 · 대표 담당자로 연결」. 수락 = 약관 동의 한 줄 + `p_terms_version`(멤버 초대 줄과 같다). 거절 확인 문구는 「다시 연결하려면 운영팀에 문의」(대표에게 새로 초대해 달라는 멤버 초대 문구 대신) |
| 수락 결과 | `owner_exists` → 「이미 다른 대표 담당자가 정해졌습니다. 운영팀에 문의해 주세요」 · `already_member` → 지금 멤버 초대 안내 그대로(「이미 연결된 브랜드」) · `invalid` → 지금 만료 안내 그대로 · `terms_version_required` → 화면이 늘 보내므로 일반 오류 안내 · `setup_incomplete`·`not_brand` → 지금 멤버 초대 안내 그대로 |
| 멤버 초대 수락(L3) | 같은 화면·같은 줄에 약관 동의 한 줄 + `p_terms_version` 을 보낸다(`BRAND_TERMS_VERSION`) |

- 빨간 점·로그인 판정은 서버가 같은 목록을 보므로 화면 변경 없음.
- 🔴 문구 후보는 `reverb-ui-copy` 로 다듬는다. 브랜드 화면 버튼·입력칸 높이 44px 이상(사양 §16-8).

### 4-5. 공개 서버 함수 (비밀번호 정하며 수락)

- `brand-invite-accept` 에 갈래를 더하거나 새 함수 — **개발이 정한다**(새 함수면 이름 `brand-link-request-accept`). 어느 쪽이든:
  - 입력 `{link_id, password, terms_version}` · 로그인 없이 · 공개 키 거부 없음(`brand-invite-accept` 와 같다)
  - 순서: `service_brand_link_request_setpw` → 인증 서비스 `updateUserById` 로 비밀번호 → `service_brand_link_request_finalize`
  - 첫 단계 실패는 비밀번호를 저장하기 전이라 4-4 「수락 결과」 안내 그대로(`invalid_link` → 4-4 `invalid` · `owner_exists`·`already_member`·`terms_version_required` 도 4-4 그대로 · `password_already_set` 은 「이미 비밀번호가 정해진 계정입니다 — 로그인해 주세요」)
  - 마지막 단계가 실패하면 비밀번호는 이미 저장된 채로 남을 수 있다 — 계정은 **원래 있던 계정**이라 지우지 않는다(새 이메일 초대의 반쪽 계정 지우기와 다르다). 안내는 결과마다: `owner_exists`·`already_member`·`password_already_set` → 4-4·첫 단계와 같은 안내 · `invalid_link`(그사이 만료·취소) → 4-4 `invalid` 안내 그대로 · 그 밖의 오류 → 「처리하지 못했습니다. 메일의 링크를 다시 열어 주세요」(비밀번호 기록이 남았으면 링크 판정이 `existing` 이라 로그인 화면으로 가고, 로그인 뒤 수락된다 · 안 남았으면 링크에서 처음부터 다시 된다 — 어느 쪽이든 길이 있다)
  - 🔴 공개 함수라 응답·로그에 링크·본문을 싣지 않는다(브랜드 메일 함수 규칙)
  - 비밀번호 규칙 검사는 화면(`passwordPolicyIssue`)과 같은 기준

### 4-6. 관리자 화면 계약 (관리자 작업표 조각 13 이 쓰는 것)

- storage.js `requestBrandOwnerLink(brandId, email)` → `admin_request_brand_owner_link` · `cancelBrandOwnerLink(brandId, requestId)` → `admin_cancel_brand_owner_link` · 메일은 멤버 초대 메일 함수를 부르는 storage 함수(이름은 개발이 정한다 — 있으면 재사용)에 `request_id` 를 넘긴다. `request_id` = `brand_invites.id` = 메일 함수 입력 `invite_id`
- 계정 상태 `owner_link_request.status`: `pending`(만료 전) → 「연결 요청 보냄 · {시각}까지」 + 「요청 취소」 · `expired`·`declined`·`cancelled` → 칩 하나 + 계정 없음(ⓐ) 단추 · null → 칩 없음(대표가 생기면 서버가 늘 null — 4-2)
- `bdOwnerLocked` 에 「`owner_link_request.status === 'pending'`」 OR — 서버 `_brand_contacts_locked` 와 같은 기준
- 결과별: `not_brand_account` → a03-04a · `owner_exists` → 토스트 · `request_exists`(다른 이메일로 대기 중) → 계정 상태를 다시 읽어 지금 요청 표시로 다시 그림 · `already_linked` → 「이미 이 브랜드에 연결된 계정입니다」 토스트 · 「계정 만들기」(`admin_upsert_brand_owner_account`)가 `request_exists` → 같은 처리(상태 다시 읽어 요청 표시로) · 그 밖의 결과(`forbidden`·`brand_archived`·`brand_not_found`·`invalid_email`·취소의 `not_pending`) → 일반 오류 토스트 + 계정 상태 다시 읽기
- 겹침 창 임시 토스트(admin-brand-detail.js:1132-1135·1151)를 이 길로 바꾼다

---

## 5. 의심·경우의 수

1. **(사용 흐름) 잘못된 사람에게 보냈다** — 수락 전이면 「요청 취소」. 수락 뒤면 관리자 브랜드 상세 담당자·계정 탭의 「해제」(관리자 작업표 조각 11 — 개발서버에 있음, 함수 533). 취소해도 이미 간 메일은 못 거두지만 링크는 `invalid` 가 된다.
2. **(사용 흐름) 받은 사람이 메일을 못 봤다** — 24시간 뒤 관리자 화면에 「만료」 칩. 같은 길로 다시 보낸다(같은 줄 다시 발급, 새 링크 — 옛 링크는 죽는다).
3. **(사용 흐름) 다른 브랜드 계정으로 로그인한 채 링크를 열었다** — 지금 멤버 초대와 같은 판정(받는 계정이 아니면 `invalid` → 안내). 로그아웃 뒤 다시.
4. **(데이터) 관리자 둘이 동시에 보냄** — 브랜드 잠금 + 브랜드당 대기 하나 색인 → 줄은 하나만 남는다(다른 이메일이면 뒤 사람이 `request_exists`, 같은 이메일이면 뒤 사람이 다시 발급 — 받는 사람에게 메일이 두 통 가고 앞 링크는 죽는다).
5. **(데이터) 요청 중 다른 관리자가 「계정 만들기」** — 서버가 `request_exists`(B3). 화면도 버튼을 안 보인다.
6. **(데이터) 수락 직전 다른 길로 대표가 생김** — 정상 경로로는 없다(B3·B4). 생기면 수락 `owner_exists`, 줄은 만료까지 남는다(대표가 있으면 관리자 화면에는 대기·만료와 상관없이 칩이 안 보인다 — 4-2 계정 상태). 두 번 누르기·다른 계정 호출은 본체 ①에서 끝나 줄을 안 바꾼다.
7. **(권한·보안) 비밀번호 정하며 수락 링크가 새면** — 링크를 가진 사람이 그 계정의 비밀번호를 정할 수 있다. 설정 메일 링크와 같은 위험 수준(링크 = 메일함 소유 증명, 24시간). 🔴 비밀번호가 **이미 정해진** 계정엔 이 갈래가 열리지 않는다(`password_already_set` — 사전 검사로 막는다). 단 사전 검사와 비밀번호 저장 사이의 짧은 틈(그사이 다른 브랜드 설정 링크로 비밀번호가 정해짐)은 인증 서비스 저장이 데이터베이스 거래 밖이라 막을 수 없어 **감수**한다 — 링크를 가진 본인만 생기는 경우이고, 마지막 단계가 `password_already_set` 으로 수락을 멈춘다(덮어쓴 비밀번호는 되돌리지 못한다 — 본인이 정한 값이다). 알려진 노출 하나: 링크 판정의 `existing_setpw` 로 링크를 가진 사람은 그 계정이 비밀번호를 정했는지 알 수 있다(링크 소지자 = 메일함 주인이라 허용).
8. **(데이터) 대표가 같은 이메일로 멤버 초대** — 대표가 없는 브랜드라 생기지 않는다. 생겨도 색인이 종류별이라 서로 덮지 않는다.
9. **(약관) 멤버 초대 수락에도 약관 버전을 받게 되므로** 서버를 먼저 내면 옛 화면(인자 둘)이 기본값 NULL 로 들어와 `terms_version_required` 로 막힌다 / 화면을 먼저 내면 옛 서버가 모르는 인자라 함수를 못 찾는다. 🔴 **둘 다 개발서버만이라 데이터베이스 적용 뒤 같은 날 안에 브랜드 화면까지 낸다(7절 순서)**(그사이 멤버 초대 수락이 몇 분 막힐 수 있다). 운영은 묶음과 함께라 문제없음.
10. **(외부) 메일 실패** — 요청은 남는다. 화면 「다시 보내기」(4-3).

---

## 6. 확인 절차 (개발서버 — 완료 기준)

① 관리자: 대표 없는 브랜드에 기존 브랜드 계정 이메일로 요청 → `ok` · 같은 브랜드에 **다른** 이메일로 → `request_exists` · 같은 이메일로 다시 → 같은 줄 새 링크(옛 링크 `invalid`) · 다른 관리자 「요청 취소」 → `ok`, 받은 사람 링크 `invalid`
② 비밀번호 정한 계정: 메일 링크 → 로그인 → 수락 → 그 브랜드 대표 · 담당자 목록 대표 표시 이동 · 계정 약관 기록 갱신
③ 같은 계정이 「받은 초대」에서 거절 → 관리자 칩 「거절」 · 계정 상태 ⓐ 단추
④ 비밀번호 안 정한 계정(다른 브랜드 ⓒ 상태): 링크 → 비밀번호 정하며 수락 → 로그인된 채 그 브랜드 · 그 계정의 다른 브랜드 설정 링크가 「이미 설정됨」으로
⑤ 만료: `issued_at`·`expires_at` 을 하루 전으로 → 관리자 「만료」 · 링크 `invalid` · 다시 보내면 같은 줄 새 링크
⑥ 요청 중 담당자 대표 줄 이메일 바꾸기·삭제 → 서버 거부(574 함수) · 「계정 만들기」 → `request_exists`
⑦ 멤버 초대 회귀: 대표가 멤버 초대 → 수락(약관 기록) · 대표의 멤버 목록·자리 숫자에 연결 요청이 안 섞임 · 관리자 「초대 대기 N」에 안 섞임
⑧ 즉시 연결 함수가 없다(`to_regprocedure` NULL) · 새 함수 다섯(`admin_request_brand_owner_link`·`admin_cancel_brand_owner_link`·`service_brand_link_request_setpw`·`…_finalize`·`_brand_accept_owner_link`)과 `DROP` 후 다시 만든 함수의 실행 권한 회수 확인(`proacl` 맨 앞 `=X/` 없음 · 서비스 키 전용 둘과 내부 본체는 로그인 사용자에게도 없음)
⑨ 메일 두 겹 잠금: 개발서버에서 메일 대신 화면 응답 · 멤버 초대 메일 함수를 대표가 연결 요청 아이디로 부르면 403 · 관리자가 멤버 초대 아이디로 부르면 403

---

## 7. 출시·운영 순서

- 개발서버: 데이터베이스(4-1·4-2) → 메일 함수·양식(4-3) → 공개 함수(4-5) → 브랜드 화면(4-4) → 관리자 화면(조각 13). 5절 9번 때문에 데이터베이스와 브랜드 화면의 수락 인자 변경은 **같은 날 이어서**.
- 운영: 브랜드 페이지 묶음 안에서 **533 · 573 · 574 뒤**. 메일 함수는 데이터베이스 뒤. 🔴 운영에 `BRAND_SETUP_DEV_ECHO` 를 넣지 않는다(기존 규칙).
- 출시 때 걷을 것: 화면의 `_brandAccountEnabled()` 판정(브랜드 페이지 공통 출시 단계) — 이 기능 고유의 잠금은 새로 두지 않는다.

## 8. 함께 고칠 문서 (개발이 구현과 같은 커밋에)

- `CLAUDE.md` 「브랜드 계정」 절: 현재 원본 번호(530·531·532·533·534·573·574 의 바뀐 함수) · 「연결 해제는 함수만 있다」 줄 옆에 즉시 연결 삭제 · 메일 파이프라인 「브랜드 메일 함수 넷」에 연결 요청 갈래
- `.claude/rules/brand-account.md` · `docs/FEATURE_SPEC.md`
- 관리자 작업표 「작업 4」 머리에 「→ 이 문서로 대체」 한 줄(기획)
- 사양 `2026-07-15-brand-portal.md` §16-8 1번 끝에 이 문서 경로(기획)

## 9. 사용자 확인 필요

없음(L1~L4 2026-10-21 결정). B1~B9 는 이 문서의 가정 — 이의가 없으면 그대로 진행한다.

## 10. 피그마와 다른 곳·남은 그림

① 로그인 뒤 연결 요청 수락 화면이 없다 — bw01-03 문구 바꿔 쓰기(B9). 필요하면 기획이 그린다
② 비밀번호 정하며 수락 화면은 bw01-02b 에서 이름·연락처 칸을 뺀 모양(B7)
③ bw01-98 메일·bw07-00c 줄의 보낸 사람 표기를 「REVERB 운영팀」으로 맞췄는지 기획이 확인

---

## 구현 결과 (개발 세션이 채울 것)
