-- ============================================================
-- migration: 039_seed_reject_reasons
-- purpose  : 결과물 반려 사유 템플릿을 lookup_values에 시드
--            - 기준 데이터 페이지에서 관리 가능
--            - 반려 모달에서 동적 로드
--
-- 기본값: name_ja는 실제 인플루언서 전달용 문구(일본어),
--         name_ko는 관리자 드롭다운 라벨(한국어)
--
-- rollback:
--   DELETE FROM lookup_values WHERE kind = 'reject_reason';
-- ============================================================

INSERT INTO lookup_values (kind, code, name_ko, name_ja, sort_order, active) VALUES
  ('reject_reason', 'pr_tag_missing',
   'PR 태그 누락 (#PR/#広告/#プロモーション)',
   'PRタグ（#PR/#広告/#プロモーションのいずれか）が記載されていません。修正後、再提出してください。',
   10, true),
  ('reject_reason', 'image_unclear',
   '이미지 품질 부족 (흐림/식별 불가)',
   '画像が不鮮明で、レシート内容が確認できません。鮮明な写真で再提出をお願いします。',
   20, true),
  ('reject_reason', 'amount_mismatch',
   '금액·구매일 확인 불가',
   '購入金額または購入日がレシートから確認できません。該当情報が見える写真を添付してください。',
   30, true),
  ('reject_reason', 'post_deleted',
   '게시물 삭제·비공개 상태',
   '投稿が削除、または非公開に設定されており、確認できません。',
   40, true),
  ('reject_reason', 'mention_missing',
   '필수 해시태그·멘션 누락',
   '必須のハッシュタグまたはメンションが含まれていません。',
   50, true)
ON CONFLICT (kind, code) DO NOTHING;
