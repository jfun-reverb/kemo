# 다이제스트 3종 — 수신자 단위 발송 기록 (전수조사 D-8)
**작성일:** 2026-09-07
**작성:** 기획 세션 · **상태:** 사용자 결정 3건 · 기획 확정 5건 · 확인 대기 0건, 개발 착수 전
**출처:** `docs/specs/2026-09-02-audit-remediation-plan.md` 묶음 D 의 D-8 = `docs/research/2026-09-02-codebase-audit-findings.md` 4-12

> 다이제스트 3종(인플루언서 일일 · 관리자 일일 · 브랜드 일일)은 **실행 단위 기록**만 있고 **수신자 단위 기록이 없다.** 그래서 ①반복문 도중 죽으면 재시도가 **전원에게 다시** 보내고 ②일부만 실패하면 실행이 「발송됨」으로 닫혀 그 사람은 **영영 못 받는다.** 이 문서는 ①을 없애고 ②는 「기록이 남고 당일 재호출로 실패분만 다시 보낼 수 있는」 상태까지 만든다 — ②의 완전 해소(운영자가 알아채고 누르는 것)는 후속 화면에 달려 있다. 수신자 단위 표를 하나 만들고, 방침 통지(D-9)가 세운 「선점 먼저 → 발송 → 성공 뒤에만 완료」 순서를 세 함수에 그대로 옮긴다.

> ⚠️ 이 문서는 파일 경로와 함수·표·칸 **이름**만 적고 줄 번호는 적지 않는다.

---

## 현재 상태 (2026-09-07 기준 — 코드·마이그레이션 직접 확인)

### 관련 코드·DB·UI 진입점

| 무엇 | 어디 | 지금 동작 |
|---|---|---|
| 인플루언서 일일 다이제스트 | `supabase/functions/notify-influencer-daily-digest/index.ts` | 예약 매일 09:00(한국·일본). 회원마다 내용이 다르다(신규 응모·승인·반려·마감 임박 4섹션). 수신자 열쇠 = `perInfluencer` 맵의 회원 id(`influencers.id` = 로그인 계정 id). 반복문 안에서 한 명 실패는 건너뛰고 계속, 끝나면 실행 상태 **`sent`** + `total_emails`(성공 수) |
| 관리자 일일 다이제스트 | `supabase/functions/notify-admin-daily-digest/index.ts` | 같은 내용을 관리자 이메일 목록(`get_subscribed_admin_emails('daily_digest')` + 환경변수 `NOTIFY_ADMIN_EMAILS`)에 1통씩. 수신자 열쇠 = **이메일**. 일부 실패면 `sent` + `error_message` 에 실패 명단 글자로, 전원 실패면 `failed` |
| 브랜드 일일 다이제스트 | `supabase/functions/notify-brand-daily-digest/index.ts` | 관리자 일일과 같은 구조(수신 종류 `brand_notify`) |
| 실행 기록 표 3종 | `influencer_daily_digest_runs`(130) · `admin_daily_digest_runs`(132) · `brand_daily_digest_runs`(203) | `digest_date UNIQUE` 가 자물쇠. `status CHECK ('sent','skipped_no_data','failed')` — **`partial` 없음**. 세 함수 모두 「`failed`+`in-flight` 로 선점 → 끝에 UPDATE」, 죽은 실행은 **10분 대기 뒤** 재진입(`RETRY_COOLDOWN_MS`) |
| 마감 임박 재발송 차단 표 | `deadline_reminder_email_sent`(UNIQUE 회원·캠페인·종류·D-N) | 인플루언서 다이제스트가 **반복문이 다 끝난 뒤** 한꺼번에 INSERT. 마감 섹션이 있는 사람만 남는다 |
| 선례 ① 홍보 메일 | `campaign_promo_digest_sent`(139) — UNIQUE(회원, 날짜), `status ('sent','skipped','failed')`, `skip_reason`, `error_message` | 발송 뒤 기록(`mark_promo_digest_sent`). 실행 표에는 `partial` 이 있다 |
| 선례 ② 방침 통지(D-9 로 고침) | `policy_notice_sent`(153) + `notify-policy-change/index.ts` | **회원 단위 선점**: INSERT `status='failed', skip_reason='in_flight@시각'` → 이미 있으면 「`send_failed` 또는 오래된 `in_flight`」만 조건부 UPDATE 로 넘겨받음 → 발송 성공 뒤에만 `status='sent', skip_reason=null`. 🔴 **조건과 바꾸는 값이 같은 칸**(`skip_reason`) — 첫 판이 이걸 어겨 여러 실행이 동시에 잡을 수 있었고 리뷰에서 막혔다 |
| 홍보 메일의 관리자 요약 | `notify-campaign-promo-digest/index.ts`(관리자 수신자 반복문) | 같은 결함이 있는 **네 번째 자리**(함수 주석이 스스로 적어 둠). 이번 범위 밖 — 아래 결정 5 |
| 보관 기간 정리 선례 | `purge_old_admin_password_reset_requests`(243, 30일·04:15) · `purge_old_influencer_flags`(166, 36개월·04:00) | 함수 + pg_cron. 04:00~05:30 사이에 예약이 이미 **아홉 개**(04:00 · 04:15 · 04:30 셋 · 04:45 · 05:00 · 05:15 · 05:30 — 리뷰어 전수 확인) |
| 관리자 화면 | 없음 | 실행 기록 표를 보는 화면이 없다(`digest_runs` 참조 0건). 수신 설정 모달의 설명 문구뿐 |
| 개인정보처리방침 | `docs/PRIVACY_{kr,ja}.md` §5 처리위탁 표에 「시스템 메일 발송 정보 → Brevo」 | 발송 **기록**의 보관 기간 항목은 없다 |

