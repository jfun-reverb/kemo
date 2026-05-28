-- ============================================
-- 마이그레이션 157: LIPS·@cosme 채널 추가
-- 의존: 024 (lookup_values 테이블), 025 (recruit_types 컬럼)
-- 대상: 개발서버 + 운영서버
-- 요약: 일본 뷰티 리뷰 플랫폼 LIPS·@cosme를 채널로 등록.
--       Qoo10 패턴(인플 계정 미수집, 리뷰어 캠페인 전용).
--       influencers 컬럼 추가 없음. 기존 1,398행 영향 없음.
-- 사양서: docs/specs/2026-05-27-lips-cosme-channels.md
-- 위험도: 최하 (INSERT 2행, ON CONFLICT DO NOTHING 멱등)
-- ============================================

INSERT INTO lookup_values (kind, code, name_ko, name_ja, sort_order, recruit_types) VALUES
  ('channel', 'lips',  'LIPS',   'LIPS',   60, ARRAY['monitor']),
  ('channel', 'cosme', '@cosme', '@cosme', 70, ARRAY['monitor'])
ON CONFLICT (kind, code) DO NOTHING;

-- ============================================
-- 운영 검증 쿼리 (적용 후 SQL Editor에서 실행)
-- ============================================
-- SELECT id, kind, code, name_ko, name_ja, sort_order, recruit_types, active
--   FROM lookup_values
--  WHERE kind = 'channel' AND code IN ('lips', 'cosme')
--  ORDER BY sort_order;
-- 기대 결과: 2행 (lips sort_order=60 / cosme sort_order=70, recruit_types='{monitor}', active=true)

-- ============================================
-- 롤백 SQL (필요 시 아래 BEGIN 블록 실행)
-- ============================================
-- BEGIN;
--   DELETE FROM lookup_values WHERE kind = 'channel' AND code IN ('lips', 'cosme');
-- COMMIT;
