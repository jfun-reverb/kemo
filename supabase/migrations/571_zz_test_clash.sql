-- 시험
BEGIN;
SELECT 1;
INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '571', '571_zz_test_clash.sql');
COMMIT;
