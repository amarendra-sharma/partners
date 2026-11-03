-- ============================================================================
--  MacroNations Partner Program — UNINSTALL (removes every mp_* object).
--  Deletes all partner data. Only run if you want to remove the program.
-- ============================================================================
drop table if exists mp_ledger, mp_attributions, mp_clicks, mp_lead_events, mp_leads,
  mp_agreements, mp_agreement_templates, mp_resources, mp_partners, mp_settings, mp_admins cascade;
do $$ declare f record; begin
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'mp\_%' loop
    execute 'drop function if exists ' || f.sig || ' cascade';
  end loop;
end $$;
