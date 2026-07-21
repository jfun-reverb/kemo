# 전체 일관성 감사 후속 — 정합성 수정 6종

**작성일:** 2026-07-22
**작성 주체:** 고문 세션 (읽기 전용 감사 → 기획 계획 → 사양서)
**배경:** 사용자 요청("코드 및 전체 검수 — 결정된 표시·데이터 처리 방식이 다른 기능에도 지켜지는지, 미적용된 것 조사")으로 5개 축 병렬 감사 실시. 확정 규칙이 대부분 일관되게 지켜지고 있었고, 주변부에서 6종의 편차가 발견됨.

---

## 현재 상태 (2026-07-22 기준)

### 감사 결과 요약 (5개 축)
- **데이터 접근**(1000행 페이지네이션·`.maybeSingle`·익명 RPC·`search_path`): 확정 위반 0건.
- **프론트 표시**(채널 비교·썸네일 폴백·XSS 이스케이프·DOM 인덱스·i18n): 신규 코드 전부 준수, 기존 아이콘 4건만 저위험.
- **목록 페인**(지연 로딩 sentinel·페인 구조·알림 kind 분기·URL 보정): 위반 0건.
- **모달 갱신**(refreshPane): 신청 페인 1건 미등록(직접 재렌더로 기능은 정상).
- **인증 판정·감사 격리·낙관적 락·감사 이력**: 핵심 로직 건강, 주변부 4건 편차.

### 확정 규칙이 잘 지켜지는 핵심 영역
정산 인증판정(헬퍼 단일화 `_settlement_cert_candidates`)·검수대기 배지(마이그레이션 248→249→250 수렴)·운영현황 진행바 판정 단일 소스·낙관적 락·감사용 격리(서버 집계)는 모범적으로 일관됨.

### 이 사양과 충돌 가능성 있는 기존 동작
- **정산 기능은 운영에서 잠금 상태**(`settlement_settings.cutoff_at=NULL`, `influencer_visible=false`) → 운영 `settlements` 행 사실상 0건. **작업 묶음 2는 활성 버그가 아니라 정산 정식 오픈 전 예방 항목.** dev에는 정산 행 있어 개발서버 재현 가능.
- `fetchDeliverablesByCampaign`(storage.js:910)는 `user_id`만 select, `influencers.is_audit` 미포함 → 작업 묶음 1의 감사 격리는 별도 감사용 id 조회 필요. `admin-brand-ops.js:210·214`에 이미 감사용 id 집합(`_auditIds`) 조회 패턴 존재 → 재사용.
- CLAUDE.md 명시 "캠페인 삭제 시 관련 applications 함께 삭제(cascading)" 동작 → 작업 묶음 2에서 부모 삭제 연결을 바꾸면 정면 충돌하므로, 확정 방향(사전 체크)은 이 동작을 건드리지 않음.

---

## 의심·경우의 수 (planner 반대론자 검증)

각 항목 「구현 결과」에서 개발 세션이 재확인할 것.

- **작업 묶음 1 (인증성공 막대 격리)**: ① `_auditIds` 비동기 로드 순서 보장 확인 ② 진행현황 화면(`openCampApplicants`)도 같은 `countCertSuccess` 사용 — 동일 누락일 수 있으므로 범위 포함 여부 확인(감사 지목은 운영현황만) ③ 감사용 0명 브랜드는 무변화 → 감사용 응모 있는 캠페인으로만 회귀 검증 가능.
- **작업 묶음 2 (정산 삭제)**: ① 사전 체크가 한 경로만 커버하고 `delete_admin_completely` 누락 시 여전히 불투명 오류 → 삭제 경로 전수 grep 필요 ② 사전 체크와 실제 삭제 사이 정산 생성 race(SECURITY DEFINER 트랜잭션이라 실무상 낮음).
- **작업 묶음 3 (영수증 이력)**: ① `deliverable_id` NOT NULL 제약과 "비우기(SET NULL)" 충돌 → nullable 전환 + 조회 인덱스 영향 점검 ② 계정 완전삭제(개인정보 파기)에선 이력 보존이 파기 의무와 상충 가능 → 경로별 정책 분기 검토 ③ `deliverable_events`도 동일 CASCADE(기존 한계) — 이번 범위는 영수증 이력만.
- **작업 묶음 5 (엑셀 과대표기)**: ① 채널 인자 추가 시 gifting/visit 호출부 회귀 → optional 처리 ② 정상 단일채널 리뷰어가 이 경로로 들어오는지 라우팅 실측 없이 고치면 정상 건도 오표기 ③ 가구매(영수증만) 분기는 건드리지 않기.

