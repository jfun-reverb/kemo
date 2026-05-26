# Supabase 운영 데이터베이스 호주(시드니) → 일본(도쿄) 이관 계획서

**작성일:** 2026-05-25
**작성 세션:** 고문(메인) 세션 — 계획 수립
**상태:** 초안 (실행 전, Supabase 지원 답변 SU-379237 대기 중)

> 캠페인 관리 속도 개선(PR 1~4 + 썸네일)으로 코드 측 지연은 잡았으나, 남은 지연의 근본 원인은 **운영 데이터베이스가 호주 시드니에 있어 한/일 사용자와의 네트워크 왕복 거리**다. 이를 도쿄로 옮기는 작업의 전체 계획.

---

## 1. 핵심 제약 (먼저 알아야 할 것)

- **Supabase는 프로젝트 리전을 그 자리에서 바꿀 수 없다.** 도쿄에 **새 프로젝트를 만들어 데이터를 옮기는 것**이 유일한 공식 방법.
- **Project Transfer**(프로젝트 이전) 기능은 *조직 간 이동*만 가능하고 *리전 변경*에는 못 쓴다.
- 즉 Supabase 지원팀에 물어도 "직접 마이그레이션하라"가 답일 가능성이 큼. 지원팀의 가치는 ① 대량 인증/저장소 이관 권고 ② 다운타임 최소화 방법 ③ 유료 우선지원.
- 출처: Supabase 공식 문서(아래 참고 링크).

---

## 2. 현황

| 구분 | 프로젝트 | 리전 | 등급 |
|---|---|---|---|
| **운영** | `twofagomeizrtkwlhsuv` | 🇦🇺 Sydney `ap-southeast-2` | Pro / NANO |
| **개발** | `qysmxtipobomefudyixw` | 🇯🇵 Tokyo `ap-northeast-1` | Pro / MICRO |

- **유리한 점**: 도쿄 리전(`ap-northeast-1`)을 개발 서버에서 이미 운영 중 → 같은 리전에 새 운영 프로젝트를 만들면 됨(경험·패턴 보유).
- 도메인 분기: `dev/lib/supabase.js`의 `resolveSupabaseEnv(hostname)` + `SUPABASE_ENVS` 객체. 운영 주소/키만 교체하면 됨(분기 로직 유지).
- **데이터 규모(2026-05-25 운영 실측)**:
  - 데이터베이스 전체 **40MB** (아주 작음 — dump/restore 수 분)
  - `auth.users`(로그인 사용자) **1,412명** (DB에 포함되어 함께 이관)
  - 저장소 파일 **1,135개 / 총 574MB** (평균 ~500KB/개 — 이관 시간의 주 변수)
- **다운타임 추정**: DB는 작아 거의 즉시. 저장소 574MB가 변수지만 **사전 복사 + 증분 전략 시 실질 다운타임 15~30분**, 단순 순차 시 ~1시간. 전체 규모가 작아 부담 낮음.

---

## 3. 이관 대상 인벤토리 (6종)