### 이 제안과 충돌 가능성 있는 기존 동작
- **실행 표 `status` CHECK 에 `partial` 이 없다.** 부분 실패를 「발송됨」으로 닫는 지금 동작이 결함의 절반이므로 세 표의 CHECK 를 넓혀야 한다. 넓히지 않으면 부분 실패 실행을 재진입시킬 근거가 없다.
- **재진입 조건이 `failed` 뿐이다.** `partial` 을 더하면 재진입 조건도 `failed 또는 partial` 로 넓혀야 하고, 대기 시간(10분)은 그대로 둔다.
- **마감 임박 표의 벌크 INSERT.** 반복문 도중 죽으면 이미 받은 사람의 마감 임박 행이 안 남는다. 수신자 표가 그 사람을 `sent` 로 막아 주므로 재발송은 안 되지만, 마감 임박 행이 빠진 채 남는다 → 사람별로 INSERT 자리를 옮긴다(결정 7).
- **개발서버 메일 발송 시험 금지**(`feedback_dev_no_mail_test`). 개발서버에서는 발송 경로를 끝까지 못 돌린다 → 검증 절차가 갈린다(아래 「검증」).
- 충돌 없음 확인 — 방침 통지 함수와 홍보 메일의 **회원 발송분**은 각자 표가 있어 손대지 않는다. 홍보 메일의 **관리자 요약**은 표가 없지만 이번 범위 밖(결정 5)이라 역시 손대지 않는다.

### 미해결 백로그·관련 작업
- 조사 4-19 「인플루언서 다이제스트에 감사용 계정 제외가 구조적으로 불가능」 — 이 표로 풀리지 않는다. 범위 밖.
- 실행 기록·수신자 기록을 보는 관리자 화면 — 후속(결정 2).

---

## 의심·경우의 수 (규칙 B)

