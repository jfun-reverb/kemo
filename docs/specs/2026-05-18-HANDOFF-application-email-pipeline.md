# HANDOFF — 응모 단계별 메일 파이프라인 (Edge Function 2개 + cron 2개) + cancel-daily 버그 수정 동반

> **작성일**: 2026-05-18 (2026-05-18 cancel-daily 통합 안내 추가)
> **작성 세션**: 기획/설계 (메인 폴더, 코드 미수정)
> **현재 상태**: ✅ **운영 배포 완료 (2026-05-18)** — 마이그레이션 130 + Edge Function 2종 + cancel-daily 버그 수정 + 관리자 접수 요약 cron 가동. **인플루언서 다이제스트 cron 은 mail-pipeline-consolidation PR 2 에서 통합 등록 예정**
> **관련 사양서**:
> - `docs/specs/2026-05-18-application-email-pipeline.md` (✅ 운영 배포 완료)
> - `docs/specs/2026-05-13-application-cancel-daily-email-fix.md` (✅ 운영 Edge Function 재배포 완료)
> **우선순위**: 🟢 완료

---

## 0-A. 동반 작업 — cancel-daily 버그 수정 (같은 PR 권장)

운영 점검(2026-05-18) 결과 응모 취소 일일 요약 메일이 인프라는 정상 작동하나, 2026-05-13 첫 발송에서 발견된 **3개 버그 + 1개 개선 요청** 미해결 상태. 다음 응모 취소가 발생해 `sent` 상태가 되는 날 동일 증상 재발.

### 통합 작업 권장 순서

1. **먼저 cancel-daily 수정** (사양서 §5 참조)
   - HTML 주석 안 플레이스홀더 제거
   - `auth.admin.getUserById` 로 이메일 별도 조회 (버그 C)
   - 시점별(`cancel_phase`) 그룹화 + 그룹 헤더
2. **개발 DB 시드 → curl 수동 호출 → 메일 본문 확인** (사양서 §7)
3. **검증된 패턴으로 신규 2종 작성** — cancel-daily 의 fixed 패턴을 그대로 미러링
   - 이메일 조회: `auth.admin.getUserById` 배치 패턴
   - 그룹화: `cancel_phase` 그룹화 로직 → 인플루언서 다이제스트 「4섹션 분류」 와 구조 유사
4. **마이그레이션 130 + Edge Function 2종 배포**
5. **한 PR 로 dev → main**

### 묶을 이유

- 둘 다 `supabase/functions/` 영역, Brevo SMTP, `auth.admin.getUserById` 패턴 공유
- cancel-daily 의 검증된 fixed 패턴을 신규 2종 코드 베이스로 재활용
- 운영 배포 1회로 끝 + reviewer 호출 1회

### 통합 시 영향 파일 추가

기존 §4 영향 파일 체크리스트에 추가:

- [ ] `docs/email-templates/application-cancelled-daily.html` 주석 안 `{{rows_html}}` / `{{admin_pane_url}}` 제거 (버그 A)
- [ ] `supabase/functions/notify-application-cancelled-daily/index.ts` 수정 (버그 C + 시점별 그룹화)
- [ ] `_templates/` / `templates.ts` 는 `sync-email-templates.sh` 자동 갱신
- [ ] (옵션) 카탈로그 카드 「응모 취소 — 일일 요약 (관리자)」 의 `.card-condition` 행 추가 시 사양서 §8-3 표 #12 그대로 적용

### 사양서 「구현 결과」 분리 기록

- cancel-daily 수정 결과는 **`2026-05-13-application-cancel-daily-email-fix.md` §10** 에 기록
- 신규 메일 파이프라인 구현 결과는 **`2026-05-18-application-email-pipeline.md` §17** 에 기록
- 카드 문구 다듬은 이력은 **`2026-05-18-application-email-pipeline.md` §8-3-1** 표에 기록
- PR description 의 「관련 사양서」 에 두 문서 모두 링크

---

---

## 0. 한 줄 요약

응모 단계별 5가지 이벤트(접수·접수확인·승인·반려·마감 임박)를 **인플루언서당 매일 09:00 KST 1통** + **관리자에게 접수 요약 1통** 으로 발송. 기존 `notify-application-cancelled-daily` 인프라(pg_cron + Edge Function + Brevo SMTP) 그대로 미러링.

---

## 1. 산출물

