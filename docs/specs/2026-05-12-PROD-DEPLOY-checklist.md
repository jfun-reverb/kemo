# 운영 배포 체크리스트 — 응모 취소 + 관리자 메일 분리 + NG 사항 번들화 + 브랜드 서베이 묶음

> **작성일**: 2026-05-12 (초안) / 2026-05-12 (1차 갱신)
> **작성 세션**: 메인 폴더(고문) — 코드·머지 안 함, 정리 자료만
> **대상 dev → main PR**: 36개 dev 커밋 일괄 운영 배포

---

## 1. 묶음 범위

dev 브랜치에 들어간 변경 중 운영(`main`)에 한 번에 올릴 항목:

### 1-1. 응모 취소 + 관리자 메일 + NG 번들화 (1차 묶음)

| 묶음 | PR | 상태 |
|---|---|---|
| 관리자 메일 수신 분리 | #156 (B) | ✅ dev |
| 응모 취소 PR-A (DB + RPC) | #157 | ✅ dev |
| 응모 취소 PR-B (인플루언서 UI) | #158, #159·#160·#161·#162·#163·#166·#167·#168 (UX 보강) | ✅ dev |
| 응모 취소 PR-C (관리자 UI) | #170 | ✅ dev |
| NG-PR-A (DB + storage) | #164 | ✅ dev |
| NG-PR-B (캠페인 폼 + 미리보기) + fix | #169, #171 | ✅ dev |
| NG-PR-C (기준 데이터 NG 탭) | #172 | ✅ dev |
| NG-PR-D (변경 이력 모달 NG 확장) | #176 | ✅ dev |

### 1-2. 브랜드 서베이(광고주 신청 관리) 정비 (2차 묶음, dev 추가분 36커밋)

| 묶음 | PR | 상태 |
|---|---|---|
| 관리자 계정 페인 「메일받기」 칩·편집버튼 정리 | #178 | ✅ dev |
| 모집비 견적 합산 트리거 (migration 111) | #179 | ✅ dev |
| 광고주 신청 모달 즉시 새로고침 fix | #180 | ✅ dev |
| sales 폼·관리자 모달 `recruit_fee_krw` 컬럼 추가 | #181 | ✅ dev |
| 상태 드롭다운 → 11개 가로 탭 | #182 | ✅ dev (긴급 보강 포함) |
| 탭 위치(필터 아래·카드 위) 재배치 | #184 | ✅ dev |
| 신규 등록 모달 880→1080px | #183 | ✅ dev |
| 탭/카드 카운트 라벨 단위 정리 (신청/제품 구분) | #185 | ✅ dev |
| 탭/카드 카운트 「신청 단위」로 통일 | #186 | ✅ dev |
| 탭 상단 마진 확대·하단 축소 | #187 | ✅ dev |
| 신청 단위 row 그룹핑 + 모달 라벨 매칭 | #188 | ✅ dev |
| 카운트 row 기준 재계산 | #189 | ✅ dev |
| 「VAT 포함」 라벨 + 「최종견적금액」 컬럼 추가 | #190 | ✅ dev |
| 견적서 URL + 오리엔트 전달 컬럼 (migration 112) | #192 | ✅ dev |
| 셀 컬럼 보더 + 신규등록 모달 80vw | #193 | ✅ dev |
| 제품 입력 단가/수량 컬럼 폭 조정 | #194 | ✅ dev |
| 단가/모집비/이체수수료 컬럼 폭 확대 | #195 | ✅ dev |
| 🔴 **PR #182 머지 후 회귀 긴급 패치** (`#brand-applications` stale state · localStorage 새로고침 시 메인 영역 공백) | 436940b 직접 push | ✅ dev |
| 🔴 **buildId 기반 자동 리로드 가드** (stale 캐시 회귀 재발 방지) | 411c9bd 직접 push | ✅ dev |

### 1-3. 본 묶음에서 제외 (별도 일감)

| 일감 | 사유 |
|---|---|
| 응모 취소 PR-D (일일 요약 메일 Edge Function + pg_cron) | 메일 템플릿 HTML 3종이 untracked, Edge Function 미구현. 별도 묶음 |
| 응모 취소 PR-E (약관·정책) | TERMS §N · PRIVACY 수집항목 4종 미반영. 별도 묶음 (NG-PR-E 와 함께) |
| NG-PR-E (약관 영향 점검) | 응모 취소 PR-E 와 묶어 `/약관확인` 슬래시 명령 1회 실행 |
| NG-PR-F (legacy `campaigns.ng` DROP) | 본 운영 배포 1주 관찰 후 |
| 리치 에디터 이미지 첨부 강화 | 사양만 확정(`docs/specs/2026-05-12-rich-editor-image-upload.md`), 미구현 |

