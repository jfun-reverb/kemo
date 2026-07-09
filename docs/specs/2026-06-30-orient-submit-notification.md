# 오리엔시트 제출 알림 — 개별 즉시 메일 + 브랜드 일일 보고

**작성일:** 2026-06-30
**작성 주체:** 기획 세션
**관련 베타 단계:** 2차 — 브랜드 포털 (오리엔시트 후속, `docs/specs/2026-06-18-brand-self-orient-sheet.md`)
**상태:** 기획 초안 — 핵심 방향 사용자 확정(2026-06-30) / 수신자·발송 시각 §9 사용자 확인 필요

---

## 0. 한 줄 요약

브랜드가 오리엔시트를 **제출(submitted)**하면 ① 관리자에게 **개별 즉시 메일**을 보내고(영업 후속 빠르게), ② **신규 제출과 수정 재제출을 구분**해 다음 날 아침 **별도 「브랜드 일일 보고」 통합 메일**에도 모아 보고한다. 기존 인플루언서 활동 일일 메일과는 **분리**한다.

---

## 1. 현재 상태 (planning.md 규칙 A — 검증 완료)

### 관련 코드·DB·UI 진입점
- **오리엔시트 제출 시각**: `orient_sheets.submitted_at timestamptz NULL`(마이그레이션 186). 제출 함수 주석 명시 = **첫 제출만 기록**(재제출 시 갱신 안 함), `version+1`. 상태 `draft/submitted → submitted`(재제출 허용).
- **제출 함수**: `submit_orient_sheet(token, data, version)` — 최신 정의는 마이그레이션 200. 익명(anon) 호출. 작성 폼 `dev/sales/orient.html:1711`(+ 빌드 복사본 `sales/orient.html`)에서 비로그인 브랜드가 원격 호출 함수로 제출.
- **`submitted_at` 코드 사용처(검증)**: 오리엔시트 한정 사용은 **단 1곳** — `dev/js/admin-orient.js:203` 관리자 발급·조회 목록의 "제출일" 컬럼. (그 외 검색 결과는 전부 `deliverables` 테이블의 동명 컬럼이라 무관.)
- **개별 즉시 메일 선례**: `supabase/functions/notify-brand-application` — `brand_applications` INSERT 직후 관리자에게 즉시 알림(`form_type`별 템플릿 분기). 수신자 = `get_subscribed_admin_emails('brand_notify')` + env `NOTIFY_ADMIN_EMAILS`. **오리엔 제출 개별 메일이 따를 패턴.**
- **일일 통합 메일 선례**: `supabase/functions/notify-admin-daily-digest` — pg_cron 매일 한국시간 09:00, 어제 한국시간 윈도우 집계, 4섹션 1통, `admin_daily_digest_runs.digest_date UNIQUE`로 발송 중복 차단(mutex), 0건 섹션 생략·전부 0건이면 미발송. 수신자 = `get_subscribed_admin_emails('daily_digest')` + env. **브랜드 일일 보고가 복제할 인프라 패턴.**
- **수신 구독 체계**: `admin_email_subscriptions(admin_id, mail_kind)` + `lookup_values(kind='admin_email_kind')` 카탈로그(활성: `brand_notify`/`daily_digest`/`campaign_promo`). 신규 메일 종류는 `lookup_values` 한 줄 추가로 토글 가능. 헬퍼 `get_subscribed_admin_emails(p_mail_kind)`.
- **메일 공통 규칙**: 템플릿 `docs/email-templates/`가 source of truth + Edge Function `_templates/` 미러(`scripts/sync-email-templates.sh` 동기화). 관리자 일괄 발송은 1인 1통 분리(받는사람 노출 차단). 부분 실패는 `status='sent'`+실패 명단 누적.