| 종류 | 갯수 | 비고 |
|---|---|---|
| 마이그레이션 | 1개 | 129 — 다이제스트 로그 3종 + lookup 시드 + 구독 시드 |
| Edge Function | 2개 | `notify-influencer-daily-digest` + `notify-application-received-admin-daily` |
| 메일 템플릿 (HTML) | 2개 메인 + preview 2개 + row 헬퍼 일부 | `docs/email-templates/` |
| pg_cron job | 2개 | 양 DB (개발 + 운영) 각각 등록 |
| 카탈로그 갱신 | 1개 | `docs/email-templates/index.html` (활성 5종 → 7종) |
| 클라이언트 코드 | **0개** | 변경 없음 |

---

## 2. 작업 전제 (이미 결정된 것)

### 2-1. 사양 확정 (사용자 답변 8건 반영)

| 항목 | 결정 |
|---|---|
| 묶음 정책 | 모두 1통 (인플루언서당 하루 최대 1통) |
| 발송 시각 | 매일 한국시간 09:00 |
| 영수증 마감 기준 | `purchase_end` (monitor 타입만) |
| 결과물 마감 기준 | `submission_end` (NULL이면 `post_deadline` 폴백) |
| D-N | D-5, D-1 (둘 만) |
| 재발송 방지 | `(인플루언서, 캠페인, 종류, D-N) UNIQUE` 로그 |
| 수신 거부 | `marketing_opt_in` 무시. 무조건 발송 |
| 관리자 기본 ON | 전체 관리자 (마이그레이션 안에서 시드) |
| 반려 사유 표시 | 이번 범위 밖 (별도 PR — `applications.reject_reason` 컬럼 추가는 후속 사양) |

### 2-2. 기존 인프라 점검 완료

- `notify-application-cancelled-daily` 가 동일한 패턴으로 운영 중 (참고용 베이스)
- Brevo SMTP·`vault.decrypted_secrets`·pg_cron 확장 모두 활성
- `lookup_values(kind='admin_email_kind')` 시드 2건 존재 (`brand_notify`, `application_cancel`)
- 다음 마이그레이션 번호: **130** (2026-05-18 main 점검 시점에 129는 「캠페인 노출 토글 — `remove_post_deadline`」 작업이 가져감. 작업 시작 전 `ls supabase/migrations/ | tail -5` 한 번 더 확인)

---

## 3. 작업 순서

### 3-1. 진입
1. `/새세션 app-email-pipeline` 호출 → worktree + `feature/app-email-pipeline` 브랜치
2. `git pull origin dev` 최신 동기화
3. `ls supabase/migrations/ | tail -5` 마이그레이션 번호 재확인 (다른 세션이 추가했을 수 있음)

### 3-2. 마이그레이션 130 작성 + 개발 DB 적용
1. `supabase/migrations/130_application_email_pipeline_infra.sql` 작성 (사양서 §6 참조)
   - `influencer_daily_digest_runs` 테이블
   - `application_received_admin_digest_runs` 테이블
   - `deadline_reminder_email_sent` 테이블 + 인덱스 + UNIQUE
   - 3개 테이블 RLS (SELECT `is_admin()`, CUD 정책 없음 — service_role 직접)
   - `lookup_values` 시드 1건 (`application_received`)
   - `admin_email_subscriptions` 시드 (전체 관리자 ON)
   - `_yesterday_kst_window()` 헬퍼 (옵션)
2. 개발 DB 적용 (SQL Editor)
3. 검증 SQL: 3개 테이블·1개 함수·시드 행 모두 존재 확인

### 3-3. 메일 템플릿 작성
1. `docs/email-templates/influencer-daily-digest.html` 신규
   - 사양서 §8-1 본문 구조 (4섹션)
   - 일본어 (인플루언서 UI 언어)
   - 섹션별 placeholder: `{{received_rows_html}}` / `{{approved_rows_html}}` / `{{rejected_rows_html}}` / `{{deadline_rows_html}}`
   - 섹션 0건 시 빈 문자열 치환 (Edge Function 가 미리 결정)
   - 푸터: 「このメールは応募活動に関する重要なお知らせです」
2. `docs/email-templates/influencer-daily-digest.preview.html` (열어서 디자인 확인용)
3. (옵션) 섹션별 row 헬퍼 4종 — 분리하면 가독성 ↑
4. `docs/email-templates/application-received-admin-daily.html` 신규 + preview + row (cancel-daily 패턴 그대로 미러)

