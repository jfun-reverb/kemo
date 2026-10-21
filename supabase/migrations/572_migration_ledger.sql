-- ============================================================
-- 572_migration_ledger.sql
-- 마이그레이션 적용 기록 표 + 기준선(단계 P1)
-- 사양서: docs/specs/2026-10-20-migration-ledger.md 「설계 1」
--
-- 왜: 어느 서버에 어느 번호·패치가 들어갔는지 데이터베이스 안에 기록이 없다(문서 문장으로만 흩어져
--   실제와 달랐던 사례 6건). 서버마다 이 표 하나에 실행 기록을 덧붙인다.
--   · 칸: 일련 번호 · 종류(migration / patch / baseline) · 열쇠(마이그레이션 = 3자리 숫자 번호, 패치 = 파일 이름)
--         · 파일 이름 · 적용 시각 · 메모. 「누가」 칸은 없다(사용자 결정 4)
--   · 덧붙이기만 — 고치기·지우기·비우기는 트리거가 거부한다(잘못 넣은 줄은 메모에 「정정」을 단 새 줄로 바로잡는다)
--   · 읽기: SQL 편집기·서비스 키만(행 단위 보안 켜고 정책 없음 + 공개 쪽·개별 쪽 두 방향 권한 회수)
--   · 기준선: 이 파일이 끝 바로 앞에 baseline 줄 → 자기 migration 줄을 넣는다. 그보다 먼저 이 서버에서
--     실행된 것의 적용 여부는 이 표가 모른다. 같은 파일을 개발·운영에 각각 돌려 각자 기준선을 갖는다
--   · 이 표 이전 실행·기록 줄 없는 파일의 성공 실행은 손기록 — 절차는 .claude/rules/supabase.md 「적용 기록 표」
-- 편집기 경고: 안 뜸(2026-10-21 개발서버 실측 — CREATE TRIGGER 의 「OR DELETE」·「BEFORE TRUNCATE」 낱말은 단어 검사에 안 걸렸다)
-- 롤백: DROP TABLE IF EXISTS public.migration_ledger; DROP FUNCTION IF EXISTS public._migration_ledger_append_only();
--   (🔴 기준선을 잃는다 — 다시 만들면 그 시각이 새 기준선이 된다)
-- ============================================================
BEGIN;

CREATE TABLE public.migration_ledger (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind       text NOT NULL CHECK (kind IN ('migration', 'patch', 'baseline')),
  key        text NOT NULL CHECK (btrim(key) <> ''),
  file_name  text NOT NULL CHECK (btrim(file_name) <> ''),
  applied_at timestamptz NOT NULL DEFAULT now(),
  note       text,
  CONSTRAINT migration_ledger_migration_key CHECK (kind <> 'migration' OR key ~ '^[0-9]{3}$')
);
COMMENT ON TABLE public.migration_ledger IS
  '이 서버의 마이그레이션·패치 실행 기록(덧붙이기만). baseline 줄보다 먼저 실행된 것은 모른다. 사양서 docs/specs/2026-10-20-migration-ledger.md';

CREATE INDEX migration_ledger_key_idx ON public.migration_ledger (kind, key, applied_at);

-- 덧붙이기만 — 고치기·지우기·비우기 거부
CREATE OR REPLACE FUNCTION public._migration_ledger_append_only()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION 'migration_ledger_append_only' USING ERRCODE = 'P0001',
    HINT = '잘못 넣은 줄은 지우지 말고 메모에 「정정」을 단 새 줄을 넣는다';
END;
$$;
REVOKE ALL ON FUNCTION public._migration_ledger_append_only() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_migration_ledger_no_update_delete
  BEFORE UPDATE OR DELETE ON public.migration_ledger
  FOR EACH ROW EXECUTE FUNCTION public._migration_ledger_append_only();
CREATE TRIGGER trg_migration_ledger_no_truncate
  BEFORE TRUNCATE ON public.migration_ledger
  FOR EACH STATEMENT EXECUTE FUNCTION public._migration_ledger_append_only();

-- 보안: 행 단위 보안 켜고 정책 없음 + 두 방향 권한 회수(공개 쪽 PUBLIC · 개별 쪽 anon·authenticated)
ALTER TABLE public.migration_ledger ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.migration_ledger FROM PUBLIC;
REVOKE ALL ON TABLE public.migration_ledger FROM anon, authenticated;
REVOKE ALL ON SEQUENCE public.migration_ledger_id_seq FROM PUBLIC;
REVOKE ALL ON SEQUENCE public.migration_ledger_id_seq FROM anon, authenticated;

-- 기준선 → 자기 줄(같은 실행 안이라 시각이 같을 수 있다 — 기준선 전후는 일련 번호로 가른다)
INSERT INTO public.migration_ledger (kind, key, file_name, note) VALUES
  ('baseline', 'baseline', '572_migration_ledger.sql',
   '이 서버에서 이 줄보다 먼저 실행된 것의 적용 여부는 이 표가 모른다. 운영의 알려진 미적용 목록은 docs/specs/2026-10-20-migration-ledger.md 「현재 상태」(P1 고정본)');
INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '572', '572_migration_ledger.sql');

COMMIT;
