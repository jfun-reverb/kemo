-- ============================================================
-- 2026-10-21-migration-ledger-prod-check.sql — 읽기 전용(쓰기 없음 · 기록 표에 기록하지 않는다)
-- 적용 기록 표(572) 운영 적용 전 확인: 사양서 docs/specs/2026-10-20-migration-ledger.md
--   · 착수 전 확인 ① — 운영에 supabase_migrations.schema_migrations 가 있는지 · migration_ledger 이름이 비어 있는지(줄 pre-1·pre-2)
--   · 「현재 상태」 미적용 목록 바로잡기(착수 전 알아야 할 것 ③) — 번호마다 대표 흔적(새 표·칸·함수·트리거, 재정의만 하는 파일은 본문 조각)이 있는지
-- 판정 주의: 565 = 545 본문에 있던 낱말이 「없음」으로 판정(545 를 다시 돌리면 거짓) · 568 = 예약 작업 이름(pg_cron 없으면 거짓)
--   · 505 = 함수만 증명(메시지 옮기기 완료는 별개) · 554·555 = 같은 이름 제약을 정의 글자로 가름
-- 2026-10-21 개발서버에서 오류 없이 56줄 반환 확인(문법)
-- 편집기 경고: 안 뜸(SELECT 만)
-- ============================================================
SELECT * FROM (
SELECT '362'::text AS num, 'trigger trg_withdrawal_signup_block'::text AS probe, (EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgname='trg_withdrawal_signup_block' AND NOT t.tgisinternal))::boolean AS present, 'auth.users trigger'::text AS note
UNION ALL
SELECT '504'::text AS num, 'table public.general_inquiry_threads'::text AS probe, (to_regclass('public.general_inquiry_threads') IS NOT NULL)::boolean AS present, ''::text AS note
UNION ALL
SELECT '505'::text AS num, 'function close_general_inquiry_thread'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='close_general_inquiry_thread'))::boolean AS present, 'new in 505 (also _general_inquiry_resolve_caller)'::text AS note
UNION ALL
SELECT '506'::text AS num, 'view general_inquiry_thread_summary'::text AS probe, (to_regclass('public.general_inquiry_thread_summary') IS NOT NULL)::boolean AS present, '508 redefines the view'::text AS note
UNION ALL
SELECT '507'::text AS num, 'column public.general_inquiry_threads.title'::text AS probe, (EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = to_regclass('public.general_inquiry_threads') AND a.attname='title' AND NOT a.attisdropped))::boolean AS present, ''::text AS note
UNION ALL
SELECT '508'::text AS num, 'function update_general_inquiry_thread_title'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='update_general_inquiry_thread_title'))::boolean AS present, ''::text AS note
UNION ALL
SELECT '509'::text AS num, 'function _application_message_writable'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='_application_message_writable'))::boolean AS present, ''::text AS note
UNION ALL
SELECT '510'::text AS num, 'column public.faq_nodes.show_in_service'::text AS probe, (EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = to_regclass('public.faq_nodes') AND a.attname='show_in_service' AND NOT a.attisdropped))::boolean AS present, ''::text AS note
UNION ALL
SELECT '511'::text AS num, 'admin_create_deliverable_proxy body has "proxy_window_closed"'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='admin_create_deliverable_proxy' AND p.prosrc LIKE '%proxy_window_closed%'))::boolean AS present, 'no later redefinition'::text AS note
UNION ALL
SELECT '512'::text AS num, 'trigger trg_deliverable_stamp_submitted_at'::text AS probe, (EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgname='trg_deliverable_stamp_submitted_at' AND NOT t.tgisinternal))::boolean AS present, ''::text AS note
UNION ALL
SELECT '525'::text AS num, 'trigger trg_guard_cancelled_application_status'::text AS probe, (EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgname='trg_guard_cancelled_application_status' AND NOT t.tgisinternal))::boolean AS present, ''::text AS note
UNION ALL
SELECT '526'::text AS num, 'table public.brand_accounts'::text AS probe, (to_regclass('public.brand_accounts') IS NOT NULL)::boolean AS present, ''::text AS note
UNION ALL
SELECT '527'::text AS num, 'function _brand_email_owner'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='_brand_email_owner'))::boolean AS present, 'only in 527 (other 527 functions redefined by 532/533/569)'::text AS note
UNION ALL
SELECT '528'::text AS num, 'invite_admin body has "brand_account_email"'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='invite_admin' AND p.prosrc LIKE '%brand_account_email%'))::boolean AS present, 'no later redefinition'::text AS note
UNION ALL
SELECT '529'::text AS num, 'get_brand_ops_detail body has "d.status <> ''draft''"'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='get_brand_ops_detail' AND p.prosrc LIKE '%d.status <> ''draft''%'))::boolean AS present, 'no later redefinition'::text AS note
UNION ALL
SELECT '530'::text AS num, 'table public.brand_invites'::text AS probe, (to_regclass('public.brand_invites') IS NOT NULL)::boolean AS present, ''::text AS note
UNION ALL
SELECT '531'::text AS num, 'function create_brand_invite'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='create_brand_invite'))::boolean AS present, ''::text AS note
UNION ALL
SELECT '532'::text AS num, 'function respond_brand_invite'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='respond_brand_invite'))::boolean AS present, ''::text AS note
UNION ALL
SELECT '533'::text AS num, 'function admin_check_brand_account_email'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='admin_check_brand_account_email'))::boolean AS present, ''::text AS note
UNION ALL
SELECT '534'::text AS num, 'get_brand_invite_link_state body has "v_inv.issued_at"'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='get_brand_invite_link_state' AND p.prosrc LIKE '%v_inv.issued_at%'))::boolean AS present, '532 base lacks this'::text AS note
UNION ALL
SELECT '536'::text AS num, 'table public.brand_profile_history'::text AS probe, (to_regclass('public.brand_profile_history') IS NOT NULL)::boolean AS present, ''::text AS note
UNION ALL
SELECT '537'::text AS num, 'column public.applications.guide_acknowledged_at'::text AS probe, (EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = to_regclass('public.applications') AND a.attname='guide_acknowledged_at' AND NOT a.attisdropped))::boolean AS present, ''::text AS note
UNION ALL
SELECT '539'::text AS num, 'function _orient_save_core'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='_orient_save_core'))::boolean AS present, ''::text AS note
UNION ALL
SELECT '540'::text AS num, 'function get_my_orient_sheets'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='get_my_orient_sheets'))::boolean AS present, ''::text AS note
UNION ALL
SELECT '541'::text AS num, 'function orient_lookup_gate_account'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='orient_lookup_gate_account'))::boolean AS present, ''::text AS note
UNION ALL
SELECT '542'::text AS num, 'get_orient_sheet body has "''reason'', ''moved''"'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='get_orient_sheet' AND p.prosrc LIKE '%''reason'', ''moved''%'))::boolean AS present, 'no later redefinition'::text AS note
UNION ALL
SELECT '543'::text AS num, 'function _brand_campaign_view_status'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='_brand_campaign_view_status'))::boolean AS present, ''::text AS note
UNION ALL
SELECT '544'::text AS num, 'table public.campaign_brand_publish'::text AS probe, (to_regclass('public.campaign_brand_publish') IS NOT NULL)::boolean AS present, ''::text AS note
UNION ALL
SELECT '545'::text AS num, 'function _results_payload_core'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='_results_payload_core'))::boolean AS present, '565 redefines body; existence still proves 545'::text AS note
UNION ALL
SELECT '546'::text AS num, 'function attach_campaign_ext_source'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='attach_campaign_ext_source'))::boolean AS present, ''::text AS note
UNION ALL
SELECT '547'::text AS num, 'function _brand_campaign_result_counts'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='_brand_campaign_result_counts'))::boolean AS present, ''::text AS note
UNION ALL
SELECT '548'::text AS num, 'bucket deliverable-media'::text AS probe, (EXISTS (SELECT 1 FROM storage.buckets b WHERE b.id='deliverable-media'))::boolean AS present, ''::text AS note
UNION ALL
SELECT '549'::text AS num, 'function _deliverable_media_key'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='_deliverable_media_key'))::boolean AS present, ''::text AS note
UNION ALL
SELECT '550'::text AS num, '_brand_campaign_summary body has "ext_participants"'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='_brand_campaign_summary' AND p.prosrc LIKE '%ext_participants%'))::boolean AS present, 'no later redefinition'::text AS note
UNION ALL
SELECT '551'::text AS num, 'function service_brand_receipt_signable'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='service_brand_receipt_signable'))::boolean AS present, ''::text AS note
UNION ALL
SELECT '552'::text AS num, 'table public.brand_provision_logs'::text AS probe, (to_regclass('public.brand_provision_logs') IS NOT NULL)::boolean AS present, ''::text AS note
UNION ALL
SELECT '553'::text AS num, 'function purge_expired_personal_data_logs'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='purge_expired_personal_data_logs'))::boolean AS present, 'cron personal-data-logs-retention-daily also'::text AS note
UNION ALL
SELECT '554'::text AS num, 'table public.campaign_shipping_lists'::text AS probe, (to_regclass('public.campaign_shipping_lists') IS NOT NULL)::boolean AS present, ''::text AS note
UNION ALL
SELECT '555'::text AS num, 'trigger trg_lookup_cs_legacy_lock'::text AS probe, (EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgname='trg_lookup_cs_legacy_lock' AND NOT t.tgisinternal))::boolean AS present, ''::text AS note
UNION ALL
SELECT '555'::text AS num, 'constraint lookup_values_kind_check has cs_category'::text AS probe, (EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conname='lookup_values_kind_check' AND c.conrelid=to_regclass('public.lookup_values') AND pg_get_constraintdef(c.oid) LIKE '%cs_category%'))::boolean AS present, 'second probe'::text AS note
UNION ALL
SELECT '556'::text AS num, 'table public.cs_cases'::text AS probe, (to_regclass('public.cs_cases') IS NOT NULL)::boolean AS present, ''::text AS note
UNION ALL
SELECT '557'::text AS num, 'function admin_get_campaign_shipping'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='admin_get_campaign_shipping'))::boolean AS present, ''::text AS note
UNION ALL
SELECT '558'::text AS num, 'trigger trg_cs_case_on_member_message'::text AS probe, (EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgname='trg_cs_case_on_member_message' AND NOT t.tgisinternal))::boolean AS present, ''::text AS note
UNION ALL
SELECT '559'::text AS num, 'admin_set_campaign_brand_publish body has "_record_brand_provision"'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='admin_set_campaign_brand_publish' AND p.prosrc LIKE '%_record_brand_provision%'))::boolean AS present, 'no later redefinition'::text AS note
UNION ALL
SELECT '560'::text AS num, 'function get_cs_summary'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='get_cs_summary'))::boolean AS present, ''::text AS note
UNION ALL
SELECT '561'::text AS num, 'function service_mark_shipping_mail_sent(uuid,boolean,timestamptz)'::text AS probe, (to_regprocedure('public.service_mark_shipping_mail_sent(uuid,boolean,timestamptz)') IS NOT NULL)::boolean AS present, '3-arg signature new in 561'::text AS note
UNION ALL
SELECT '562'::text AS num, 'function cs_complete_case'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='cs_complete_case'))::boolean AS present, ''::text AS note
UNION ALL
SELECT '563'::text AS num, 'trigger trg_cs_case_source_removed'::text AS probe, (EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgname='trg_cs_case_source_removed' AND NOT t.tgisinternal))::boolean AS present, ''::text AS note
UNION ALL
SELECT '564'::text AS num, 'link_orient_card_to_campaign body has "form_type_retired"'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='link_orient_card_to_campaign' AND p.prosrc LIKE '%form_type_retired%'))::boolean AS present, 'no later redefinition'::text AS note
UNION ALL
SELECT '565'::text AS num, '_results_payload_core body lacks "proxy_purchase"'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='_results_payload_core' AND p.prosrc NOT LIKE '%proxy_purchase%'))::boolean AS present, 'present = 565 removed proxy_purchase key (545 has it); false if function missing'::text AS note
UNION ALL
SELECT '566'::text AS num, 'function get_cs_case'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='get_cs_case'))::boolean AS present, ''::text AS note
UNION ALL
SELECT '567'::text AS num, 'function list_pending_cs_attachment_purge'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='list_pending_cs_attachment_purge'))::boolean AS present, ''::text AS note
UNION ALL
SELECT '568'::text AS num, 'cron job cs-comment-attachment-purge-daily'::text AS probe, (CASE WHEN to_regclass('cron.job') IS NULL THEN false ELSE (xpath('/row/c/text()', query_to_xml('SELECT count(*) AS c FROM cron.job WHERE jobname = ''cs-comment-attachment-purge-daily''', false, true, '')))[1]::text::int > 0 END)::boolean AS present, 'cron only; false if pg_cron absent'::text AS note
UNION ALL
SELECT '569'::text AS num, 'column public.brand_password_reset_requests.allowed'::text AS probe, (EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = to_regclass('public.brand_password_reset_requests') AND a.attname='allowed' AND NOT a.attisdropped))::boolean AS present, ''::text AS note
UNION ALL
SELECT '570'::text AS num, 'table public.cs_attachment_purge_queue'::text AS probe, (to_regclass('public.cs_attachment_purge_queue') IS NOT NULL)::boolean AS present, ''::text AS note
UNION ALL
SELECT '571'::text AS num, 'function cs_save_case_draft'::text AS probe, (EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='cs_save_case_draft'))::boolean AS present, ''::text AS note
UNION ALL
SELECT 'pre-1'::text, 'supabase_migrations.schema_migrations exists'::text, (to_regclass('supabase_migrations.schema_migrations') IS NOT NULL), 'true 면 건드리지 않고 이름만 피한다'::text
UNION ALL
SELECT 'pre-2'::text, 'public.migration_ledger exists'::text, (to_regclass('public.migration_ledger') IS NOT NULL), '572 적용 전이면 false 여야 한다'::text
) q ORDER BY 1;