### 3-3-1. 카탈로그 페이지(`docs/email-templates/index.html`) 갱신 (2026-05-18 추가 요구사항)

**목표**: 운영 도메인(`https://www.globalreverb.com/docs/email-templates/index.html`) 에서 운영자·CS 담당자가 메일 발송 시점을 한눈에 이해.

**작업**:
1. **신규 CSS 클래스 추가** (사양서 §8-3 스타일 블록 그대로 복사)
   - `.card-condition`, `.cc-label`, `.cc-text`
2. **활성 12장 모든 카드에 「언제 보내요?」 박스 행 추가** — 사양서 §8-3 표의 「발송 조건 (평이한 한국어)」 컬럼 그대로 삽입
3. **신규 카드 2장 추가** (활성 섹션 안)
   - 「인플루언서 일일 다이제스트」 (tag-infl)
     - `미리보기` → `influencer-daily-digest.preview.html`
     - `원본` → `influencer-daily-digest.html`
   - 「캠페인 신청 접수 — 관리자 일일 요약」 (tag-infl)
     - `미리보기` → `application-received-admin-daily.preview.html`
     - `원본` → `application-received-admin-daily.html`
4. **미구현 섹션 정리**
   - 「캠페인 신청 접수 확인 (본인)」 카드 → **삭제** (신규 13번에 흡수)
   - 「신청 승인 알림」 카드 → **삭제** (신규 13번에 흡수)
   - 「신청 반려 알림」 카드 → **삭제** (신규 13번에 흡수)
   - 「마감일 임박 리마인더」 카드 → **삭제** (신규 13번에 흡수)
   - 「캠페인 신청 접수 알림 (관리자)」 카드 → **삭제** (신규 14번으로 활성화)
   - 「OT 발송 안내」 카드 → **그대로 유지** (미구현) + 「언제 보내요?」 박스 추가
5. **푸터 안내 한 줄 추가** (사양서 §8-3 footer 안내 블록 — 「🟡 노란 박스 안 ...」)
6. **legend 색 키 확인** — 신규 카드는 `tag-infl` (인플루언서 영역) 또는 별도 신규 색? **`tag-infl` 그대로 사용** 권장 (Influencer 비즈니스 로직 메일이라 일관)

**카드별 한 줄 발송 조건은 사양서 §8-3 표의 기획 초안을 1차 적용** — 단, 실제 카드에 붙여보고 어색한 부분이 있으면 **개발 세션이 자유롭게 다듬어도 됩니다**.

**다만 변경 시 사양서 §8-3-1 「문구 다듬기 이력」 표에 한 행씩 기록 의무** (변경 전 / 변경 후 / 이유). 그래야 다음 기획 세션이나 사용자가 「왜 이렇게 바뀌었지?」 추적 가능. 사용자가 작업 중 「이 문장 어색해, 이렇게 고쳐줘」 라고 요청해서 바뀐 경우도 동일하게 기록.

→ 사양서 §17 「구현 결과」 의 「달라진 것」 에는 변경 행 수만 짧게 요약 (예: "§8-3 카드 문구 3건 다듬음 — 상세는 §8-3-1 참조")

### 3-4. Edge Function 2개 작성
1. `supabase/functions/notify-influencer-daily-digest/`
   - `index.ts` — 4섹션 쿼리 (사양서 §4-2) + 인플루언서별 그룹핑 + 4섹션 렌더 + Brevo 발송 + `deadline_reminder_email_sent` 벌크 INSERT
   - 인플루언서별 try/catch — 한 명 실패 가 다른 명 차단 안 함
   - `templates.ts` (sync 자동 생성)
2. `supabase/functions/notify-application-received-admin-daily/`
   - `index.ts` — 사양서 §5 쿼리 + cancel-daily 패턴 그대로
   - 수신자: `get_subscribed_admin_emails('application_received')` + env
   - `templates.ts` (sync 자동 생성)

### 3-5. 동기화·빌드·검증
1. `scripts/sync-email-templates.sh` 실행 → `_templates/` + `templates.ts` 양 함수에 복사
2. 개발 환경에 Edge Function 2개 배포 (`supabase functions deploy ...`)
3. 환경 변수 확인 (cancel-daily 와 공유 — 신규 설정 거의 없음)
4. 개발 DB pg_cron 2개 job 등록 (사양서 §9)
5. 수동 호출 검증 (`curl` + service_role JWT) — 시나리오 1
6. 시드 데이터 생성 + 검증 시나리오 1~12 (사양서 §11) 통과