### 깨질 수 있는 경우
1. **동시성 — 선점 조건과 바꾸는 값이 다른 칸이면 두 실행이 같은 사람을 동시에 잡는다.** D-9 첫 판의 사고. → `skip_reason` 한 칸으로 조건·값을 통일(설계 3). 실행 단위 자물쇠가 있어도 이 규칙은 그대로 둔다 — 자물쇠는 **실행**이 죽었는지를 보고, 이 규칙은 **수신자 한 명의 발송**이 죽었는지를 본다(대상이 다르다).
2. **기술 — 재시도 때 대상 집합이 달라질 수 있다.** 인플루언서 다이제스트는 「어제 창」을 다시 세므로 같은 날짜면 같은 집합이지만, 관리자 구독 목록은 그 사이 바뀔 수 있다. → 수신자 표는 「누가 이미 받았나」만 답하고, 대상 집합은 매 실행이 새로 만든다(새로 들어온 관리자는 받고, 빠진 관리자는 안 받는다 — 정상).
3. **데이터 — 부피.** 인플루언서 쪽은 하루 수백 행 → 1년 십수만 행. → 90일 정리(결정 3). 실행 표(하루 1행)는 종전대로 영구.
4. **UX — 기록만 남기면 아무도 안 본다.** 화면이 없어 SQL 편집기로만 본다. → 이번엔 기록·재시도 동작까지(결정 2), 화면은 후속 사양서. 다만 **운영자가 손으로 재호출할 때 무엇이 일어나는지**는 이 문서가 정한다(설계 5).
5. **권한 — 표 접근.** 인플루언서 다이제스트 행은 회원 id 를 담는다. 관리자만 읽고, 쓰기는 서비스 키만(정책 없음). 방침 통지·홍보 메일 표와 같은 기준.
6. **법률 — 새 개인정보 항목인가.** 회원 쪽은 회원 id 와 발송 결과만 남기고 **회원 이메일은 안 남긴다.** 관리자·브랜드 다이제스트는 수신자 열쇠가 관리자 이메일이라 그 값이 남지만 회원 개인정보가 아니다. 방침 §5 표에 발송 「기록」 보관 기간이 없으므로 한 줄 추가가 필요한지 `/약관확인` 으로 본다(결정 8).
7. **탈퇴 회원.** 회원 행은 탈퇴 뒤에도 남고 개인정보 칸만 비워진다(352) → 회원 id 만 있는 이 표는 파기 대상이 아니다. 회원 행이 실제로 삭제되면(`delete_admin_completely` 등) 함께 지워지도록 `ON DELETE CASCADE`.
8. **실행 표 CHECK 를 넓히면 옛 판 함수가 돌아도 안전한가.** 옛 판은 `partial` 을 안 쓰므로 무해. 반대로 **새 판 함수가 먼저 배포되고 마이그레이션이 늦으면** 수신자 표가 없어 첫 사람부터 `record_error` → 그날 실행이 통째로 `failed`(설계 7) → 배포 순서 「데이터베이스 먼저」(단계).
9. **수신자 단위 「죽은 선점」 판별 시간은 얼마인가.** 실행 자물쇠(종전 10분)가 풀려 재호출이 들어왔는데 수신자 행의 `in_flight` 가 아직 안 풀리면, 그 사람들은 「진행 중」으로 건너뛰어져 **재호출이 헛돈다.** 그래서 수신자 단위 판별 시간은 **실행 자물쇠와 같은 10분**으로 둔다(`CLAIM_STALE_MINUTES = 10`) — 완전히 없애는 것은 아니고(기준 시각이 달라 첫 재호출에 남는 사람이 있을 수 있다, 설계 5) 남는 사람을 줄이는 조치다. 남은 사람은 그 실행이 `partial` 로 남아 다음 재호출이 마저 보낸다. 방침 통지는 20분을 쓰지만 그쪽은 실행 자물쇠가 없어 관계가 다르다 — 이 함수군에서는 「수신자 판별 시간 ≤ 실행 자물쇠 시간」이 지켜져야 한다. 한 사람 발송은 Brevo 왕복 수 초라 10분이면 넉넉하다.

### 현재 구현과 충돌하는 지점
- 위 「충돌 가능성」 네 줄. 그 외 충돌 없음 — 다이제스트 3종·실행 표 3종·마감 임박 표·홍보/방침 선례·정리 예약·방침 문서 7개 영역 확인.

### 의도가 갈리는 지점 → 사용자 결정으로 해소
| 갈림 | 결정 |
|---|---|
| 표를 종류마다 따로 / 하나로 | **공용 표 하나** |
| 화면까지 이번에 / 기록만 | **기록만, 화면은 후속** |
| 보관 기간 | **90일 뒤 자동 정리** |

---

## 결정 목록

「상태」 열은 두 값이다 — **확정** = 사용자가 고른 것 / **확정(기획)** = 기획이 정했고 사용자에게 따로 묻지 않는 것 — 기존 선례를 따르거나, 기획 판단으로 정한 설계 결정이거나, 결과가 아니라 **절차**만 정한 항목.

