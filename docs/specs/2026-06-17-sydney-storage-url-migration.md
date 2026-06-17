# 시드니 옛 운영 서버 폐기 전 — Storage 주소 이전 (이관 잔여 작업)

**작성일:** 2026-06-17
**상태:** 계획 완료 (치환 쿼리 준비됨 — 백업 후 개발/실행 단계 대기)
**작성 주체:** 기획 세션 (조사·계획) + reverb-supabase-expert (컬럼 식별·치환 SQL)
**발단:** 사용자 "서버 이관하면서 예전에 쓰던 서버(reverb-jp-production) 정리해야 할 것 같다"

---

## 한 줄 요약

옛 운영 서버(호주 시드니)를 그냥 끄면 **운영 사이트의 캠페인 이미지·영수증이 전부 깨진다.** 도쿄 이관 때 파일은 옮겼으나 **DB에 저장된 이미지 주소가 시드니 그대로** 남아, 운영 사이트가 아직 시드니에서 이미지를 불러오고 있기 때문. **시드니 폐기 전, DB의 시드니 주소를 도쿄 주소로 일괄 치환하는 잔여 작업이 선행돼야 한다.**

---

## 현재 상태 (2026-06-17 조사 완료)

### 대상 서버 (식별자로 확정 — 이름 오인 주의)
| 구분 | 옛 운영 (정리 대상) | 현 운영 (보존) |
|---|---|---|
| 프로젝트 이름 | **reverb-jp-production** | (도쿄) |
| 식별자(ref) | `twofagomeizrtkwlhsuv` | `nrwtujmlbktxjgdwlpjj` |
| 리전 | 🇦🇺 호주 시드니 ap-southeast-2 | 🇯🇵 일본 도쿄 ap-northeast-1 |
| 상태(대시보드) | **Healthy(활성)** · NANO | 운영 중 |
| 코드 연결(`dev/lib/supabase.js`) | ❌ 안 씀 | ✅ |

> ⚠️ 폐기 대상은 **식별자 `twofagomeizrtkwlhsuv` + 리전 호주 시드니**인 것뿐. 이름(`reverb-jp-production`)이 비슷할 수 있으니 **반드시 식별자로 확인**. 도쿄(`nrwtujmlbktxjgdwlpjj`)를 건드리면 운영 전체가 죽는다.

### 발견 경위
- 시드니 대시보드 지난 24시간: 데이터베이스 요청 0 · 인증 1 · **저장소(Storage) 요청 4,278** → DB는 안 쓰는데 이미지만 시드니에서 로드 중인 모순.
- 도쿄 DB `campaigns` 126건 중 **125건의 `img1`이 시드니 주소**(도쿄는 1건뿐 = 이관 후 신규 등록).
- 파일 존재 검증: 캠페인 이미지·영수증 샘플을 시드니 주소→도쿄 주소로 바꿔 접속 → **양쪽 다 정상(HTTP 200)**. 즉 **도쿄에 같은 경로로 파일이 이미 존재**. 파일 이동 불필요, **호스트 문자열만 치환**하면 됨.

### 치환 대상 잔존 건수 (도쿄 운영 DB, 2026-06-17 조사)
| 데이터(테이블.컬럼) | 건수 |
|---|---|
| `deliverables.receipt_url` (영수증) | **968** |
| `campaigns.image_url` | 119 |
| `campaigns.img1` | 119 |
| `campaigns.img2` | 14 |
| `campaigns.img3` | 6 |
| `campaigns.img4` | 4 |
| `campaigns.participation_steps` (구조화 데이터) | 1 |
| `img5`~`img8`·`caution_items`·`ng_items`·번들 3종 | 0 |
| `campaign_caution_history`(참여방법 변경 이력) | **3건** (participation_steps prev/next) |

### 치환 불필요 (확인됨)
- 비공개 버킷 저장분(메시지 첨부 `application_messages.attachments`, 위반 증빙 `influencer_flags.evidence_paths`, 대리등록 증빙)은 **주소가 아니라 경로만** 저장 → 영향 없음.
- 일반 텍스트 본문(`campaigns.description/appeal/guide`, `admin_notices.body_html`)은 이미지 삽입이 차단돼 URL 없음.

---

## 의심·경우의 수 (반대론자)

