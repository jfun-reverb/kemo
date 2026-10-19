-- ============================================================
-- 2026-10-19-receipt-url-to-private-path.sql — 영수증 칸 공개 주소 → 비공개 통 경로 (출시 날 ⑥ · 작업표 「조각 8」)
--
-- 순서(한 번에 한 단계씩 — 결과를 보고 다음으로):
--   0) 🔴 데이터베이스 백업(운영). 그다음 scripts/copy-receipts-to-private.js 를 관리자 화면 콘솔에서 돌려 실패 0 을 확인
--   1) [A] 사전 건수   2) [B] 백업 표 + 올린 사람 고치기 + 변환(한 거래)   3) [C] 대조   (되돌리기는 [R])
--   🔴 파일 전체를 붙여 한 번에 돌리지 말 것 — 블록(머리 [A]~[C])만 골라 실행한다(통째로 돌리면 마지막 결과만 보인다)
--
-- 무엇을 바꾸나
--   · kind='receipt' 줄 중 공개 주소 접두사(…/storage/v1/object/public/campaign-images/)가 있고
--     🔴 **비공개 통에 같은 경로의 파일이 있는 줄만** receipt_url 을 경로(receipts/…)로 바꾼다(D1 — 리뷰 인증샷 줄은 그대로).
--     복사가 실패한 파일의 줄은 공개 주소로 남는다(두 형식 모두 화면이 연다 — 조각 6).
--   · 비공개 통 복사본의 올린 사람(owner_id)을 그 영수증 줄의 회원으로 고친다 — 복사 도구를 돌린 관리자가
--     owner 라서, 안 고치면 회원이 자기 영수증을 못 본다(548 조회 정책의 올린 사람 대조). 썸네일 사본도 같이.
--   · 되돌리기용으로 바꾸기 전 값을 백업 표 public._receipt_url_backup_20261019 에 남긴다(행 단위 보안 켜고 정책 없음 —
--     서비스 키·편집기만). 🔴 조각 20(옛 공개 파일 삭제)·21 이 끝나고 확인한 뒤 지운다.
-- 편집기 경고: [B] 에 UPDATE 가 있다. [R] 은 주석이다(필요할 때만 주석을 풀어 실행). DROP·DELETE 없음.
-- ============================================================

-- [A] 사전 건수 — 바꿀 줄 · 그중 복사본이 있는 줄 · 함께 쓰는 파일(리뷰 인증샷도 가리킴)
WITH r AS (
  SELECT d.id, d.user_id, regexp_replace(d.receipt_url, '^.*/storage/v1/object/public/campaign-images/', '') AS p
    FROM public.deliverables d
   WHERE d.kind = 'receipt' AND d.receipt_url LIKE '%/storage/v1/object/public/campaign-images/%'
), rv AS (   -- 리뷰 인증샷 경로는 한 번만 계산
  SELECT DISTINCT regexp_replace(v.receipt_url, '^.*/storage/v1/object/public/campaign-images/', '') AS p
    FROM public.deliverables v
   WHERE v.kind = 'review_image' AND v.receipt_url LIKE '%/storage/v1/object/public/campaign-images/%'
)
SELECT count(*)                                                                                         AS public_receipt_rows,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM storage.objects o WHERE o.bucket_id = 'deliverable-media' AND o.name = r.p)) AS with_private_copy,
       count(*) FILTER (WHERE r.p IN (SELECT p FROM rv))                                                AS shared_with_review,
       (SELECT count(*) FROM (SELECT p FROM r GROUP BY p HAVING count(DISTINCT user_id) > 1) x)       AS path_with_two_members   -- 0 이어야 owner 가 한 사람으로 정해진다
  FROM r;

-- [B] 백업 → 올린 사람 → 변환 (한 거래)
BEGIN;