| # | 항목 | 내용 | 상태 | 근거·비고 |
|---|---|---|---|---|
| 1 | 기록 표 | **공용 표 하나** `digest_email_sent` — 종류·날짜·수신자 열쇠로 유일 | 확정 | 세 함수가 같은 선점·기록 코드를 쓴다. 선례(파이프라인마다 표 하나)와 다른 선택 |
| 2 | 범위 | 표 1개 + 정리 함수·예약 + 함수 3개 수정. **화면 없음** | 확정 | 재시도는 「같은 날 함수를 다시 부르면 실패분만」까지. 발송 현황 화면·재시도 단추는 후속 사양서 |
| 3 | 보관 | 수신자 행은 **90일 뒤 자동 정리**(pg_cron). 실행 표는 종전대로 영구 | 확정 | 선례 243(30일)·166(36개월)과 같은 방식 |
| 4 | 선점 순서 | **D-9 방식 그대로**: 선점(`failed`+`in_flight@시각`) → 발송 → 성공 뒤에만 `sent` | 확정(기획) | 전수조사가 세운 원칙(D-9 방침 통지·D-19 검수 결과 메일). 실패는 `failed`+`send_failed` 로 남겨 재진입 대상 |
| 5 | 대상 | 인플루언서 일일 · 관리자 일일 · 브랜드 일일 **3종**. 홍보 메일의 관리자 요약은 종류 값(`promo_admin_summary`)만 CHECK 에 예약하고 **코드는 안 건드린다** | 확정(기획) | 홍보 함수는 이번 주에 세 번 배포돼 손대지 않는다. 값만 예약해 두면 후속이 표를 또 만들지 않는다 |
| 6 | 실행 표 상태 | 세 실행 표 CHECK 에 **`partial`** 추가. 재진입 조건을 `failed 또는 partial`(+10분 대기) 로 넓힌다 | 확정(기획) | 부분 실패를 「발송됨」으로 닫는 것이 결함의 절반이다 |
| 7 | 마감 임박 표 | 인플루언서 다이제스트의 `deadline_reminder_email_sent` INSERT 를 **사람별로 그 사람 발송 직후**로 옮긴다(벌크 INSERT 폐지) | 확정(기획) | 도중에 죽으면 받은 사람의 마감 임박 행이 빠지는 것을 막는다. 마감 섹션이 있는 사람은 하루 수십 명 수준이라 INSERT 횟수 부담이 작다 |
| 8 | 방침 문서 | `/약관확인` 으로 §5 처리위탁 표에 「발송 기록 90일」 한 줄이 필요한지 판정. 필요하면 한·일 동시 개정 — **여기서 확정하는 것은 절차**이고 결과는 개발 단계에서 나온다 | 확정(기획) | 새 수집 항목이 아니라 처리 기록이지만, 보관 기간을 정했으므로 문서와 맞춘다 |

---

## 설계

### 1. 표 — `digest_email_sent` (마이그레이션 1개, 번호는 개발 세션이 확정)

| 칸 | 형 | 뜻 |
|---|---|---|
| `id` | uuid 기본키 | |
| `digest_kind` | text, CHECK IN (`influencer_daily`, `admin_daily`, `brand_daily`, `promo_admin_summary`) | 네 번째 값은 예약(결정 5) |
| `digest_date` | date | 실행 표의 `digest_date` 와 같은 값 |
| `recipient_key` | text | 인플루언서 = 회원 id 문자열 / 관리자·브랜드 = **소문자로 정규화한 이메일** |
| `influencer_id` | uuid NULL, `REFERENCES influencers(id) ON DELETE CASCADE` | 인플루언서 종류만 채운다. **회원 이메일은 안 남긴다**(관리자 이메일은 `recipient_key` 에 남는다) |
| `status` | text CHECK (`sent`, `skipped`, `failed`) | 선례와 같은 세 값 |
| `skip_reason` | text | `no_email` / `send_failed` / `in_flight@<ISO 시각>` — **선점 조건과 바꾸는 값이 이 한 칸** |
| `error_message` | text | 실패 시 Brevo 응답 앞 300자 |
| `created_at` · `updated_at` | timestamptz | `updated_at` 은 이 표 전용 갱신 트리거 함수 `touch_digest_email_sent_updated_at()` (공용 함수가 없고 표마다 전용 함수를 두는 것이 이 저장소 관례 — `touch_companies_updated_at` 등) |
| UNIQUE | (`digest_kind`, `digest_date`, `recipient_key`) | 종류·날짜당 수신자 1행 = 멱등 |
| 색인 | (`digest_kind`, `digest_date`, `status`) · (`created_at`) | 실행 중 집계 · 정리 예약 |

- 행 단위 보안 정책: SELECT `is_admin()`. INSERT/UPDATE/DELETE 정책 **없음**(서비스 키만 — 방침 통지·홍보 메일 표와 같다).
- ⚠️ `recipient_key` 를 이메일로 쓰는 종류는 대소문자·앞뒤 공백을 **한 함수**(`normalizeRecipientKey`)로 정규화한다. 안 하면 같은 관리자가 두 행이 되어 두 통 받는다.