### 이 제안과 충돌 가능성 있는 기존 동작
- ⚠️ **`submitted_at` 의미 보존**: 재제출을 잡으려고 `submitted_at`을 매 제출마다 덮어쓰면 관리자 목록(`admin-orient.js:203`)의 "제출일"이 최초→마지막으로 의미가 바뀐다. → **별도 컬럼 `last_submitted_at` 추가로 해결**(submitted_at은 최초 불변 유지). 회귀 없음.
- **기존 인플 일일 다이제스트와 정책 비대칭 주의**: 인플 메일 "결과물 제출" 섹션은 **재제출을 일부러 배제**(첫 제출만). 오리엔은 사용자 요구로 **재제출 포함**하되 **신규/재제출을 구분 표시**해 비대칭이 혼란이 아니라 의도된 구분이 되게 한다.
- 그 외 정산·캠페인 발행 등과 충돌 없음 — 신규 알림 경로라 코드 충돌 없음(확인 완료).

### 미해결 백로그·관련 작업
- 오리엔시트 PR 4(자동 채움 발행)·PR 6(발급 메일) 등 후속과 **독립** — 본 알림은 제출 이벤트만 다룬다.
- 향후 브랜드 일일 보고에 견적·입금 등 브랜드 활동을 더 담을 수 있음(그릇 역할, §3 결정 근거).

---

## 2. 의심·경우의 수 (planning.md 규칙 B — 반대론자 모드)

### 깨질 수 있는 경우의 수
1. **(신규 vs 재제출 판정 경계)** 어제 처음 냈는데 어제 또 고친 경우(`submitted_at`도 어제, `last_submitted_at`도 어제) → **신규로 분류**(중복 표시 방지, 신규 우선). 판정식 §5 명시.
2. **(개별 메일 폭주)** 재제출도 즉시 메일을 보내면 한 브랜드가 여러 통. 단 오리엔 제출은 드문 이벤트(사용자 확정 전제)라 실무상 폭주 위험 낮음. 그래도 메일 제목에 「신규/수정」 구분으로 관리자가 즉시 분별.
3. **(같은 날 발행 consumed)** 어제 제출 후 같은 날 관리자가 캠페인 발행하면 status가 `submitted→consumed`로 바뀜. 일일 보고 조회를 `status='submitted'`로 걸면 누락 → **`last_submitted_at`/`submitted_at` 시각 기준(상태 무관) 조회.**
4. **(개별 메일 트리거 위치)** 익명 제출이므로 ⓐ 작성 폼 클라이언트가 제출 성공 후 메일 함수 호출 / ⓑ 제출 원격 호출 함수 안에서 호출 / ⓒ DB 트리거 — 선례(`notify-brand-application`)와 동일 방식 채택. 익명 클라이언트가 메일 함수를 직접 부르는 건 보안 주의 → 구현 방식은 supabase-expert 착수 시 확정(§6).
5. **(0건 일일 보고)** 브랜드 일일 보고가 오리엔 0건이면 발송 안 함(기존 패턴). 향후 다른 브랜드 섹션이 생기면 발송 판정에 합산.
6. **(권한·민감정보)** 메일 본문에 브랜드명·폼타입·제출시각·관리자 링크만. 오리엔 `data jsonb` 전체 내용은 메일에 싣지 않음(관리자 화면에서 확인). 수신자는 관리자 구독자 한정.
7. **(개발/운영 발송 분리)** 신규 메일 파이프라인이므로 메모리 `feedback_dev_no_mail_test` 적용 — 개발서버는 환경만 구축, 실제 발송 테스트는 운영에서. cron 등록은 수동 호출 안정성 검증 후 별도 단계.
8. **(메일 발송 실패가 제출을 막지 않게)** 개별 즉시 메일 발송 실패가 브랜드의 제출 자체를 실패로 만들면 안 됨 → 메일은 best-effort(제출 성공과 분리).

### 현재 구현과 어긋나는 지점
- `submitted_at` 의미 보존 1건(§1) — `last_submitted_at` 신규 컬럼으로 회피. 그 외 충돌 없음(확인 완료).

### 의도 모호점
- "제출했을 때" = **신규 + 재제출 모두**, 단 **구분 표시**(사용자 확정 2026-06-30).
- "별도 일일 보고" = **인플루언서 활동 메일과 분리된 신규 메일**(사용자 확정).
- 개별 즉시 메일 + 일일 통합 보고 **둘 다**(사용자 확정).

---

## 3. 확정 설계 결정 (사용자 확인 완료 2026-06-30)

