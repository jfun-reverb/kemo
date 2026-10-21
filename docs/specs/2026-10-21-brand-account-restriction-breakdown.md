# 📋 작업 분해표 — 브랜드 계정 이용 제한 · 결과물 열람 정지

**사양서:** `docs/specs/2026-10-21-brand-account-restriction.md` (선례 양식: `docs/specs/2026-10-21-brand-link-request-breakdown.md` · `docs/specs/2026-10-21-admin-brand-detail-tabs-breakdown.md`)
**정본 화면:** 피그마 「레버브시딩_브랜드」 Admin `[1차] a03-4 이용 제한 · 결과물 열람 정지`(686:584) · Brand `bw01-13`(675:507) · `bw05-01d`(675:525)
**분해일:** 2026-10-21 (저장소 기준 `origin/dev` 8848307b — 마지막 마이그레이션 **580**)
**총 작업 조각:** 16개(개발서버 15 + 출시 날 1) · **병렬 가능:** 5개(제한 5·6·7·8·13 — 데이터베이스 흐름과 동시에 **작성** 가능, 병합·배포는 짝 조각 뒤) · **순차 필수:** 11개(데이터베이스 제한 1→2→3→4 · 관리자 화면 제한 9→10→11→12 · 확인 14 · 문서 15 · 출시 16)
**완료 기준:** 개발서버 데이터베이스 적용 + 개발서버 배포까지. 운영은 브랜드 페이지 1차 출시 날(제한 16).

> **화면 문구:** 브랜드 화면·관리자 화면·메일 모두 한국어. 일본어 문구 없음.
> **마이그레이션 번호:** 미리 정하지 않는다(「새 마이그레이션 — 번호는 작성 시 확정」). 572 뒤 새 파일은 기록 표 양식(`BEGIN;` … 자기 기록 줄 … `COMMIT;`)이어야 병합 요청 검사를 통과한다(`.claude/rules/supabase.md` 「새 파일 양식」).
> **이름:** 아래 「산출 계약」의 함수·표·종류 이름은 **작업표 제안 이름**이다. 데이터베이스 세션(kemo-cd)이 작성 때 바꾸면 **같은 날 짝 조각 세션에 이름을 알린다**(기획 세션 kemo-7d 를 거쳐 세션 간 메시지).
> 🔴 **데이터베이스 먼저 → 서버 함수 → 화면.** 제한·정지 줄은 관리자 쓰기 함수(제한 4)가 생기기 전에는 만들어지지 않으므로, 제한 2·3 은 개발서버에 일찍 들어가도 **동작이 바뀌는 사람이 없다**(단, 제한 2 의 판정 함수 재작성은 모든 브랜드 화면 회귀를 본다).

---

## 🚦 착수 전 선결 조건

| # | 선결 조건 | 근거 | 막는 조각 |
|---|---|---|---|
| **S1** | 🔴 **상대 개발자에게 알림**(사용자를 통해) — 「530 `my_brand_role`·`is_my_brand` · 531 `_brand_caller_link_role`·`_brand_transfer_owner` · 532 `get_my_brand_login_state` · 541 `orient_lookup_gate_account` · 547 `get_my_brand_campaign_results` · 550 `_brand_campaign_summary` · 557 `_brand_mailable_accounts`·`_shipping_list_open_for_brand`·배송 브랜드 함수 넷·`admin_deliver_shipping_list` · 573 `admin_check_brand_account_email` · 578 `admin_request_brand_owner_link`·`admin_get_brand_account_status` · 579 `respond_brand_invite`·`_brand_accept_owner_link` · 580 `service_brand_link_request_setpw`·`service_brand_link_request_finalize` · 552 제공 기록 검사 제약을 다시 정의한다. 같은 대상을 손대는 작업이 있나?」 | `two-developers.md` 1조 | 1~4 |
| **S2** | 착수 직전 `git pull origin dev` 뒤 위 대상들의 **마지막 `CREATE` 정의**를 다시 본다 + 사양서 3절 「연결 표를 직접 읽는 함수 데이터베이스 29·서버 함수 5」 전수를 다시 센다(그 뒤 생긴 함수) | 사양서 4-2 🔴 · `supabase.md` 「재정의 경고」 | 1~4 |
| **S3** | `/약관확인` — 제한 이력 보관 기간·방침 수집 항목·권리 행사 경로(사양서 9절 ①②③). **출시 전까지만 필요 — 개발을 막지 않는다.** 보관 기간이 「정리 예약」을 요구하면 후속 조각을 하나 더 만든다(표 칸 설계는 그대로) | 사양서 6절 ⑧ · 9절 | 16 |
| **S4** | 피그마 정리(기획 몫) — 피그마에 없는 화면·문구: ①기간 바꾸기 모달(A1) ②겹침 확인에서 만난 제한 계정 안내(A12) ③배송 리스트 정지 안내(4-5) ④열람 정지 모달 안내 「대표 담당자·멤버에게」(R5) ⑤bw01-13 문의처 문구(R6). **개발을 막지 않는다** — 개발은 사양서 문구로 만들고 기획이 나중에 피그마를 맞춘다 | 사양서 4-3·4-5·4-7 | (16 전) |
| **S5** | 개발서버 시험 데이터 — ①두 브랜드 이상에 연결된 비밀번호 정한 계정(`zz-b2-second@example.com` — 「가나다 시험」·「Aroma Farm 시험」 멤버) ②대표 계정(`zz-b2-owner@example.com`) ③결과물 공개가 켜진 캠페인(시험 캠페인 B0046) ④배송 리스트가 전달된 시딩형 캠페인 하나 ⑤연결이 모두 해제된 브랜드 계정 하나(A12 시험용 — 제한 걸고 해제해서 만든다). 로그인이 필요한 확인은 **사용자에게 로그인을 부탁**(비밀번호 입력 금지) | 사양서 6절 11 | 2~14 |
| **S6** | 메일 다섯·브랜드 화면 안내 문구는 `reverb-ui-copy` 로 다듬는다(한국어 화면이라 일본어 병기 대상 아님) | 사양서 4-5·4-8 | 6·8 |

---

## ⚠️ 사양서 stale 점검 (코드 대조 결과 — 사양서 본문은 그대로 두고 여기서 처리)

1. **`my_brand_role`·`is_my_brand` 는 `LANGUAGE sql` 이다**(530:282·307). 오류를 내려면 `plpgsql` 로 바꾸거나, SQL 안에서 오류를 내는 작은 내부 함수(예: `_raise_account_restricted()`)를 부른다. 어느 쪽이든 **SQL 함수 펼침(인라인)이 사라질 수 있어** 조회 정책·목록 함수 속도가 달라질 수 있다 → 제한 2 완료 정의에 브랜드 캠페인 목록 응답 시간 비교를 넣었다. 실행 권한(530 의 `postgres`·`authenticated`·`service_role` 부여, `PUBLIC`·`anon` 회수)은 `CREATE OR REPLACE` 로 보존된다(언어를 바꿔도 이름·인자·반환형이 같으면 된다).
2. **`brand-campaign-results` 는 데이터베이스 오류를 그대로 넘기지 않는다** — 지금은 `PGRST30*`·`42501` 만 `not_found`, 나머지는 전부 **500 `server_error`**(index.ts 151~156). 사양서 5-2b 「확인」 → 실제로는 **고쳐야 한다**: `error.message === 'account_restricted'` 면 `{success:false, reason:'account_restricted'}`. 그래서 브랜드 화면 공통 입구는 원격 호출 오류 글자(`brandRpc`)와 **서버 함수 응답 `body.reason`**(`brandCallFunction`) 둘을 본다(제한 5·7).
3. **`notify-orient-sheet` 는 `_brand_mailable_accounts` 를 부를 수 없다** — 그 함수는 `postgres` 만 실행할 수 있고 `service_role` 도 회수돼 있다(557:1040·1063). 서버 함수는 서비스 키로 `brand_account_links` 를 **직접** 읽는다(index.ts 186~212). 사본에 제한 판정을 하나 더 베끼면 「판정식 한 곳」(A3)이 깨진다 → **서비스 키 전용 감싸개 `service_brand_mailable_accounts(p_brand_id uuid)`** 를 두고 `notify-orient-sheet` 가 그것을 부르게 바꾼다(사본 자체가 사라진다). 새 메일 함수(④⑤ 받는 사람)도 같은 감싸개를 쓴다.
4. **`_shipping_list_open_for_brand` 는 `RETURNS boolean`**(557:128) — 「이유를 돌려주는 판정」으로 바꾸면 반환형이 달라져 `CREATE OR REPLACE` 가 안 된다. → 새 이름 **`_shipping_list_block_reason(p_campaign_id uuid) RETURNS text`** 로 만들고 네 함수(`get_my_brand_shipping_summary`·`get_my_brand_shipping_list`·`get_my_brand_shipping_export`(→ `_shipping_brand_rows_logged`)·`save_my_brand_shipping_rows`)를 그것으로 바꾼 뒤 옛 함수는 `DROP`(정지 판정이 두 곳에 남지 않게 — D9).
5. **580 `service_brand_link_request_setpw`(비밀번호 저장 전 검사)도 넣는다** — 사양서는 마무리(`finalize`)만 적었다. 마무리에만 넣으면 인증 서비스에 비밀번호가 저장된 **뒤에** 거부된다. ⚠️ 다만 이 경로는 비밀번호를 안 정한 계정 전용이고 이용 제한은 비밀번호를 정한 계정에만 걸리므로(기본값 2) **실제로는 거의 닿지 않는 방어선**이다 — 값싸서 둘 다 넣는다.
6. **「열람 정지」 배지 자리** — 「브랜드 공개」 배지는 실제로 **세 파일**에 있다: 캠페인 관리 목록 `dev/js/admin.js`(494·604 — 🔴 핫스팟) · 브랜드 상세 캠페인 탭 `dev/js/admin-brand.js`(2109·2156) · 진행현황 머리 `dev/js/admin-brand-publish.js` `refreshCampBrandPublishStatus`. 사양서 4-7 은 「캠페인 목록·진행현황」 둘만 적었다 → 브랜드 상세 캠페인 탭은 머리에 이미 「결과물 열람 정지 중」 배지가 있으므로 **넣지 않는다**(기본값 6).
7. **관리자 서버 호출 감싸개는 `dev/lib/storage.js`(핫스팟)에 모여 있다** — `fetchBrandAccountStatus`(3547)·`_brandAccountRpc`(3559)·`checkBrandAccountEmail`(3573)·`requestBrandOwnerLink`(3608)·`fetchBrandPublishStates`(2062)·`deliverShippingList`(2099). 새 감싸개도 그 자리에 → 한 조각(제한 9)에 몰았다.
8. **제공 기록 동작 종류 검사 제약은 이름 없이 줄 안에 선언**돼 있다(552:106 — 자동 이름은 보통 `brand_provision_logs_action_check`). 지우기 전에 `pg_constraint` 로 실제 이름을 본다. 관리자 「제공 기록」 화면(`admin-privacy-logs.js`)의 종류 이름표와 552 머리말의 「9개 종류」 서술도 함께 늘어난다.
9. **브랜드 화면이 공통 입구를 거치지 않는 호출이 셋** — ①오리엔시트 사진 올리기 `brandDb.storage…upload`(brand-orient-form.js 941 — 저장소 정책이 `is_my_brand` 를 부른다) ②내 계정 줄 조회 `brandDb.from('brand_accounts')`(brand-mypage.js 44 · brand-orient-form.js 555 — 자기 줄 정책, A14 로 안 막힘) ③큐텐 불러오기 `qoo10-product-lookup`(관문이 `false` 면 일반 실패). ①③은 제한 계정이 일반 실패 문구를 보고 **다음 동작(다른 호출) 때** bw01-13 으로 간다 — 받아들인다(R2 「다음 동작 때」와 같다). 제한 7 주의에 적었다.
10. **사양서 5-2 「`get_my_brand_login_state` 현재 원본 확인」** — 확인: **532**(527 → 532, 이후 재정의 없음). 제한 갈래는 계정 줄을 찾은 직후, `_brand_acceptable_invites_for` 를 부르기 **전**에 둔다(대기 초대가 있으면 화면이 초대 화면으로 새지 않게).
11. **사양서 5-2 `service_claim_shipping_mail`(561)** — `_brand_mailable_accounts` 를 이름으로 부르므로 다시 정의할 필요 없다. 관리자 배송 탭 「받는 사람」(557 `admin_get_campaign_shipping`)에서도 제한 계정이 빠진다(사양서가 받아들임).