---

## 설계 (확정 방향)

### 작업 묶음 1 — 저위험 정합 (데이터베이스 변경 없음)
1. **운영현황 인증성공 막대 감사 격리** (`admin-brand-ops.js:286·297`): `_auditIds` 집합을 `hydrateCampCertBars`에 전달, `fetchDeliverablesByCampaign` 결과를 `filter(d => !auditIds.has(d.user_id))` 후 `countCertSuccess`. 공용 함수 시그니처 변경 대신 호출부 클라 필터(회귀 최소).
4. **신청 페인 갱신 매핑 등록** (`shared.js:523` PANE_REFRESHERS): `applications` 키 추가. 갱신 함수명은 admin-applications.js에서 grep 확인.
5. **엑셀 과대표기** (`admin-excel.js:131`): `_excelCertStatusKo` 리뷰어 비-가구매 분기가 채널 0개(legacy_no_channel) 케이스를 인증성공에서 배제, `computeCertStatus`와 정합. 호출부(809·1258) 라우팅 실측 후 최소 침습안.
6. **저위험 묶음**: (a) 아이콘 `translate="no"`+`notranslate` 4곳(`application.js:76·77·528`, `ui.js` download) (b) `sales/orient.html:697` `normalizeUrl`을 shared.js `normalizeUrlInput` 위험 스킴·보정 규칙과 인라인 동기화(정적 배포라 통짜 import 불가) (c) `admin-brand.js:3975` stale 주석 정정.

### 작업 묶음 2 — 정산 삭제 교착 (사전 체크 + 명확한 안내)
- **확정 방향(d)**: 삭제 연결 구조(외래 키)는 무변경. `delete_admin_completely` 등 정산으로 연쇄되는 삭제 함수에 "정산 존재 시 불투명 오류 대신 명확 안내(정산 걸린 대상은 삭제 불가)" 사전 체크 추가.
- **신규 마이그레이션 1개** — 삭제 함수(SECURITY DEFINER)에 사전 체크 추가. 번호는 개발 세션이 생성 시 확정.
- 정산 미가동이라 급하지 않음. 정산 정식 오픈 전 처리, 정식 오픈 시 삭제 차단(방향 c) 재검토.

### 작업 묶음 3 — 영수증 이력 보존 (스냅샷 보강)
- **확정 방향(b)**: 결과물이 삭제돼도 `receipt_edit_history` 행은 보존. 삭제된 결과물 식별용 스냅샷 컬럼 추가 + 삭제 연결을 CASCADE→SET NULL.
- **신규 마이그레이션 2개** — ①스냅샷 컬럼 추가(삭제된 결과물 식별용) + `deliverable_id` nullable 전환 → ②외래 키를 SET NULL 재정의. ①이 ②보다 먼저.
- 계정 완전삭제(개인정보 파기) 경로는 이력도 파기가 맞을 수 있음 → 경로별 정책 분기 검토(구현 시 결정).

---

## PR 분할