| # | 항목 | 결정 |
|---|---|---|
| ① | 제출 범위 | **신규 제출 + 재제출(수정) 모두** 알림 대상 |
| ② | 구분 표시 | 메일에서 **「신규 제출」 / 「수정 재제출」 구분** |
| ③ | 시각 추적 | `submitted_at`(최초·불변) **보존** + `last_submitted_at`(마지막) **신규 컬럼** |
| ④ | 개별 즉시 메일 | 제출 시 관리자에게 **즉시 1통**(광고주 신청 알림 `notify-brand-application` 패턴) |
| ⑤ | 일일 통합 보고 | **별도 「브랜드 일일 보고」 메일 신설**(인플 활동 메일과 분리). 향후 브랜드 활동 보고 그릇 |
| ⑥ | 일일 보고 집계 | 어제 한국시간 윈도우, **시각 기준(상태 무관)**, 신규/재제출 구분 섹션 |
| ⑦ | 개발/운영 | 개발서버 환경만 구축, 실제 발송 테스트·cron은 운영에서(메모리 `feedback_dev_no_mail_test`) |
| ⑧ | 일일 보고 수신자 | **새 수신 종류 `brand_digest` 신설**(`lookup_values(kind='admin_email_kind')` 한 줄). 영업/운영 담당 분리 토글 |
| ⑨ | 일일 보고 발송 시각 | **한국시간 09:00**(인플 일일 메일과 동일, 별도 예약 작업) |
| ⑩ | 개별 즉시 메일 수신자 | **`brand_notify` 재사용**(광고주 신청 알림과 동일 담당) |

---

## 4. 데이터 모델 (최소 변경)

### `orient_sheets` 컬럼 1개 추가
| 컬럼 | 타입 | 설명 |
|---|---|---|
| `last_submitted_at` | timestamptz NULL | **마지막 제출 시각**. 재제출마다 갱신. `submitted_at`(최초)과 분리. 일일 보고 재제출 판정용 |

- 인덱스: 일일 보고가 `last_submitted_at`/`submitted_at` 범위 조회 → 둘에 대한 인덱스 검토(soonest 빈도 낮으면 생략 가능, 개발 판단).

### `submit_orient_sheet` 함수 수정
- `submitted_at = COALESCE(submitted_at, now())` (최초만 — 기존 유지)
- `last_submitted_at = now()` (매 제출 갱신 — 신규)
- 반환값에 "이번 호출이 최초인지 재제출인지" 플래그 추가(개별 즉시 메일이 「신규/수정」 분기에 사용).

### 발송 로그 테이블 (브랜드 일일 보고)
- `notify-admin-daily-digest`의 `admin_daily_digest_runs` 패턴 복제 — 신규 테이블 1개(예: `brand_daily_digest_runs`): `digest_date UNIQUE`(mutex) + `status CHECK(sent|skipped_no_data|failed)` + `sections_summary jsonb`(`{new_submitted, resubmitted}`) + `recipients_count` + `error_message` + `run_at`. RLS SELECT `is_admin()`, INSERT는 service_role만.
- (개별 즉시 메일은 별도 로그 테이블 불필요 — best-effort. 필요 시 `notify-brand-application` 수준의 로깅만.)

### 수신 구독 종류 (§9 확인)
- 개별 즉시 메일 수신자: **`brand_notify` 재사용 권고**(광고주 신청 알림과 같은 담당).
- 일일 통합 보고 수신자: **새 종류 `brand_digest` 신설 권고**(`lookup_values(kind='admin_email_kind')` 한 줄) — 별도 토글로 영업/운영 담당 분리 가능. → §9 사용자 확인.

---

## 5. 신규/재제출 판정 로직 (일일 보고)

어제 한국시간 윈도우 `[start, end)` 기준:

```
신규 제출:   submitted_at      >= start AND submitted_at      < end
재제출(수정): last_submitted_at >= start AND last_submitted_at < end
             AND submitted_at < start          ← 최초는 과거, 마지막만 어제
```

- 같은 날 신규+수정(둘 다 어제) → **신규로만 분류**(중복 방지, 신규 우선).
- status 필터 없음(consumed/expired여도 시각 기준으로 잡음).

---

## 6. 개별 즉시 메일 — 트리거 방식 (개발/supabase-expert 결정 인계)