---

## ✅ 개발 기본값 (묻지 않고 알림 — 바꾸려면 말해 주세요)

| # | 기본값 | 근거 | 조각 |
|---|---|---|---|
| 기본값 1 | 브랜드 로그인 사용자 경로(조회·저장·수락)는 **오류 `account_restricted`(P0001)** 로 막고, 서비스 키 경로(`service_*`)와 관리자 함수는 **결과 값** `account_restricted` 로 돌려준다 | 화면 공통 입구는 오류 글자 하나만 본다(4-2). 서버 함수는 결과 값으로 갈래를 나누는 지금 방식 | 2 |
| 기본값 2 | `admin_restrict_brand_account` 는 **비밀번호를 정한 브랜드 계정만** 받는다(아니면 `not_active_account`) | 화면 「…」 도 사용 중 계정 줄에만(4-7). 서버도 같은 기준 | 4 |
| 기본값 3 | 메일 함수는 **하나**(`notify-brand-restriction`)에 종류 다섯 갈래 | 사양서 5-7 「개발이 고른다」. 두 겹 잠금·선점이 한 벌이라 걷을 자리가 한 곳 | 6 |
| 기본값 4 | 메일 선점은 **새 표 하나**(`brand_sanction_mail_claims` — 같은 원본 줄·같은 종류에 한 줄 고유) | 제한·정지 두 표에 칸을 각각 넣으면 칸이 열 개가 넘는다 | 1·4 |
| 기본값 5 | 계정 이용 제한 상태는 **`admin_get_brand_account_status` 에 싣는다**(새 조회 함수 없음). 겹침 확인(A12)은 `admin_check_brand_account_email` 에 싣는다 | 화면이 이미 두 함수를 부른다 — 호출 수가 늘지 않는다 | 4 |
| 기본값 6 | 「열람 정지」 배지는 캠페인 관리 목록·진행현황 머리 **두 자리만** — 브랜드 상세 캠페인 탭에는 안 둔다 | stale 6 · 사양서 4-7 그대로 | 12 |
| 기본값 7 | 관리자 쪽 이용 제한·열람 정지 모달·동작은 **새 파일 `dev/js/admin-brand-sanction.js`** 에 둔다(빌드 목록 등록은 제한 9) | `admin-brand-detail.js` 가 이미 1,700줄을 넘는다 · 제한 10·11 이 새 파일에 모여 브랜드 상세 파일 수정이 줄 그리기에만 머문다 | 9·10·11 |

---

## 한눈에 보는 의존 순서

```
[데이터베이스 — kemo-cd · 순서대로]
제한 1 표 둘·판정 둘·메일 선점 표 (동작 변화 없음)
 └→ 제한 2 관문 재정의(판정 함수·직접 읽는 자리·로그인 상태·수락·넘기기·메일 받는 사람·겹침 확인)
      ══ 같은 날 ══ 제한 5 서버 함수 셋 배포(kemo-af) → 제한 7 브랜드 화면 병합(kemo-45)
     └→ 제한 3 결과물·배송 판정 + 관리자 전달 거부
          ══ 같은 날 ══ 제한 8 브랜드 배송 안내(kemo-45) · 제한 13-a 관리자 배송 안내(kemo-af)
         └→ 제한 4 관리자 함수 + 권한 시드 + 제공 기록 종류 + 상태·일괄 조회 + 메일 선점 함수
              ══ 같은 날 ══ 제한 9 관리자 감싸개·권한 카탈로그·빌드 목록(kemo-45, 핫스팟) · 제한 13-b(kemo-af)
              ──→ 제한 6 메일 함수 배포(kemo-af — 작성은 지금부터)
[관리자 화면 — kemo-45 · 순서대로] 제한 9 → 제한 10 계정 이용 제한 → 제한 11 열람 정지·겹침 확인 → 제한 12 목록 배지(admin.js 핫스팟)
제한 14 개발서버 처음부터 끝까지 확인(크롬 단일) — 1~13 뒤
제한 15 문서 — 14 뒤
제한 16 출시 날 운영 반영·잠금 걷기 — 브랜드 페이지 1차 출시 날
```

- **병렬**: kemo-cd(제한 1→4)와 kemo-af(제한 5·6·13 작성)·kemo-45(제한 7·8 작성)는 파일이 안 겹친다. kemo-45 는 제한 4 적용 전까지 브랜드 화면(7·8)을, 그 뒤 관리자 화면(9→12)을 한다.
- **같은 날 짝**(데이터베이스 개발서버 적용 → 그것을 부르는 서버 함수 배포·화면 병합):
  - 제한 2 적용 → 제한 5 배포 → 제한 7 병합
  - 제한 3 적용 → 제한 8 병합 · 제한 13-a 병합
  - 제한 4 적용 → 제한 9 병합 · 제한 13-b 병합(그 뒤 10·11·12 는 각자 리뷰 통과 때) · 제한 6 배포
  - kemo-cd 는 마이그레이션 파일을 미리 써 두되 **적용은 짝 병합 요청이 리뷰를 통과한 날** 한다.

---

## 작업 조각 표