- **작업 묶음 1 (저위험 정합)**: 항목 1·4·5·6. 마이그레이션 없음. reverb-reviewer 후 dev 배포. (1번은 개발서버에서 감사용 응모로 검증)
- **작업 묶음 2 (정산 삭제)**: 항목 2. 마이그레이션 1개. reverb-supabase-expert 필수. 정산 오픈 전 처리(급하지 않음).
- **작업 묶음 3 (영수증 이력)**: 항목 3. 마이그레이션 2개. reverb-supabase-expert 필수.
- 작업 묶음 2·3은 각각 독립 설계라 묶지 않음. 단 둘 다 `supabase/migrations` 순차 번호라 **한 세션에서 순차 생성**(멀티세션 번호 충돌 방지).

---

## 사용자 확인 필요 → 확정됨 (2026-07-22)

- **정산 삭제 교착**: 「사전 체크 + 명확한 안내」(방향 d) 선택.
- **영수증 이력 유실**: 「이력 보존 + 스냅샷 보강」(방향 b) 선택.

---

## 구현 결과

**구현일:** 2026-07-22
**작업 범위:** 작업 묶음 2·3 (작업 묶음 1·5·6은 별도 세션/범위)

### 마이그레이션 번호 확정
- **251** `251_settlement_delete_guard.sql` — 작업 묶음 2 (정산 삭제 교착)
- **252** `252_receipt_edit_history_snapshot_columns.sql` — 작업 묶음 3 (1/2, 스냅샷+nullable 전환)
- **253** `253_receipt_edit_history_cascade_to_set_null.sql` — 작업 묶음 3 (2/2, FK 재정의+계정삭제 분기)

### 작업 묶음 2 — 초안 대비 변경 사항
- **삭제 경로 전수 확인 결과**: 실질적으로 사전 체크가 필요한 지점은 2곳뿐 — ① `delete_admin_completely`(031, RPC) ② `dev/js/admin.js`의 `executeDeleteCampaign()`(RPC 아님, 클라이언트 직접 `db.from('applications'/'campaigns').delete()`). `delete_brand`(174·191)·`delete_orient_sheet`(199·239)는 이미 자체 검증(연결 0건/신청 0건 확인)으로 안전함을 확인, 손대지 않음.
- **초안과 다른 구현 방식**: 초안은 "정산으로 연쇄되는 삭제 함수에 사전 체크 추가"(함수 단위)를 가정했으나, `executeDeleteCampaign()`은 RPC가 아니라 함수에 체크를 못 심는다. 대신 **`applications`/`campaigns`/`influencers` 3개 테이블에 공용 BEFORE DELETE 트리거 1개**(`block_delete_with_settlements()`)를 걸어, RPC 경유든 클라이언트 직접 DELETE든 동일하게 방어하도록 설계를 변경했다. 외래 키 구조(`settlement_events` RESTRICT 포함)는 무변경 — 방향(d) 그대로.
- **차단 대상 정산 상태**: 상태 무관 전체(cancelled 포함) 차단으로 확정. 근거: `settlement_events`는 정산 생성 시(마이그레이션 218·231) 상태와 무관하게 항상 `create` 이벤트가 INSERT되므로, 어떤 상태의 정산이든 cascade가 도달하면 반드시 RESTRICT에 부딪힌다 — "안전을 위한 선택"이 아니라 구조적으로 유일하게 맞는 조건.
- **클라이언트 매핑**: `dev/js/admin-core.js` `friendlyError()`에 `settlement_exists_cannot_delete` 코드어 매핑 추가. `dev/js/admin.js` `executeDeleteCampaign()`은 기존에 확인하지 않던 `applications` 삭제 결과의 에러를 확인하도록 수정(잠재 버그 겸 수정 — 이전엔 이 단계 실패가 조용히 무시되고 캠페인 삭제 단계에서 우연히만 드러났음). `admin-accounts.js`의 `executeDeleteCompletely()`는 기존 `friendlyError()` 경유 toast로 충분히 커버되어 별도 수정 없음.

