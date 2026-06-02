# 서비스 건강도 리포트 — 2026-06-02 (시범 점검)

**모드:** 빠른 점검 (시범) — 차원 2·5만
**점검 세션:** 기획/설계 세션
**사양서:** `docs/specs/2026-06-02-service-health-audit.md`

---

## 점검한 차원 / 안 한 차원 (silent skip 금지)

| 차원 | 점검 여부 |
|---|---|
| 2. 죽은·중복·충돌 코드 | ✅ 점검 |
| 5. 문서 정합성 | ✅ 점검 |
| 8. 외부 시스템 정합성 | ✅ **자동 항목** 점검 (사람 체크리스트 항목은 미점검) |
| 1. 기능 회귀 / 3. 정책 / 4. DB / 6. 보안 / 7. 성능 | ⬜ **이번엔 안 함** (분기 심층 점검에서) |

---

## 발견 사항

### 차원 2 — 죽은·중복 코드

| ID | 위치 | 내용 | 확실성 | 조치 |
|---|---|---|---|---|
| 2-1 | `dev/js/admin-messaging.js:892` `influencerNameById(id)` | 정의만 있고 호출처 없음(스크립트·HTML 0회). 일괄발송 PR 3에서 추가됐으나 미사용 추정 | 추정 (개발 세션 재확인 필요) | 백로그 등록 |
| 2-2 | `dev/js/admin-messaging.js:957~1100` | 일괄발송 모달 display 제어 코드 반복(`setDisplayState()` 헬퍼 통합 여지) | 경계선(경미) | 선택적 — 우선순위 낮음 |

잔존 참조(stale reference): **미발견** — messaging/errors/error-report의 DOM id 참조 모두 HTML에 실재.

### 차원 5 — 문서 정합성

| ID | 위치 | 내용 | 확실성 | 조치 |
|---|---|---|---|---|
| 5-3 | `docs/CODEMAPS/data-layer.md:108` | "마이그레이션 최근 흐름 (125~144)" — 실제 167까지 존재. 145~167(주요: 160·165·166·167) 누락 | **확실** | 백로그 등록 (코드맵 갱신) |
| 5-2 | `docs/CODEMAPS/admin-app.md` | 일괄발송 PR 3 함수(`openBulkMessageModal` 등 11+) 코드맵 미반영 | 확실(경미) | 백로그 등록 |

### 부수 발견 (점검 외 눈에 띈 것)
- `broadcast-*.png`·`bulk-send-*.png` 등 QA 스크린샷 다수가 git untracked → `.gitignore` 누락 가능성. (다른 세션 일괄발송 QA 산출물)

### 차원 8 — 외부 시스템 정합성 (터미널 자동 검토)

**✅ 이상 없음:**
- DNS: SPF(`include:spf.brevo.com`)·DKIM(brevo-code)·DMARC 모두 설정됨. A레코드 Vercel(216.198.79.1) 정상
- 시크릿: `service_role`·SMTP/Brevo key 코드 노출 **없음**. `.gitignore`에 `.env*.local`·`supabase/.temp/` 존재
- 환경 정합: `dev/lib/supabase.js` URL(운영 `nrwtujmlbktxjgdwlpjj` 도쿄·개발 `qysmxtipobomefudyixw`) = CLAUDE.md 일치
- 하드코딩 URL: `shared.js`는 주석, `index.html`은 preconnect 힌트 — **위반 아님**
- 빌드 drift: 산출물(16:59) > dev 최신수정(16:58) — **drift 없음**
- 운영/개발 사이트: globalreverb.com 307→www 200 / dev 200 — **정상 가동**
- Edge Function 6종 디렉터리 정상, supabase CLI 2.101.0 가용

| ID | 위치 | 내용 | 확실성 | 조치 |
|---|---|---|---|---|
| 8-1 | `.claude/rules/supabase.md:9,27` | 운영서버를 **시드니 `twofagomeizrtkwlhsuv`** 로 기재 — 실제는 도쿄 `nrwtujmlbktxjgdwlpjj` 이관 완료(2026-05-27). 규칙 파일이 stale | **확실** | 백로그 (우선) |
| 8-2 | `docs/PROJECT_CONTEXT.md:28,30,80` | 국외이전 리전을 "호주 시드니"로 기재 — 실제 도쿄. 개인정보처리방침(PRIVACY)은 도쿄로 정정됐으나 맥락 문서는 시드니로 남음 | **확실** | 백로그 (우선·정책 정합성) |
| 8-3 | (거짓 경보 — 해소) | GitHub Deployments API상 Production이 2026-04-20에 멈춤 → 실제 운영 사이트는 200 정상. **Vercel이 GitHub Production deployment 레코드를 안 남김.** "gh deployments로 Production 확인"법은 신뢰 불가 → **curl -L이 진짜 확인법** | 확인 완료 | 메모 갱신 권고 |

