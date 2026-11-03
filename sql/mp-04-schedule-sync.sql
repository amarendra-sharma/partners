-- ============================================================================
--  MacroNations Partner Program — hourly Stripe sync (live project only)
--  Calls the mp-stripe-sync edge function at minute 17 of every hour.
--  Remove with:  select cron.unschedule('mp-stripe-sync');
-- ============================================================================
create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.unschedule(jobid) from cron.job where jobname = 'mp-stripe-sync';

select cron.schedule(
  'mp-stripe-sync',
  '17 * * * *',
  $job$
    select net.http_post(
      url     := 'https://rtaiivegcqqmdchpguzn.supabase.co/functions/v1/mp-stripe-sync',
      headers := jsonb_build_object('Content-Type', 'application/json',
                                    'x-mp-token', (select value from public.mp_secrets where id = 'cron')),
      body    := '{"source":"schedule"}'::jsonb,
      timeout_milliseconds := 60000
    );
  $job$
);