---

## 2. 운영 DB 마이그레이션 (Supabase SQL Editor)

**적용 순서대로** 운영 프로젝트(`twofagomeizrtkwlhsuv.supabase.co`) SQL Editor에서 실행. 110은 이미 운영 적용 완료(`a1505a8 fix(migration-110): bypass closed-campaign lock trigger for backfill`).

```
103_admin_email_subscriptions.sql              # 관리자 메일 수신 구독 분리
104_application_cancellation.sql               # 응모 취소 컬럼 5종 + cancel_application RPC + partial unique index
105_notifications_kind_application_cancelled.sql  # notifications.kind CHECK 확장
106_lookup_values_kind_check_extend.sql        # lookup_values.kind CHECK 확장 (cancel_reason, admin_email_kind)
107_create_ng_sets.sql                         # ng_sets 테이블 + campaigns.ng_set_id/ng_items
108_lock_ng_on_closed.sql                      # closed 캠페인 NG 변경 차단 트리거
109_campaign_ng_history.sql                    # campaign_caution_history NG 확장 + record_caution_history 시그니처 확장
111_recalc_with_recruit_fee.sql                # brand_applications 견적 트리거에 모집비 합산
112_brand_app_quote_orient_urls.sql            # brand_applications.quote_sent_url + orient_sheet_sent_at/url
```

⚠️ **110_backfill_participation_steps_legacy.sql** 은 이미 운영 적용 완료(중복 적용 금지).

### 마이그레이션 적용 직후 검증 SQL

```sql
-- 1-A) applications 응모 취소 컬럼 추가 확인
SELECT column_name FROM information_schema.columns
  WHERE table_name='applications' AND column_name IN
  ('cancelled_at','cancel_reason','cancel_reason_code','cancel_phase','previous_status');
-- 5건 반환 기대

-- 1-B) campaigns NG 컬럼 추가 확인
SELECT column_name FROM information_schema.columns
  WHERE table_name='campaigns' AND column_name IN ('ng_set_id','ng_items');
-- 2건 반환 기대

-- 1-C) brand_applications 신규 URL/타임스탬프 컬럼 확인 (migration 112)
SELECT column_name FROM information_schema.columns
  WHERE table_name='brand_applications'
    AND column_name IN ('quote_sent_url','orient_sheet_sent_at','orient_sheet_sent_url');
-- 3건 반환 기대

-- 2) RPC/트리거 함수 존재 확인
SELECT proname FROM pg_proc WHERE proname IN
  ('cancel_application','get_subscribed_admin_emails','record_campaign_ng_history',
   'recalc_brand_application_totals');

-- 3) lookup_values 시드 확인
SELECT kind, count(*) FROM lookup_values
  WHERE kind IN ('cancel_reason','admin_email_kind','violation_reason')
  GROUP BY kind;
-- cancel_reason ≥ 6, admin_email_kind ≥ 2, violation_reason 기존+1(cancel_after_purchase_start)

-- 4) partial unique index 확인
SELECT indexname FROM pg_indexes
  WHERE tablename='applications' AND indexname='applications_user_camp_active_uidx';

-- 5) 데이터 이관 확인 (admin_email_subscriptions)
SELECT a.email, s.mail_kind
  FROM admins a LEFT JOIN admin_email_subscriptions s ON s.admin_id=a.id
  WHERE a.receive_brand_notify=true OR s.mail_kind='brand_notify';
-- 기존 receive_brand_notify=true 관리자가 brand_notify 구독으로 이관됐는지 확인

-- 6) ng_sets 테이블 + RLS 확인
SELECT relname FROM pg_class WHERE relname='ng_sets';
SELECT polname FROM pg_policies WHERE tablename='ng_sets';

-- 7) 모집비 견적 트리거 동작 확인 (운영 데이터 1건 sample)
--    reviewer 신청 1건의 products[i].recruit_fee_krw 합산이 estimated_krw 에 반영되는지
SELECT id, application_no, total_jpy, total_qty,
       (SELECT SUM((p->>'recruit_fee_krw')::numeric * (p->>'qty')::numeric)
        FROM jsonb_array_elements(products) p) AS expected_recruit_sum,
       estimated_krw
  FROM brand_applications
  WHERE form_type='reviewer'
  ORDER BY created_at DESC
  LIMIT 3;
-- 신규 INSERT/UPDATE 시 estimated_krw 가 모집비를 포함해 재계산되는지 검증 (기존 행은
-- 트리거 재실행 전까지 옛값 유지 — 필요 시 UPDATE … SET products=products 로 강제 재계산)
```