### 2. 정리 — `purge_old_digest_email_sent()` + pg_cron
- `created_at < now() - interval '90 days'` 행 삭제. 삭제 건수 반환.
- 예약 이름 `digest-email-sent-retention-daily`, 시각은 **한국·일본 03:45**(04:00~05:30 은 이미 예약 아홉 개가 몰려 있다 — 실패 원인을 가리기 어렵다. 03:30~03:59 는 비어 있음).
- 🔴 **운영에만 등록하는 것이 아니다** — 이 함수는 메일을 안 보내므로 개발에도 등록한다(351 과 다르고 364·365 와 같다).
- 실행 권한: `postgres`·`service_role` 만. 새 함수라 **부여 먼저, 회수 나중**(375 의 순서 — `REVOKE ... FROM PUBLIC` + `FROM anon, authenticated` 두 줄 다).

### 3. 선점·기록 — 세 함수가 같은 헬퍼를 쓴다

세 함수는 별개 배포 단위라 코드를 공유할 수 없다. 그래서 아래 **「복사 목록」 여덟 개를 같은 이름·같은 본문으로** 각 함수에 둔다. 본문이 갈리면 그 자체가 사고이므로 「검증 5」에서 세 벌 diff 가 0 인지 본다. 다른 절이 「복사 목록」이라 하면 이 여덟 개를 뜻한다.

**복사 목록** — ① `CLAIM_STALE_MINUTES = 10`(상수) ② `inFlightMarker()` ③ `staleInFlightCutoff()` ④ `normalizeRecipientKey()` ⑤ `claimRecipient()` ⑥ `markSent()` ⑦ `markFailed()` ⑧ `markSkipped()`. ②·③은 방침 통지 함수(`notify-policy-change`)의 것을 그대로 옮긴다(①의 값만 이 문서대로). ⑤는 방침 통지의 선점 함수를 본떠 **새로 쓴다** — 열쇠가 (종류·날짜·수신자 열쇠) 3열이고 반환값이 넷이라 그대로 옮길 수 없다. ④·⑥·⑦·⑧도 새로 쓴다.

```
normalizeRecipientKey(raw)  → 어떤 값이든 앞뒤 공백 제거 + 소문자. 회원 id(소문자 uuid 문자열)는 결과가 원래 값과 같다
claimRecipient(kind, date, key, influencerId?)
  → 'claimed' | 'already_sent' | 'in_progress' | 'record_error'
  INSERT {kind, date, key, influencer_id(인플루언서 종류만), status:'failed', skip_reason:'in_flight@now'} → 'claimed'
  23505 면 UPDATE skip_reason='in_flight@now'
     WHERE (kind,date,key) 일치
       AND (skip_reason = 'send_failed' OR skip_reason < 'in_flight@<now-CLAIM_STALE_MINUTES 분>')
     → 1행 갱신: 'claimed'
     → 0행 갱신: 그 행을 읽어 status 가 'sent' 또는 'skipped' 면 'already_sent'(더 볼 것 없음), 아니면 'in_progress'(다른 실행이 CLAIM_STALE_MINUTES 안에 잡음)
  그 밖의 데이터베이스 오류(표 없음·권한 등)                   → 'record_error'
markSent(kind, date, key)         → status='sent', skip_reason=null
markFailed(kind, date, key, msg)  → status='failed', skip_reason='send_failed', error_message=msg 앞 300자
markSkipped(kind, date, key, reason, influencerId?) → INSERT {status:'skipped', skip_reason:reason, influencer_id} ON CONFLICT DO NOTHING
```
- 🔴 `skip_reason < 'in_flight@…'` 문자열 비교가 성립하려면 시각을 **ISO 8601(UTC, 자릿수 고정)** 로 적어야 한다 — D-9 의 `inFlightMarker()` 를 그대로 쓴다.
- `status='sent'` 행은 `skip_reason` 이 null 이라 갱신 조건에 안 걸린다 → 절대 다시 안 보낸다.
- `skipped`(`no_email`)는 `markSkipped` 로만 생기고 선점을 거치지 않는다. 재시도해도 다시 안 본다. 이메일이 나중에 생겨도 그 날짜 다이제스트는 안 간다(정상 — 그날 몫은 지난 것이다).

### 4. 세 함수의 반복문 (공통 골격)