| 번호 | 제목 | 담당 파일 | 산출 계약(요지) | 선행 | 병렬? | 담당 |
|---|---|---|---|---|---|---|
| 제한 1 | 표 둘·판정 둘·메일 선점 표(4-1·5-1·5-7 표) | 새 마이그레이션 | 표 `brand_account_restrictions`·`brand_results_suspensions`·`brand_sanction_mail_claims` · `_brand_account_restricted(uuid) → boolean` · `_brand_active_suspension(uuid) → jsonb` | S1·S2 | ✗ | kemo-cd |
| 제한 2 | 관문 재정의(4-2·5-2) | 새 마이그레이션 | `my_brand_role`·`_brand_caller_link_role` 오류 `account_restricted` · `get_my_brand_login_state` 갈래 `restricted` · 수락 셋·넘기기 거부 · `_brand_mailable_accounts` 제외 + `service_brand_mailable_accounts` · 겹침 확인 `restricted` · 연결 요청 `account_restricted` | 1 · **5·7 과 같은 날** | ✗ | kemo-cd |
| 제한 3 | 결과물·배송 판정 + 관리자 전달 거부(4-4·5-3) | 새 마이그레이션 | 547 `reason:'suspended'` · 550 `results_suspended` · `_shipping_list_block_reason` · 배송 넷 `suspended` · `admin_deliver_shipping_list` `results_suspended` | 2 · **8·13-a 와 같은 날** | ✗ | kemo-cd |
| 제한 4 | 관리자 함수·권한 시드·제공 기록 종류·조회·메일 선점 함수(4-6·4-9·5-4·5-5·5-6·5-7) | 새 마이그레이션 | 쓰기 다섯 · `admin_get_brand_account_status` 칸 · `admin_get_brand_results_suspended_map` · 권한 `brand.restriction_manage` 시드 3행 · 검사 제약 11종 · `service_claim_brand_sanction_mail`·`service_mark_brand_sanction_mail_sent` | 3 · **9·13-b 와 같은 날** | ✗ | kemo-cd |
| 제한 5 | 서버 함수 셋 수정(5-2b) | `supabase/functions/brand-campaign-results/index.ts` · `brand-link-request-accept/index.ts` · `notify-orient-sheet/index.ts` | `account_restricted` 넘기기 · 수락 거부 갈래 · 받는 사람 = `service_brand_mailable_accounts` | (작성) 없음 · (배포) 2 | ○ | kemo-af |
| 제한 6 | 메일 양식 다섯 + 메일 함수(4-8) | 새 `supabase/functions/notify-brand-restriction/index.ts` · `docs/email-templates/brand-*.html` 다섯(+미리보기) · `docs/email-templates/index.html` · `scripts/sync-email-templates.sh` · 생성 미러 | `POST {kind, ref_id}` → 선점 → 발송 → 결과 기록 · 두 겹 잠금 `BRAND_SANCTION_MAIL=1` + 개발 프로젝트 | (작성) 없음 · (배포) 4 | ○ | kemo-af |
| 제한 7 | 브랜드 화면 — bw01-13 + 공통 입구(4-3) | `dev/brand/index.html` · `dev/js/brand-core.js` · `dev/js/brand-login.js` · `dev/js/brand-invite.js` · 브랜드 화면 스타일 | `data-screen="restricted"` · `handleBrandAccountRestricted()` · `applyBrandLoginState` 갈래 · `laterCurrentInvite` | (작성) 없음 · (병합) 2 적용 + 5 배포 직후 | ○ | kemo-45 |
| 제한 8 | 브랜드 화면 — 배송 정지 안내(4-5) | `dev/js/brand-shipping.js` · `dev/js/brand-campaigns.js`(배송 카드) | `reason:'suspended'` → 「배송 리스트 열람이 정지되었습니다」 안내 | (작성) 없음 · (병합) 3 적용 직후 | ○ | kemo-45 |
| 제한 9 | 관리자 감싸개·권한 카탈로그·빌드 목록(핫스팟) | `dev/lib/storage.js` · `dev/lib/shared.js` · `dev/build.sh` · 새 빈 파일 `dev/js/admin-brand-sanction.js` | 감싸개 일곱 · 카탈로그 `brand.restriction_manage`(`staging_only`·`server_enforced`) | 4 적용 · (같은 날) | ✗ | kemo-45 |
| 제한 10 | 관리자 — 계정 이용 제한(a03-00·11·94 ①③⑤ · A1) | `dev/js/admin-brand-detail.js`(계정 줄) · `dev/js/admin-brand-sanction.js` | 계정 줄 「…」·제한 모달·제한 중 배지·기간 바꾸기·제한 해제·다른 브랜드 배지 | 9 (6 배포는 권장 — 없으면 메일만 안 나간다) | ✗ | kemo-45 |
| 제한 11 | 관리자 — 결과물 열람 정지 + 겹침 확인 제한 계정(a03-12·94 ②④ · A12) | `dev/js/admin-brand-detail.js`(머리·겹침 확인 갈래) · `dev/js/admin-brand-sanction.js` | 머리 「…」 항목·정지 모달·정지 중 배지·정지 해제 · 겹침 확인 안내 + 「제한 해제」 | 10 | ✗ | kemo-45 |
| 제한 12 | 관리자 — 「열람 정지」 배지 두 자리 | `dev/js/admin.js`(🔴 핫스팟) · `dev/js/admin-brand-publish.js` | `fetchBrandResultsSuspendedMap` 결과로 배지 | 9 (같은 세션 순서상 11 뒤) | ✗ | kemo-45 |
| 제한 13 | 관리자 — 배송 전달 거부 안내 · 제공 기록 이름표 | `dev/js/admin-shipping.js` · `dev/js/admin-privacy-logs.js` | `results_suspended` 안내 · 종류 `results_suspend`·`results_unsuspend` 이름표 | (병합) 3 적용(13-a) · 4 적용(13-b) | ○ | kemo-af |
| 제한 14 | 개발서버 처음부터 끝까지 확인(크롬 단일) | (확인만) | 사양서 7절 5번 전 항목 | 1~13 | ✗ | kemo-cd |
| 제한 15 | 문서 | 사양서 「구현 결과」 · `docs/FEATURE_SPEC.md` · `CLAUDE.md` · 결과물 작업표 4c 줄 · 배송 작업표 D9 줄 · `.claude/rules/brand-account.md`·`shipping-list.md` | 현재 원본 번호 · 경고 한 줄(6절 2번) | 14 | ✗ | kemo-af |
| 제한 16 | 출시 날 — 운영 반영·잠금 걷기(8절) | 운영 데이터베이스 · 운영 서버 함수 비밀값 · `shared.js`(카탈로그) · `notify-brand-restriction` · 관리자 공지·Notion | 1→4 운영 적용(브랜드 묶음 뒤) → 함수 → 화면 | 15 · S3 · 브랜드 묶음 운영 반영 | ✗ | 출시 담당(사용자 지정) |

---

## 조각별 상세

### 제한 1 — 표 둘·판정 둘·메일 선점 표 (사양서 4-1 · 5-1 · 5-7 표 · 기본값 4)
- **하는 일:** 새 표 셋과 내부 판정 함수 둘. **지금 있는 함수·화면은 하나도 안 바뀐다**(아무도 안 부른다).
- **담당 파일:** 새 마이그레이션 1개.
- **산출 계약:**
  - 표 **`brand_account_restrictions`** — `id uuid` 기본 키 · `auth_id uuid NOT NULL`(인증 사용자, 외래 키는 작성 때 판단 — 탈퇴·계정 삭제 뒤 보관은 S3) · `reason_code text NOT NULL CHECK (IN ('terms_8','account_sharing','other'))` · `reason_note text NOT NULL`(빈 글자 거부) · `until_date date NULL`(비면 「해제할 때까지」, 일본 날짜) · `created_by uuid`·`created_by_name text`·`created_at timestamptz` · `lifted_by uuid`·`lifted_by_name text`·`lifted_at timestamptz`(관리자가 닫을 때만) · `close_reason text NULL CHECK (IN ('lifted','period_changed'))` · `prev_id uuid NULL`(기간 바꾸기로 이어진 앞 줄). 색인 `(auth_id, created_at DESC)`.
  - 표 **`brand_results_suspensions`** — `id` · `brand_id uuid NOT NULL` · `reason_code CHECK (IN ('terms_8','other'))` · `reason_note NOT NULL` · `include_shipping boolean NOT NULL DEFAULT false` · 건 사람·시각 · 푼 사람·시각. 부분 고유 색인 `(brand_id) WHERE lifted_at IS NULL`(브랜드당 하나 — 날짜 비교가 없어 색인으로 막을 수 있다).
  - 표 **`brand_sanction_mail_claims`** — `ref_kind text CHECK (IN ('restriction','suspension'))` · `ref_id uuid` · `mail_kind text CHECK (IN ('account_restrict','account_period','account_lift','results_suspend','results_lift'))` · `claimed_at`·`sent_at`·`ok boolean`·`failed jsonb` · 고유 `(ref_kind, ref_id, mail_kind)`.
  - 세 표 모두 행 단위 보안 켬 · 읽기·쓰기 정책 없음 · `anon`·`authenticated` 표 권한 전부 회수(552 [J7] 방식 — 읽기는 제한 4 조회 함수로만).
  - **`_brand_account_restricted(p_auth_id uuid) RETURNS boolean`** — `lifted_at IS NULL AND (until_date IS NULL OR until_date >= (now() AT TIME ZONE 'Asia/Tokyo')::date)` 인 줄이 있으면 참. 🔴 「지금 걸려 있음」 판정식은 **여기 한 곳**(A3). `STABLE` · `SECURITY DEFINER` · `SET search_path = ''`.
  - **`_brand_active_suspension(p_brand_id uuid) RETURNS jsonb`** — 풀지 않은 줄이 있으면 `{id, include_shipping}`, 없으면 NULL. 🔴 정지 판정 한 곳.
  - 두 판정 함수 실행 권한: `postgres` 부여 → `PUBLIC` 회수 → `anon`·`authenticated`·`service_role` 회수(호출자 검사 없는 함수 — `supabase.md`).
- **선행 의존:** S1·S2.
- **완료 정의:** 개발서버 적용 + 기록 표 방금 시각 줄 · `SELECT relname, relrowsecurity FROM pg_class WHERE relname IN (세 표);` → 셋 다 참 · `SELECT p.proacl::text FROM pg_proc p WHERE proname IN ('_brand_account_restricted','_brand_active_suspension');` → 맨 앞 `=X/` 없음·`anon`·`authenticated` 없음 · 거래 안 시험: `BEGIN;` 제한 줄(`until_date`=어제) 넣고 판정 → 거짓, `until_date`=오늘 → 참, `until_date NULL` → 참, `lifted_at=now()` → 거짓 `ROLLBACK;` · 정지 줄 둘 넣기 → 23505.
- **필요 검문소:** `reverb-supabase-expert`(쓰기 전 — 일본 날짜 식·권한 회수 두 방향) · `reverb-reviewer`.
- **주의·롤백:** 롤백 = 판정 함수 둘 `DROP` → 표 셋 `DROP`(줄 0건일 때만). 다른 조각이 부르기 시작한 뒤에는 그 조각부터 되돌린다.