### 3-6. dev push + PR
1. `cd dev && bash build.sh` (클라이언트 변경 0이라 산출물 동일하지만 빌드 검증 차원)
2. `reverb-supabase-expert` 호출 — 마이그레이션 130 + Edge Function 검증 (특히 `_yesterday_kst_window`, RLS, 시드 SQL)
3. `reverb-reviewer` 호출 — commit 직전
4. `reverb-qa-tester` skip (백엔드 cron 작업, 클라이언트 변경 없음 — 필요시 light 로 메일 결과 모달/링크 확인)
5. PR `dev → main` 생성
6. 사용자 운영 배포 승인 후 §3-7 진행

### 3-7. 운영 배포 (사용자 승인 후)
1. 운영 DB 백업
2. 운영 DB SQL Editor 마이그레이션 130 적용
3. Edge Function 2개 운영 프로젝트 배포
4. 운영 Brevo 환경변수 확인 (개발과 다름 — `BREVO_API_KEY` 운영용)
5. 운영 DB pg_cron 2개 job 등록
6. 수동 호출 검증 (소량 데이터 시점, 가능하면 발송 차단된 시간대)
7. 다음 날 09:00 자연 실행 결과 확인

---

## 4. 영향 파일 체크리스트

> ✅ = 운영 배포 완료 / ⏳ = mail-pipeline-consolidation PR 2 에서 처리 / 🔲 = 미완료

### DB
- [x] `supabase/migrations/130_application_email_pipeline_infra.sql` ✅ 운영 DB 적용 완료

### Edge Functions
- [x] `supabase/functions/notify-influencer-daily-digest/index.ts` ✅
- [x] `supabase/functions/notify-influencer-daily-digest/templates.ts` ✅
- [x] `supabase/functions/notify-application-received-admin-daily/index.ts` ✅
- [x] `supabase/functions/notify-application-received-admin-daily/templates.ts` ✅

### 메일 템플릿
- [x] `docs/email-templates/influencer-daily-digest.html` + `.preview.html` ✅
- [x] `docs/email-templates/application-received-admin-daily.html` + `.preview.html` + `.row.html` ✅
- [x] `docs/email-templates/index.html` (카탈로그 갱신 — 사양서 §8-3 적용) ✅
  - [x] 신규 CSS 클래스 `.card-condition` / `.cc-label` / `.cc-text` / `.cc-timing` 추가 ✅
  - [x] 활성 14장 모든 카드에 「언제 보내요?」 박스 삽입 ✅
  - [x] 신규 카드 2장 추가 (활성 섹션) ✅
  - [x] 미구현 섹션 정리 (4장 흡수 삭제 + 1장 활성화 + 「OT 발송 안내」만 미구현 유지) ✅
  - [x] 푸터에 노란 박스 안내 추가 ✅
  - [x] 운영 URL 자동 반영 확인 ✅

### pg_cron
- [x] 개발 DB: `cron.schedule('application-received-admin-daily', '0 0 * * *', ...)` ✅
- [x] 개발 DB: `cron.schedule('notify-influencer-daily-digest', '0 0 * * *', ...)` ✅ (mail-pipeline-consolidation PR 2 에서 통합 전환 완료)
- [x] 운영 DB: `application-received-admin-daily` cron → 관리자 통합 다이제스트 cron 으로 전환 완료 ✅
- [x] 운영 DB: `notify-influencer-daily-digest` cron 가동 중 ✅

### 문서
- [x] `CLAUDE.md` — Email / SMTP 섹션 + Database Schema 섹션 업데이트 ✅
- [x] `docs/specs/2026-05-18-application-email-pipeline.md` §17 「구현 결과」 채움 ✅

---

## 5. 핵심 SQL 시그니처

### 인플루언서 4섹션 통합 쿼리 (개념)
사양서 §4-2 전체 참조. 다섯 개 CTE → 인플루언서별 GROUP BY → `array_agg(item)` 형태로 반환.

### 마감 임박 재발송 방지
```sql
AND NOT EXISTS (
  SELECT 1 FROM deadline_reminder_email_sent s
   WHERE s.influencer_id = a.user_id
     AND s.campaign_id   = c.id
     AND s.kind          = '<receipt|post>'
     AND s.d_minus       = <계산된 D-N>)
```