```
대상 목록을 종전대로 만든다
대상이 0건이면 실행 표 'skipped_no_data' 로 닫고 종료(종전과 같음)
sent=0, failed=0, inProgress=0, alreadySent=0, recordLostAfterSend=0
for 수신자 in 대상:
  key = normalizeRecipientKey(수신자)
  (인플루언서만) 이메일 없음 → markSkipped(no_email, influencerId); continue
  r = claimRecipient(...)
  if r == 'record_error': 반복문을 멈추고 실행 표 'failed' + error_message 「기록 실패: …」 (설계 7)
  if r == 'already_sent': alreadySent++; continue
  if r == 'in_progress':  inProgress++; continue
  try:
    본문 렌더 → sendBrevoEmail            // try 는 여기까지 — 이 뒤는 메일이 이미 나간 상태
  catch e:
    markFailed(e); failed++; continue
  sent++
  markSent — 실패하면 한 번 더 시도, 그래도 실패면 로그 + recordLostAfterSend++ (되돌릴 것이 없다, 설계 7)
  (인플루언서만) 그 사람의 마감 임박 행 INSERT — 자체 try: 23505 는 무시, 그 밖의 오류는 로그만(설계 6)
실행 표 UPDATE (record_error 로 멈춘 경우는 위에서 이미 'failed'):
  failed == 0 and inProgress == 0 and recordLostAfterSend == 0 → 'sent'  (전원 already_sent 로 셋 다 0 인 경우 포함)
  sent == 0 and alreadySent == 0 and failed > 0 and inProgress == 0
                                                  → 'failed'(전원 실패 — 이번 실행에서 성공도 기수신도 하나 없을 때만. 관리자·브랜드는 종전과 같고, 인플루언서는 종전엔 sent 였던 것이 이번에 failed 로 바뀐다)
  그 외(실패·진행 중·발송 뒤 기록 실패가 하나라도 남음) → 'partial' + error_message 에 실패 수·진행 중 수·기록 실패 수·첫 오류
```
- `already_sent` 는 재시도 실행에서 정상적으로 많이 나온다. 「보낸 수」에는 안 들어가지만 **성공으로 친다** — 그래서 기수신과 실패가 섞인 실행은 `failed` 가 아니라 `partial` 이 된다(`failed` 갈래의 `alreadySent == 0` 이 그 역할이다). 전원이 이미 받은 실행은 첫 갈래에서 `sent` 로 닫힌다.
- `in_progress` 는 「다른 실행이 CLAIM_STALE_MINUTES(10분) 안에 잡고 있는 사람」(살아 있는 실행이든 방금 죽은 실행이든)이라 이번 실행은 손대지 않되, 실행을 `sent` 로 닫으면 안 된다(그 사람이 실패로 끝날 수 있다) → `partial` 로 남겨 재진입 대상에 둔다.
- `recipients_count`/`total_emails` 는 **이번 실행에서 보낸 수**(종전 정의 유지). 재시도 실행이면 그 실행에서 새로 보낸 수만 센다 — 날짜 전체 합계는 수신자 표의 `sent` 행에서 센다(화면은 후속).
- 관리자·브랜드 다이제스트의 「전원 실패 → `failed` + 500 응답」 갈래는 그대로 둔다.

### 5. 재진입 — 같은 날 함수를 다시 부르면
- 실행 표 자물쇠: 기존 행이 `sent`/`skipped_no_data` 면 종전대로 스킵. **`failed` 또는 `partial`** 이고 마지막 `run_at` 에서 10분이 지났으면 넘겨받는다(종전 `failed` 조건에 `partial` 을 더한 것뿐).
- 넘겨받은 실행은 대상 목록을 **새로** 만들고(의심 2) 설계 4 의 반복문을 돈다. `sent` 행은 `claimRecipient` 가 `already_sent` 를 돌려주므로 **실패분만** 나간다. 죽은 실행이 남긴 `in_flight` 행은 **선점 시각에서 10분이 지난 것만** 넘겨받고, 아직 안 지난 사람은 `in_progress` 로 남아 이번 실행이 `partial` 이 된다(다음 재호출이 마저 보낸다). 실행 자물쇠는 `run_at` 기준, 수신자 행은 선점 시각 기준이라 같은 10분이어도 실행 자물쇠가 먼저 풀린다 — 그래서 첫 재호출에 남는 사람이 있을 수 있다(의심 9).
- 운영자가 손으로 재호출하는 방법은 종전과 같다(서비스 키로 함수 호출). 화면 단추는 후속.
- ⚠️ **다음 날 예약은 재시도가 아니다** — 날짜가 다르므로 어제 실패분은 안 나간다. 세 함수는 날짜 인자를 받지 않고 호출 시각으로 `digestDate` 를 만든다(코드 확인) → **이번 범위의 재시도는 「당일 재호출」뿐**이다. 지난 날짜 재발송은 화면과 함께 후속(결정 2).