1. **이름 오인(치명)** — 도쿄 프로젝트 이름이 비슷할 수 있음. 식별자(ref)로만 폐기 대상 확정. ✅ 위 표로 명시.
2. **파일이 도쿄에 없을 위험** — 주소만 바꾸고 파일이 없으면 똑같이 깨짐. ✅ 캠페인·영수증 샘플 200/200 검증 완료. 단 968개 영수증 전수가 아니라 샘플 1개 검증 — 치환 후 ④ 관찰 단계에서 운영 사이트 영수증 화면 실확인 필요.
3. **시드니 cron(예약 메일) 이중 발송** — 시드니가 활성이라 그쪽 pg_cron(매일 다이제스트·주2회 홍보)이 옛 명단에 발송 중일 수 있음. ⚠️ **미확인**(비밀번호 없어 조회 불가). 시드니 일시정지하면 cron도 멈춤 — 폐기 단계에서 자연 해소되나, 그 전까지 이중 발송 가능성은 별도 점검 권장.
4. **jsonb 형식 깨짐** — 구조화 데이터(participation_steps 등) 치환 시 텍스트 변환→치환→재변환. URL은 값(value)에만 있고 키에 없어 안전(supabase-expert 확인). 대상도 1건뿐.
5. **감사 이력 누락** — `campaign_caution_history`는 컬럼명이 특이(`ng_items_prev`/`ng_items_next` 접미사형). 치환 SQL [13]에 포함했으나 건수는 (A)로 먼저 확인 권장.
6. **현재 구현 충돌** — 없음. 이미지 표시는 `imgThumb()`가 DB의 원본 URL을 런타임 변환만 하므로, DB 주소가 도쿄로 바뀌면 변환 경로도 자동 도쿄.

---

## 작업 순서

```
① (선행) 감사 이력 테이블 잔존 건수 확인        ← (A) 조사 SQL
② 도쿄 운영 DB 백업 (대시보드 Database → Backups → Create backup)
③ 주소 일괄 치환                                ← (B) 치환 패치 SQL (트랜잭션)
④ 잔존 0 검증                                   ← (C) 검증 SQL
⑤ 운영 사이트에서 이미지·영수증 정상 + 시드니 트래픽 감소 확인 (며칠 관찰)
⑥ 시드니 cron(예약 메일) 발송 여부 점검 후 일시정지
⑦ (1~2주 관찰) → 시드니 삭제
⑧ 잔여 흔적 청소: .claude/settings.local.json 의 시드니 접속 명령 2줄 제거
```

- ③은 **운영 데이터베이스 변경**이라 ② 백업 + Supabase 전문 검증(완료) 후 **개발 세션이 실행**, 사용자 배포 확인 절차를 따른다.
- 실행 위치는 도쿄 운영 DB(`nrwtujmlbktxjgdwlpjj`) SQL 입력창. **시드니 아님.**

---

## (A) 감사 이력 테이블 조사 SQL (선행 — 읽기 전용)

```sql
-- campaign_caution_history 내 시드니 URL 잔존 건수 (ng 컬럼은 접미사형 _prev/_next)
SELECT
  COUNT(*) FILTER (WHERE prev_caution_items::text      LIKE '%twofagomeizrtkwlhsuv%') AS prev_caution_items_count,
  COUNT(*) FILTER (WHERE next_caution_items::text      LIKE '%twofagomeizrtkwlhsuv%') AS next_caution_items_count,
  COUNT(*) FILTER (WHERE prev_participation_steps::text LIKE '%twofagomeizrtkwlhsuv%') AS prev_participation_steps_count,
  COUNT(*) FILTER (WHERE next_participation_steps::text LIKE '%twofagomeizrtkwlhsuv%') AS next_participation_steps_count,
  COUNT(*) FILTER (WHERE ng_items_prev::text           LIKE '%twofagomeizrtkwlhsuv%') AS ng_items_prev_count,
  COUNT(*) FILTER (WHERE ng_items_next::text           LIKE '%twofagomeizrtkwlhsuv%') AS ng_items_next_count
FROM public.campaign_caution_history;
```

---

## (B) 치환 패치 SQL (도쿄 운영 DB · 트랜잭션 · ② 백업 후 실행)

> `COMMIT;` 전까지는 `ROLLBACK;`으로 전부 취소 가능. [8]~[12]는 조사 결과 0건이나 WHERE 조건으로 자동 스킵되니 포함해도 무방. [13]은 (A) 결과가 있으면 함께.