### 발송 직후 벌크 INSERT
```sql
INSERT INTO deadline_reminder_email_sent (influencer_id, campaign_id, kind, d_minus, deadline_date)
SELECT * FROM unnest(<values>);
-- 또는 INSERT ... VALUES (...) (...) (...)
```

---

## 6. 검증 시나리오 (사양서 §11 그대로 — 12건)

1. Edge Function 2개 `curl` 호출 → `status='sent'`
2. 같은 날 두 번 호출 → `digest_date` UNIQUE 차단
3. 데이터 0건 → `status='skipped_no_data'`, 메일 미발송
4. 어제 승인 1 + 반려 1 인플루언서 → 1통에 섹션 2·3 노출
5. D-5 영수증 + D-1 결과물 1명 → 1통 섹션 4 안 2건 묶음
6. 신청 1 + D-5 영수증 + D-1 결과물 1명 → 1통 섹션 1·4 노출
7. 4섹션 모두 0건 인플루언서 → 그 인플루언서만 발송 스킵
8. 같은 D-N 메일 두 번 시도 → `deadline_reminder_email_sent` UNIQUE 차단
9. D-5 받고 D-3 시점 영수증 제출 → D-1 메일에 임박 섹션 없음
10. 관리자 「application_received」 OFF → 그 관리자 미발송
11. Brevo API 키 잘못 → `status='failed'` + `error_message`
12. 일본어 인코딩 (마감일·캠페인명 한자) 정상 표시

---

## 7. 리스크 (사양서 §13 발췌)

- **Brevo 한도 압박** — 인플루언서당 1통 통합으로 절약. 사용량 모니터링
- **캠페인 마감일 연장** — `deadline_reminder_email_sent` 운영자 reset 도구 (이번 범위 밖)
- **`reviewed_at` UPDATE 가정** — storage.js / RPC 점검 필요 (개발 세션)
- **30건 신청 폭주** — 본문 잘림 처리 (이번 범위 밖)
- **인플루언서별 트랜잭션** — 개별 try/catch 패턴

---

## 8. 에이전트 호출 의무

- `reverb-supabase-expert` — 마이그레이션 130 + RLS + 시드 SQL 검증 (의무)
- `reverb-reviewer` — 모든 commit 직전 (의무)
- `reverb-qa-tester` — **skip** (백엔드 cron, 클라이언트 변경 없음). 단 카탈로그 페이지(`docs/email-templates/index.html`) 미리보기 링크 동작은 dev push 후 사용자가 직접 확인
- `reverb-planner` — **스킵** (사양 확정 + HANDOFF 작성 완료, 별도 분기점 없음)

---

## 9. PR 본문 템플릿

```markdown
## 변경 요약
- 응모 단계별 메일 파이프라인 (인플루언서 통합 1통 + 관리자 접수 1통)
- Edge Function 2개 + 마이그레이션 130 + 메일 템플릿 2종
- 매일 한국시간 09:00 일괄 발송, 인플루언서당 최대 1통

## 요청 외 추가 변경
- (없으면 "없음" 명시)

## 관련 사양서
- docs/specs/2026-05-18-application-email-pipeline.md (확정)
- docs/specs/2026-05-18-HANDOFF-application-email-pipeline.md (이 문서)

## DB 변경
- 마이그레이션 130: 다이제스트 로그 3종 + lookup 시드 1건 + admin 구독 시드

## 검증
- 검증 시나리오 12건 통과 (개발서버)
- 다음 날 09:00 자연 실행 결과 확인 예정

## 운영 배포 절차
- HANDOFF §3-7 참조 (운영 DB 백업 + 마이그레이션 + Edge Function + pg_cron 2개)
```

---

## 10. 작업 완료 후

- 사양서 `docs/specs/2026-05-18-application-email-pipeline.md` §17 「구현 결과」 채우기
- `CLAUDE.md` Email / SMTP 섹션에 신규 cron 2개 + Edge Function 2개 한 줄씩 추가
- 신규 메일 종류 2개에 대한 사용자 안내 (한국어 운영자용 README 또는 노션 페이지)
- 후속 과제 메모: `applications.reject_reason` 컬럼 + 입력 UI 별도 사양 (사용자 메모리 등록)