### 작업 묶음 3 — 초안 대비 변경 사항
- **스냅샷 컬럼 4종 확정**: `deliverable_id_snapshot`(NOT NULL, 영구)·`application_id_snapshot`/`campaign_id_snapshot`/`user_id_snapshot`(NULL 허용, FK 없음 — 정보용). `deliverables` 테이블의 3개 연관 컬럼 그대로 재사용(신규 개념 도입 없음).
- **BEFORE INSERT 트리거로 자동 채움**: `update_receipt_admin`(128) RPC는 무변경 — `snapshot_receipt_edit_history()` 트리거가 `NEW.deliverable_id`로부터 나머지를 조회해 투명하게 채운다.
- **경로별 정책 분기 구현**: `delete_admin_completely`(031)를 253에서 재정의해, `applications` 삭제 직후 `receipt_edit_history WHERE user_id_snapshot = target_auth_id`를 명시적으로 DELETE(개인정보 파기 우선 — SET NULL로 잔존시키지 않음). 결과물 개별 하드 삭제 경로(160·162·183)는 FK 재정의(CASCADE→SET NULL)만으로 자동 커버(이력 보존).
- **251과의 순서 정합 확인**: `delete_admin_completely`는 `applications` 삭제를 함수 맨 앞에서 수행하므로, 정산이 하나라도 있는 계정은 251 트리거가 그 시점에 함수 전체를 중단시킨다 — 253이 추가한 `receipt_edit_history` 명시 삭제 줄은 항상 "정산이 없는" 계정에서만 실행됨을 확인(충돌 없음).
- **부가 개선(범위 외 자연 확장)**: `dev/lib/storage.js`의 `fetchReceiptEditHistory()`를 `deliverable_id` 단일 매칭에서 `deliverable_id`/`deliverable_id_snapshot` 양쪽 매칭(`.or()`)으로 변경 — 이력 보존만 하고 조회 경로가 없으면 사실상 죽은 데이터가 되므로, 최소 비용으로 조회 가능하게 함. 현재 UI는 살아있는 결과물의 이력만 열람하므로 즉각적인 화면 변화는 없음(회귀 없음).

### 구현 중 추가 기술 결정 (초안에 없던 것)
- **트리거 함수는 반드시 `SECURITY DEFINER`** — `campaign_manager`처럼 `settlement.view` 권한이 `hidden`인 세션이 삭제를 시도할 때, `SECURITY INVOKER`였다면 `settlements` RLS(`settlements_select_admin`)에 걸려 정산이 있어도 count=0으로 오판해 체크가 무력화됐을 것. 이 부분은 초안에 없던 반대론자 검증 항목이라 구현 중 발견·반영.
- **FK 제약 이름을 하드코딩하지 않고 동적 조회 후 DROP** — 128 작성 당시 인라인 `REFERENCES` 선언이라 실제 제약 이름이 문서화돼 있지 않아, `pg_constraint` 조회로 안전하게 처리(추측 금지 원칙).
- **미해결/후속 과제**: 삭제된 결과물의 영수증 이력을 관리자 화면에서 열람하는 UI(스냅샷 기반 표시)는 이번 범위에 포함하지 않음 — 현재 UI 진입 경로 자체가 "살아있는 결과물의 검수 모달"이라 즉시 필요하지 않다고 판단(사양서 §의심 3의 미해결 질문). 필요해지면 `deliverable_id_snapshot` 기준 별도 조회 화면을 추가 설계.

### 검증 상태
- 정적 검증만 수행(서브에이전트 권한 범위 — DB 미실행). `node --check`로 수정된 JS 3개 파일 구문 확인 완료, `dev/build.sh` 로컬 빌드 성공 확인. **개발서버 SQL 적용·실제 트리거 발동 검증은 아직 수행되지 않음** — 다음 세션에서 각 마이그레이션 파일 상단의 검증 SQL을 1단계씩 실행할 것.