### 제한 2 — 관문 재정의 (사양서 4-2 · 5-2 · stale 1·3·5·10 · 기본값 1)
- **하는 일:** 제한 판정을 브랜드 데이터 관문 전부에 넣는다. 제한 줄이 0건인 동안은 **결과가 지금과 같다**.
- **담당 파일:** 새 마이그레이션 1개.
- **산출 계약**(전부 `CREATE OR REPLACE`, 베이스는 괄호 — 반환형 그대로):
  - `my_brand_role(uuid)`(530) — 로그인 사용자가 `_brand_account_restricted(auth.uid())` 면 `RAISE EXCEPTION 'account_restricted' USING ERRCODE = 'P0001'`. 그 밖은 530 식 그대로. `is_my_brand`(530)는 본문이 `my_brand_role` 을 부르므로 같이 막힌다 — 언어 변경이 필요하면 함께(stale 1).
  - `_brand_caller_link_role(uuid)`(531) — 같은 오류.
  - `orient_lookup_gate_account(uuid, uuid)`(541) — 받은 계정이 제한이면 지금 거부 값(함수의 「통과 안 됨」 값) — 530 식 사본에 판정 한 줄.
  - `get_my_brand_login_state()`(532) — 계정 줄을 찾은 **직후**, `_brand_acceptable_invites_for` 전에 제한이면 `{state:'restricted', name:NULL, email:NULL, brands:'[]', last_brand_id:NULL, has_pending_invite:false, new_invite_dot:false, password_changed_at:NULL}`(사유·기간 싣지 않음).
  - `respond_brand_invite(uuid, uuid, text, text)`(579) — 수락이고 호출자가 제한이면 오류 `account_restricted`(거절은 그대로 허용). `_brand_accept_owner_link(uuid, uuid, text)`(579) — 받는 계정이 제한이면 반환 `'account_restricted'`.
  - `_brand_transfer_owner(uuid, uuid)`(531) — 새 대표가 제한이면 반환 `'account_restricted'`(옛 대표가 제한이어도 멤버 줄은 지금처럼). 이 값을 받는 두 호출자(대표 넘기기·관리자 대표 바꾸기)가 결과를 그대로 넘기는지 본다.
  - `service_brand_link_request_setpw(uuid, text)`·`service_brand_link_request_finalize(uuid, text)`(580) — 받는 계정 제한이면 `{result:'account_restricted'}`(stale 5).
  - `_brand_mailable_accounts(uuid)`(557) — `AND NOT public._brand_account_restricted(ba.auth_id)`. **새 `service_brand_mailable_accounts(p_brand_id uuid) RETURNS jsonb`** — 같은 결과를 서비스 키에 준다(`postgres`·`service_role` 만, stale 3).
  - `admin_check_brand_account_email(uuid, text)`(573) — 브랜드 계정이 제한이면 결과에 `restricted:true, restriction_id, linked_brands:[{id,name}]`(활성 연결만, 0개면 빈 배열). 그 밖 칸 그대로.
  - `admin_request_brand_owner_link(uuid, text)`(578) — 받을 계정이 제한이면 `{result:'account_restricted'}`(계정·줄 안 만듦).
  - 머리말: 「연결 표를 직접 읽는 함수를 새로 만들면 `_brand_account_restricted` 를 넣는다」 + S2 에서 다시 센 전수 목록 + 롤백 절차(각 베이스 블록 재실행).
- **선행 의존:** 1. 🔴 **개발서버 적용 → 제한 5 배포 → 제한 7 병합을 같은 날.**
- **완료 정의:**
  - 회귀(제한 줄 0건): 사용자가 `zz-b2-owner` 로 로그인한 브랜드 화면에서 캠페인 목록·상세·결과물·배송·오리엔시트·멤버·브랜드 정보·마이페이지가 지금과 같다 · 캠페인 목록 원격 호출 응답 시간이 적용 전과 크게 다르지 않다(stale 1).
  - 제한 시험(SQL 편집기로 `zz-b2-second` 에 「해제할 때까지」 줄을 직접 넣고 끝나면 지운다): 그 계정 로그인 콘솔에서 `rpc('get_my_brand_campaigns')` → 오류 메시지 `account_restricted` · `rpc('get_my_brand_login_state')` → `state:'restricted'` · 같은 브랜드의 `zz-b2-owner` 는 그대로 쓴다(F1) · 관리자 콘솔 `admin_check_brand_account_email(브랜드, 그 이메일)` → `restricted:true`, `linked_brands` 2개 · `admin_request_brand_owner_link` → `account_restricted` · SQL 편집기 `SELECT public.service_brand_mailable_accounts('<가나다 시험 id>')` → 그 계정 빠짐.
  - 🔴 SQL 편집기로는 `auth.uid()` 경로가 안 돈다 — 로그인 브라우저 콘솔로만(사용자에게 로그인 부탁).
- **필요 검문소:** `reverb-supabase-expert`(530·531·532·541·557·573·578·579·580 줄 단위 대조 · 언어 변경 영향) · `reverb-reviewer`.
- **주의·롤백:** 롤백 = 각 함수 베이스 블록 재실행 + `service_brand_mailable_accounts` `DROP`(제한 5 의 `notify-orient-sheet` 를 먼저 되돌린다). 🔴 579 `respond_brand_invite` 는 4인자 — 인자 목록을 바꾸지 말 것(바꾸면 `DROP` 후 실행 권한을 다시 건다).

### 제한 3 — 결과물·배송 판정 + 관리자 전달 거부 (사양서 4-4 · 5-3 · R7 · stale 4 · 결과물 작업표 4c 를 여기로)
- **하는 일:** 정지 중인 브랜드에 결과물(표·엑셀·영수증)·배송 리스트(포함일 때)를 서버가 내주지 않는다. 관리자 전달을 막는다.
- **담당 파일:** 새 마이그레이션 1개.
- **산출 계약:**
  - `get_my_brand_campaign_results(uuid)`(547) — 「내 브랜드인가」 확인 **뒤**, 공개 꺼짐 **앞**에서 `_brand_active_suspension(브랜드)` 가 있으면 `{success:true, ready:false, reason:'suspended'}`. 🔴 더 앞에 두면 남의 캠페인에 정지 여부가 샌다.
  - `_brand_campaign_summary(uuid)`(550) — 정지면 `results_suspended:true` + `result_posted` 칸 **없음**. 아니면 지금 그대로(`results_suspended` 는 거짓으로 싣거나 생략 — 화면 `brandResultsSuspended` 가 참일 때만 본다).
  - **`_shipping_list_block_reason(p_campaign_id uuid) RETURNS text`** — 브랜드 판정 실패 `'not_found'` · 시딩형 아님·전달 전 `'not_ready'` · `include_shipping` 정지 `'suspended'`(정지 판정은 「내 브랜드」 뒤) · 열림 NULL. 옛 `_shipping_list_open_for_brand(uuid)` `DROP`.
  - `get_my_brand_shipping_summary(uuid)`(557) — `suspended` 면 `{success:true, ready:false, reason:'suspended'}`, 그 밖은 지금 모양. `get_my_brand_shipping_list`·`get_my_brand_shipping_export`(→ `_shipping_brand_rows_logged`)·`save_my_brand_shipping_rows`(557) — `suspended` 면 `{success:false, reason:'suspended'}`, 나머지 거부는 지금처럼 `not_found`. 기록(`shipping_view`·`shipping_excel`)은 막히면 안 남는다.
  - `admin_deliver_shipping_list(uuid)`(557) — 캠페인 브랜드가 `include_shipping` 정지면 `{success:false, reason:'results_suspended'}`(지금 그 함수의 거부 모양에 맞춘다) — 전달 상태·메일 선점·제공 기록(`shipping_deliver`) 모두 안 생긴다.
  - `_application_shipping_sync`(557) — **고치지 않는다**(사양서 4-4 마지막 줄).
  - 실행 권한: 새 내부 함수 `postgres` 만(557 의 내부 함수 방식). 바꾼 함수는 `CREATE OR REPLACE` 라 보존.
- **선행 의존:** 2. 🔴 **개발서버 적용 → 제한 8·13-a 병합을 같은 날.**
- **완료 정의:** 회귀(정지 0건): B0046 결과물 보기·엑셀·영수증 확대, 전달된 시딩형 배송 목록·내려받기·저장, 관리자 전달이 지금과 같다 · 정지 시험(SQL 로 「가나다 시험」 정지 줄, `include_shipping=false`): 브랜드 콘솔 `get_my_brand_campaign_results` → `reason:'suspended'`, `brand-campaign-results` 엑셀 → `ready:false`(서버 함수 판정), 요약 `results_suspended:true`·`result_posted` 없음, 배송은 그대로 열림, 관리자 전달 그대로 · `include_shipping=true` 로 바꾸면 배송 요약 `reason:'suspended'`, 목록 `{success:false, reason:'suspended'}`, 관리자 전달 `results_suspended` + `campaign_shipping_lists.delivered_at` 그대로·제공 기록 새 줄 없음 · 다른 브랜드 캠페인 번호로 부르면 `not_found`(정지 여부 안 샘) · 시험 줄 지움 · `to_regprocedure('public._shipping_list_open_for_brand(uuid)')` → NULL.
- **필요 검문소:** `reverb-supabase-expert`(547·550·557 줄 단위 대조 — 547 은 543 베이스 금지, 550 은 547 베이스 금지) · `reverb-reviewer`.
- **주의·롤백:** 롤백 = 547·550·557 블록 재실행(옛 판정 함수도 557 블록으로 되살아난다) → 새 판정 `DROP`. 제한 8 을 먼저 되돌릴 필요는 없다(화면은 모르는 이유를 일반 실패로 그린다).

