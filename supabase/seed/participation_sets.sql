-- ============================================
-- participation_sets 초기 시드
-- 작성일: 2026-04-15
-- 용도: 신규 환경 초기 데이터 투입 (staging / production 공통)
-- 재실행: name_ko 기준 충돌 시 SKIP (idempotent)
-- 원본 하드코딩 출처: dev/js/application.js:105-119
-- ============================================

INSERT INTO public.participation_sets (name_ko, name_ja, recruit_types, steps, sort_order, active)
VALUES

-- ① 리뷰어(monitor) 기본
(
  '리뷰어 기본',
  'レビュアー基本',
  ARRAY['monitor'],
  '[
    {
      "title_ko": "신청 폼 제출",
      "title_ja": "応募フォームを提出",
      "desc_ko":  "당첨자는 당첨일에 LINE으로 안내드립니다.",
      "desc_ja":  "当選された方には当選日にLINEにてご連絡いたします。"
    },
    {
      "title_ko": "제품 사용 후 SNS에 리뷰 게시",
      "title_ja": "製品を使用してSNSにレビューを投稿",
      "desc_ko":  "① 게시 가이드 확인 ② SNS에 리뷰 게시",
      "desc_ja":  "① 投稿ガイドを確認 ② SNSにレビューを投稿"
    },
    {
      "title_ko": "LINE으로 게시 링크 전송",
      "title_ja": "LINEで投稿リンクを送る",
      "desc_ko":  "SNS 게시물 링크를 복사해 LINE으로 보내주세요.",
      "desc_ja":  "SNSの投稿リンクをコピーして、LINEで送信してください。"
    }
  ]'::jsonb,
  10,
  true
),

-- ② 기프팅(gifting) 기본
(
  '기프팅 기본',
  'ギフティング基本',
  ARRAY['gifting'],
  '[
    {
      "title_ko": "신청 폼 제출",
      "title_ja": "応募フォームを提出",
      "desc_ko":  "당첨자는 당첨일에 LINE으로 안내드립니다.",
      "desc_ja":  "当選された方には当選日にLINEにてご連絡いたします。"
    },
    {
      "title_ko": "제품 사용 후 SNS에 리뷰 게시",
      "title_ja": "製品を使用してSNSにレビューを投稿",
      "desc_ko":  "① 게시 가이드 확인 ② SNS에 리뷰 게시",
      "desc_ja":  "① 投稿ガイドを確認 ② SNSにレビューを投稿"
    },
    {
      "title_ko": "LINE으로 게시 링크 전송",
      "title_ja": "LINEで投稿リンクを送る",
      "desc_ko":  "SNS 게시물 링크를 복사해 LINE으로 보내주세요.",
      "desc_ja":  "SNSの投稿リンクをコピーして、LINEで送信してください。"
    }
  ]'::jsonb,
  20,
  true
),

-- ③ 방문형(visit) 기본 — STEP 2 visit 전용 문구
(
  '방문형 기본',
  '訪問型基本',
  ARRAY['visit'],
  '[
    {
      "title_ko": "신청 폼 제출",
      "title_ja": "応募フォームを提出",
      "desc_ko":  "당첨자는 당첨일에 LINE으로 안내드립니다.",
      "desc_ja":  "当選された方には当選日にLINEにてご連絡いたします。"
    },
    {
      "title_ko": "매장/팝업 방문 후 SNS에 게시",
      "title_ja": "店舗/ポップアップを訪問しSNSに投稿",
      "desc_ko":  "① 게시 가이드 확인 ② 방문 후 SNS에 리뷰 게시",
      "desc_ja":  "① 投稿ガイドを確認 ② 訪問後SNSにレビューを投稿"
    },
    {
      "title_ko": "LINE으로 게시 링크 전송",
      "title_ja": "LINEで投稿リンクを送る",
      "desc_ko":  "SNS 게시물 링크를 복사해 LINE으로 보내주세요.",
      "desc_ja":  "SNSの投稿リンクをコピーして、LINEで送信してください。"
    }
  ]'::jsonb,
  30,
  true
)

ON CONFLICT (name_ko) DO NOTHING;
