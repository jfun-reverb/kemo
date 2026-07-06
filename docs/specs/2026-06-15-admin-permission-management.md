# 관리자 권한 설정 화면 (동적 역할 기반 권한 제어) — 기획 사양서

**작성일:** 2026-06-15
**작성 세션:** 기획/설계
**배경:** 관리자 등급별 권한이 코드·서버 정책에 하드코딩돼 흩어져 있음(감사: `docs/specs/2026-06-15-admin-permission-matrix.md`). super_admin이 화면에서 등급별 권한(쓰기/읽기/숨김)을 직접 설정할 수 있게 하는 동적 권한 관리 도입.
**선행 문서:** 권한 현황 매트릭스(`2026-06-15-admin-permission-matrix.md`) — 이 사양의 「현재 상태」이자 1단계 **기본값 시드**.

---

## ⚠️ 가장 중요한 전제 (보안 — 반복 강조)

**화면 설정 토글만으로는 실제 차단이 되지 않는다.** 권한의 진짜 방어선은 서버(행 단위 보안 정책 RLS)다. 1단계(화면 제어)만 배포된 상태에서는 **설정값이 메뉴·버튼 노출만 바꾸고, 데이터는 서버에서 여전히 열려 있다**(예: 민감정보 갭1 미해결). 따라서:
- 1단계 화면에 **「이 설정은 화면 표시 제어이며, 데이터 접근 차단은 2단계에서 적용됩니다」 경고 문구 필수.**
- 민감정보 등 **실제 차단이 필요한 기능은 2단계 서버 연동 완료 전까지 "설정상 차단"으로 오인하지 않게** 표기.

---

## 현재 상태 (작성일 기준)
- 권한 판정: 서버 `is_admin()`/`is_super_admin()`/`is_campaign_admin()`(하드코딩), 클라 `isCampaignAdminOrAbove()` 등. 전수 매트릭스는 선행 문서 참조.
- 등급 3단계: super_admin > campaign_admin > campaign_manager (`admins.role`).
- 메뉴 노출 분기는 `admin-accounts.js:186`(기준데이터·FAQ만 campaign_admin 이상), 나머지 전 관리자 공통.
- **동적 권한 테이블·설정 화면은 없음**(전부 코드 상수/RLS).
- 관련 갭: 갭1(인플 민감정보 서버 노출), 갭3(search_path) — 선행 매트릭스 문서.

## 의심·경우의 수 (반대론자 모드 — 사양에 박힌 위험)
1. **(보안) 화면 토글 ≠ 실제 차단** — 위 전제. 1단계 단독은 보안 착각 위험. → 경고 문구 + 2단계 서버 연동으로만 실차단.
2. **(잠금 사고) super_admin 자기 권한 축소 → 잠금** — super_admin이 자기 등급 권한을 끄면 복구 불가. → **super_admin은 항상 전권 고정, 설정 대상에서 제외(토글 불가).**
3. **(범위 폭발) 전 기능×등급 동적화는 초대형** — 한 번에 전 RLS 재작성은 고위험. → 단계적(1단계 화면, 2단계 핵심만 서버).
4. **(데이터 일관성) 신규 기능 추가 시 설정 누락** — 새 기능이 권한 카탈로그에 없으면 기본값 미정. → **기본값 = 안전 측(미정의는 campaign_admin 이상만, 또는 super 전용). 코드에 카탈로그 단일 소스.**
5. **(UX) 비개발자 오설정 → 운영 사고** — 수십 토글 실수 위험. → 변경 시 확인 모달 + 변경 이력(audit) + "기본값으로 복원" 버튼.
6. **(UX) 캐싱·반영 지연** — 설정 변경이 다른 관리자 세션에 언제 반영되나. → 로그인/페인 진입 시 권한 재조회, 즉시 반영 아님 명시.

## 제안 / 설계

### 1. 개념
권한 매트릭스를 **DB 테이블**로 옮기고, super_admin이 설정 화면에서 등급×기능별 접근 수준(쓰기/읽기/숨김)을 변경. 클라(1단계)·서버(2단계)가 이 테이블을 참조해 분기. 기본값은 현행 매트릭스 시드라 **도입 즉시 동작 변화 없음**(현행과 동일하게 시작).