### 제한 4 — 관리자 함수·권한 시드·제공 기록 종류·조회·메일 선점 함수 (사양서 4-6 · 4-9 · 5-4 · 5-5 · 5-6 · 5-7 · A1·A4·A11·A12 · 기본값 2·4·5)
- **하는 일:** 관리자가 걸고·바꾸고·푸는 함수, 상태 조회, 권한 항목, 기록, 메일 선점.
- **담당 파일:** 새 마이그레이션 1개(🔴 권한 시드는 관리자 함수와 **같은 파일**).
- **산출 계약:** (반환은 578 방식 `{result, …}` jsonb · 가드 `has_permission('brand.restriction_manage','write')` 실패 `forbidden`)
  - 권한 시드 `role_permissions`(530:275 방식): `super_admin`·`campaign_admin` = `write` · `campaign_manager` = `hidden`, 키 **`brand.restriction_manage`** · `default_level` 도 함께(`admin-permissions.md` 「정책을 바꾸는 마이그레이션」).
  - **`admin_restrict_brand_account(p_auth_id uuid, p_reason_code text, p_reason_note text, p_until date) RETURNS jsonb`** → `{result:'ok', restriction_id}` | `forbidden` · `not_found`(브랜드 계정 아님) · `not_active_account`(비밀번호 안 정함 — 기본값 2) · `already_restricted` · `invalid_reason` · `note_required` · `invalid_until`(오늘 일본 날짜보다 앞). 같은 계정 잠금(`pg_advisory_xact_lock(hashtext('brand_restriction:'||auth_id))`)을 먼저 잡고 `_brand_account_restricted` 로 겹침 확인(A4).
  - **`admin_change_brand_restriction_period(p_restriction_id uuid, p_until date) RETURNS jsonb`** → `{result:'ok', restriction_id: 새 줄}` | `forbidden` · `not_restricted`(그 줄이 지금 걸려 있지 않음) · `invalid_until` · `same_period`. 지금 줄 `lifted_*` + `close_reason='period_changed'`, 같은 사유·설명으로 새 줄(`prev_id`=옛 줄) — 같은 거래(A1).
  - **`admin_lift_brand_account_restriction(p_restriction_id uuid) RETURNS jsonb`** → `{result:'ok'}` | `forbidden` · `not_restricted`. `close_reason='lifted'`.
  - **`admin_suspend_brand_results(p_brand_id uuid, p_reason_code text, p_reason_note text, p_include_shipping boolean) RETURNS jsonb`** → `{result:'ok', suspension_id}` | `forbidden` · `brand_not_found` · `already_suspended` · `invalid_reason` · `note_required`. 같은 거래에서 `_record_brand_provision(브랜드, NULL, 'results_suspend', columns, '[]', NULL, 'admin')` — `columns` 에 막는 대상(`results`·`excel`·`receipt` + 포함이면 `shipping`).
  - **`admin_lift_brand_results_suspension(p_brand_id uuid) RETURNS jsonb`** → `{result:'ok', suspension_id}` | `forbidden` · `not_suspended`. 같은 거래에서 `results_unsuspend` 기록.
  - **`admin_get_brand_account_status(uuid)`**(578 베이스) — 기존 칸 전부 + 계정 줄마다 `restriction:{id, reason_code, reason_note, until_date, created_at, created_by_name, linked_brands:[{id,name}]}|null`(🔴 다른 브랜드 연결도 실어 F1 배지·모달 문구에 쓴다) + 머리 `results_suspension:{id, reason_code, reason_note, include_shipping, created_at, created_by_name}|null` + `can_restrict:boolean`(`has_permission(…,'write')`). 읽기 가드는 지금 함수 그대로(브랜드 상세를 볼 수 있는 관리자).
  - **`admin_get_brand_results_suspended_map(p_brand_ids uuid[]) RETURNS jsonb`** → `{"<brand_id>": true, …}`(정지 중만). 가드 `is_admin()`.
  - 제공 기록 검사 제약(552) — 실제 이름 확인 뒤 `DROP` → 11종(`results_suspend`·`results_unsuspend` 추가)으로 다시. `admin_get_brand_provision_logs`(552)가 종류를 화이트리스트로 거르면 함께(stale 8).
  - **`service_claim_brand_sanction_mail(p_ref_kind text, p_ref_id uuid, p_mail_kind text, p_caller uuid) RETURNS jsonb`** → `{result:'ok', claimed_at, recipients:[{auth_id,email,name}], payload:{account_name?, brand_names:[], reason_code, reason_note, until_date?, include_shipping?, brand_name?}}` | `forbidden`(호출 관리자 권한 없음) · `not_found` · `not_eligible`(종류와 줄 상태가 안 맞음 — 예: `account_lift` 인데 손으로 해제된 줄이 아님, `results_lift` 인데 아직 정지 중) · `already_claimed`. 받는 사람: ①②③ = 그 계정 한 명(A8) / ④⑤ = `_brand_mailable_accounts(브랜드)`(R4·R5). 선점 줄 삽입이 곧 「알림 1건 = 메일 1통」.
  - **`service_mark_brand_sanction_mail_sent(p_ref_kind text, p_ref_id uuid, p_mail_kind text, p_claimed_at timestamptz, p_ok boolean, p_failed jsonb) RETURNS void`** — 선점 시각 대조(561 방식).
  - 실행 권한: 관리자 함수 일곱 `postgres`·`authenticated`·`service_role` 부여 → `PUBLIC` 회수 → `anon` 회수 · 서비스 함수 둘 `postgres`·`service_role` 만.
- **선행 의존:** 3. 🔴 **개발서버 적용 → 제한 9·13-b 병합 같은 날**, 제한 6 배포는 적용 뒤.
- **완료 정의:** 🔴 권한 판정이 로그인 사용자 기준이라 **관리자 로그인 콘솔**에서(사용자 로그인 부탁): ①`zz-b2-second` 「날짜까지(오늘+7)」 → `ok` ②다시 → `already_restricted` ③어제 날짜 → `invalid_until` ④기간 바꾸기 → 새 `restriction_id`, 옛 줄 `period_changed` ⑤`admin_get_brand_account_status(가나다)` 그 계정 줄 `restriction` 에 `linked_brands` 둘 · `Aroma Farm 시험` 상태에서도 같은 값 ⑥해제 → `ok`, 다시 → `not_restricted` ⑦비밀번호 안 정한 계정 → `not_active_account` ⑧정지 걸기(배송 포함) → `ok` + `brand_provision_logs` 새 줄(`results_suspend`, `campaign_id` NULL) ⑨다시 → `already_suspended` ⑩일괄 조회에 그 브랜드만 참 ⑪풀기 → `results_unsuspend` 줄 ⑫캠페인 매니저 등급 계정(사용자 로그인) → `forbidden`, `can_restrict:false` ⑬SQL 편집기 `service_claim_brand_sanction_mail('restriction', id, 'account_restrict', 관리자 id)` → `ok` + 받는 사람 1명, 두 번째 → `already_claimed` ⑭`proacl` 확인 ⑮`SELECT role, level FROM role_permissions WHERE feature_key='brand.restriction_manage';` → 3행.
- **필요 검문소:** `reverb-supabase-expert`(578 베이스 대조 · 시드와 함수 같은 파일 · 권한 회수 두 방향) · `reverb-reviewer`.
- **주의·롤백:** 롤백 = 새 함수 `DROP` → 578 블록 재실행 → 검사 제약 9종으로(새 종류 줄이 있으면 먼저 지울지 사용자 확인 — 법 기록) → 시드 3행 삭제. 🔴 시드를 빠뜨리면 등급별로 판정이 반대가 된다(`has_permission` 미등록).

### 제한 5 — 서버 함수 셋 수정 (사양서 5-2b · stale 2·3·5)
- **하는 일:** 제한 오류가 화면까지 오게 하고, 오리엔시트 메일 받는 사람 사본을 없앤다.
- **담당 파일:** `supabase/functions/brand-campaign-results/index.ts` · `supabase/functions/brand-link-request-accept/index.ts` · `supabase/functions/notify-orient-sheet/index.ts`.
- **산출 계약:**
  - `brand-campaign-results` — `get_my_brand_campaign_results` 오류의 `message === 'account_restricted'` 면 `200 {success:false, reason:'account_restricted'}`(500 아님). 서명 갈래(`service_brand_receipt_signable` 앞)도 같은 조회를 먼저 거치므로 한 곳.
  - `brand-link-request-accept` — `setpw`·`finalize` 결과 `account_restricted` 를 `200 {ok:false, reason:'account_restricted'}` 로 넘긴다(「링크 무효」로 바꾸지 않는다). 비밀번호 저장 전 `setpw` 에서 걸리면 인증 서비스에 쓰지 않는다.
  - `notify-orient-sheet` — `resolveBrandAccountRecipients` 를 `rpc('service_brand_mailable_accounts', {p_brand_id})` 로 바꾸고 직접 조회·사본 주석을 걷는다. 0명이면 지금처럼 `no_account`. 두 겹 잠금(`ORIENT_MAIL_TO_BRAND_ACCOUNTS`) 그대로.
- **선행 의존:** (작성) 없음 · 🔴 (배포) 제한 2 개발서버 적용 확인 뒤(감싸개가 없는 데이터베이스에서 배포하면 오리엔시트 발급 메일이 전부 실패).
- **완료 정의:** 개발 프로젝트 배포(`--use-api`, 각 함수 머리말 명령) · 사전 요청(교차 출처 허용 헤더) 200 · 제한 시험 계정 토큰으로 `brand-campaign-results` → `reason:'account_restricted'` · 정상 계정 → 지금과 같음 · 관리자 오리엔시트 발급(시험 브랜드) → `dev` 응답 받는 사람에 제한 계정 없음, 정상 계정 있음 · 로그에 이메일·링크 없음.
- **필요 검문소:** `reverb-reviewer`(로그·교차 출처 허용 헤더·잠금 유지).
- **주의·롤백:** 롤백 = 이전 커밋 함수 재배포. 🔴 운영 배포 금지(출시 날 제한 16).

### 제한 6 — 메일 양식 다섯 + 메일 함수 (사양서 4-8 · A8·A9 · R4·R5 · 기본값 3·4)
- **하는 일:** 걸기·바꾸기·풀기·정지·정지 해제 알림 메일.
- **담당 파일:** 새 `supabase/functions/notify-brand-restriction/index.ts` · `docs/email-templates/brand-account-restricted.html`·`brand-account-restriction-changed.html`·`brand-account-unrestricted.html`·`brand-results-suspended.html`·`brand-results-unsuspended.html`(+ 각 `.preview.html`) · `docs/email-templates/index.html`(카탈로그 줄) · `scripts/sync-email-templates.sh`(대응표에 `notify-brand-restriction|…` 한 줄 + `--use-api` 분기 목록) · 생성 미러 `_templates/`·`templates.ts`.
- **산출 계약:**
  - `POST {kind, ref_id}` — `kind` ∈ `account_restrict`·`account_period`·`account_lift`·`results_suspend`·`results_lift`(그 밖 400 `invalid_request`). 호출자 토큰 필수(없으면 401). 순서: 호출자 토큰으로 `has_permission('brand.restriction_manage','write')` → `service_claim_brand_sanction_mail(ref_kind, ref_id, kind, caller)` → 1명당 1통 발송 → `service_mark_brand_sanction_mail_sent`(일부 실패 = `ok:true` + 실패 명단, 전원 실패만 `ok:false`).
  - 응답 `200 {sent:true, count}` | `200 {sent:false, reason: forbidden|not_found|not_eligible|already_claimed|no_recipient|send_failed}` | 개발서버 잠금 응답 `dev_mail:[{to_masked, subject, text}]`(본문은 잠금일 때만 — 공개 함수 아님) | 400 · 401 · 500.
  - 🔴 두 겹 잠금: 비밀값 `BRAND_SANCTION_MAIL=1`(개발서버에만) **그리고** `isStagingProject()`. 🔴 운영에 비밀값을 넣는 것은 출시 날.
  - 양식 자리: 공통 `{{reason_label}}`·`{{reason_note}}`·`{{contact}}`(「REVERB 운영팀 담당자에게 직접 문의」 — R6) · ①② `{{until_text}}`(「YYYY/MM/DD까지」 또는 「해제할 때까지」)·`{{brand_names}}` · ④ `{{brand_name}}`·`{{blocked_items}}`(배송 포함 여부) · ④⑤ `{{brand_url}}` 한 줄(A9 — ①②③ 링크 없음). 인플루언서 4줄 푸터 의무 없음(브랜드 메일 관례). 텍스트 판은 양식의 사본 — 머리말에 「함께 고칠 것」.
  - 사유 이름표: `terms_8` 「이용약관 제8조 위반(인플루언서 정보)」 · `account_sharing` 「계정 공유」 · `other` 「기타」 — 🔴 관리자 모달(제한 10·11)과 **사본 두 벌** — 양쪽 머리말에 서로를 적는다.