| | 방식 | 비고 |
|---|---|---|
| A | 작성 폼 클라이언트가 제출 성공 후 메일 함수 호출 | 익명 클라이언트가 메일 함수 직접 호출 → 인증/남용 주의 |
| B | 제출 원격 호출 함수 안에서 메일 호출(pg_net 등) | 서버측 트리거, 익명 노출 없음 |
| C | DB 트리거(status→submitted)에서 메일 함수 호출 | 재제출도 자동 포착 |

→ 선례 `notify-brand-application`의 실제 방식을 따르되, **익명 노출 없는 서버측(B/C)** 권고. 최종은 supabase-expert 착수 시 확정. 메일은 best-effort(제출 성공과 분리).

---

## 7. 메일 본문 설계

### 7-1. 개별 즉시 메일 (`notify-orient-submitted`, 신규)
- 제목: 「[신규 제출] {브랜드명} 오리엔시트」 또는 「[수정 재제출] {브랜드명} 오리엔시트」 (③ 분기).
- 본문: 브랜드명 · 폼타입(리뷰어/시딩) · 제출 시각(한국시간) · 연결 신청 번호(있으면) · 관리자 발급·조회 페인 링크.
- `data jsonb` 전체 내용은 싣지 않음(관리자 화면 확인).

### 7-2. 브랜드 일일 보고 메일 (`notify-brand-daily-digest`, 신규)
- 매일 한국시간 09:00, 어제 윈도우. 2섹션(신규 제출 / 수정 재제출). 0건 섹션 생략, 전부 0건이면 미발송.
- 각 행: 브랜드명 · 폼타입 · 제출 시각 · 관리자 링크.
- 인플 메일과 동일한 발송 인프라 패턴(mutex·부분 실패 처리·푸터 등).

---

## 8. 약관·정책 영향 (policy.md 체크)

- **신규 개인정보 수집 없음** — 브랜드명·제출 시각 등 기존 `orient_sheets` 데이터를 관리자에게 보고만. PRIVACY 영향 없음(확인).
- 인플루언서 개인정보 무관(브랜드 활동).
- 관리자 대상 내부 메일 — 마케팅·동의 게이트 무관.
- → `/약관확인` 불필요 수준(신규 외부 수집·제3자 제공 없음). 확인용 1회만 가벼이.

---

## 9. 사용자 확인 — 확정 완료 (2026-06-30)

권고안 전체 채택(사용자 확정). §3 표 ⑧⑨⑩ 참조.
1. 일일 통합 보고 수신자 → **새 수신 종류 `brand_digest` 신설**.
2. 일일 통합 보고 발송 시각 → **한국시간 09:00**.
3. 개별 즉시 메일 수신자 → **`brand_notify` 재사용**.

---

## 10. PR 분할 (개발서버 먼저, 시퀀셜)

> 마이그레이션 번호는 개발 세션이 생성 시점 확정 후 「구현 결과」에 기록(planning.md 규칙 A).

- **PR 1 — 데이터 + 개별 즉시 메일**: `orient_sheets.last_submitted_at` 컬럼(마이그레이션 ①) + `submit_orient_sheet` 함수 수정(최초/재제출 플래그 반환) + 신규 Edge Function `notify-orient-submitted` + 트리거 방식(§6). 즉시 알림 핵심.
- **PR 2 — 브랜드 일일 보고**: 신규 Edge Function `notify-brand-daily-digest` + 발송 로그 테이블(마이그레이션 ②) + 신규/재제출 2섹션 + (수신 구독 종류 §9 결정 시 `lookup_values` 한 줄). cron 등록은 수동 호출 검증 후.
- 메일 템플릿은 `docs/email-templates/` 작성 후 `scripts/sync-email-templates.sh` 동기화.

---

## 11. 구현 결과

### PR 1 — 데이터 + 개별 즉시 메일 (개발서버 반영)

**구현일:** 2026-06-30
**브랜치/PR:** `feature/orient-submit-notify` → dev