### 2. 접근 수준 (access_level — 3단계, 사용자 확정)
`write`(쓰기·전체) > `read`(읽기 전용) > `hidden`(숨김). 상위는 하위 포함.

### 3. 데이터 모델 (마이그레이션 — 착수 시 재채번, 최신 178 기준 179부터)
- **권한 카탈로그**: 기능 식별자(`feature_key`) 목록. **코드 상수 단일 소스**(`dev/lib/shared.js`) 권장 — 새 기능 추가 시 코드에 한 줄. (lookup_values로 둘 수도 있으나 기능은 코드와 강결합이라 상수 권장.) 각 항목 `{key, label_ko, category, server_enforced:boolean}`. `server_enforced`=2단계 서버 차단 적용 여부 표시.
- **신규 테이블 `role_permissions`**: `(role text, feature_key text, access_level text CHECK(write|read|hidden))`, `(role, feature_key)` UNIQUE. RLS SELECT `is_admin()`(전 관리자가 자기 권한 알아야 함), CUD `is_super_admin()`.
- **시드**: 현행 매트릭스 그대로(선행 문서). super_admin 행은 전부 `write` 고정(애초에 저장 안 하고 코드에서 항상 write 반환해도 됨 — 잠금 방지).
- **서버 판정 함수(2단계)** `has_permission(p_feature text, p_min text)`: 현재 관리자 role의 `role_permissions` 조회, super_admin은 무조건 통과. SECURITY DEFINER + `search_path=''`.
- **변경 이력** `role_permission_history`(누가/언제/무엇을 어떻게) — audit. RLS SELECT super_admin.

### 4. 1단계 — 화면 제어 + 현황 표시 (PR 1~2)
- 설정 테이블 + 카탈로그 + 시드(마이그레이션).
- 클라 헬퍼 `permLevel(featureKey)` → 현재 role의 설정값 반환(없으면 기본). 기존 `isCampaignAdminOrAbove()` 호출부를 점진 교체(또는 래핑).
- **설정 화면**(관리자 설정 하위, super_admin 전용): 기능 카탈로그를 행, 등급을 열로 하는 그리드. 각 칸 쓰기/읽기/숨김 드롭다운. super_admin 열은 잠금(write 고정·비활성). 변경 시 확인 모달 + "기본값 복원". `server_enforced=false` 기능엔 「화면 제어만」 표식.
- **현황 표시 겸용**: 같은 그리드가 읽기 전용으로도 보임(매트릭스 문서의 화면판).
- 메뉴/버튼 노출이 `permLevel` 참조하도록 전환(hidden=숨김, read=비활성/보기만, write=전체).

### 5. 2단계 — 핵심 기능 서버 차단 (PR 3~, 기능별 점진)
- `server_enforced=true` 기능부터 RLS/RPC 가드를 `has_permission()` 참조로 교체. **민감정보(갭1) 최우선** — `influencers` 민감 컬럼 마스킹 뷰 또는 등급별 RLS + `fetchInfluencers` 분리.
- 기능 하나씩 PR 분리(전수 일괄 금지). 각 PR은 supabase-expert + 스모크 + 전건/페이징 동작 대조.

### 6. 잠금 방지 (필수)
- super_admin = 항상 전권. 설정 그리드에서 super_admin 열 비활성(토글 불가).
- 최소 1명의 super_admin 보장(기존 관리자 삭제 가드와 동일 정신).

### 7. 설정 화면 접근
- **super_admin 전용**(`is_super_admin()`). campaign_admin 이하는 메뉴 미노출 + 진입 차단(서버 CUD 가드).

## PR 분할
> 1단계(PR 1·2) → 2단계(PR 3~) 점진. 1단계만으로는 실차단 없음(경고 문구 필수).
- **PR 1 — DB**: `role_permissions`+`role_permission_history`+`has_permission()`+카탈로그 상수+시드(현행 매트릭스). supabase-expert + 스모크.
- **PR 2 — 설정 화면 + 클라 분기**: super 전용 그리드(쓰기/읽기/숨김·확인모달·기본값복원·super잠금) + 현황 표시 겸용 + 메뉴/버튼이 `permLevel` 참조. 동작 변화 없음(시드=현행).
- **PR 3+ — 서버 차단 점진**: `server_enforced` 기능별로 RLS/RPC를 `has_permission` 참조로. **민감정보(갭1) 우선**. 기능당 1 PR.

