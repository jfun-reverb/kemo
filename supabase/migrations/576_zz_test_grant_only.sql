BEGIN;
GRANT EXECUTE ON FUNCTION public.cs_save_case_draft(uuid, integer, text, text) TO authenticated;
INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '576', '576_zz_test_grant_only.sql');
COMMIT;
