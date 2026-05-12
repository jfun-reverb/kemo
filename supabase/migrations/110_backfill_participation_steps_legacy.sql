-- migration 110: 운영 캠페인 참여방법(participation_steps) NULL/빈배열 행 백필
-- 목적: admin.js / application.js의 legacySteps 하드코딩 폴백을 제거하기 위해
--       이미 운영 중인 캠페인 중 participation_steps가 없는 행에
--       기존 3단계 기본값을 일괄 채운다.
--
-- 영향 행: campaigns WHERE participation_steps IS NULL OR participation_steps = '[]'::jsonb
-- 검증 쿼리(적용 후 실행): 아래 롤백 섹션 참조
--
-- 롤백 방법 (아래 UPDATE의 jsonb 본문은 본 마이그레이션의 SET 절과 정확히 동일해야 함):
--   UPDATE public.campaigns
--   SET participation_steps = '[]'::jsonb
--   WHERE participation_steps = '[
--     {
--       "title_ja": "応募フォームを提出",
--       "title_ko": "신청 폼 제출",
--       "desc_ja": "当選された方には当選日にLINEにてご連絡いたします。",
--       "desc_ko": "선정된 분께는 선정일에 LINE으로 안내드립니다."
--     },
--     {
--       "title_ja": "製品を使用してSNSにレビューを投稿",
--       "title_ko": "제품을 사용해 SNS에 리뷰 게시",
--       "desc_ja": "① 投稿ガイドを確認 ② SNSにレビューを投稿",
--       "desc_ko": "① 게시 가이드 확인 ② SNS에 리뷰 게시"
--     },
--     {
--       "title_ja": "LINEで投稿リンクを送る",
--       "title_ko": "LINE으로 게시 링크 전송",
--       "desc_ja": "SNSの投稿リンクをコピーして、LINEで送信してください。",
--       "desc_ko": "SNS 게시 링크를 복사해 LINE으로 보내주세요."
--     }
--   ]'::jsonb
--     AND participation_set_id IS NULL;
--
--   주의: 백필 후 운영자가 폼에서 본 값을 직접 수정한 행은 jsonb 본문이 달라 위 WHERE에 안 걸림.
--         그 경우 안전한 롤백은 적용 전 pg_dump 백업에서 복원.

BEGIN;

-- 잠금 트리거 일시 비활성 (migration 075/108)
--   closed 캠페인의 participation_steps 변경을 막는 트리거가 시스템 백필도 차단함.
--   백필은 시스템 마이그레이션이라 변경 의도가 안전하므로 우회. 운영자 수동 편집은 여전히 보호됨.
ALTER TABLE public.campaigns DISABLE TRIGGER trg_block_closed_caution_participation;

UPDATE public.campaigns
SET participation_steps = '[
  {
    "title_ja": "応募フォームを提出",
    "title_ko": "신청 폼 제출",
    "desc_ja": "当選された方には当選日にLINEにてご連絡いたします。",
    "desc_ko": "선정된 분께는 선정일에 LINE으로 안내드립니다."
  },
  {
    "title_ja": "製品を使用してSNSにレビューを投稿",
    "title_ko": "제품을 사용해 SNS에 리뷰 게시",
    "desc_ja": "① 投稿ガイドを確認 ② SNSにレビューを投稿",
    "desc_ko": "① 게시 가이드 확인 ② SNS에 리뷰 게시"
  },
  {
    "title_ja": "LINEで投稿リンクを送る",
    "title_ko": "LINE으로 게시 링크 전송",
    "desc_ja": "SNSの投稿リンクをコピーして、LINEで送信してください。",
    "desc_ko": "SNS 게시 링크를 복사해 LINE으로 보내주세요."
  }
]'::jsonb
WHERE (participation_steps IS NULL OR participation_steps = '[]'::jsonb);

-- 잠금 트리거 재활성
ALTER TABLE public.campaigns ENABLE TRIGGER trg_block_closed_caution_participation;

-- 영향 행 확인용 (적용 직후 실행)
-- SELECT id, title, participation_steps
-- FROM public.campaigns
-- WHERE jsonb_array_length(participation_steps) = 3
--   AND participation_set_id IS NULL
-- ORDER BY created_at DESC;

COMMIT;