- **선행 의존:** (작성) 없음 · 🔴 (배포) 제한 4 개발서버 적용 뒤.
- **완료 정의:** `bash scripts/sync-email-templates.sh` 뒤 미러에 다섯 · 개발 프로젝트 배포 · 사전 요청 200 · 관리자 토큰 + 제한 4 시험 줄로 다섯 종류 각각 → `dev_mail` 제목·본문이 종류에 맞음(④ 받는 사람에 제한 계정 없음) · 같은 요청 두 번째 → `already_claimed` · 캠페인 매니저 토큰 → `forbidden` · `account_lift` 를 아직 걸린 줄로 → `not_eligible` · 카탈로그(`docs/email-templates/index.html`)에 다섯 줄. 🔴 실제 발송 시험은 사용자 확인 뒤(`supabase.md`).
- **필요 검문소:** `reverb-reviewer`(두 겹 잠금·로그에 본문·이메일 없음·1명당 1통) · `reverb-supabase-expert`(선점 → 결과 기록 순서).
- **주의·롤백:** 롤백 = 함수 삭제(대시보드) 또는 이전 판. 운영 배포 금지.

### 제한 7 — 브랜드 화면 bw01-13 + 공통 입구 (사양서 4-3 · R2·R3·R6 · stale 2·9)
- **하는 일:** 제한된 계정이 로그인하면 안내 화면, 이미 열린 탭은 다음 동작 때 안내 화면.
- **담당 파일:** `dev/brand/index.html`(새 화면) · `dev/js/brand-core.js`(`brandRpc`·`brandCallFunction`) · `dev/js/brand-login.js`(`applyBrandLoginState`) · `dev/js/brand-invite.js`(`laterCurrentInvite`·수락 결과 문구·비밀번호 정하며 수락 결과) · 브랜드 화면 스타일 파일. 새 JS 파일 없음 → `dev/build.sh` 변경 없음(빌드만).
- **산출 계약:**
  - 화면 `<section class="brand-card" data-screen="restricted" hidden>` — 「브랜드 계정이 아님」(`data-screen="not-brand"`)과 같은 틀. 제목 「이용이 제한된 계정입니다」 · 본문 · 안내 두 줄(사양서 4-3 그대로, 문의처 R6) · 단추 「다른 계정으로 로그인」 하나(누르면 로그아웃 후 로그인 화면 — 「브랜드 계정이 아님」 화면 단추와 같은 방식).
  - `applyBrandLoginState` — `kind === 'restricted'` → 로그아웃 후 `goBrandScreen('restricted')`(다른 갈래와 같은 순서 — 초대 갈래보다 앞).
  - **`handleBrandAccountRestricted()`**(brand-core.js) — 한 번만 도는 표시(`_brandRestrictedHandled`)를 세우고 `brandSignOutLocal()` → `goBrandScreen('restricted')`. 🔴 페이지마다 따로 넣지 않는다.
  - `brandRpc` — 결과 `r.error && r.error.message === 'account_restricted'` 면 `handleBrandAccountRestricted()` 를 부르고 결과는 그대로 돌려준다. `brandCallFunction` — `r.body && r.body.reason === 'account_restricted'` 면 같은 처리.
  - `laterCurrentInvite` — 로그인 상태가 `restricted` 면 `applyBrandLoginState` 로 보낸다(지금은 ok 아니면 바로 로그아웃).
  - 비밀번호 정하며 수락 결과 `account_restricted` → 「이용이 제한된 계정입니다」 화면.
- **선행 의존:** (작성) 없음 · 🔴 (병합) 제한 2 적용 + 제한 5 배포 직후, 같은 날.
- **완료 정의:** 개발서버(크롬은 마우스로 — `browser-qa.md`): SQL 로 제한 줄을 넣은 계정(사용자 로그인) → 로그인 즉시 bw01-13, 「다른 계정으로 로그인」 → 로그인 화면 · **열린 탭**: 정상 로그인 상태로 캠페인 상세를 연 채 SQL 로 제한 → 결과물 탭 누르기(서버 함수 경로) → bw01-13 · 다른 탭에서 목록 새로고침(원격 호출 경로) → bw01-13 · 여러 호출이 동시에 실패해도 화면 전환 한 번 · 같은 브랜드 대표 계정은 그대로 · 제한 줄을 지운 뒤 다시 로그인 → 정상 · 문구가 사양서 4-3 과 글자 단위로 같음.
- **필요 검문소:** `reverb-reviewer` · `reverb-qa-tester` 권장(다른 세션이 크롬 안 쓸 때 단일 세션).
- **주의·롤백:** 롤백 = 커밋 되돌림(데이터베이스를 먼저 되돌릴 필요 없음 — 모르는 갈래는 「로그인 화면 + 확인 실패」로 막히는 방향). ⚠️ 오리엔시트 사진 올리기·큐텐 불러오기는 공통 입구 밖이라 그 동작 하나는 일반 실패 문구가 뜬다(stale 9 — 받아들임).

### 제한 8 — 브랜드 화면 배송 정지 안내 (사양서 4-5 · F7)
- **하는 일:** 배송 포함 정지면 배송 화면·카드에 정지 안내.
- **담당 파일:** `dev/js/brand-shipping.js` · `dev/js/brand-campaigns.js`(캠페인 상세의 배송 카드 자리 — 카드가 있는 파일 확인) · 필요하면 브랜드 화면 스타일.
- **산출 계약:** 배송 요약 `reason:'suspended'` · 목록·내려받기·저장 `reason:'suspended'` → 결과물 정지 안내와 같은 틀(`brandResultsSuspended` 가 쓰는 카드 모양)로 「배송 리스트 열람이 정지되었습니다」 + 본문 한 줄(`reverb-ui-copy`) — 「찾을 수 없음」 대신. 저장 중 받으면 입력값을 지우지 않고 안내.
- **선행 의존:** (작성) 없음 · 🔴 (병합) 제한 3 적용 직후 같은 날.
- **완료 정의:** 개발서버: 「가나다 시험」 배송 포함 정지(SQL) → 캠페인 상세 배송 카드·`#campaigns/<번호>/shipping` 둘 다 정지 안내, 결과물 카드도 정지 안내 · 배송 미포함 정지 → 배송은 그대로 열림 · 정지 지우면 원래대로.
- **필요 검문소:** `reverb-reviewer`.
- **주의·롤백:** 롤백 = 커밋 되돌림.

### 제한 9 — 관리자 감싸개·권한 카탈로그·빌드 목록 (핫스팟 — 기본값 7 · stale 7)
- **하는 일:** 관리자 화면이 부를 서버 호출과 권한 항목을 한 번에.
- **담당 파일:** `dev/lib/storage.js` · `dev/lib/shared.js` · `dev/build.sh`(`ADMIN_JS_FILES` + 같은 파일 「같이 고칠 목록」) · 새 `dev/js/admin-brand-sanction.js`(머리말만 — 내용은 제한 10·11).
- **산출 계약:**
  - storage.js(브랜드 계정 감싸개 옆, `_brandAccountRpc` 방식 · `_brandAccountEnabled()` 아래만 부름) **일곱**: `restrictBrandAccount(authId, reasonCode, reasonNote, until)` · `changeBrandRestrictionPeriod(restrictionId, until)` · `liftBrandAccountRestriction(restrictionId)` · `suspendBrandResults(brandId, reasonCode, reasonNote, includeShipping)` · `liftBrandResultsSuspension(brandId)` · `fetchBrandResultsSuspendedMap(brandIds)` → 실패 `null`·없음 `{}` · `sendBrandSanctionMail(kind, refId)` → `{sent:true[, dev_mail]}` | `{sent:false, reason}`(`notify-brand-restriction` 호출 — 관리자 쪽 서버 함수 호출 방식은 배송 알림 호출과 같게). 모두 서버 결과 `{result,…}` 를 그대로 돌려준다.
  - shared.js `ADMIN_PERMISSION_CATALOG` 한 줄 `{ key: 'brand.restriction_manage', label_ko: '브랜드 이용 제한·열람 정지', category: '브랜드', server_enforced: true, staging_only: true }` + 서버 강제 목록에 키.
  - build.sh — `admin-brand-sanction.js` 를 `admin-brand-detail.js` 뒤에.
- **선행 의존:** 제한 4 개발서버 적용(🔴 같은 날 병합).
- **완료 정의:** `bash dev/build.sh` 성공 · 산출물 `admin/index.html` 에 새 파일 내용이 실림 · 개발서버 관리자 「권한 관리」 화면에 항목이 보이고(최고 관리자) 운영 주소 판정에서는 숨음 · 콘솔에서 감싸개 각각 1회 호출 → 서버 결과 그대로.
- **필요 검문소:** `reverb-reviewer`(핫스팟 세 파일 — 남의 미커밋 없는지).
- **주의·롤백:** 🔴 핫스팟 — 이 조각 동안 같은 세 파일을 다른 세션이 만지지 않는다. 롤백 = 커밋 되돌림.

