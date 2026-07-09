# 오리엔시트 자체 식별번호 (B0001-O001) — 신청 번호 의존 분리

**작성일:** 2026-06-30
**작성 주체:** 기획 세션
**상태:** 기획 초안 — 방향·번호 형식 사용자 확정(2026-06-30) / 메일 표시 방식 §8 사용자 확인 필요
**관련:** 메모리 `project_orient_submit_notification`(운영 가동된 알림 메일) · `project_orient_sheet` · `project_brand_survey_future`

---

## 0. 한 줄 요약

오리엔시트는 자체 식별번호가 없어 **연결된 광고주 신청 번호(`B0001-A001`)로 식별·표시**해 왔다. 서베이 공개 접수를 막으면 **신청 없이 브랜드에 직접 발급하는 오리엔(비-서베이)이 주 흐름**이 되는데, 그 경우 식별 번호가 없다(메일에 `-`). 오리엔에 **자체 번호 `B0001-O001`(브랜드의 N번째 오리엔)**를 부여해 신청 번호 의존에서 분리한다.

---

## 1. 현재 상태 (planning.md 규칙 A — 검증 완료)

### 관련 코드·DB·UI 진입점
- **오리엔시트 자체 번호 = 없음**(마이그레이션 186 테이블에 번호 컬럼 없음, 확인). 식별은 `brand_id`(필수) + `application_id`(선택)로만.
- **브랜드 신청 채번**: `brand_applications.application_no` = `B{brand_seq 4자리}-A{app_seq 3자리}` 계층 채번(`generate_brand_application_no` 마이그레이션 078 → 089·090 계층화). 캠페인 `campaign_no` = `B{brand}-A{app}-C{camp}`의 앞부분과 동일 체계.
- **채번 카운터(재사용 참고)**: `brand_seq_counter`(싱글톤, 브랜드별 brand_seq) · `application_campaign_counter`(브랜드/신청별 순번) 등 — SECURITY DEFINER 트리거 전용. 오리엔 순번 카운터를 이 패턴으로 신설.
- **발급 2경로**(광고주 여정 재설계 사양서 §54·§85·§127): (a) 신청 상세에서 발급 → `application_id` 채움 → 메일 `application_no` 표시 / (b) **신청 없이 브랜드 관리에서 직접 발급(비-서베이)** → `application_id` NULL → 메일 `-`. `create_orient_sheet(p_brand_id, p_application_id DEFAULT NULL)`(마이그레이션 195).
- **운영 가동된 알림 메일**(2026-06-30, main): `notify-orient-submitted`(개별 즉시, `application_no` 표시·없으면 `-`) + `notify-brand-daily-digest`(일일 보고). `index.ts`가 `record.application_id` 있을 때 `brand_applications.application_no` 조회.
- **관리자 화면**: `dev/js/admin-orient.js`(발급·조회 목록·발급 모달·상세 모달). 현재 자체 번호 표시 없음.

### 이 제안과 충돌 가능성 있는 기존 동작
- ⚠️ **운영 가동 중 변경**: 알림 메일 2개가 이미 운영 가동 → 표시를 자체 번호로 바꾸면 메일 함수·템플릿 + `admin-orient.js` + **운영 재배포** 동반.
- ⚠️ **기존 발급분 백필**: 이미 발급된 오리엔(개발서버 등)에 자체 번호 소급 부여 필요(없으면 옛 행은 번호 공백).
- **`application_id` 연결은 유지**: 자체 번호는 식별 수단을 **추가**하는 것. 신청 연결(영업 2단계 추적)은 그대로 둠 — 데이터 모델 변경 아니라 컬럼 1개 추가.
- 그 외 충돌 없음(확인 완료).

### 미해결 백로그·관련 작업
- 브랜드 서베이 공개 제출 차단(`docs/specs/2026-06-30-brand-survey-submit-lock.md`) — 본 작업의 동기(비-서베이 직접 발급이 주 흐름이 됨).
- "브랜드 서베이" 라벨과 실체(`brand_applications`=광고주 신청) 불일치로 인한 인식 혼란 — 별도 정리 과제(본 사양 밖).

---

## 2. 의심·경우의 수 (planning.md 규칙 B — 반대론자 모드)