### 6. 마감 임박 표 INSERT 자리 이동 (결정 7)
- 지금: 반복문 뒤 `sentInserts` 벌크 INSERT. 바꿈: 그 사람 `markSent` 직후에 그 사람 몫만 INSERT. `sentDuringRun` 중복 차단은 그대로.
- 23505(동시 실행 충돌)는 종전대로 무시. 그 밖의 오류는 로그만 남기고 **발송 성공은 되돌리지 않는다**(메일은 이미 나갔다).

### 7. 빈 상태·실패
| 상황 | 동작 |
|---|---|
| 대상 0건 | 종전대로 `skipped_no_data`. 수신자 행 0 |
| **발송 전** 수신자 표 INSERT/UPDATE 실패(표가 없음·권한) — `claimRecipient` 가 `record_error` | **그 수신자는 보내지 않고 반복문을 멈춘다**(기록 못 하면 발송도 안 한다 — 기록 없는 발송이 이 결함의 원인. 표가 없으면 다음 사람도 다 실패하므로 계속 돌 이유가 없다). 실행은 `failed`, `error_message` 에 「기록 실패: 원문」 |
| **발송 뒤** `markSent` 실패(발송 직후 데이터베이스 장애) | 메일은 이미 나가 되돌릴 것이 없다. 한 번 더 시도하고 그래도 실패면 로그 + 실행 `partial`(`recordLostAfterSend`). 그 행은 `in_flight` 로 남아 **10분 뒤 재호출이 그 사람에게 한 통 더 보낼 수 있다** — 발송 직후 그 순간에만 나는 장애라 드물고, 「기록 없이 보내지 않는다」 원칙보다 「받은 사람을 못 받은 것으로 되돌리지 않는다」를 앞세운 결과다. 재호출 전에 `error_message` 를 보면 안다 |
| Brevo 실패 | `failed`/`send_failed`, 다음 재진입 대상 |

---

## 바뀌는 자리 (개발 세션 확인용)

| 파일 | 무엇 |
|---|---|
| `supabase/migrations/` 신규 **1개**(번호는 개발 세션이 확정) | 표 `digest_email_sent` + 정책 + 색인 · 실행 표 3종 CHECK 에 `partial` · `purge_old_digest_email_sent()` + 실행 권한 + pg_cron(개발·운영 양쪽) |
| `supabase/functions/notify-influencer-daily-digest/index.ts` | 「복사 목록」 여덟 개(설계 3) · 반복문 · 마감 임박 INSERT 이동 · 재진입 조건 · 실행 상태 3갈래 |
| `supabase/functions/notify-admin-daily-digest/index.ts` | 「복사 목록」 여덟 개(설계 3) · 반복문 · 재진입 조건 · 실행 상태 3갈래 |
| `supabase/functions/notify-brand-daily-digest/index.ts` | 같음 |
| `CLAUDE.md` 메일 파이프라인 항목 3종 | 수신자 표·재진입·`partial` — **같은 커밋** |
| `docs/PRIVACY_{kr,ja}.md` | `/약관확인` 결과에 따라(결정 8) |
| `docs/specs/2026-09-02-audit-remediation-plan.md` D-8 행 | 완료 표기(개발) |

---

## 단계
**병합 요청 1개, 배포 순서는 둘.** ①마이그레이션을 개발·운영에 적용 → ②함수 3개 배포. 🔴 **순서를 바꾸면** 수신자 표가 없어 첫 사람부터 `record_error` 가 나고 그날 다이제스트가 통째로 `failed` 가 된다(설계 7 둘째 줄). 함수 배포는 개발·운영 각각 사람이 한다(`supabase functions deploy`).

---

## 검증 시나리오
개발서버는 **실제 메일 발송 시험 금지**라 두 단계로 나눈다.