**🔵 사람 체크리스트 (자동 불가 — 대시보드 확인 필요):**
- pg_cron 실제 가동 여부 — 마이그레이션 166(위반기록 3년 삭제)·142(홍보)·113 등록 SQL은 존재하나 DB에서 `select jobname,schedule,active from cron.job` 확인 필요
- Brevo 월 쿼터 잔량(20,000통)
- Auth Confirm email 토글(운영 ON·개발 OFF), Rate limit(운영 100/h)
- Storage 버킷·정책, Vercel 도메인·환경변수
- (선택) DMARC `p=none` → 보안 강화 시 `quarantine`/`reject` 고려, 우선순위 낮음

---

## ⚠️ 오탐 기록 (시범 점검 메타 교훈)

- **차원 5-1 (Explore 오탐)**: Explore가 "CLAUDE.md:219에 PR 3 미구현이라 적혀 stale"이라 보고했으나, **직접 확인 결과 CLAUDE.md:219는 이미 "PR 3 개발서버 구현 완료"로 정확히 반영**돼 있었음 → 문제 없음.
- **교훈**: Explore/서브에이전트 발견을 검증 없이 리포트에 넣으면 오탐이 섞인다. **건강도 리포트 등재 전 핵심 발견은 메인 세션이 직접 grep/Read 검증** 필요. → 사양서 §3 의심 ④(신뢰성)의 실제 사례. 양식·운영 규칙에 "검증 후 등재" 명문화 권고.

---

## 발견 → 백로그 연결 (조치 누락 방지)

개발 세션이 받아 처리할 항목 (진단만, 수리는 별도):
1. **2-1** `influencerNameById()` 미사용 여부 재확인 후 제거 — 추정이라 검증 선행
2. **5-3** `data-layer.md` 마이그레이션 범위 125~144 → 167 갱신 (확실, 우선)
3. **5-2** `admin-app.md` 또는 신규 `admin-messaging.md` 코드맵에 일괄발송 함수 반영
4. **부수** QA 스크린샷 png `.gitignore` 추가 검토
5. **8-1** `.claude/rules/supabase.md` 운영서버 시드니→도쿄(`nrwtujmlbktxjgdwlpjj`) 갱신 (확실, 우선)
6. **8-2** `docs/PROJECT_CONTEXT.md` 국외이전 리전 호주 시드니→일본 도쿄 정정 (확실, 정책 정합성, 우선)

→ 위 항목은 본 세션에서 **수리하지 않음**(기획 세션 + 다른 세션 작업 영역 존중). 개발 세션 인계.

---

## 체계 개선 — 전수조사가 놓친 유형 (2026-06-02 @cosme 사례)

**별건 운영 버그**(`@cosme`·LIPS 채널 코드가 화면에 원문 노출)가 점검 외에서 제보됨 → 이 시범 점검(차원 2·5)으로는 **못 잡혔을 유형**임이 드러남. 체계 보강 트리거.

- **원인**: `dev/js/ui.js:192` `CHANNEL_LABEL_FALLBACK`에 LIPS·@cosme 누락(마이그레이션 157에서 DB만 추가, 코드 미러 drift) + `getChannelLabel`이 캐시 미로드 시 폴백 추락. `dev/admin/app.js:91` 주석이 "같은 버그 admin에만 패치"한 증거(횡단 재발).
- **왜 전수조사가 놓치나**: 각 부분(데이터·로직·폴백)이 개별 정상 → "틀린 코드" 점검(차원 2)에 안 걸림. 발현이 캐시 로드 타이밍(런타임). 하드코딩 미러↔DB 정합 점검 항목 부재.
- **반영**: 차원 2에 **정합성 미러 점검 3종**(2-A 하드코딩 미러↔DB / 2-B 핫픽스 횡단 재발 / 2-C 캐시 의존 동기함수) 신설 → 사양서 §4-1-2 + `/서비스점검` 명령에 추가 완료. 다음 점검부터 채널 외 카테고리·상태 라벨 미러도 전수 대상.
- 버그 자체 수정은 개발 세션 진행 중.

## 시범 점검 결론 (양식·체계 검증)

- 빠른 모드 2차원이 **약 1회 점검으로 실효 발견 2건(확실) + 추정 1건 + 오탐 1건**을 산출 → 체계가 작동함
- **양식 보정 의견**:
  - "오탐 기록" 섹션은 유지 가치 있음 (서브에이전트 신뢰도 추적)
  - "점검 안 한 차원 명시"가 silent skip을 막아 유효
  - 다음 리포트부터 "이전 리포트 대비 반복 발견" 추세 칸 추가