CREATE TABLE IF NOT EXISTS public._receipt_url_backup_20261019 (
  deliverable_id uuid PRIMARY KEY,
  receipt_url    text NOT NULL,
  backed_up_at   timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public._receipt_url_backup_20261019 ENABLE ROW LEVEL SECURITY;   -- 정책 없음 = 서비스 키·편집기만
REVOKE ALL ON public._receipt_url_backup_20261019 FROM PUBLIC, anon, authenticated;

WITH r AS (
  SELECT d.id, d.receipt_url, d.user_id,
         regexp_replace(d.receipt_url, '^.*/storage/v1/object/public/campaign-images/', '') AS p
    FROM public.deliverables d
   WHERE d.kind = 'receipt' AND d.receipt_url LIKE '%/storage/v1/object/public/campaign-images/%'
     AND EXISTS (SELECT 1 FROM storage.objects o WHERE o.bucket_id = 'deliverable-media'
                    AND o.name = regexp_replace(d.receipt_url, '^.*/storage/v1/object/public/campaign-images/', ''))
)
INSERT INTO public._receipt_url_backup_20261019 (deliverable_id, receipt_url)
SELECT id, receipt_url FROM r
ON CONFLICT (deliverable_id) DO NOTHING;      -- 다시 돌려도 처음 값을 지킨다

-- 올린 사람 = 그 영수증 줄의 회원(원본 + thumb/ 사본)
UPDATE storage.objects o
   SET owner_id = b.user_id::text
  FROM (
    SELECT d.user_id, regexp_replace(k.receipt_url, '^.*/storage/v1/object/public/campaign-images/', '') AS p
      FROM public._receipt_url_backup_20261019 k
      JOIN public.deliverables d ON d.id = k.deliverable_id
  ) b
 WHERE o.bucket_id = 'deliverable-media'
   AND o.name IN (b.p, regexp_replace(b.p, '^([^/]+)/', '\1/thumb/'))
   AND o.owner_id IS DISTINCT FROM b.user_id::text;

-- 변환 — 백업에 있고 아직 공개 주소인 영수증 줄만. 바꾼 줄 수를 돌려준다(converted)
WITH u AS (
  UPDATE public.deliverables d
     SET receipt_url = regexp_replace(d.receipt_url, '^.*/storage/v1/object/public/campaign-images/', '')
    FROM public._receipt_url_backup_20261019 k
   WHERE k.deliverable_id = d.id
     AND d.kind = 'receipt'
     AND d.receipt_url LIKE '%/storage/v1/object/public/campaign-images/%'
  RETURNING 1
)
SELECT count(*) AS converted FROM u;

COMMIT;
-- ⚠️ 변환은 deliverables UPDATE 라 updated_at 만 바뀐다(상태 기록·알림 트리거는 status 변경에만, 마감·영수증 잠금·탈퇴 차단은 편집기 실행이라 통과)

-- [C] 대조 — still_public(공개 통 주소가 남은 영수증 줄) 0 이어야 한다(남으면 복사 실패분 — 도구를 다시 돌리고 [B] 재실행)
--     other_url = 공개 통이 아닌 주소(개발서버 시험 줄 example.invalid 등) — 변환 대상이 아니다
SELECT count(*) FILTER (WHERE receipt_url LIKE '%/storage/v1/object/public/campaign-images/%') AS still_public,
       count(*) FILTER (WHERE receipt_url LIKE '%://%' AND receipt_url NOT LIKE '%/storage/v1/object/public/campaign-images/%') AS other_url,
       count(*) FILTER (WHERE receipt_url NOT LIKE '%://%')  AS now_path,
       (SELECT count(*) FROM public._receipt_url_backup_20261019) AS backed_up
  FROM public.deliverables WHERE kind = 'receipt' AND receipt_url IS NOT NULL;
-- 표본 20건은 회원·관리자 화면에서 연다(작업표 조각 8 완료 정의)

-- [R] 되돌리기 — 백업 값으로 정확히 되돌린다(올린 사람은 그대로 둬도 된다 — 공개 주소는 정책과 무관하게 열린다)
--     ⚠️ 변환 뒤 그 영수증 줄을 다시 고친 경우(재제출·수정)는 되돌리지 않는다 — updated_at 이 백업 시각보다 늦은 줄 제외
--     🔴 조각 20(옛 공개 파일 삭제) 뒤에는 되돌리기가 깨진다(옛 주소의 파일이 없다)
-- BEGIN;
-- UPDATE public.deliverables d
--    SET receipt_url = k.receipt_url
--   FROM public._receipt_url_backup_20261019 k
--  WHERE k.deliverable_id = d.id AND d.kind = 'receipt' AND d.receipt_url NOT LIKE '%://%'
--    AND d.updated_at <= k.backed_up_at + interval '5 minutes';
-- COMMIT;
