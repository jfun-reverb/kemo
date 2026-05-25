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

## 실행 이력
(실제 이관 진행 시 단계별 결과·소요시간·문제점을 여기 기록)