**마이그레이션:** `supabase/migrations/202_orient_submit_notification.sql`
- `orient_sheets.last_submitted_at timestamptz NULL` 추가(`ADD COLUMN IF NOT EXISTS`, 멱등)
- `submit_orient_sheet(token, data, version)` 수정: `submitted_at = COALESCE(submitted_at, now())`(최초 불변 유지) + `last_submitted_at = now()`(매 제출 갱신). 인자 시그니처·익명 호출·반환 `success`/`version` 하위호환 유지 + 신규 반환키 `is_first_submission`/`orient_sheet_id`/`brand_id`/`form_type`/`application_id`. `SECURITY DEFINER + search_path=''`, `GRANT anon` 재부여 포함.

**트리거 방식 (§6 결정):** **데이터베이스 웹훅** 채택(방식 A 익명 직접호출=스팸 위험 / B·C pg_net=키 주입 복잡으로 탈락). `notify-brand-application`의 웹훅 패턴 미러. 설정 = `orient_sheets` 테이블 · UPDATE · Row filter `status='submitted'`. 임시저장(draft) 제외, 재제출은 `last_submitted_at` 변경으로 UPDATE 발생해 포착, 발행(consumed) 전환 제외. 신규/재제출 판정 = 웹훅 페이로드 `old_record.submitted_at IS NULL`(DB 재조회 불필요).

**Edge Function:** `supabase/functions/notify-orient-submitted/` (신규). 수신자 `get_subscribed_admin_emails('brand_notify')` + env `NOTIFY_ADMIN_EMAILS`, 1인 1통 분리, best-effort. 제목 「[신규 제출]/[수정 재제출] {브랜드명} 오리엔시트」, 본문에 `data jsonb` 미탑재. 템플릿 `docs/email-templates/orient-submitted-notify.html`(+ `_templates/` 미러, `scripts/sync-email-templates.sh` 등록).

### 초안 대비 변경 사항
- 추가된 것: 반환 플래그를 `is_first_submission` 외에 `orient_sheet_id`/`brand_id`/`form_type`/`application_id`까지 확장(웹훅 페이로드만으로 메일 구성 가능하게).
- 트리거 방식: 사양서 §6의 A/B/C 중 **웹훅(C 계열)** 확정.
- 부수: 기존 `docs/email-templates/admin-daily-digest.html` 주석이 마이그164 이전 텍스트로 남아 sync 시 회귀하던 드리프트를 함께 정정(생성물 `templates.ts`와 일치).

### 개발서버 환경 구축 (수동 — 마이그레이션 자동화 불가)
1. 개발 SQL Editor 에서 `202_orient_submit_notification.sql` 실행
2. `supabase functions deploy notify-orient-submitted --project-ref qysmxtipobomefudyixw`
3. Dashboard → Database → Webhooks: `orient_sheets`/UPDATE/filter `status='submitted'` → Edge Function `notify-orient-submitted`
4. Secrets `BREVO_API_KEY`/`PUBLIC_ADMIN_URL` 기존 함수와 공유 여부 확인
- ⚠️ 실제 발송 테스트·cron·운영 배포는 운영에서만(`feedback_dev_no_mail_test`). 오리엔 기능 운영 보류 중.

### PR 2 — 브랜드 일일 보고

**구현일:** 2026-06-30
**브랜치:** `feature/brand-daily-digest`

**마이그레이션:** `supabase/migrations/203_brand_daily_digest.sql`
- `public.brand_daily_digest_runs` 테이블 신설 — `admin_daily_digest_runs`(마이그레이션 132) 패턴 복제. `digest_date UNIQUE`(mutex) + `status CHECK(sent/skipped_no_data/failed)` + `sections_summary jsonb` + `recipients_count` + `error_message` + `run_at`. 행 단위 보안 정책(RLS) SELECT `is_admin()`, INSERT/UPDATE 는 서비스 역할(service_role)만 우회.
- `lookup_values` 시드 1행: `kind='admin_email_kind'`, `code='brand_digest'`, `name_ko='브랜드 일일 보고'`, `name_ja='ブランド日次報告'`, `sort_order=50`, `active=true`. 이로써 관리자 「메일 받기 설정」 모달에 `brand_digest` 토글 자동 노출(앱 코드 수정 불필요).
- ⚠️ pg_cron 등록은 본 마이그레이션에 포함하지 않음(수동 curl 검증 후 별도 단계).