```sql
BEGIN;

-- [1] deliverables.receipt_url — 예상 968건
UPDATE public.deliverables
SET receipt_url = REPLACE(receipt_url, 'twofagomeizrtkwlhsuv', 'nrwtujmlbktxjgdwlpjj')
WHERE receipt_url LIKE '%twofagomeizrtkwlhsuv%';

-- [2] campaigns.image_url — 예상 119건
UPDATE public.campaigns
SET image_url = REPLACE(image_url, 'twofagomeizrtkwlhsuv', 'nrwtujmlbktxjgdwlpjj')
WHERE image_url LIKE '%twofagomeizrtkwlhsuv%';

-- [3]~[6] campaigns.img1~img4 — 예상 119/14/6/4건
UPDATE public.campaigns SET img1 = REPLACE(img1,'twofagomeizrtkwlhsuv','nrwtujmlbktxjgdwlpjj') WHERE img1 LIKE '%twofagomeizrtkwlhsuv%';
UPDATE public.campaigns SET img2 = REPLACE(img2,'twofagomeizrtkwlhsuv','nrwtujmlbktxjgdwlpjj') WHERE img2 LIKE '%twofagomeizrtkwlhsuv%';
UPDATE public.campaigns SET img3 = REPLACE(img3,'twofagomeizrtkwlhsuv','nrwtujmlbktxjgdwlpjj') WHERE img3 LIKE '%twofagomeizrtkwlhsuv%';
UPDATE public.campaigns SET img4 = REPLACE(img4,'twofagomeizrtkwlhsuv','nrwtujmlbktxjgdwlpjj') WHERE img4 LIKE '%twofagomeizrtkwlhsuv%';

-- [7] campaigns.participation_steps (구조화 데이터) — 예상 1건
UPDATE public.campaigns
SET participation_steps = REPLACE(participation_steps::text,'twofagomeizrtkwlhsuv','nrwtujmlbktxjgdwlpjj')::jsonb
WHERE participation_steps::text LIKE '%twofagomeizrtkwlhsuv%';

-- [8]~[12] 0건 안전망 (campaigns.caution_items/ng_items, participation_sets.steps, caution_sets.items, ng_sets.items)
UPDATE public.campaigns SET caution_items = REPLACE(caution_items::text,'twofagomeizrtkwlhsuv','nrwtujmlbktxjgdwlpjj')::jsonb WHERE caution_items::text LIKE '%twofagomeizrtkwlhsuv%';
UPDATE public.campaigns SET ng_items = REPLACE(ng_items::text,'twofagomeizrtkwlhsuv','nrwtujmlbktxjgdwlpjj')::jsonb WHERE ng_items::text LIKE '%twofagomeizrtkwlhsuv%';
UPDATE public.participation_sets SET steps = REPLACE(steps::text,'twofagomeizrtkwlhsuv','nrwtujmlbktxjgdwlpjj')::jsonb WHERE steps::text LIKE '%twofagomeizrtkwlhsuv%';
UPDATE public.caution_sets SET items = REPLACE(items::text,'twofagomeizrtkwlhsuv','nrwtujmlbktxjgdwlpjj')::jsonb WHERE items::text LIKE '%twofagomeizrtkwlhsuv%';
UPDATE public.ng_sets SET items = REPLACE(items::text,'twofagomeizrtkwlhsuv','nrwtujmlbktxjgdwlpjj')::jsonb WHERE items::text LIKE '%twofagomeizrtkwlhsuv%';

-- [13] campaign_caution_history (감사 이력 — (A) 결과 1건 이상이면 포함)
UPDATE public.campaign_caution_history
SET
  prev_caution_items       = CASE WHEN prev_caution_items::text       LIKE '%twofagomeizrtkwlhsuv%' THEN REPLACE(prev_caution_items::text,'twofagomeizrtkwlhsuv','nrwtujmlbktxjgdwlpjj')::jsonb ELSE prev_caution_items END,
  next_caution_items       = CASE WHEN next_caution_items::text       LIKE '%twofagomeizrtkwlhsuv%' THEN REPLACE(next_caution_items::text,'twofagomeizrtkwlhsuv','nrwtujmlbktxjgdwlpjj')::jsonb ELSE next_caution_items END,
  prev_participation_steps = CASE WHEN prev_participation_steps::text LIKE '%twofagomeizrtkwlhsuv%' THEN REPLACE(prev_participation_steps::text,'twofagomeizrtkwlhsuv','nrwtujmlbktxjgdwlpjj')::jsonb ELSE prev_participation_steps END,
  next_participation_steps = CASE WHEN next_participation_steps::text LIKE '%twofagomeizrtkwlhsuv%' THEN REPLACE(next_participation_steps::text,'twofagomeizrtkwlhsuv','nrwtujmlbktxjgdwlpjj')::jsonb ELSE next_participation_steps END,
  ng_items_prev            = CASE WHEN ng_items_prev::text            LIKE '%twofagomeizrtkwlhsuv%' THEN REPLACE(ng_items_prev::text,'twofagomeizrtkwlhsuv','nrwtujmlbktxjgdwlpjj')::jsonb ELSE ng_items_prev END,
  ng_items_next            = CASE WHEN ng_items_next::text            LIKE '%twofagomeizrtkwlhsuv%' THEN REPLACE(ng_items_next::text,'twofagomeizrtkwlhsuv','nrwtujmlbktxjgdwlpjj')::jsonb ELSE ng_items_next END
WHERE prev_caution_items::text LIKE '%twofagomeizrtkwlhsuv%'
   OR next_caution_items::text LIKE '%twofagomeizrtkwlhsuv%'
   OR prev_participation_steps::text LIKE '%twofagomeizrtkwlhsuv%'
   OR next_participation_steps::text LIKE '%twofagomeizrtkwlhsuv%'
   OR ng_items_prev::text LIKE '%twofagomeizrtkwlhsuv%'
   OR ng_items_next::text LIKE '%twofagomeizrtkwlhsuv%';

-- 검증 (C)를 같은 트랜잭션에서 먼저 돌려 0 확인 후 COMMIT 권장
COMMIT;
```