## 영향 파일
- `dev/lib/shared.js`(카탈로그 상수 + `permLevel` 헬퍼), `dev/lib/storage.js`(role_permissions fetch/update RPC 래퍼)
- `dev/admin/index.html`(설정 메뉴 + 페인), 신규 `dev/js/admin-permissions.js`(그리드, build.sh 등록)
- 기존 권한 호출부(`admin-accounts.js`·각 admin-*.js)의 `isCampaignAdminOrAbove()` → `permLevel` 점진 교체
- `dev/css/admin.css`(그리드)
- 마이그레이션: `role_permissions`·`role_permission_history`·`has_permission()` (착수 시 179~ 재채번)

## 위험·검증
- 1단계 배포 후 **시드=현행이라 동작 변화 0** 확인(회귀 없음이 검증 기준).
- super_admin 잠금 시나리오(자기 권한 축소 시도 차단) 테스트.
- 2단계 각 기능: 설정 write/read/hidden별 서버 실제 차단 SQL 검증(클라 우회 시도 포함).
- 변경 이력 기록 확인. 기본값 복원 동작.
- reverb-supabase-expert(테이블·함수·RLS) + 스모크 + reverb-reviewer + reverb-qa-tester(권한 플로우).
- 약관·개인정보: 갭1 서버 차단(2단계)은 **개인정보 접근권한 최소화 강화** 방향이라 약관 영향은 유리한 변경(통지 의무 약함). 단 변경 시 `/약관확인`.

## 사용자 확인 필요 (남은 결정 — 착수 전)
1. **1단계 설정 단위 세분도**: 메뉴/페인 단위(굵게)부터 vs 동작(승인/삭제) 단위까지(세밀). 권고: **1단계는 페인/주요버튼 단위**, 세밀화는 후순위.
2. **2단계 우선순위**: 민감정보(갭1) 최우선 확정 여부 / 그다음 순서.
3. 권한 카탈로그를 코드 상수 vs lookup_values 중 어디에 둘지(권고: 코드 상수).

## 구현 결과

**구현일:** 2026-07-02 (dev 배포, 운영 미배포) / **관련 PR:** PR1 #672, PR2 조각A #673·조각B #674·조각C(이 커밋)

### PR1 (인프라, 마이그레이션 207~210)
- `role_permissions`(등급×기능 접근수준, PK(role,feature_key), role CHECK 2종=super 행 없음=잠금 방지, 시드 72행=현행 무변동) + `role_permission_history`(RLS SELECT super) + `has_permission(feature,min)`(super 통과·미등록 false) + `is_campaign_admin` search_path '' 정정(갭3, 별도 파일 210).
- 권한 카탈로그 코드 상수 `ADMIN_PERMISSION_CATALOG`(shared.js) — 최초 36개(menu.* 19 + 기능 17), 조각 B에서 `menu.permissions` 추가로 20+17=37.
- 개발 DB 적용·검증: 시드 72/36/super0, super 잠금방지 has_permission 전부 true.