### 깨질 수 있는 경우의 수
1. **(채번 동시성)** 같은 브랜드에 오리엔을 동시 발급하면 순번 충돌 → 캠페인 채번 카운터 패턴(SECURITY DEFINER + advisory lock 또는 카운터 테이블) 재사용으로 방어.
2. **(백필 일관성)** 기존 발급 오리엔에 발급순(`created_at`)대로 순번 부여 → 브랜드별 정렬해 1부터. 운영/개발 양쪽.
3. **(생성 시점)** 발급 시(`create_orient_sheet`) 부여 vs INSERT 트리거 — 발급 경로가 함수 1곳이면 함수 안 부여가 단순. 비-서베이·신청연결 양쪽 모두 같은 함수 경유인지 확인 필요(개발 단계).
4. **(메일 표시 혼란 — UX)** 자체 번호와 연결 신청 번호를 둘 다 보이면 또 헷갈림 → §8에서 표시 방식 결정(자체 번호 주, 신청 번호는 라벨 명확화 후 보조 또는 제거).
5. **(브랜드 삭제·병합 영향)** `merge_brands`/`delete_brand`(마이그레이션 174·175)가 brand_seq를 다루는데, 오리엔 자체 번호가 brand_seq 기반이면 병합 시 번호 정합 검토 필요.
6. **(운영/개발 동기화)** 컬럼·카운터·트리거(데이터베이스) + 메일 함수 + 화면(코드) + 백필 → 운영 반영 시 전부.

### 현재 구현과 어긋나는 지점
- 운영 가동된 메일 표시 변경 1건(§1) — 운영 재배포로 처리. 그 외 충돌 없음(확인 완료).

### 의도 모호점
- 자체 번호는 **신청 번호 의존을 끊는 식별 수단**(사용자 확정). 신청 연결 자체는 유지.
- 형식 = **`B0001-O001`**(브랜드별 N번째, 캠페인 번호와 일관, 사용자 확정 2026-06-30).

---

## 3. 확정 설계 결정 (사용자 확인 완료 2026-06-30)

| # | 항목 | 결정 |
|---|---|---|
| ① | 목적 | 오리엔 식별을 **신청 번호 의존에서 분리** |
| ② | 형식 | **`B0001-O001`** = `B{brand_seq 4자리}-O{orient_seq 3자리}`(브랜드의 N번째 오리엔) |
| ③ | 연결 유지 | `application_id`(신청 연결)는 **그대로** — 자체 번호는 추가 식별 수단 |
| ④ | 채번 패턴 | 캠페인 계층 채번 카운터 패턴 재사용(동시성 방어) |
| ⑤ | 백필 | 기존 발급 오리엔에 발급순 소급 부여(운영·개발) |
| ⑥ | 표시 교체 | 알림 메일 2개 + `admin-orient.js`에 자체 번호 표시(운영 재배포 동반) |
| ⑦ | 메일 신청번호 | **연결 신청 번호(`application_no`) 표시 제거** — 자체 번호만. "서베이 경유" 오해 소지 차단 |

---

## 4. 데이터 모델

### `orient_sheets` 컬럼 1개 추가
| 컬럼 | 타입 | 설명 |
|---|---|---|
| `orient_no` | text | 자체 식별번호 `B0001-O001`. 발급 시 생성. UNIQUE |

### 채번 카운터 (캠페인 패턴 재사용)
- 브랜드별 오리엔 순번 카운터 — `application_campaign_counter` 등 기존 패턴 미러. SECURITY DEFINER 트리거/함수 전용.
- `brand_seq`는 `brands.brand_seq` 재사용(앞자리).

### 생성 위치
- `create_orient_sheet`(발급 함수, 마이그레이션 195) 안에서 `orient_no` 생성·INSERT (발급 경로가 이 함수 1곳이면 단순). 또는 INSERT 트리거(`generate_brand_application_no` 패턴). → 개발 결정.

### 백필
- 기존 행: 브랜드별 `created_at` 정렬 → `O001`부터 부여(마이그레이션 백필 SQL). 운영·개발 양쪽.

---

## 5. 표시 교체

### 5-1. 알림 메일 (`notify-orient-submitted` · `notify-brand-daily-digest`)
- 현재 `application_no`(연결 신청, 없으면 `-`) 표시 → **`orient_no`를 주 식별로** 표시.
- 연결 신청 번호(`application_no`)는 §8 결정에 따라 보조 표시(라벨 명확화) 또는 제거.
- 운영 가동 중 → 함수·템플릿 수정 후 **운영 재배포**(`scripts/sync-email-templates.sh` 동기화 포함).