---

## (C) 치환 후 검증 SQL (모두 0이어야 성공)

```sql
SELECT
  (SELECT COUNT(*) FROM public.deliverables WHERE receipt_url LIKE '%twofagomeizrtkwlhsuv%')              AS receipt_url_잔존,
  (SELECT COUNT(*) FROM public.campaigns WHERE image_url LIKE '%twofagomeizrtkwlhsuv%')                   AS image_url_잔존,
  (SELECT COUNT(*) FROM public.campaigns WHERE img1 LIKE '%twofagomeizrtkwlhsuv%')                        AS img1_잔존,
  (SELECT COUNT(*) FROM public.campaigns WHERE img2 LIKE '%twofagomeizrtkwlhsuv%')                        AS img2_잔존,
  (SELECT COUNT(*) FROM public.campaigns WHERE img3 LIKE '%twofagomeizrtkwlhsuv%')                        AS img3_잔존,
  (SELECT COUNT(*) FROM public.campaigns WHERE img4 LIKE '%twofagomeizrtkwlhsuv%')                        AS img4_잔존,
  (SELECT COUNT(*) FROM public.campaigns WHERE participation_steps::text LIKE '%twofagomeizrtkwlhsuv%')   AS participation_steps_잔존,
  (SELECT COUNT(*) FROM public.campaign_caution_history
     WHERE prev_caution_items::text LIKE '%twofagomeizrtkwlhsuv%' OR next_caution_items::text LIKE '%twofagomeizrtkwlhsuv%'
        OR prev_participation_steps::text LIKE '%twofagomeizrtkwlhsuv%' OR next_participation_steps::text LIKE '%twofagomeizrtkwlhsuv%'
        OR ng_items_prev::text LIKE '%twofagomeizrtkwlhsuv%' OR ng_items_next::text LIKE '%twofagomeizrtkwlhsuv%') AS caution_history_잔존;
```

---

## (D) 롤백·백업

- **작업 전**: Supabase 대시보드 → `Database` → `Backups` → `Create backup`(Pro 플랜 즉시 가능).
- **COMMIT 전**: `ROLLBACK;`으로 전부 원복.
- **COMMIT 후 문제 시**: 역치환 SQL(`nrwtujmlbktxjgdwlpjj`→`twofagomeizrtkwlhsuv`). 단 **시드니가 살아있는 동안만** 의미. 영수증 역치환은 `AND kind='receipt'` 안전망. (전문은 supabase-expert 산출 보관 — 필요 시 재생성)

---

## 시드니 폐기 (치환·관찰 완료 후)

1. ⑥ 시드니 예약 메일(pg_cron) 발송 여부 점검 — 도는 중이면 이중 발송이므로 정지.
2. ⑥ 시드니 **일시정지(Pause)** → 운영 사이트·메일 이상 없는지 1~2주 관찰.
3. ⑦ 이상 없으면 **삭제**.
4. ⑧ `.claude/settings.local.json`의 시드니(`twofagomeizrtkwlhsuv`/`aws-1-ap-southeast-2.pooler...`) 접속 명령 2줄 제거(코드 동작엔 영향 없는 허용 목록).
5. 보안 후속(이관 체크리스트 잔여): 시드니 service_role·Brevo 키 폐기.

---

## 미확인·다음 세션 확인 사항
- ✅ `campaign_caution_history` 잔존 = 3건(participation_steps 변경 이력) — (A) 확인 완료, 치환 [13] 포함.
- 시드니 pg_cron 메일 발송 여부 — 비밀번호 필요(대시보드 SQL 입력창에서 `SELECT jobname, schedule, active FROM cron.job;`).
- 영수증 968건 중 샘플 1개만 도쿄 존재 검증 — ⑤ 관찰 단계에서 운영 영수증 화면 실확인.

## 구현 결과 (개발 세션이 채울 것)
_(미착수 — 치환 실행 후 영향 행 수·검증 결과·시드니 폐기일 기록)_
