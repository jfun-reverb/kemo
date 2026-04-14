# Supabase 환경 분리 (staging / production) 실행 계획

**작성일**: 2026-04-14
**상태**: 확정 (사용자 승인 완료)

---

## 배경
- 현재 dev 서버(`kemo-liart.vercel.app`)와 운영(`globalreverb.com`)이 단일 Supabase 프로젝트(`twofagomeizrtkwlhsuv`)를 공유.
- 대중 오픈을 앞두고, 테스트 행위(캠페인 CRUD, lookup_values 변경, 테스트 신청 등)가 운영 데이터에 즉시 반영되는 리스크 제거 필요.
- **목표**: Supabase를 staging/production 2개 프로젝트로 분리하고, 도메인 기반 자동 분기 로직 구현.

---

## 확정 사항 (사용자 결정)

| # | 항목 | 결정 |
|---|------|------|
| 1 | 분리 방향 | 현 프로젝트 = production 승격 + staging 신규 생성 |
| 2 | 운영 초기 데이터 | 실제 파트너 캠페인만 유지 (lookup_values, 관리자 포함) |
| 3 | 테스트 계정 | staging 이전 후 production에서 삭제 |
| 4 | 관리자 | production은 실제 사용자 super_admin (설정 완료), `admin@kemo.jp`는 staging에만 |
| 5 | Vercel | 프로젝트 1개 유지, 도메인 분기만 |
| 6-1 | staging 도메인 | `dev.globalreverb.com` |
| 6-2 | `kemo-liart.vercel.app` | 제거 |
| 7 | Supabase 플랜 | staging Free로 시작, 필요 시 Pro 승급 |
| 8 | STAGING 배지 | 관리자 페이지에만 표시 |
| 9 | lookup_values seed | 현 데이터 dump → 양쪽 적용 |
| 10 | 마이그레이션 점검 | 파일 vs 실제 DB 대조 검증 필요 |

---

## 영향 파일 / 범위
- `dev/lib/supabase.js` — URL/KEY 하드코딩 → 도메인 분기 로직
- `dev/build.sh` — 빌드 산출물 확인
- `dev/index.html`, `dev/admin/index.html` 및 루트 산출물
- `supabase/migrations/*.sql` — 새 프로젝트 순차 적용
- `supabase/seed/lookup_values.sql` 신규
- `CLAUDE.md` Key URLs 업데이트
- `.claude/rules/supabase.md` 환경 분리 원칙 추가
- Vercel 도메인 설정, Supabase Auth(양쪽) 설정

---

## 실행 단계

### Phase 0: 사전 준비
- [ ] 현 Supabase DB 풀 백업 (pg_dump + Storage 목록)
- [ ] **마이그레이션 점검**: 현 production DB `pg_dump --schema-only` vs `supabase/migrations/` 적용 결과 비교
  - 차이 발견 시 `028_*.sql` 형태로 복구 마이그레이션 작성
- [ ] `supabase/seed/lookup_values.sql` 추출 및 커밋

### Phase 1: Supabase 프로젝트 작업
- [ ] **현 프로젝트 → production으로 rename** (`reverb-jp-production`)
- [ ] **staging 신규 프로젝트 생성** (`reverb-jp-staging`, Free 플랜, 일본 리전)
- [ ] staging에 마이그레이션 순차 적용 (001~최신)
- [ ] staging에 `campaign-images` Storage 버킷 생성 + RLS 복제
- [ ] staging에 lookup_values seed 적용
- [ ] staging 관리자 계정 생성: `admin@kemo.jp / admin1234`
- [ ] staging Auth 설정
  - Site URL: `https://dev.globalreverb.com`
  - Redirect URLs: `https://dev.globalreverb.com/**`, `http://localhost:*`, `file://`
- [ ] production 클린업
  - 테스트 인플루언서(`*.test@reverb.jp`) 삭제
  - 테스트 캠페인/applications/receipts 삭제
  - `admin@kemo.jp` 계정 삭제
  - view_count 리셋 여부 결정