**개발서버(발송 없이)**
1. 마이그레이션 적용 후 표·정책·CHECK·예약(`cron.job` 에 `digest-email-sent-retention-daily`) 확인.
2. `claimRecipient` 동작을 SQL 로 재현: 같은 (종류·날짜·열쇠)에 ①첫 INSERT 성공 ②`sent` 행에 UPDATE → 0행 ③`send_failed` 행에 UPDATE → 1행 ④`in_flight@<9분 전>` → 0행, `in_flight@<11분 전>` → 1행(`CLAIM_STALE_MINUTES = 10` 기준).
3. ⚠️ **이 단계는 개발서버 「수동 호출·발송 시험 건너뜀」 규칙(`.claude/rules/supabase.md`)의 문언 밖이다 — 착수 전 사용자 확인을 받고 하며, 승인되면 그 규칙에 「Brevo 키를 고의로 무효화한 호출은 예외」를 명문화한다.** Brevo 키를 잘못된 값으로 두고 함수를 호출 → 발송을 시도한 수신자 행은 전부 `failed`/`send_failed`, 이메일 없는 회원은 `skipped`/`no_email`, 실행 표 `failed`(전원 실패). 10분 안에 재호출 → 대기로 스킵. 🔴 **개발서버 회원 이메일로 실제 발송이 나가지 않도록 키를 반드시 잘못된 값으로**.
4. 정리 함수: `created_at` 을 91일 전·89일 전으로 둔 시험 행 2개 → 함수 호출 → 1 반환, 91일 행만 삭제되고 89일 행은 남는다.
5. 세 함수의 「복사 목록」 여덟 개(설계 3) 본문 diff = 0.

**운영(다음 09:00 예약 뒤)**
6. 실행 표 3종의 그날 행이 — 전원 성공이고 발송 뒤 기록 실패도 없었던 종류는 `sent`, 실패·진행 중·발송 뒤 기록 실패가 섞였던 종류는 `partial`(8번으로), 대상 0건인 종류는 `skipped_no_data`(수신자 행 0). **재시도가 없었던 날에 한해** 수신자 표의 그날 `sent` 행 수 + 발송 뒤 기록 실패 수(`error_message`) = 그 실행이 보낸 수(`total_emails`/`recipients_count`). 재시도가 있었던 날은 실행 표 1행이 마지막 실행 몫만 담으므로 이 등식을 쓰지 않는다.
7. 인플루언서: 마감 임박 표의 그날 행 수가 종전 방식과 같은 규칙으로 쌓였는지(마감 섹션 인원 × 항목).
8. 이번 실행에서 성공도 기수신도 없이 실패만 있으면 `failed`, 그 경우를 뺀 나머지 중 실패·진행 중·발송 뒤 기록 실패가 하나라도 남으면 `partial` 인지(설계 4 의 세 갈래 그대로), 재호출로 실패한 사람만 다시 나가는지 — 발생했을 때만.

---

## 착수 전 알아야 할 것 (규칙 D — 개발 세션이 대조)
- 방침 통지 함수에서 그대로 옮겨 올 둘(설계 3 「복사 목록」 ②·③)과 본뜰 하나(⑤의 원형)의 **현재 원문**.
- 실행 표 CHECK 를 바꿀 때 **제약 이름**(130·132·203 이 이름을 안 줬으면 자동 이름이라 `\d` 로 찾아야 한다).
- `updated_at` 트리거 함수 이름 관례(`touch_<표>_updated_at`)를 최근 표에서 확인해 같은 모양으로.
- 운영 실측(부분 실패가 실제로 있었나): 관리자·브랜드 실행 표는 `error_message` 에 「sent. failed:」가 든 행, 인플루언서 실행 표는 `total_influencers > total_emails` 인 행(실패 명단을 안 남기므로 두 수의 차이로만 안다 — 그 차이에는 이메일이 없어 건너뛴 회원이 섞여 있으니 **상한값**으로만 본다) — 최근 30일. 있었다면 이 변경의 효과가 즉시 나타나는 자리다.
- `cron.job` 에서 03:30~04:00 사이 예약이 없는지(03:45 를 쓰기 위해). 별도로 04:00~05:30 이 지금도 아홉 개인지(문서의 「붐빈다」 근거 확인).

---

## 사용자 확인 필요
**없음** — 갈림 세 곳(표 구조·화면 범위·보관 기간)은 2026-09-07 에 사용자가 골랐다. 결정 목록 1·2·3 이 그 결과다.

---

## 구현 결과 (개발 세션이 채울 것)