---

## 3. Edge Function 운영 재배포

`notify-brand-application` — 수신자 쿼리가 `get_subscribed_admin_emails('brand_notify')` RPC 경유로 변경됨. 운영 프로젝트에서 재배포 필요.

```bash
# Supabase CLI 로그인 + 운영 프로젝트 link 가정
supabase functions deploy notify-brand-application --project-ref twofagomeizrtkwlhsuv
```

또는 Supabase 대시보드 → Edge Functions → 해당 함수 → "Deploy from GitHub" / 코드 붙여넣기.

배포 직후 운영 광고주 신청 폼(sales.globalreverb.com) 1건 테스트 → 관리자 메일 도착 확인.

⚠️ **dev → main 차분에 Edge Function 코드 변경 없음**(`git diff origin/main..origin/dev -- supabase/functions/`). `notify-brand-application` 은 본 묶음에 들어간 migration 103 의 RPC 시그니처(`get_subscribed_admin_emails`)를 호출하는 이미 머지된 코드 — 운영에 그 코드가 머지된 시점이 본 배포라면 재배포 필수. 운영에 이전에 별도 배포돼 있다면 검증만.

---

## 4. 약관·정책 변경

본 묶음 dev → main diff 에 `docs/TERMS_*.md` / `docs/PRIVACY_*.md` 변경 없음(확인 완료).

**본 묶음 운영 배포 후 별도 묶음에서 처리 예정**:
- TERMS_{ko,ja}.md: 응모 취소 정책 신규 §N (응모 취소 사양 `docs/specs/2026-05-11-application-cancel.md` §7-1) — 응모 취소 PR-E
- TERMS / PRIVACY: NG 사항 번들화 영향 점검 — NG-PR-E
- `/약관확인` 슬래시 명령 + Notion 동기화 블록(`.claude/rules/notion-sync.md` 규칙) — 별도 묶음에서 한 번에

본 묶음은 약관·정책 변경 없이 그대로 진행 가능.

---

## 5. 코드 배포

- `dev → main` PR 머지 → Vercel 자동 배포 (`globalreverb.com` / `www.globalreverb.com`)
- **dev 추가분 36개 커밋이 한 번에 main 으로** — 응모 취소 + NG 번들화 + 브랜드 서베이 정비 전부 동시 노출됨
- 인플루언서 측 i18n 추가 키 30+ → 운영서버에도 그대로 반영 (i18n 자체는 개발서버 한정 토글이라 사용자 화면에 노출은 없으나 코드는 포함)
- 빌드 산출물(`index.html`, `admin/index.html`) 자동 빌드/배포 (Vercel 빌드 스텝)
- 인플루언서 화면 변경 없음(응모 취소 UI 는 본 묶음 1차 운영 노출, 브랜드 서베이는 관리자 전용)
- 관리자 화면은 **브랜드 서베이 페인 레이아웃이 크게 바뀜**(상태 드롭다운 → 11개 탭, 신규등록 모달 80vw, 컬럼 보더·폭 조정 등) — 운영 배포 직후 영업팀 사전 안내 권장
- 🔴 **buildId 가드 (411c9bd)**: 배포 직후 기존 사용자 탭은 stale 캐시 감지 시 자동 리로드. 영업·관리자 측에 「화면이 한 번 새로고침될 수 있습니다」 사전 안내 권장

---

## 6. 외부 시스템 — 변경 사항 없음

| 시스템 | 변경 여부 |
|---|---|
| Brevo SMTP | 없음 |
| Supabase Auth Site URL / Redirect | 없음 |
| Vercel 환경 변수 | 없음 |
| DNS | 없음 |
| Storage 버킷 / 정책 | 없음 |

---

## 7. 운영 배포 직후 스모크 테스트 (사용자 + 관리자 1명)