- [ ] production Auth 재확인
  - Site URL: `https://globalreverb.com`
  - Redirect URLs: `https://globalreverb.com/**`, `https://www.globalreverb.com/**`

### Phase 2: Vercel 도메인 작업
- [ ] `dev.globalreverb.com` 도메인 추가 + dev 브랜치에 연결
- [ ] `kemo-liart.vercel.app` 제거
- [ ] production(main 브랜치) 도메인 확인: `globalreverb.com`, `www.globalreverb.com`

### Phase 3: 코드 변경
- [ ] **커밋 C** (dev): `dev/lib/supabase.js`에 도메인 분기 로직 추가
  ```js
  const isProd = /^(www\.)?globalreverb\.com$/.test(location.hostname);
  const CONFIG = {
    production: { url: 'PROD_URL', key: 'PROD_ANON_KEY' },
    staging:    { url: 'STAGING_URL', key: 'STAGING_ANON_KEY' }
  };
  const { url: SUPABASE_URL, key: SUPABASE_ANON_KEY } = CONFIG[isProd ? 'production' : 'staging'];
  ```
- [ ] 관리자 페이지에 `[STAGING]` 배지 (staging 환경에서만 표시)
- [ ] `cd dev && bash build.sh` 실행하여 루트 산출물 갱신
- [ ] **커밋 D**: `CLAUDE.md` Key URLs 업데이트, `.claude/rules/supabase.md`에 환경 분리 원칙 추가

### Phase 4: 검증 (staging)
- [ ] dev 브랜치 push → `dev.globalreverb.com` 배포 확인
- [ ] Network 탭에서 staging Supabase URL로 요청 가는지 확인
- [ ] 회원가입 + 이메일 확인 링크 → staging URL 리다이렉트
- [ ] 로그인/로그아웃/세션 갱신
- [ ] 비밀번호 재설정 메일 링크 올바른지
- [ ] 캠페인 목록/상세/신청 정상 동작
- [ ] 관리자 CRUD, lookup_values CRUD 정상
- [ ] 이미지 업로드(Storage) 동작 (transform은 Free라 제한 있음 — 원본 폴백 확인)
- [ ] **데이터 격리 확인**: staging에서 캠페인 생성 → production에 노출 안 됨

### Phase 5: production 배포
- [ ] PR dev → main 생성
- [ ] PR 리뷰 (reverb-reviewer 호출)
- [ ] main merge + push → `globalreverb.com` 배포
- [ ] production Network 탭에서 production Supabase URL 확인
- [ ] production 기능 E2E 재검증
- [ ] **데이터 격리 역방향 확인**: production에서 lookup_values 수정 → staging 영향 없음

### Phase 6: 모니터링 (72시간)
- [ ] Supabase 로그 확인 (staging/production 각각)
- [ ] 실사용자 신청 플로우 샘플 확인
- [ ] 에러 리포트 모니터링

---

## 롤백 계획
- 전환 직전 `pg_dump` 풀백업 (로컬 + 원격 2곳)
- 분기 로직 문제 시: `git revert` → `build.sh` → `main` push (단일 커밋 rollback)
- production 데이터 손상 시: dump restore

---

## 리스크 체크리스트
- [ ] anon key 노출 → RLS 감사 완료
- [ ] Email confirm redirect 꼬임 위험 → Site URL 명확 분리
- [ ] **build.sh 미실행 시 치명적 사고** (production이 잘못된 DB로 붙음) → 배포 전 빌드 필수
- [ ] 현 운영에 수동 SQL 적용분 → Phase 0 점검에서 확인
- [ ] STAGING 배지 누락 → 환경 착각 가능

---

## 참고
- Supabase URL: 현 `twofagomeizrtkwlhsuv` → production
- Storage 버킷: `campaign-images`
- 주요 테이블: campaigns, influencers, applications, admins, receipts, lookup_values