1. **데이터베이스 구조 + 데이터** — 마이그레이션 파일 다수(`supabase/migrations/`) + 실데이터. 구조는 파일로 보관돼 있어 재현 가능, 데이터는 dump/restore.
2. **로그인 사용자(`auth.users` ~1,700명) + `auth.identities`** — 비밀번호 해시 포함. **가장 신중해야 할 부분**(누락 시 전원 로그인 불가). 이관 방법 확정 필요(§8).
3. **저장소(Storage) 파일** — **실측(2026-05-25): 574MB 전부 `campaign-images` 단일 버킷에 집중(1,135파일)**. `application-message-attachments`·`influencer-flag-evidence` 버킷은 파일 0(메시지 기능 운영 보류·증빙 미사용) → **빈 버킷 구조+정책만 도쿄에 생성**. 실제 파일 복사는 `campaign-images` 하나뿐이라 단순(도구로 일괄). 대시보드에서 버킷 목록·정책 최종 확인.
4. **Edge Function 7개** — `notify-admin-daily-digest`, `notify-application-cancelled-daily`, `notify-application-received-admin-daily`, `notify-brand-application`, `notify-campaign-promo-digest`, `notify-deliverable-decision`, `notify-influencer-daily-digest`. 새 프로젝트로 재배포 + 환경변수(secrets) 재설정.
5. **예약 작업(pg_cron)** — 마이그레이션 113(응모 취소 다이제스트)·142(홍보 메일)·144(메시지) 등에서 등록한 스케줄. 새 프로젝트에 재등록(cron은 데이터로 안 딸려옴).
6. **수동 설정**(대시보드, 코드로 안 옮겨짐):
   - `dev/lib/supabase.js` `SUPABASE_ENVS`의 **운영 URL/anon key 교체**
   - Auth → URL Configuration: **Site URL `https://globalreverb.com` + Redirect URLs**(globalreverb.com/**, www.globalreverb.com/**)
   - Auth → **Confirm email ON**(운영 필수)
   - Auth → **Rate Limits**(이메일 100/h)
   - **Brevo Custom SMTP** 설정(smtp-relay.brevo.com:587, 발신 도메인 인증)
   - **Storage 정책**(버킷별 RLS)
   - **Edge Function secrets**(예: `NOTIFY_ADMIN_EMAILS`, SMTP 키 등)

---

## 4. 단계별 절차

### Phase 0 — 사전 준비
- 도쿄(`ap-northeast-1`)에 **새 운영 프로젝트** 생성. compute 등급 결정(현 운영 NANO → 트래픽 고려해 동급 이상).
- Supabase CLI 링크, service_role 키 확보(이관 도구용, 코드 노출 금지).
- 현재 운영 DB 용량·저장소 총량 측정 → 다운타임 추정.

### Phase 1 — 리허설 (실데이터로 1회 연습, 필수)
- 시드니 운영 → **임시 도쿄 테스트 프로젝트**로 전체(DB+auth+storage+functions+cron) 이관을 한 번 연습.
- 소요 시간 측정, 로그인/이미지/메일 동작 확인, 누락 항목 발견.
- 이 리허설로 본 이관의 다운타임·체크리스트를 확정.

### Phase 2 — 본 이관 (다운타임 윈도우, 새벽 권장)
1. 사용자 점검 공지(앱/메일).
2. 시드니 운영 **쓰기 중단**(점검 모드) — 데이터 어긋남 방지.
3. DB **dump**(스키마+데이터, auth 포함) → 도쿄 프로젝트 **restore**.
4. **저장소 파일 복사**(버킷별, 정책 포함).
5. **Edge Function 배포**(`--project-ref` 도쿄) + secrets 설정.
6. **pg_cron 재등록**.
7. **수동 설정 적용**(§3-6: Auth URL·SMTP·Confirm email·Rate Limits·Storage 정책).
8. **코드 교체**: `SUPABASE_ENVS` 운영 URL/key → 도쿄 → 빌드 → main 배포.
9. 도메인/DNS는 **변경 없음**(Supabase 주소만 코드에서 바뀜).

### Phase 3 — 검증
- 기존 사용자 **로그인**(비밀번호 유지 확인 — 가장 중요), 캠페인 목록·상세, 신청·승인, 결과물, **이미지 표시**, **메일 발송**(다이제스트 수동 1회), cron 동작.
- 시드니 vs 도쿄 **데이터 건수 대조**(인플·신청·캠페인 등).

### Phase 4 — 안정화·정리
- 며칠 모니터링(에러·메일·속도). 속도 개선 실측(왕복 시간 호주 대비).
- 안정 후 시드니 프로젝트 보관 또는 해지.

---

## 5. 다운타임
- DB dump/restore + 저장소 복사 동안 **쓰기 중단** 필요. 데이터 규모에 비례(리허설로 정확히 측정).
- 새벽 시간 + 사전 공지. 읽기 전용/점검 페이지 노출 검토.

## 6. 롤백
- 검증 실패 시 **코드 `SUPABASE_ENVS`를 시드니로 되돌리고 재배포** → 즉시 원복(시드니 프로젝트는 정리 전까지 유지).
- DNS 변경이 없어 롤백이 빠름(코드 한 곳).

## 7. 리스크
| 리스크 | 영향 | 대비 |
|---|---|---|
| auth 비밀번호 해시 이관 실패 | 전원 로그인 불가 | 리허설에서 실제 로그인 검증, 방법 확정(§8) |
| 저장소 파일 누락 | 이미지·첨부 깨짐 | 버킷별 건수·용량 대조 |
| 이관 중 신규 쓰기 | 데이터 유실 | 쓰기 중단 윈도우 |
| Edge secret/SMTP 누락 | 메일 중단 | §3-6 체크리스트 |
| cron 미등록 | 다이제스트 메일 중단 | Phase 2-6 |

## 8. 확정 필요 (Supabase 답변·리허설로)
- **`auth.users` + `auth.identities` 정확한 이관 방법** — `supabase db dump`가 auth 스키마를 포함하는지, 별도 절차가 필요한지(가장 중요).
- 저장소 대량 파일 복사 도구·방법.
- 다운타임 최소화 방법(물리 복제 등 지원팀 권고).
- 도쿄 프로젝트 compute 등급.
- 정확한 데이터/저장소 용량.

## 9. Supabase 지원 활용 (티켓 SU-379237)
- 1~2 영업일 답변 대기. 위 §8 항목을 명시적으로 질의.
- 병행: Discord(`discord.supabase.com`), GitHub Discussions.
- 대량·무중단이 중요하면 priority support 패키지 검토.

---

## 참고 링크
- [Change Project Region](https://supabase.com/docs/guides/troubleshooting/change-project-region-eWJo5Z)
- [Migrating within Supabase](https://supabase.com/docs/guides/platform/migrating-within-supabase)
- [Project Transfers](https://supabase.com/docs/guides/platform/project-transfer)
- [Available regions](https://supabase.com/docs/guides/platform/regions)

---

## 부록 A — 리허설 실행 절차 (개발자용)

> ⚠️ **주의 1**: 메인 작업 폴더(`reverb-jp`)가 **운영 프로젝트(시드니)에 링크**돼 있음(2026-05-25 확인 — `supabase db dump`가 운영 호스트 사용). 리허설의 **복원·초기화 같은 쓰기 명령이 운영을 건드리지 않도록**, 리허설은 **별도 디렉터리에서 연습 프로젝트로 `supabase link` 후** 진행할 것.
> ⚠️ **주의 2**: 이 환경엔 `pg_dump`/`psql` 미설치. 복원(psql)·일부 백업에 PostgreSQL 클라이언트 설치 필요.
> ✅ **확인됨**: 로그인 사용자(auth)는 `supabase db dump --schema auth` 로 백업 가능(dry-run 검증). 이게 본 이관의 핵심 불확실 요소였음.

### Step 1 — 도쿄 연습 프로젝트 생성 (대시보드)
- New project → Region **Northeast Asia (Tokyo) `ap-northeast-1`** → ref·DB password 확보.

### Step 2 — 운영 백업 (읽기 전용, 시드니)
```
supabase link --project-ref twofagomeizrtkwlhsuv
supabase db dump --role-only       -f roles.sql
supabase db dump                   -f schema.sql   # public 등 스키마
supabase db dump --data-only --use-copy -f data.sql
supabase db dump --schema auth     -f auth.sql     # 로그인 사용자(비번 해시 포함)
```

### Step 3 — 연습 프로젝트로 복원 (도쿄)
```
# 연습 프로젝트 connection string 사용. 순서 주의: roles → schema → auth → data
psql "<연습 connection string>" -f roles.sql
psql "<연습 connection string>" -f schema.sql
psql "<연습 connection string>" -f auth.sql
psql "<연습 connection string>" -f data.sql
```

### Step 4 — 저장소 복사 (`campaign-images` 574MB / 1,135파일)
- rclone 또는 다운로드→업로드 스크립트로 `campaign-images` 버킷 복사.
- 빈 버킷(`application-message-attachments`·`influencer-flag-evidence`)은 구조+접근 정책만 생성.

### Step 5 — 검증 (리허설 성공 판정)
- 연습 프로젝트 anon key로 임시 환경에서 **기존 사용자 로그인 테스트**(비밀번호 그대로 되는지 = auth 이관 성공 여부, 가장 중요).
- 데이터 건수 대조(인플 1,412 / 신청 등).
- **전체 소요시간 기록** → 본 이관 다운타임 정밀 추정.

### 리허설로 확정할 것
- auth 복원 후 로그인 성공 여부(✓/✗) → 실패 시 Supabase 권장 방법 재확인.
- 단계별 소요시간 → 다운타임 윈도우 확정.

---

## 실행 이력

### 2026-05-26 — Phase A 사전준비 (다운타임 0) 실행

**도쿄 신규 운영 프로젝트:** `nrwtujmlbktxjgdwlpjj` (ap-northeast-1 Tokyo, **Micro** 등급, t4g.micro). URL `https://nrwtujmlbktxjgdwlpjj.supabase.co`.

**완료 항목:**
1. **CLI 업그레이드** 2.90.0 → 2.101.0 (`supabase storage` 명령이 `--experimental` 플래그 필수 — 이게 핵심. 2.90에선 usage만 출력).
2. **시드니 구조 백업** (`supabase db dump`, 읽기 전용): roles.sql / schema.sql(public 구조). `db dump`는 pg_dump에 `--exclude-schema`로 auth·storage·cron·supabase_functions 등 제외 + 일반 트리거를 `CREATE OR REPLACE TRIGGER`로 변환(이벤트 트리거만 제외). → schema.sql에 `CREATE TRIGGER` 0개로 보이지만 `CREATE OR REPLACE TRIGGER` 37개 포함(놀라지 말 것).
3. **구조 복원** (psql): roles → schema. 결과 검증 = 시드니와 일치: **테이블 43·함수 76·정책(RLS) 104·트리거 35**(웹훅 2개는 supabase_functions 스키마 없어 복원 실패 — 예상된 무시가능 오류). RLS 활성 43/43.
4. **신규 가입 트리거 별도 적용** — `on_auth_user_created`(auth.users AFTER INSERT → public.handle_new_user)는 auth 스키마라 schema.sql에 없음. 014 마이그레이션에서 추출해 도쿄에 수동 적용(누락 시 신규 회원가입 깨짐 — 반드시 챙길 것).
5. **Storage 버킷·정책**: 운영 실제 버킷은 **2개뿐**(`campaign-images` public, `influencer-flag-evidence` 비공개 10MB) — `application-message-attachments`는 메시지 기능 운영 보류라 운영에 없음. `storage.objects` 정책 9개(campaign_images 4 + flag_evidence 4 + receipts 1) 추출·적용.
6. **저장소 다운로드** (시드니→로컬): `supabase storage cp -r ss:///campaign-images <local> --experimental`. **1,181파일/682MB**(이미지 1,156 + avif 25). 시드니 실제도 1,181 = 완전 일치(목록의 1,192는 폴더 라인 11개 포함). 호주 거리라 다운로드만 수십 분.
7. **저장소 업로드** (로컬→도쿄): link 도쿄 전환 후 업로드. ⚠️ **함정**: `cp -r <local>/campaign-images ss:///campaign-images`는 소스 basename을 덧붙여 `campaign-images/campaign-images/...` **중첩** 발생 → 중첩분 `storage rm -r --yes` 삭제 후 **하위 폴더별**(`cp -r <local>/campaign-images/campaigns ss:///campaign-images` 식, content·campaigns·receipts 3개)로 재업로드해야 올바른 경로. **최종 검증 완료**: 도쿄 1,181 = 로컬 1,181(campaigns 136·content 4·receipts 1,041 폴더 분포 일치, 중첩 없음). (2026-05-26 완료)
8. **Edge Function 7개 배포** (`functions deploy --project-ref` 도쿄): 전부 ACTIVE.
9. **Edge secret 5개**: BREVO_API_KEY(신규 생성 `reverb-jp-edge-tokyo`) · NOTIFY_ADMIN_EMAILS(`younggeun.kim@jfun.co.kr`) · BREVO_SENDER_NAME · PUBLIC_ADMIN_URL · PUBLIC_SITE_URL. 뒤 3개는 해시값이 시드니와 일치 확인. (SUPABASE_* 7개는 런타임 자동 주입이라 설정 안 함)
10. **대시보드 수동설정(사용자)**: URL Config(Site URL globalreverb.com + Redirect 2개) · Confirm email ON · Custom SMTP(Brevo: smtp-relay.brevo.com:587, Login a2de8e001@smtp-brevo.com, 신규 SMTP key `reverb-jp-production-tokyo`, sender noreply@globalreverb.com / REVERB JP) · Rate limit email **100**. ⚠️ Brevo의 IP 차단("Activate for SMTP/API keys") 누르지 않음(Supabase 발송과 비호환).

**Phase A 종료 시점 상태:** 도쿄에 구조+트리거+가입트리거+저장소+함수+secret+인증/SMTP 설정 완료. **데이터(auth+public)·pg_cron·웹훅트리거·코드주소교체만 컷오버에 남김.**

### 컷오버(Phase B) 체크리스트 — 다음 단계
1. (선택) 사용자 점검 공지.
2. 시드니 **쓰기 중단**(새벽 윈도우).
3. **link 시드니로 복귀** 후 최종 dump: auth 데이터(`--schema auth --data-only --use-copy`) + public 데이터(`--data-only --use-copy`, auth 중복 주의). 약 2분.
4. 도쿄 복원: `SET session_replication_role=replica;` 파이프 psql로 auth → public 순.
5. **저장소 증분**: Phase A(2026-05-26) 이후 시드니 신규 파일만 재다운로드+업로드(`cp` + 파일 수 재대조).
6. **웹훅 트리거 2개 재생성**: 도쿄 대시보드 Database → Webhooks로 `notify-brand-application`(brand_applications INSERT)·`notify-deliverable-decision`(notifications INSERT) 생성(도쿄 URL + 도쿄 service_role). supabase_functions 스키마는 첫 웹훅 생성 시 자동 활성.
7. **pg_cron 등록(도쿄)** + **시드니 cron 해제**(메일 중복 차단). 다이제스트 cron SQL은 각 Edge Function README/index.ts 주석, 홍보메일은 마이그레이션 142.
8. **코드 교체**: `dev/lib/supabase.js` production → url `https://nrwtujmlbktxjgdwlpjj.supabase.co` / key `sb_publishable_3pfK7sF55NZO7owlm13_uA_iCbORAvP`. reviewer→빌드→main 배포.
9. **검증**: 기존 비번 로그인 · 행수 대조 · 이미지 표시 · 메일 1회.
10. **개인정보처리방침** 국외이전 경유지 호주→일본 갱신(`/약관확인`).
11. 롤백: 코드 production만 시드니로 되돌려 재배포(DNS 무변경).

**도쿄 DB password 보안:** Phase A 작업에 사용한 도쿄 DB password는 이관 완료 후 재설정 권장. BREVO API 키도 스크린샷 일부 노출돼 재생성 권장.

### 2026-05-27 — 컷오버(Phase B) 완료 ✅ (globalreverb.com 도쿄 전환)

새벽 컷오버 실행. **다운타임 사실상 0**(데이터 dump~배포 사이 새벽 트래픽 0, 신규 데이터 유입 없음 확인).

1. **최종 데이터 dump+복원**: 시드니 link 복귀 → auth-data(6.8MB) + public-data(16MB) dump → 도쿄 복원(`session_replication_role=replica` 파이프 psql). ⚠️ **direct 연결(IPv6) 불가** — 작업 PC 네트워크가 IPv4 only로 바뀌어 `db.<ref>.supabase.co` DNS 실패. **pooler(IPv4)로 우회**: 도쿄 `aws-1-ap-northeast-1.pooler.supabase.com:5432` user `postgres.<ref>`, 시드니 `aws-1-ap-southeast-2.pooler...`. 복원 ERROR(buckets_vectors/supabase_functions)는 무시가능.
2. **행 수 최종 대조**: auth.users/influencers 1,421 · campaigns 119 · applications 2,983 · deliverables 1,037 · brand_applications 33 — 시드니=도쿄 **완전 일치**.
3. **저장소 증분**: 1차(1,181) 이후 신규 29개 → 도쿄 업로드, 총 1,210 일치.
4. **웹훅 트리거 2개**: 대시보드 "Enable webhooks"로 supabase_functions 활성 후, SQL로 `notify-brand-application`(brand_applications)·`notify-deliverable-decision`(notifications) 생성(도쿄 URL + 도쿄 service_role).
5. **pg_cron 전환**: 도쿄에 3개 등록(admin/influencer 다이제스트 daily, promo 월·목) — `vault.create_secret(도쿄 service_role, 'edge_function_jwt')` 선행. 시드니 3개 `cron.unschedule`(메일 중복 차단). 첫 자동 발송 = 2026-05-27 09:00 KST.
6. **코드 전환·배포**: `SUPABASE_ENVS.production` + preconnect + sales 폼 도쿄로. ⚠️ **dev→main 전체 머지 금지**(dev에 운영 보류 기능 다수) → main 기준 worktree에서 도쿄 치환만 + 재빌드 → PR #294 머지(운영 배포). origin/main 머지 충돌은 빌드 산출물(admin/index.html)뿐, 재빌드로 해소. Netlify 체크 fail은 미사용 잔존 연동(Vercel만 사용) → `--admin` 머지.
7. **검증**: globalreverb.com·admin·sales 전부 도쿄 반영(curl -L) · 이미지 public 200 · Edge Function 401(정상) · **관리자 기존 비번 로그인 성공**(auth 이관 확정).

**남은 후속:** ① 시드니 프로젝트 1주 보존(롤백 대비) 후 폐기 ② 도쿄 DB password 재설정 + Brevo API 키 재생성(노출) ③ 개인정보처리방침 국외이전 호주→일본 갱신(`/약관확인`) ④ 2026-05-27 09:00 첫 cron 메일 발송 모니터링 ⑤ dev 브랜치 도쿄 전환 커밋(7887f50)은 추후 dev→main(보류기능 운영 배포) 시 정합.