### 5-2. 관리자 화면 (`admin-orient.js`)
- 발급·조회 목록·상세에 `orient_no` 열/필드 추가.

---

## 6. 약관·정책 영향 (policy.md 체크)

- 내부 식별번호 추가 — 개인정보 수집·외부 제공 없음. 약관 영향 없음(확인).

---

## 7. PR 분할 (개발서버 먼저, 시퀀셜)

> 마이그레이션 번호는 개발 세션이 생성 시점 확정 후 「구현 결과」에 기록.

- **PR 1 — 채번 + 백필**: `orient_sheets.orient_no` 컬럼 + 카운터 + 생성(함수/트리거) + 기존 행 백필(마이그레이션 ①~②). 화면·메일 없음.
- **PR 2 — 표시 교체**: 알림 메일 2개(함수·템플릿) + `admin-orient.js` 표시 + 운영 재배포.

---

## 8. 사용자 확인 — 확정/잔여 (2026-06-30)

1. **메일 연결 신청 번호 처리** — ✅ 확정: **자체 번호(`orient_no`)만 표시, 연결 신청 번호(`application_no`) 제거**(§3 ⑦). "서베이 경유" 오해 소지 차단. (`application_id` 데이터 연결은 유지 — 표시만 제거.)
2. **생성/백필 방식** — 함수 부여 vs 트리거, 백필 정렬(발급순) — 개발 세션 결정 인계.

---

## 9. 구현 결과

### PR 1 — 채번 + 백필 (DB)

**구현일:** 2026-06-30
**마이그레이션:** `supabase/migrations/205_orient_self_numbering.sql` (단일)
**브랜치:** `feature/orient-self-numbering` → dev

- **발급 경로 단일성 확인**: `create_orient_sheet(uuid, uuid DEFAULT NULL)`(마이그195)가 유일한 INSERT 경로(익명 함수 3종은 조회·수정 전용) → **함수 안 채번** 채택(트리거 불필요, RLS WITH CHECK 가 직접 INSERT 이미 차단).
- **신규 테이블** `brand_orient_counter`(`brand_id` PK FK CASCADE, `last_seq`) — `brand_application_counter`(088) 패턴 미러, RLS SELECT 관리자, 직접 UPDATE 금지.
- **컬럼** `orient_sheets.orient_no text` — NULL 허용 추가 → 백필 → NOT NULL + UNIQUE.
- **백필**: 같은 트랜잭션 DO 블록, 브랜드별 `created_at ASC, id ASC` 정렬 O001부터, `orient_no IS NULL` 한정(멱등), 카운터 `GREATEST` 동기화. 누락 시 NOT NULL 전환에서 롤백돼 즉시 감지.
- **발급 함수 수정**: `pg_advisory_xact_lock(hashtext(brand_id))` + 카운터 `ON CONFLICT DO UPDATE` 원자 증가(동시성 이중 방어, 090 패턴). `orient_no = 'B'||lpad(brand_seq,4)||'-O'||lpad(seq,3)`. 반환 jsonb 기존 키(success/id/token/token_expires_at) 유지 + `orient_no` 추가(하위호환).

### 초안 대비 변경 사항 (PR 1)
- 생성 위치: 트리거 후보 중 **함수 내 채번** 확정(발급 단일 경로 + RLS 차단).
- 신규 reason `brand_seq_missing` 반환(브랜드에 brand_seq 없을 때) — `admin-orient.js osReasonText` 라벨은 PR2에서 추가(reviewer 경고①).

### 운영 적용 전 점검 (reviewer 경고②)
운영 SQL Editor 적용 직전 아래로 `brand_seq` NULL 브랜드의 오리엔 행이 0건인지 확인(0건이어야 백필 안전):
```sql
SELECT b.id, b.name, b.brand_seq, COUNT(os.id) AS orient_count
  FROM public.brands b JOIN public.orient_sheets os ON os.brand_id = b.id
 WHERE b.brand_seq IS NULL GROUP BY b.id, b.name, b.brand_seq;
```

### 미해결·다음
- PR 2(표시 교체): 메일 2개(notify-orient-submitted·notify-brand-daily-digest) 신청번호 → `orient_no`, `admin-orient.js` 목록·상세 표시 + `osReasonText` 에 `brand_seq_missing` 라벨. ⚠️ 메일 운영 가동 중 → 운영 재배포 동반(사용자 확인).
- merge_brands 후 source 오리엔 이관·O999 초과는 별도 과제(현재 미발생).
