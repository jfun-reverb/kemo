BEGIN;
CREATE OR REPLACE FUNCTION public.cs_save_case_draft(p uuid) RETURNS void LANGUAGE sql AS $$ SELECT 1 $$;
INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '575', '575_zz_test_redefine.sql');
COMMIT;