**Edge Function:** `supabase/functions/notify-brand-daily-digest/index.ts` (신규)
- `notify-admin-daily-digest` 패턴 미러. 2섹션(신규 제출 / 수정 재제출).
- §5 판정 쿼리: 신규=`submitted_at ∈ [start, end)`, 재제출=`last_submitted_at ∈ [start, end) AND submitted_at < start`. 두 조건 상호배타 → 중복 제거 불필요. `status` 필터 없음(consumed/expired 도 시각 기준 포착).
- 브랜드명 배치 조회: `brands` 테이블 `in(brand_id)`.
- `form_type` NULL 안전 처리: `-` 표시.
- mutex: `brand_daily_digest_runs.digest_date UNIQUE` INSERT 선행. 2섹션 모두 0건이면 `skipped_no_data`.
- 수신자: `get_subscribed_admin_emails('brand_digest')` + env `NOTIFY_ADMIN_EMAILS`, 1인 1통 분리.
- 관리자 페인 링크: 오리엔시트 발급·조회 페인 모달 기반이라 per-row 딥링크 없음 → 단일 CTA 버튼(`PUBLIC_ADMIN_URL + /#orient-sheets`).
- 인플루언서 대상 4줄 푸터 없음(내부 관리자 메일).

**이메일 템플릿:**
- `docs/email-templates/brand-daily-digest.html` — 메인 템플릿(placeholder 6종)
- `docs/email-templates/brand-daily-digest.section.html` — 섹션 wrapper
- `scripts/sync-email-templates.sh` `SYNC_GROUPS`에 등록 + `templates.ts` 자동 생성 조건 추가. sync 실행 후 기존 7개 함수 `templates.ts` 회귀 없음 확인.

### 초안 대비 변경 사항 (PR 2)
- 동일: §5 판정·mutex·0건 처리·수신자·1인 1통 분리 모두 초안과 일치.
- 추가: 재제출 섹션 행에 「최초 제출」 열 추가(현황 파악 편의).
- cron 등록 보류 유지(개발서버 수동 curl 검증 후 별도 단계).

### 개발서버 환경 구축 (PR 2 수동 — 마이그레이션 자동화 불가)
1. 개발 SQL Editor 에서 `203_brand_daily_digest.sql` 실행
2. `bash scripts/sync-email-templates.sh`
3. `supabase functions deploy notify-brand-daily-digest --project-ref qysmxtipobomefudyixw`
4. Secrets `BREVO_API_KEY`/`PUBLIC_ADMIN_URL` 기존 함수와 공유 여부 확인

### 운영 가동 (2026-06-30 — 사용자 「완전 운영 가동」 결정)
오리엔 기능 운영 보류 해제 + PR1·PR2 운영 배포 완료(오리엔 기반 186~201은 운영 DB에 이미 존재 확인 → 202·203만 신규 실행).
1. 운영 DB(`nrwtujmlbktxjgdwlpjj`) SQL Editor: 마이그 **202** 실행 → **203** 실행(`brand_digest` 수신 종류 확인).
2. Edge Function 운영 배포: `notify-orient-submitted`, `notify-brand-daily-digest` (`--project-ref nrwtujmlbktxjgdwlpjj`).
3. 제출 알림 **웹훅** 운영 Dashboard 등록(`orient_sheets` UPDATE → `notify-orient-submitted`).
4. 일일 보고 **수동 발송 검증**: `net.http_post`로 1회 호출 → `brand_daily_digest_runs` 에 `digest_date=2026-06-29 status=skipped_no_data`(어제 0건) 정상 기록 확인.
5. **cron 등록(마이그 204)**: 운영 SQL Editor 실행 → job `brand-daily-digest-0900kst` `'0 0 * * *'` active=true. 내일 KST 09:00 첫 자동 발송.
6. 운영 Secrets 확인 완료(BREVO 키·PUBLIC_ADMIN_URL·PUBLIC_SALES_URL 존재).
- 저장소(main) 반영: 알림 파일만 핫픽스로 main 머지(보류 프론트 `admin-orient.js` 브랜드 검색 #638 등은 제외). 마이그 **204** 신규(cron 기록).
- 남은 검증: 실제 브랜드 제출 1건 시 제출 알림 즉시 메일 + 익일 09:00 일일 보고 인박스 확인(운영 첫 실데이터 발생 시).