### 제한 10 — 관리자 계정 이용 제한 (사양서 4-7 a03-00·a03-11·a03-94 ①③⑤ · A1·A4·F1·F6)
- **하는 일:** 계정 줄 「…」 → 이용 제한 모달, 제한 중 배지·기간 바꾸기·제한 해제, 다른 브랜드 줄에도 배지, 메일 호출.
- **담당 파일:** `dev/js/admin-brand-detail.js`(`_bdPeopleRowHtml` 계정 줄 — 「…」·배지·단추만) · `dev/js/admin-brand-sanction.js`(모달·동작).
- **산출 계약:**
  - 계정 줄 「…」 — **사용 중**(`ownerState==='active'` 대표 줄 · 멤버 줄) + `st.can_restrict` + `restriction==null` 일 때만, 항목 「이용 제한」 하나. 기존 단추는 옮기지 않는다.
  - 제한 중 줄: 칩 「이용 제한 중」 + 설명 한 줄(「YYYY/MM/DD까지」 또는 「해제할 때까지」 · 사유 이름 · 건 사람) + `can_restrict` 면 「기간 바꾸기」·「제한 해제」 단추(「…」 없음 — A4).
  - 모달(동적 생성 `modal-overlay` 방식): **`#bdRestrictModal`** — 제목 「{이름} 계정의 브랜드 페이지 이용을 제한하시겠습니까?」, 이메일·`linked_brands` 이름들, 사유 라디오 셋(필수), 설명 `#bdRestrictNote`(칸 이름에 「이 내용이 메일에 그대로 들어갑니다」, 필수), 기간 `#bdRestrictUntilMode`(날짜까지/해제할 때까지) + `#bdRestrictUntil`(일본 날짜 오늘 이상만), 안내 두 줄, 「취소」/「이용 제한」. 기간 바꾸기는 같은 모달에 사유·설명 읽기 전용 + 「바뀐 기간을 이메일로 알립니다」 `#bdRestrictMailChk`(기본 켬). 제한 해제 확인 **`#bdRestrictLiftModal`** — 「바로 로그인할 수 있게 됩니다. 연결된 브랜드 N개(…) 모두에서 풀립니다.」 + 「해제를 이메일로 알립니다」(기본 켬).
  - 성공 → `sendBrandSanctionMail`(걸 때 항상 / 바꾸기·해제는 체크 때만) → 토스트(메일 실패면 「알림 메일을 보내지 못했습니다」 — 제한은 그대로) → `await refreshPane(…)`(브랜드 상세 페인 — `PANE_REFRESHERS` 에 있는 아이디 확인) + 계정 상태 다시 읽기.
  - 서버 거부 코드 → 한국어 안내(`already_restricted` 「이미 이용 제한 중인 계정입니다」 등).
- **선행 의존:** 9. 제한 6 개발 배포는 **권장**(없으면 「알림 메일을 보내지 못했습니다」 토스트만 뜨고 제한 동작은 된다).
- **완료 정의:** 개발서버(사용자 관리자 로그인, 크롬 마우스): 「가나다 시험」 `zz-b2-second` 줄 「…」 → 이용 제한(날짜까지 +3일) → 줄 배지 · 「Aroma Farm 시험」 상세 같은 계정 줄에도 배지 · 기간 바꾸기(해제할 때까지, 메일 체크) → 표에 새 줄·옛 줄 `period_changed` · 제한 해제(체크 끔) → 배지 사라짐·메일 호출 없음 · 「…」 는 비밀번호 안 정한 줄·연결 요청 줄에 없음 · 캠페인 매니저 등급(사용자 로그인)은 배지만 보고 「…」·단추 없음 · 어제 날짜는 고를 수 없음 · `dev_mail` 이 종류대로.
- **필요 검문소:** `reverb-reviewer`(`refreshPane`·`esc()`·확인 창 강도) · `reverb-qa-tester` 권장(단일 세션).
- **주의·롤백:** 롤백 = 커밋 되돌림. 「…」 메뉴는 머리 「…」(`brandDetailToggleMoreMenu`)와 같은 부품을 쓴다(새로 만들지 않는다 — `quality.md`).

### 제한 11 — 관리자 결과물 열람 정지 + 겹침 확인 제한 계정 (사양서 4-7 a03-12·a03-94 ②④ · A12 · R5·R7)
- **하는 일:** 머리 「…」 → 정지 모달, 정지 중 배지·정지 해제, 「계정 만들기」·「브랜드 연결 추가」에서 만난 제한 계정 안내.
- **담당 파일:** `dev/js/admin-brand-detail.js`(`_bdHeadHtml` 항목·배지 자리 · 겹침 확인 결과 갈래) · `dev/js/admin-brand-sanction.js`.
- **산출 계약:**
  - `_bdHeadHtml` — `can_restrict` 이고 `results_suspension==null` 이면 항목 「결과물 열람 정지」(🔴 「항목 0개면 「…」 숨김」 판정에 포함). 정지 중이면 상태 배지 옆 칩 「결과물 열람 정지 중」 + 설명(시작일 · 배송 포함 여부 · 건 사람) + `can_restrict` 면 「정지 해제」 단추. ⚠️ 머리는 계정 상태 조회(`_bdLoadAccountStatus`)보다 먼저 그려진다 — 조회가 끝나면 머리 배지 자리(`#brandDetailSuspendBadge` 새 아이디)만 다시 그린다.
  - 모달 **`#bdSuspendModal`** — 사유 둘 · 설명 `#bdSuspendNote`(필수) · 막을 것(결과물 표·엑셀·영수증 사진 — 고정) + 「시딩형 배송 리스트도」 `#bdSuspendShipping`(기본 꺼짐) + 그 옆 경고 한 줄(사양서 6절 5) · 안내 「대표 담당자·멤버에게 이메일로 알립니다」(R5) · 「취소」/「결과물 열람 정지」. 해제 확인 **`#bdSuspendLiftModal`** + 「해제를 이메일로 알립니다」(기본 켬).
  - 겹침 확인(`checkBrandAccountEmail` 결과 `restricted:true`) — 연결 요청 확인 모달 대신 「이용이 제한된 계정이라 연결할 수 없습니다」 + `can_restrict` 면 「제한 해제」 → `#bdRestrictLiftModal`(연결 0개면 둘째 문장 뺌). 연결 요청 보내기 결과 `account_restricted` 도 같은 안내.
  - 저장 뒤 `refreshPane` + 머리 다시 그리기.
- **선행 의존:** 10(같은 두 파일).
- **완료 정의:** 개발서버: 「가나다 시험」 머리 「…」 → 정지(배송 미포함) → 머리 배지·「…」에서 항목 사라짐 · 브랜드 화면 결과물 카드 정지 안내 · 「…」 항목이 「제공 기록」 하나도 없는 등급(캠페인 관리자)에서 정지 항목만으로 「…」 가 보인다 · 정지 해제(메일 체크) → `dev_mail` 받는 사람 = 대표·멤버(제한 계정 제외) · 연결 없는 제한 계정(S5 ⑤) 이메일로 「브랜드 연결 추가」 → 안내 + 「제한 해제」 → 풀린 뒤 다시 시도하면 연결 요청 모달.
- **필요 검문소:** `reverb-reviewer` · `reverb-qa-tester` 권장.
- **주의·롤백:** 롤백 = 커밋 되돌림(제한 10 과 따로 되돌릴 수 있게 커밋을 나눈다).

### 제한 12 — 「열람 정지」 배지 두 자리 (사양서 4-7 마지막 줄 · 기본값 6 · stale 6)
- **하는 일:** 캠페인 관리 목록·진행현황 머리의 「브랜드 공개」 배지 옆 「열람 정지」 배지.
- **담당 파일:** `dev/js/admin.js`(🔴 핫스팟 — 공개 상태 일괄 조회 옆에서 `fetchBrandResultsSuspendedMap` 같이, 배지 옆) · `dev/js/admin-brand-publish.js`(`refreshCampBrandPublishStatus` — 진행현황 머리).
- **산출 계약:** 배지 함수 **`brandSuspendBadgeHtml()`**(admin-brand-publish.js — `brandPublishBadgeHtml` 옆, 같은 모양). 조회 실패 `null` 이면 배지를 안 그린다(「정지 아님」으로 단정하지 않음 — 관리자 화면 판단에 영향 없는 보조 표시). `_brandAccountEnabled()` 아래만.
- **선행 의존:** 9(파일 의존). 같은 세션 순서상 11 뒤에 한다.
- **완료 정의:** 개발서버: 「가나다 시험」 정지 → 캠페인 관리 목록의 그 브랜드 캠페인 줄·진행현황 머리에 배지 · 다른 브랜드 캠페인엔 없음 · 해제 뒤 목록 새로고침하면 사라짐 · 운영 주소 판정(`_brandAccountEnabled()` 거짓)에서 조회·배지 없음.
- **필요 검문소:** `reverb-reviewer`.
- **주의·롤백:** 🔴 `admin.js` 핫스팟 — 이 조각 동안 다른 세션이 만지지 않게 사용자에게 알린다. 롤백 = 커밋 되돌림.

### 제한 13 — 관리자 배송 전달 거부 안내 · 제공 기록 이름표 (사양서 4-4 R7 · 4-9)
- **하는 일:** (13-a) 배송 탭 「배송 리스트 전달」이 `results_suspended` 를 받으면 안내. (13-b) 「개인정보 기록」 화면 종류 이름표 둘.
- **담당 파일:** `dev/js/admin-shipping.js` · `dev/js/admin-privacy-logs.js`.
- **산출 계약:** (13-a) `deliverShippingList` 결과 `reason:'results_suspended'` → 「이 브랜드는 배송 리스트까지 열람이 정지되어 전달할 수 없습니다. 정지를 풀거나 배송 미포함으로 다시 걸어 주십시오.」(확인 창 아님 — 기존 실패 안내 모양 따름) — 전달 상태·메일 호출 없음. (13-b) 종류 `results_suspend` 「결과물 열람 정지」 · `results_unsuspend` 「결과물 열람 정지 해제」 + 거르기 선택지에 둘.
- **선행 의존:** (13-a 병합) 제한 3 적용 · (13-b 병합) 제한 4 적용. 두 커밋으로 나눈다.
- **완료 정의:** 개발서버: 배송 포함 정지 브랜드 캠페인에서 「배송 리스트 전달」 → 안내, 전달 상태 그대로, 메일 함수 호출 없음 · 「개인정보 기록」(최고 관리자) 브랜드 거르기에 정지·해제 줄이 이름표로 보임.
- **필요 검문소:** `reverb-reviewer`.
- **주의·롤백:** 롤백 = 커밋 되돌림.