### 인플루언서 측 (globalreverb.com)
- [ ] 마이페이지 응모이력 진입 → 활동관리 페이지에서 「응모 취소」 버튼 노출
- [ ] 모집기간 중 신청 1건 단순 취소 → 「取消」 탭 이동, applied_count 감소
- [ ] 구매기간 진입한 신청 1건 사유 입력 취소 → 동의 체크 강제, 차단·통과 분기 정상
- [ ] 신청 취소 후 같은 캠페인 재응모 → partial unique index 가 cancelled 행 제외라 정상 INSERT

### 관리자 측 (globalreverb.com/admin/)

#### 응모 취소
- [ ] /admin#applications → 상태 필터 「취소」 옵션 노출
- [ ] cancelled 행: 「취소됨」 배지 + cancel_phase 한국어 라벨
- [ ] cancelled 행 인플루언서 이름 클릭 → 상세 모달 신청 이력에 보조 행 + 「이 취소 건으로 위반 등록」
- [ ] 위반 등록 버튼 → 사유 자동 체크(cancel_after_purchase_start) + 메모 prefill
- [ ] /admin#campaigns 캠페인 더보기 → 신청자 엑셀 다운: 21컬럼 + cancelled 행 4컬럼 정상

#### NG 사항 번들
- [ ] /admin#campaigns 캠페인 등록·편집 폼: NG 사항 번들 카드 노출 + 편집 모달
- [ ] 미리보기 모달에 NG 한·일 토글 노출
- [ ] /admin#lookups NG 탭이 번들 CRUD로 동작 (기존 lookup_values `kind='ng_item'` 6건은 비활성 + 「기본 NG 묶음」 번들 1건으로 흡수)
- [ ] 캠페인 더보기 「변경 이력」(super_admin 한정) → NG 변경 diff 노출

#### 관리자 메일 수신 설정
- [ ] /admin#admin-accounts 각 행에 「메일받기」 칩 + 「설정」 버튼
- [ ] 모달에서 메일 종류별 on/off 저장 → DB 반영
- [ ] 운영 광고주 폼 신청 1건 테스트 → 구독한 관리자에게만 알림 메일