### PR2 (설정 화면, 마이그레이션 211)
- **조각 A**: `update_role_permissions(jsonb)` 일괄 저장 RPC(원자·이력·denylist·낙관적 락) + menu.permissions 시드 2행.
- **조각 B**: 클라 헬퍼 `permLevel/canWrite/canRead/isHidden`(super=write·미로드 fail-open) + `fetchRolePermissions`(storage.js) + 부팅 로드(admin/app.js) + `applyLookupMenuVisibility` 를 카탈로그 menu.* 순회로 확장(id→data-pane 셀렉터).
- **조각 C**: `dev/js/admin-permissions.js` 설정 화면(#permissions, super 전용) — 등급×기능 그리드·category 접기·super 열 고정·denylist 행 잠금·server_enforced 「화면 제어만」 표식·경고 배너·일괄 저장(확인 모달)·충돌 안내. `switchAdminPane` 진입 가드(super 전용·hidden 페인 대시보드 리다이렉트, dashboard 무한재귀 방지 제외). `saveRolePermissions`(storage.js) + PANE_REFRESHERS 등록 + build.sh 등록 + admin.css 스타일.

### 초안 대비 변경 사항
- **추가**: `menu.permissions` 카탈로그·시드(설정 화면 자체 메뉴) + 클라 denylist(permissions.manage·admin.manage·menu.permissions — UI 잠금). 진입 가드는 super 직접 판정(위임 불가).
- **빠진 것**: 「기본값 복원」 버튼 — 조각 C 에서 제외(카탈로그에 등급별 기본값 72개 하드코딩은 시드 동기화 위험). 결정 2(코드 상수)는 복원 구현 시점으로 이월. 후속 조각.
- **달라진 것**: 저장을 셀 즉시 저장 아닌 **일괄 배치**(결정 1). 낙관적 락은 version 컬럼 없이 prev_level 비교(결정 4).

### 구현 중 기술 결정 사항
- 시드 = 매트릭스 §B "현재 상태" 열 그대로 → 도입 즉시 동작 변화 0(회귀 기준: campaign_manager 는 여전히 기준데이터·FAQ 만 숨김).
- 클라 메뉴 숨김 fail-open / 서버 has_permission fail-closed 대비(표시는 관대·차단은 엄격).
- 잠금 방지 = super_admin 행 미존재(CHECK) + has_permission 코드 통과 → 어떤 설정으로도 super 권한 못 끔.
- 배치 저장 시 (role,feature_key) 정렬로 잠금 순서 고정(데드락 예방).
- ✅ **PR1·PR2 운영 배포 완료(2026-07-06, PR #686)** — dev→main 전체 머지, 마이그레이션 207~211 운영 적용. campaign_manager 테스트 계정으로 사이드바 숨김·#permissions 리다이렉트·super 그리드·denylist QA 통과. 시드=현행이라 동작 변화 0.

## PR3 (민감정보 서버 실차단, 마이그레이션 212·213)

**구현일:** 2026-07-06 (dev) / **결정:** 가림막 뷰 방식 / 엑셀 6종 가림 / 배포 즉시 하위등급 차단

### PR3-A (마이그레이션 212) — 가림막 뷰
- `influencers_admin_view`(security_invoker=true): 민감 6종(phone·line_id·paypal_email·zip·building·address)을 `has_permission('influencer.sensitive_pii','read')` false면 NULL 마스킹(스칼라 서브쿼리 InitPlan 최적화, 마이그137 패턴) + 존재 불리언 3종(has_phone·has_line·has_paypal). 레거시 `pw`·`bank_*` 6컬럼은 뷰에서 제외(코드 미참조·민감). 총 47컬럼. 개발 DB 검증(마스킹 동작·컬럼 수) 완료.

### PR3-B (코드) — 조회 경로·화면 전환
- `fetchInfluencers`·`fetchInfluencersByIds` 뷰 경유(쓰기 함수는 base `influencers` 유지). shared.js 헬퍼 2종(`maskedFieldByFlag` 존재불리언 기준·`maskedFieldByPermission` 클라 근사·보안경계 아님). admin-influencers/applications/deliverables/dashboard 배지·필터·모달을 has_* 기준·「열람 권한 없음」 라벨로 전환. 대시보드 배송지 완성률은 prefecture 근사 지표로 대체. 신청자·결과물 엑셀도 뷰 경유로 자동 마스킹(부수 개선).

### PR3-C (마이그레이션 213) — 실차단 발동
- campaign_manager `influencer.sensitive_pii` read→hidden UPDATE(멱등, CTE로 실변경 시만 `role_permission_history` 기록·actor NULL). 이 시점부터 campaign_manager는 뷰에서 민감정보 NULL 수신. campaign_admin·super 불변.

### reviewer Warning 처리
- W3 이력 기록 반영(213 CTE INSERT), W4 대시보드 주석 「근사 지표」 완화, W5 문서 동기화(이 섹션·CLAUDE.md). W1(엑셀 2곳 빈칸 마스킹)=부수 보안 개선 수용(엑셀은 빈칸 유지). W2(엑셀 「민감정보 포함」 게이트 동적 권한화)=PR3-D 백로그. 기본값 복원 버튼도 후속.