### 제한 14 — 개발서버 처음부터 끝까지 확인 (사양서 7절 5번)
- **하는 일:** 크롬으로 전 흐름 확인(🔴 크롬은 한 번에 한 세션 — 기획 세션이 차례를 정한다).
- **담당 파일:** 없음(확인만 · 결과는 제한 15 「구현 결과」로).
- **확인 항목:** ①관리자 이용 제한 → 열려 있던 브랜드 탭 다음 동작에서 bw01-13 ②같은 계정이 연결된 다른 브랜드 상세 배지 ③같은 브랜드 다른 계정 정상 ④「날짜까지」 자동 해제 — 🔴 화면·서버가 지난 날짜를 거부하므로 **개발서버 SQL 편집기에서 그 줄 `until_date` 를 어제로 직접 고쳐** 로그인 → 정상, 관리자 배지 사라짐, 메일 없음 ⑤기간 바꾸기·해제 메일 체크 켬/끔 ⑥제한 계정 초대 수락 → 거부(A5) · 제한 계정을 새 대표로 바꾸기 → `account_restricted`(A6) ⑦열람 정지(배송 미포함) → bw05-01d · 엑셀·영수증 진입 불가 · 목록 「결과물 게시」 「-」 ⑧배송 포함 → 배송 안내 · 관리자 전달 거부(R7) ⑨메일 다섯 `dev_mail` 내용(실제 발송은 사용자 확인 뒤) ⑩오리엔시트 발급 메일 받는 사람에서 제한 계정 빠짐(R4) ⑪권한 — 캠페인 매니저는 배지만 ⑫시험 데이터 원상복구.
- **선행 의존:** 1~13.
- **완료 정의:** ①~⑫ 결과(스크린샷·건수)를 기획 세션에 보고 · SQL 편집기 탭은 `navigate force:true` 후 닫음(`browser-qa.md`).
- **필요 검문소:** `reverb-qa-tester`(단일 세션).
- **주의·롤백:** 되돌릴 수 없는 것 없음(개발서버 시험 데이터) — 시험 줄은 끝나고 지운다(제한 표 줄은 이력이라 지울지 사용자에게 묻는다).

### 제한 15 — 문서
- **하는 일:** 사양서 「구현 결과」(실제 마이그레이션 번호·함수 이름·이 표 stale 1~11 처리·기본값 1~7·제한 14 결과) · `docs/FEATURE_SPEC.md` · `CLAUDE.md`(「브랜드 계정·로그인·멤버 관리」 현재 원본 번호 — 바뀐 함수 전부 · 경고 한 줄 「연결 표를 직접 읽는 함수를 새로 만들면 `_brand_account_restricted` 를 넣는다」(사양서 6절 2번) · 메일 파이프라인에 `notify-brand-restriction` 두 겹 잠금 · 출시 때 걷을 것) · `.claude/rules/brand-account.md`·`.claude/rules/shipping-list.md`(판정 이름 바뀜) · 결과물 작업표 4c 줄 「→ `2026-10-21-brand-account-restriction.md` 제한 3」 · 배송 작업표 D9 줄 「정지 판정 = `_shipping_list_block_reason`, 배송 포함은 관리자 선택(F2)」.
- **선행 의존:** 14.
- **완료 정의:** `grep -rn "_shipping_list_open_for_brand" CLAUDE.md .claude/rules/ docs/FEATURE_SPEC.md` → 「바뀜」 서술만 · 4c·D9 줄 갱신 · 「구현 결과」에 stale 처리.
- **필요 검문소:** `reverb-reviewer`.
- **주의·롤백:** `CLAUDE.md` 는 핫스팟 — 병합 직전 `origin/dev` 를 받아 합친다. 규칙 파일 커밋이 막히면 고문에게 넘긴다.

### 제한 16 — 출시 날 운영 반영·잠금 걷기 (사양서 8절)
- **하는 일:** 브랜드 페이지 1차 출시 날, 브랜드 묶음 운영 반영 **뒤**에 이 작업을 운영에 낸다.
- **순서:** ①운영 데이터베이스 — 브랜드 묶음(…→ 547·550·552·557·561·573·578·579·580 포함)이 들어간 뒤 제한 1 → 2 → 3 → 4(🔴 각 베이스 함수가 운영에 있어야 한다) ②운영 비밀값 `BRAND_SANCTION_MAIL=1` → 함수의 `isStagingProject()` 조건을 걷은 판을 운영 배포 + 제한 5 세 함수 운영 배포 ③화면 — 권한 카탈로그 `staging_only` 걷기 · `_brandAccountEnabled()` 는 브랜드 페이지 공통 출시 단계에서 ④관리자 공지 한 줄 「브랜드 상세 「…」 → 결과물 열람 정지 / 계정 줄 「…」 → 이용 제한」 + Notion 실무자 가이드(관리자 가이드 브랜드 상세 페이지 — `notion-sync.md` 정확성 게이트).
- **선행 의존:** 15 · S3(`/약관확인` 완료) · 브랜드 묶음 운영 반영.
- **완료 정의:** 운영 기록 표에 넷 · 운영 `role_permissions` 3행 · 운영 관리자 「권한 관리」에 항목 · 운영에서 시험 계정으로 걸기·풀기 1회(사용자 확인 뒤 — 실제 메일이 나간다) · 공지·Notion 갱신.
- **필요 검문소:** `reverb-supabase-expert`(운영 적용 순서) · `reverb-reviewer` · `reverb-qa-tester` 권장.
- **주의·롤백:** 🔴 운영 병합은 상대 개발자 확인 뒤(`two-developers.md` 4조). 롤백은 화면 → 함수 → 데이터베이스 역순.

---

## ⚠️ 공유 지점 경고 (충돌 주의)

| 파일·대상 | 만지는 조각 | 주의 |
|---|---|---|
| `my_brand_role`·`is_my_brand`(530) | 2 | 브랜드 데이터 관문 전부 — 언어를 바꾸면 모든 브랜드 화면 회귀(stale 1) |
| 579 `respond_brand_invite`·`_brand_accept_owner_link` · 580 둘 · 578 둘 · 573 | 2(·4) | 오늘 만든 함수 — 연결 요청 작업과 같은 대상. S1 알림 필수, 베이스는 마지막 `CREATE` |
| 557 배송 함수 · `_brand_mailable_accounts` | 2 · 3 | 배송 작업과 같은 대상 — `_application_shipping_sync` 는 안 만진다 |
| 552 제공 기록 검사 제약 | 4 | 같은 제약을 다른 작업이 늘리면 나중 적용이 앞을 지운다 — 병합 직전 `origin/dev` 의 마지막 정의를 다시 본다 |
| `dev/lib/storage.js`·`dev/lib/shared.js`·`dev/build.sh`(핫스팟) | 9 | 한 조각·한 세션 |
| `dev/js/admin.js`(핫스팟) | 12 | 한 조각·한 세션 |
| `dev/js/admin-brand-detail.js` | 10 · 11 | 같은 세션 순서대로 |
| `dev/js/brand-core.js`·`brand-login.js`·`brand-invite.js` | 7 | 연결 요청 화면 작업과 같은 파일 — 병합 직전 `origin/dev` 받기 |
| `scripts/sync-email-templates.sh` · `docs/email-templates/index.html` | 6 | 다른 메일 작업과 같은 대응표 — 한 줄만 추가 |
| 사유 이름표 사본 | 6(메일) · 10·11(모달) | 두 벌 — 머리말에 서로를 적는다 |
| `CLAUDE.md`(핫스팟) | 15 | 다른 작업표 문서 조각과 같은 절 — 나중 쪽이 합친다 |
| 마이그레이션 번호 | 1~4 | kemo-cd 한 세션이 정한다. push 직전 `origin/dev`·열린 병합 요청까지 보고 확정 |
| 크롬 | 7·10·11 확인 · 14 | 단일 자원 — 기획 세션이 차례를 정한다 |

---

## 🧭 배분 (2026-10-21 사용자 결정 — 제안대로)

- **kemo-cd — 데이터베이스**: 제한 1 → 2 → 3 → 4, 그 뒤 **제한 14**(개발서버 처음부터 끝까지). 번호를 이 세션 하나가 정한다. 제한 2·3·4 는 **파일을 먼저 쓰고, 개발서버 적용은 짝 조각 병합 요청이 리뷰를 통과한 날**.
- **kemo-af — 서버 함수·메일·작은 관리자 화면·문서**: 짝 날짜 순서로 제한 5(제한 2 적용 날 배포) → 13-a(제한 3 적용 날 병합) → 6 작성(지금부터 병행) → 13-b·6 배포(제한 4 적용 날) → 15. 제한 13 은 핫스팟이 아니어서 관리자 화면 세션과 동시에 갈 수 있다.
- **kemo-45 — 브랜드·관리자 화면**: 제한 7 → 8(데이터베이스 2·3 을 기다리는 동안) → 9 → 10 → 11 → 12. 핫스팟(9 의 storage·shared·build, 12 의 admin.js)이 전부 이 세션 하나에 모여 병렬 충돌이 없다.
- 🔴 **화면 버튼과 서버 함수는 같은 배포에 묶이지 않는다** — 각 화면 조각은 짝 데이터베이스 조각의 개발서버 적용(기록 표 줄)을 확인한 뒤 `dev` 에 병합한다.
- 🔴 조율은 기획 세션(kemo-7d) 경유 — 보고·이름 변경 알림·사용자 부탁(로그인·결정)·크롬 차례는 모두 기획 세션으로. 운영 배포·운영 데이터 변경은 세션 간 메시지를 승인 근거로 쓰지 않는다.
- 각 세션은 **자기 작업 폴더(worktree)와 `feature` 브랜치**에서 일한다(메인 폴더 `kemo` 는 공유 — 브랜치를 바꾸지 않는다).