#### 🔴 브랜드 서베이 (광고주 신청 관리)
- [ ] /admin#brand-applications **일반 브라우저(Chrome 시크릿 X)에서 새로고침**:
      메인 영역 빈 화면·사이드바만 표시 회귀 **재발 없는지** 확인 (PR #182 직후 발생, 436940b 패치)
- [ ] 상태 필터 → **11개 가로 탭**으로 표시(드롭다운 아님), 탭 옆 카운트가 신청 단위로 표기
- [ ] 「신규 등록」 버튼 → **80vw 폭** 모달 + 제품 입력 테이블의 「단가/수량/모집비/이체수수료」 컬럼 폭 정상
- [ ] 모집비 입력 행 추가 후 저장 → **예상 견적(VAT 포함)** 셀에 모집비가 합산되어 표시 (migration 111)
- [ ] 견적서 URL + 오리엔트 전달 컬럼 노출 + 외부 링크 클릭 정상 (migration 112, `safeBrandUrl` http/https 검증)
- [ ] 신청 1건 수정 후 모달 닫기 → 페인 즉시 새로고침 (예상견적/최종견적금액 셀 stale 없음, PR #180)
- [ ] 브랜드 서베이 엑셀 다운로드 → 새 컬럼(최종견적금액·견적 URL·오리엔트 전달) 정상 노출 여부

#### 🔴 빌드 ID 자동 리로드 가드 (411c9bd)
- [ ] 운영 배포 직후 **기존 열려있던 관리자 탭** 1개: stale 캐시 감지 시 자동 리로드 1회 후 정상 동작
- [ ] 영업·관리자 측에 「화면이 한 번 새로고침될 수 있습니다」 사전 안내

---

## 8. 롤백 절차

| 문제 | 액션 |
|---|---|
| 마이그레이션 적용 실패 | 해당 SQL 트랜잭션 ROLLBACK, 코드 main 머지 보류 |
| Edge Function 발송 실패 | env `NOTIFY_ADMIN_EMAILS` 폴백으로 임시 운영, 다음 패치 |
| 코드 회귀 발견 | `git revert` 해당 main 머지 커밋 + Vercel 자동 재배포 |
| 본인 취소 RPC 예외 | 사용자에게 「잠시 후 다시 시도」 안내 + Supabase Logs 점검 |
| 브랜드 서베이 페인 회귀 (#brand-applications 빈 화면 재발) | dev 의 436940b·411c9bd 가 main 에 들어갔는지 우선 확인. 없으면 cherry-pick. 있으면 추가 로그 수집 + Supabase Logs 점검 |
| 모집비 견적 합산 결과 회귀 | migration 111 의 `recalc_brand_application_totals()` 함수만 `CREATE OR REPLACE` 로 052 버전 복원 (DDL drop 불필요) |
| migration 112 URL 컬럼 회귀 | 컬럼은 NULL 허용 — 코드만 revert 가능. 컬럼 자체 DROP은 `ALTER TABLE brand_applications DROP COLUMN IF EXISTS quote_sent_url, orient_sheet_sent_at, orient_sheet_sent_url`(롤백 SQL은 112 파일 상단 주석 참조) |

DB 컬럼 추가는 backwards-compatible (NULL 허용) — 마이그레이션 ROLLBACK 안 해도 코드만 revert 가능.

### 8-1. 부분 롤백 vs 전체 롤백 선택

본 묶음은 36 커밋 일괄 운영 배포라 회귀 발생 시:
- **부분 롤백 (권장)**: 회귀 일으킨 단일 PR (예: #195 컬럼 폭 조정)만 `git revert <merge-sha> -m 1` 후 main push → Vercel 재배포
- **전체 롤백 (예외)**: 응모 취소·NG 번들·브랜드 서베이 셋 중 어느 영역이라도 데이터 손상 발생 시 main 을 본 묶음 직전 시점으로 reset(force push 사용자 명시 승인 필수). DB 마이그레이션은 그대로 두고 코드만 되돌리는 게 우선

---

## 9. 다음 작업 큐 (운영 배포 후)

| # | 일감 | 시작 조건 |
|---|---|---|
| 1 | **응모 취소 PR-E + NG-PR-E 약관·정책 묶음** (`/약관확인` + TERMS §N + PRIVACY 수집항목 + Notion 동기화) | 본 운영 배포 직후 (코드 변경 없는 문서·정책 작업) |
| 2 | **응모 취소 PR-D — 일일 요약 메일** (Edge Function `notify-application-cancelled-daily` + pg_cron + 메일 템플릿 3종 정식 커밋) | 별도 PR. dev 에 untracked 상태인 메일 HTML 검토 후 |
| 3 | **NG-PR-F (legacy `campaigns.ng` 컬럼 DROP)** | 본 묶음 운영 배포 1주 관찰 후 (회귀 없음 확인) |
| 4 | **리치 에디터 이미지 첨부 강화** | 사양 재검토 → 개발 인수인계 후 |
| 5 | **신청 관리 행 ⋮ 더보기** (사양 미확정) | admin-split 머지 후 backlog |

---

## 10. PR 작성 시 본문 템플릿 (dev → main)

```
release: app cancel + admin email subs + ng bundles + brand survey polish

## Summary

본 PR 은 dev 에 쌓인 36 커밋을 운영(main) 으로 한 번에 올립니다.

### 응모 취소 (인플루언서 본인)
- 단계별 동의·사유 분기 (모집/구매/방문/게시/기타)
- partial unique index 로 cancelled 행 제외 → 같은 캠페인 재응모 허용
- 인플루언서: 응모이력 ⋮ 메뉴 + 「取消」 탭 + i18n 키 30+
- 관리자: 상태 필터·배지·cancel_phase 라벨·상세 모달 보조 행·위반 등록 prefill·엑셀 4컬럼

### 관리자 메일 수신 설정 분리
- 메일 종류별 구독 모달 + 「메일받기」 칩
- 기존 `admins.receive_brand_notify` 단일 컬럼 → `admin_email_subscriptions` 테이블로 이관
- `get_subscribed_admin_emails(메일종류코드)` RPC 경유 수신자 조회

### NG 사항 번들화
- ng_sets 테이블 + caution_sets 패턴 미러
- 캠페인 등록·편집 폼 NG 번들 카드 + 편집 모달 + 미리보기 한·일 토글
- 기준 데이터 NG 탭 번들 CRUD 전환
- 변경 이력 모달에 NG diff 확장 (super_admin 한정)

### 브랜드 서베이(광고주 신청 관리) 정비
- 상태 드롭다운 → 11개 가로 탭 (PR #182)
- 신규 등록 모달 880→1080→80vw 단계적 확대
- 모집비(recruit_fee_krw) 견적 합산 트리거 추가 (migration 111)
- 견적서 URL + 오리엔트 전달 시각·URL 컬럼 추가 (migration 112)
- 카운트 단위 정리, 셀 보더, 컬럼 폭 조정 등 UI 정비 9건
- 🔴 stale state 회귀 긴급 패치 (436940b) + buildId 자동 리로드 가드 (411c9bd)

## 운영 배포 체크리스트

- [ ] Supabase 마이그레이션 9개(103~109, 111, 112) 운영 SQL Editor 적용 (110 은 이미 적용)
- [ ] 검증 SQL §2 의 7개 SELECT PASS
- [ ] Edge Function `notify-brand-application` 운영 재배포 (`get_subscribed_admin_emails` RPC 참조)
- [ ] 스모크 테스트 §7 항목 모두 PASS
- [ ] 영업·관리자 측 「화면 한 번 자동 새로고침될 수 있음」 사전 안내

## 본 묶음 제외 항목

- 응모 취소 PR-D (일일 요약 메일 Edge Function + pg_cron) — 별도 PR
- 응모 취소 PR-E + NG-PR-E (약관·정책) — 별도 PR
- NG-PR-F (legacy `campaigns.ng` DROP) — 본 배포 1주 후

## Test plan

- 인플루언서 본인 취소 + 관리자 화면 노출 + 위반 등록 prefill
- NG 번들 등록·캠페인 적용·미리보기·변경 이력 diff
- 메일 수신 칩 + 광고주 신청 알림 1건
- 브랜드 서베이: 11개 탭 + 80vw 모달 + 모집비 견적 합산 + 견적/오리엔트 URL + 일반 브라우저 새로고침 회귀 없음
- buildId 자동 리로드: 기존 탭에서 1회 자동 새로고침 후 정상

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

---

## 11. 시점 정리

```
[현재] 2026-05-12 — dev 36 커밋 누적, NG-PR-D 까지 dev 완료

운영 배포 (오늘 또는 사용자 결정 시점)
  1. dev 브랜치에서 main 으로 PR 작성 (제목·본문 §10 템플릿)
  2. 운영 Supabase 마이그레이션 9개 SQL Editor 적용 (§2)
  3. 검증 SQL §2 의 7개 SELECT PASS 확인
  4. reverb-qa-tester 한 번 더 (운영 배포 직전, 본 묶음 규모 고려 → full 권장)
  5. 사용자 명시 머지 → Vercel 자동 배포
  6. Edge Function `notify-brand-application` 운영 재배포 (§3)
  7. 스모크 테스트 §7 모두 PASS
  8. 영업·관리자 측 사전 안내

운영 배포 직후 (별도 묶음)
  ├ 응모 취소 PR-E + NG-PR-E 약관·정책 (`/약관확인`)
  └ 응모 취소 PR-D (일일 요약 메일 Edge Function + pg_cron + 메일 템플릿 3종)

운영 배포 1주 후
  └ NG-PR-F (legacy `campaigns.ng` DROP)
```

---

## 12. 작업 흔적 정리 (운영 배포 전 점검)

운영 배포 PR 작성 직전, untracked 파일 정리:

- `docs/specs/2026-05-12-HANDOFF-application-cancel-and-admin-email-subs.md` — 이미 모두 머지된 일감 인수인계서. **PR 본문 「Closes/Refs」에 인용 후 dev 별도 PR 로 commit** 또는 보존용으로 남길지 결정
- `docs/specs/2026-05-12-PROD-DEPLOY-checklist.md` — 본 문서. 운영 배포 PR 본문 작성에 그대로 활용
- `docs/specs/2026-05-12-brand-app-status-tabs.md` / `2026-05-12-ng-sets.md` / `2026-05-12-rich-editor-image-upload.md` — 사양서. 본 묶음 또는 별도 docs PR 로 dev commit
- `docs/email-templates/application-cancelled-daily.*.html` — 응모 취소 PR-D 작업 시 정식 commit. 본 묶음 제외
- `supabase/migrations/084_security_advisor_cleanup.sql` — **출처 불명**. 운영 적용 여부·작성 의도 사용자 확인 필요. 본 묶음 제외
- `supabase/seed/dev_monitor_v2_validation.sql` — 개발용 시드. 본 묶음 제외

untracked 파일은 PR 에 포함되지 않으므로 본 묶음 운영 배포 자체에 영향 없음 — 다만 dev 브랜치 위생을 위해 별도 commit 또는 명확한 정리 권장.
