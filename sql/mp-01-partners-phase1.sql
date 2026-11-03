-- ============================================================================
--  MacroNations Partner Program — Phase 1 schema
--  Project: MacroNation Tournament (rtaiivegcqqmdchpguzn)
--
--  ADDITIVE ONLY: creates new mp_* tables, functions and policies. It does not
--  alter or read-modify any existing course table. Safe to re-run (idempotent).
--  To remove everything later, run mp-99-uninstall.sql.
--
--  Conventions: text ids, RLS everywhere, auth.uid()::text, writes that need
--  rules (status, rates, conflicts) go through SECURITY DEFINER functions.
-- ============================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- 1. Admins + settings
-- ---------------------------------------------------------------------------
create table if not exists mp_admins (
  user_id    text primary key,
  added_at   timestamptz not null default now()
);
alter table mp_admins enable row level security;

-- Seed: whoever is already the Intro Micro admin becomes partner super-admin.
insert into mp_admins (user_id)
select p.user_id from im_person p where p.role = 'admin'
on conflict do nothing;

create or replace function mp_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from mp_admins a where a.user_id = auth.uid()::text)
$$;

drop policy if exists mp_admins_sel on mp_admins;
create policy mp_admins_sel on mp_admins for select to authenticated using (mp_is_admin());

create table if not exists mp_settings (
  id                    text primary key default 'default' check (id = 'default'),
  default_rate          numeric(5,4) not null default 0.20,
  tier_rate             numeric(5,4) not null default 0.25,
  tier_threshold        int          not null default 5,
  attribution_months    int          not null default 24,
  lead_protection_days  int          not null default 90,
  min_payout_cents      int          not null default 5000,
  agreements_open       boolean      not null default false,  -- flip on after counsel review
  support_email         text         not null default 'partners@macronations.com',
  site_url              text         not null default 'https://macronations.com',
  updated_at            timestamptz  not null default now()
);
insert into mp_settings (id) values ('default') on conflict do nothing;
alter table mp_settings enable row level security;
drop policy if exists mp_settings_sel on mp_settings;
create policy mp_settings_sel on mp_settings for select to authenticated using (true);
drop policy if exists mp_settings_upd on mp_settings;
create policy mp_settings_upd on mp_settings for update to authenticated using (mp_is_admin()) with check (mp_is_admin());

-- ---------------------------------------------------------------------------
-- 2. Partners
-- ---------------------------------------------------------------------------
create table if not exists mp_partners (
  id            text primary key default gen_random_uuid()::text,
  user_id       text not null unique,
  email         text not null,
  full_name     text not null,
  phone         text,
  partner_type  text not null default 'faculty' check (partner_type in ('faculty','sales','other')),
  institution   text,
  title         text,
  region        text,
  linkedin      text,
  pitch         text,          -- "how will you promote MacroNations?"
  status        text not null default 'applied'
                check (status in ('applied','approved','active','suspended','rejected')),
  code          text unique,   -- referral code, issued on approval
  rate_override numeric(5,4) check (rate_override is null or (rate_override >= 0 and rate_override <= 1)),
  admin_notes   text,
  decision_note text,
  created_at    timestamptz not null default now(),
  approved_at   timestamptz,
  approved_by   text,
  updated_at    timestamptz not null default now()
);
alter table mp_partners enable row level security;

create or replace function mp_my_partner_id() returns text
language sql stable security definer set search_path = public as $$
  select id from mp_partners where user_id = auth.uid()::text
$$;

drop policy if exists mp_partners_sel on mp_partners;
create policy mp_partners_sel on mp_partners for select to authenticated
  using (user_id = auth.uid()::text or mp_is_admin());

-- ---------------------------------------------------------------------------
-- 3. Agreement templates + signed agreements
-- ---------------------------------------------------------------------------
create table if not exists mp_agreement_templates (
  id          text primary key default gen_random_uuid()::text,
  kind        text not null check (kind in ('partner','pilot','adoption','license')),
  version     int  not null,
  title       text not null,
  body        text not null,
  is_current  boolean not null default false,
  created_at  timestamptz not null default now(),
  created_by  text,
  unique (kind, version)
);
alter table mp_agreement_templates enable row level security;
drop policy if exists mp_tpl_sel on mp_agreement_templates;
create policy mp_tpl_sel on mp_agreement_templates for select to authenticated using (true);

create table if not exists mp_agreements (
  id                 text primary key default gen_random_uuid()::text,
  kind               text not null,
  template_id        text references mp_agreement_templates(id),
  version            int,
  partner_id         text references mp_partners(id),
  counterparty_name  text,
  counterparty_email text,
  signed_name        text not null,
  signed_at          timestamptz not null default now(),
  user_agent         text,
  body_snapshot      text not null,
  terms              jsonb not null default '{}'::jsonb,
  status             text not null default 'signed' check (status in ('signed','countersigned','void')),
  countersigned_at   timestamptz,
  countersigned_by   text
);
alter table mp_agreements enable row level security;
drop policy if exists mp_agr_sel on mp_agreements;
create policy mp_agr_sel on mp_agreements for select to authenticated
  using (partner_id = mp_my_partner_id() or mp_is_admin());

-- ---------------------------------------------------------------------------
-- 4. Leads (professors a partner is working) + activity log
-- ---------------------------------------------------------------------------
create table if not exists mp_leads (
  id              text primary key default gen_random_uuid()::text,
  partner_id      text not null references mp_partners(id),
  prof_name       text not null,
  prof_email      text not null,
  prof_email_norm text generated always as (lower(btrim(prof_email))) stored,
  institution     text not null,
  department      text,
  course_taught   text,
  est_students    int,
  stage           text not null default 'contacted'
                  check (stage in ('contacted','demo','pilot','adopted','lost')),
  notes           text,
  next_step       text,
  next_step_date  date,
  protected_until date not null,
  review_status   text not null default 'clear'
                  check (review_status in ('clear','conflict','approved','rejected')),
  review_note     text,
  conflict_reason text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists mp_leads_partner on mp_leads(partner_id);
create index if not exists mp_leads_email   on mp_leads(prof_email_norm);
alter table mp_leads enable row level security;

drop policy if exists mp_leads_sel on mp_leads;
create policy mp_leads_sel on mp_leads for select to authenticated
  using (partner_id = mp_my_partner_id() or mp_is_admin());
drop policy if exists mp_leads_upd on mp_leads;
create policy mp_leads_upd on mp_leads for update to authenticated
  using (partner_id = mp_my_partner_id()) with check (partner_id = mp_my_partner_id());
-- Partners may only edit the working fields; ownership/protection/review are locked.
-- 'adopted' is set by an admin when a course is attributed (see trigger below).
revoke update on mp_leads from authenticated;
grant update (prof_name, department, course_taught, est_students, stage, notes,
              next_step, next_step_date, updated_at) on mp_leads to authenticated;

create table if not exists mp_lead_events (
  id         text primary key default gen_random_uuid()::text,
  lead_id    text not null references mp_leads(id) on delete cascade,
  partner_id text not null references mp_partners(id),
  kind       text not null check (kind in ('created','stage','note','email','call','meeting','demo')),
  detail     text,
  at         timestamptz not null default now()
);
create index if not exists mp_events_partner on mp_lead_events(partner_id, at);
alter table mp_lead_events enable row level security;
drop policy if exists mp_ev_sel on mp_lead_events;
create policy mp_ev_sel on mp_lead_events for select to authenticated
  using (partner_id = mp_my_partner_id() or mp_is_admin());
drop policy if exists mp_ev_ins on mp_lead_events;
create policy mp_ev_ins on mp_lead_events for insert to authenticated
  with check (partner_id = mp_my_partner_id()
              and kind in ('note','email','call','meeting','demo')
              and exists (select 1 from mp_leads l where l.id = lead_id and l.partner_id = mp_my_partner_id()));

-- Stage changes: log them, stop partners self-declaring 'adopted', bump updated_at.
create or replace function mp_leads_before_upd() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.stage is distinct from old.stage then
    if old.stage = 'adopted' and not mp_is_admin()
       and coalesce(current_setting('mp.internal', true), '') <> '1' then
      raise exception 'This course is already confirmed as adopted. Contact MacroNations to change it.';
    end if;
    if new.stage = 'adopted' and not mp_is_admin()
       and coalesce(current_setting('mp.internal', true), '') <> '1' then
      raise exception 'A course is marked Adopted once MacroNations confirms it. Move the lead to Pilot and tell us the course is live.';
    end if;
    insert into mp_lead_events (lead_id, partner_id, kind, detail)
    values (new.id, new.partner_id, 'stage', old.stage || ' → ' || new.stage);
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists mp_leads_before_upd on mp_leads;
create trigger mp_leads_before_upd before update on mp_leads
  for each row execute function mp_leads_before_upd();

-- ---------------------------------------------------------------------------
-- 5. Referral clicks
-- ---------------------------------------------------------------------------
create table if not exists mp_clicks (
  id         text primary key default gen_random_uuid()::text,
  partner_id text not null references mp_partners(id),
  code       text not null,
  path       text,
  referrer   text,
  at         timestamptz not null default now()
);
create index if not exists mp_clicks_partner on mp_clicks(partner_id, at);
alter table mp_clicks enable row level security;
drop policy if exists mp_clicks_sel on mp_clicks;
create policy mp_clicks_sel on mp_clicks for select to authenticated
  using (partner_id = mp_my_partner_id() or mp_is_admin());

-- ---------------------------------------------------------------------------
-- 6. Attributions (adopted course ↔ partner) and the commission ledger
-- ---------------------------------------------------------------------------
create table if not exists mp_attributions (
  id              text primary key default gen_random_uuid()::text,
  partner_id      text not null references mp_partners(id),
  lead_id         text references mp_leads(id),
  product         text not null check (product in ('im','ma','it','eq','sa','fin','ef','institutional')),
  course_id       text,
  course_label    text not null,
  professor_email text,
  institution     text,
  starts_at       date not null default current_date,
  ends_at         date not null,
  rate            numeric(5,4) not null,
  status          text not null default 'active' check (status in ('active','ended','void')),
  note            text,
  created_by      text,
  created_at      timestamptz not null default now()
);
create unique index if not exists mp_attr_course_active
  on mp_attributions(product, course_id) where status = 'active' and course_id is not null;
alter table mp_attributions enable row level security;
drop policy if exists mp_attr_sel on mp_attributions;
create policy mp_attr_sel on mp_attributions for select to authenticated
  using (partner_id = mp_my_partner_id() or mp_is_admin());

create table if not exists mp_ledger (
  id               text primary key default gen_random_uuid()::text,
  partner_id       text not null references mp_partners(id),
  attribution_id   text references mp_attributions(id),
  source           text not null check (source in ('stripe','invoice','adjustment')),
  source_ref       text,
  description      text,
  gross_cents      int not null default 0,
  fees_cents       int not null default 0,
  refund_cents     int not null default 0,
  net_cents        int generated always as (gross_cents - fees_cents - refund_cents) stored,
  rate             numeric(5,4) not null,
  commission_cents int not null,
  earned_on        date not null default current_date,
  status           text not null default 'pending' check (status in ('pending','approved','paid','void')),
  paid_at          timestamptz,
  payout_ref       text,
  created_by       text,
  created_at       timestamptz not null default now()
);
create unique index if not exists mp_ledger_source_ref on mp_ledger(source, source_ref) where source_ref is not null;
create index if not exists mp_ledger_partner on mp_ledger(partner_id, earned_on);
alter table mp_ledger enable row level security;
drop policy if exists mp_ledger_sel on mp_ledger;
create policy mp_ledger_sel on mp_ledger for select to authenticated
  using (partner_id = mp_my_partner_id() or mp_is_admin());

-- ---------------------------------------------------------------------------
-- 7. Toolkit resources
-- ---------------------------------------------------------------------------
create table if not exists mp_resources (
  id          text primary key default gen_random_uuid()::text,
  kind        text not null check (kind in ('deck','demo','email','video','doc','link')),
  title       text not null,
  description text,
  url         text,
  body        text,             -- e.g. an email template with {{prof_name}} / {{my_link}}
  sort        int not null default 100,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
alter table mp_resources enable row level security;
drop policy if exists mp_res_sel on mp_resources;
create policy mp_res_sel on mp_resources for select to authenticated
  using (mp_is_admin() or (is_active and exists
    (select 1 from mp_partners p where p.user_id = auth.uid()::text and p.status in ('approved','active'))));
drop policy if exists mp_res_admin on mp_resources;
create policy mp_res_admin on mp_resources for all to authenticated
  using (mp_is_admin()) with check (mp_is_admin());

-- ---------------------------------------------------------------------------
-- 8. Helpers
-- ---------------------------------------------------------------------------
create or replace function mp_effective_rate(p_partner text) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(p.rate_override,
           case when (select count(*) from mp_attributions a
                      where a.partner_id = p.id and a.status <> 'void') >= s.tier_threshold
                then s.tier_rate else s.default_rate end)
  from mp_partners p cross join mp_settings s
  where p.id = p_partner
$$;

create or replace function mp_new_code(p_name text) returns text
language plpgsql volatile set search_path = public as $$
declare base text; c text; i int := 0;
begin
  base := upper(regexp_replace(split_part(coalesce(p_name,''), ' ', 1), '[^A-Za-z]', '', 'g'));
  if length(base) < 2 then base := 'MN'; end if;
  base := left(base, 8);
  loop
    c := base || lpad((floor(random() * 9000) + 1000)::int::text, 4, '0');
    exit when not exists (select 1 from mp_partners where code = c);
    i := i + 1;
    if i > 50 then c := 'MN' || upper(substr(md5(random()::text), 1, 8)); exit; end if;
  end loop;
  return c;
end $$;

-- Fill {{fields}} in an agreement for a given partner.
create or replace function mp_render_agreement(p_body text, p_partner text) returns text
language plpgsql stable security definer set search_path = public as $$
declare p mp_partners; s mp_settings; r numeric; out text;
begin
  select * into p from mp_partners where id = p_partner;
  select * into s from mp_settings where id = 'default';
  r := coalesce(p.rate_override, s.default_rate);
  out := p_body;
  out := replace(out, '{{partner_name}}',    coalesce(p.full_name, ''));
  out := replace(out, '{{partner_email}}',   coalesce(p.email, ''));
  out := replace(out, '{{rate}}',            trim(to_char(r * 100, 'FM990.##')) || '%');
  out := replace(out, '{{tier_rate}}',       trim(to_char(greatest(s.tier_rate, r) * 100, 'FM990.##')) || '%');
  out := replace(out, '{{tier_threshold}}',  s.tier_threshold::text);
  out := replace(out, '{{months}}',          s.attribution_months::text);
  out := replace(out, '{{protection_days}}', s.lead_protection_days::text);
  out := replace(out, '{{min_payout}}',      '$' || to_char(s.min_payout_cents / 100.0, 'FM999,990.00'));
  out := replace(out, '{{date}}',            to_char(current_date, 'FMMonth FMDD, YYYY'));
  return out;
end $$;

-- ---------------------------------------------------------------------------
-- 9. Partner-facing RPCs
-- ---------------------------------------------------------------------------
create or replace function mp_apply(p_full_name text, p_phone text, p_partner_type text,
  p_institution text, p_title text, p_region text, p_linkedin text, p_pitch text)
returns mp_partners language plpgsql security definer set search_path = public as $$
declare uid text := auth.uid()::text; em text := lower(coalesce(auth.jwt() ->> 'email', '')); r mp_partners;
begin
  if uid is null then raise exception 'Please sign in first.'; end if;
  if coalesce(btrim(p_full_name), '') = '' then raise exception 'Please enter your full name.'; end if;
  select * into r from mp_partners where user_id = uid;
  if found and r.status not in ('applied','rejected') then
    raise exception 'You already have a partner account.';
  end if;
  insert into mp_partners (user_id, email, full_name, phone, partner_type, institution, title, region, linkedin, pitch, status)
  values (uid, em, btrim(p_full_name), p_phone, coalesce(nullif(p_partner_type,''), 'faculty'),
          p_institution, p_title, p_region, p_linkedin, p_pitch, 'applied')
  on conflict (user_id) do update set
    full_name = excluded.full_name, phone = excluded.phone, partner_type = excluded.partner_type,
    institution = excluded.institution, title = excluded.title, region = excluded.region,
    linkedin = excluded.linkedin, pitch = excluded.pitch, status = 'applied',
    decision_note = null, updated_at = now()
  returning * into r;
  return r;
end $$;

create or replace function mp_update_profile(p_full_name text, p_phone text,
  p_institution text, p_title text, p_region text, p_linkedin text)
returns mp_partners language plpgsql security definer set search_path = public as $$
declare r mp_partners;
begin
  update mp_partners set full_name = coalesce(nullif(btrim(p_full_name),''), full_name), phone = p_phone,
         institution = p_institution, title = p_title, region = p_region, linkedin = p_linkedin, updated_at = now()
   where user_id = auth.uid()::text returning * into r;
  if not found then raise exception 'No partner account.'; end if;
  return r;
end $$;

-- The partner agreement as it would read for the signed-in partner.
create or replace function mp_my_agreement_preview()
returns table (template_id text, version int, title text, body text, agreements_open boolean)
language plpgsql stable security definer set search_path = public as $$
declare pid text := mp_my_partner_id();
begin
  if pid is null then raise exception 'No partner account.'; end if;
  return query
    select t.id, t.version, t.title, mp_render_agreement(t.body, pid), s.agreements_open
      from mp_agreement_templates t cross join mp_settings s
     where t.kind = 'partner' and t.is_current
     order by t.version desc limit 1;
end $$;

create or replace function mp_sign_partner_agreement(p_template_id text, p_signed_name text, p_user_agent text)
returns mp_agreements language plpgsql security definer set search_path = public as $$
declare p mp_partners; t mp_agreement_templates; s mp_settings; a mp_agreements;
begin
  select * into p from mp_partners where user_id = auth.uid()::text;
  if not found then raise exception 'No partner account.'; end if;
  if p.status not in ('approved','active') then raise exception 'Your application has not been approved yet.'; end if;
  select * into s from mp_settings where id = 'default';
  if not s.agreements_open then raise exception 'The partner agreement is being finalized. You will be emailed when it is ready to sign.'; end if;
  select * into t from mp_agreement_templates where id = p_template_id and kind = 'partner' and is_current;
  if not found then raise exception 'The agreement was updated. Please reload and review the latest version.'; end if;
  if lower(regexp_replace(btrim(coalesce(p_signed_name,'')), '\s+', ' ', 'g'))
     <> lower(regexp_replace(btrim(p.full_name), '\s+', ' ', 'g')) then
    raise exception 'Please type your full name exactly as shown: %', p.full_name;
  end if;
  insert into mp_agreements (kind, template_id, version, partner_id, counterparty_name, counterparty_email,
                             signed_name, user_agent, body_snapshot, terms)
  values ('partner', t.id, t.version, p.id, p.full_name, p.email, btrim(p_signed_name), left(p_user_agent, 400),
          mp_render_agreement(t.body, p.id),
          jsonb_build_object('rate', coalesce(p.rate_override, s.default_rate), 'tier_rate', s.tier_rate,
                             'tier_threshold', s.tier_threshold, 'months', s.attribution_months,
                             'protection_days', s.lead_protection_days, 'min_payout_cents', s.min_payout_cents))
  returning * into a;
  update mp_partners set status = 'active', code = coalesce(code, mp_new_code(full_name)), updated_at = now()
   where id = p.id;
  return a;
end $$;

-- Register a professor. Checks for conflicts across ALL partners (which a
-- partner cannot see directly) and flags rather than blocks.
create or replace function mp_register_lead(p_prof_name text, p_prof_email text, p_institution text,
  p_department text, p_course_taught text, p_est_students int, p_notes text)
returns mp_leads language plpgsql security definer set search_path = public as $$
declare p mp_partners; s mp_settings; em text; why text := null; l mp_leads;
begin
  select * into p from mp_partners where user_id = auth.uid()::text;
  if not found or p.status <> 'active' then raise exception 'Only active partners can register professors.'; end if;
  em := lower(btrim(coalesce(p_prof_email, '')));
  if em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Please enter a valid email address for the professor.'; end if;
  if coalesce(btrim(p_prof_name),'') = '' or coalesce(btrim(p_institution),'') = '' then
    raise exception 'Name and institution are required.';
  end if;
  if exists (select 1 from mp_leads where partner_id = p.id and prof_email_norm = em and stage <> 'lost') then
    raise exception 'This professor is already in your pipeline.';
  end if;
  select * into s from mp_settings where id = 'default';

  if exists (select 1 from mp_attributions a where lower(a.professor_email) = em and a.status = 'active') then
    why := 'This professor already has a MacroNations course credited to a partner.';
  elsif exists (select 1 from mp_leads o where o.prof_email_norm = em and o.partner_id <> p.id
                  and o.stage <> 'lost' and o.review_status in ('clear','approved')
                  and o.protected_until >= current_date) then
    why := 'Another partner registered this professor recently.';
  end if;

  insert into mp_leads (partner_id, prof_name, prof_email, institution, department, course_taught,
                        est_students, notes, protected_until, review_status, conflict_reason)
  values (p.id, btrim(p_prof_name), em, btrim(p_institution), p_department, p_course_taught,
          p_est_students, p_notes, current_date + s.lead_protection_days,
          case when why is null then 'clear' else 'conflict' end, why)
  returning * into l;
  insert into mp_lead_events (lead_id, partner_id, kind, detail) values (l.id, p.id, 'created', null);
  return l;
end $$;

-- Public (anon) — log a referral-link visit. Silent no-op for unknown codes.
create or replace function mp_log_click(p_code text, p_path text, p_referrer text)
returns boolean language plpgsql security definer set search_path = public as $$
declare pid text;
begin
  select id into pid from mp_partners where code = upper(btrim(coalesce(p_code,''))) and status = 'active';
  if pid is null then return false; end if;
  -- light throttle: ignore floods from the same code within 2 seconds
  if exists (select 1 from mp_clicks where partner_id = pid and at > now() - interval '2 seconds') then return true; end if;
  insert into mp_clicks (partner_id, code, path, referrer)
  values (pid, upper(btrim(p_code)), left(p_path, 300), left(p_referrer, 300));
  return true;
end $$;

-- Partner scorecard (or any partner's, for an admin).
create or replace function mp_scorecard(p_partner text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare pid text; s mp_settings; courses int; j jsonb; mstart date := date_trunc('month', current_date)::date;
begin
  pid := coalesce(p_partner, mp_my_partner_id());
  if pid is null then raise exception 'No partner account.'; end if;
  if pid <> coalesce(mp_my_partner_id(), '') and not mp_is_admin() then raise exception 'Not allowed.'; end if;
  select * into s from mp_settings where id = 'default';
  select count(*) into courses from mp_attributions where partner_id = pid and status <> 'void';
  j := jsonb_build_object(
    'leads_total',     (select count(*) from mp_leads where partner_id = pid),
    'leads_open',      (select count(*) from mp_leads where partner_id = pid and stage in ('contacted','demo','pilot')),
    'by_stage',        (select coalesce(jsonb_object_agg(stage, n), '{}'::jsonb)
                          from (select stage, count(*) n from mp_leads where partner_id = pid group by stage) x),
    'demos',           (select count(*) from mp_lead_events where partner_id = pid
                          and (kind = 'demo' or (kind = 'stage' and detail like '%→ demo'))),
    'activities_30d',  (select count(*) from mp_lead_events where partner_id = pid
                          and kind in ('note','email','call','meeting','demo') and at > now() - interval '30 days'),
    'clicks_30d',      (select count(*) from mp_clicks where partner_id = pid and at > now() - interval '30 days'),
    'courses',         courses,
    'courses_active',  (select count(*) from mp_attributions where partner_id = pid and status = 'active'),
    'earned_month_cents', (select coalesce(sum(commission_cents),0) from mp_ledger
                            where partner_id = pid and status <> 'void' and earned_on >= mstart),
    'earned_total_cents', (select coalesce(sum(commission_cents),0) from mp_ledger where partner_id = pid and status <> 'void'),
    'pending_cents',   (select coalesce(sum(commission_cents),0) from mp_ledger where partner_id = pid and status = 'pending'),
    'approved_cents',  (select coalesce(sum(commission_cents),0) from mp_ledger where partner_id = pid and status = 'approved'),
    'paid_cents',      (select coalesce(sum(commission_cents),0) from mp_ledger where partner_id = pid and status = 'paid'),
    'rate',            mp_effective_rate(pid),
    'rate_override',   (select rate_override from mp_partners where id = pid),
    'default_rate',    s.default_rate,
    'tier_rate',       s.tier_rate,
    'tier_threshold',  s.tier_threshold,
    'tier',            case when courses >= s.tier_threshold then 'Senior Partner' else 'Partner' end,
    'to_next_tier',    greatest(s.tier_threshold - courses, 0),
    'months',          s.attribution_months,
    'protection_days', s.lead_protection_days,
    'min_payout_cents', s.min_payout_cents
  );
  return j;
end $$;

-- Leaderboard among active partners. Other partners appear as "First L.".
create or replace function mp_leaderboard() returns table
  (rank int, display_name text, courses int, demos int, leads int, is_me boolean)
language sql stable security definer set search_path = public as $$
  with base as (
    select p.id, p.full_name,
      (select count(*) from mp_attributions a where a.partner_id = p.id and a.status <> 'void')::int courses,
      (select count(*) from mp_lead_events e where e.partner_id = p.id
         and (e.kind = 'demo' or (e.kind = 'stage' and e.detail like '%→ demo')))::int demos,
      (select count(*) from mp_leads l where l.partner_id = p.id)::int leads
    from mp_partners p where p.status = 'active'
  )
  select (row_number() over (order by courses desc, demos desc, leads desc, full_name))::int,
         case when id = mp_my_partner_id() or mp_is_admin() then full_name
              else split_part(full_name,' ',1) || coalesce(' ' || nullif(left(split_part(full_name,' ',2),1),'') || '.', '') end,
         courses, demos, leads, id = mp_my_partner_id()
  from base
  where mp_my_partner_id() is not null or mp_is_admin()
  order by 1 limit 25
$$;

-- ---------------------------------------------------------------------------
-- 10. Admin RPCs
-- ---------------------------------------------------------------------------
create or replace function mp_admin_guard() returns void language plpgsql stable security definer set search_path = public as $$
begin if not mp_is_admin() then raise exception 'Admins only.'; end if; end $$;

create or replace function mp_admin_decide(p_partner text, p_decision text, p_note text)
returns mp_partners language plpgsql security definer set search_path = public as $$
declare r mp_partners;
begin
  perform mp_admin_guard();
  select * into r from mp_partners where id = p_partner;
  if not found then raise exception 'Partner not found.'; end if;
  if p_decision = 'approve' then
    update mp_partners set status = case when exists (select 1 from mp_agreements a where a.partner_id = r.id and a.kind = 'partner' and a.status <> 'void')
                                         then 'active' else 'approved' end,
           code = coalesce(code, mp_new_code(full_name)), approved_at = coalesce(approved_at, now()),
           approved_by = auth.uid()::text, decision_note = p_note, updated_at = now()
     where id = p_partner returning * into r;
  elsif p_decision = 'reject' then
    update mp_partners set status = 'rejected', decision_note = p_note, updated_at = now() where id = p_partner returning * into r;
  elsif p_decision = 'suspend' then
    update mp_partners set status = 'suspended', decision_note = p_note, updated_at = now() where id = p_partner returning * into r;
  elsif p_decision = 'reinstate' then
    update mp_partners set status = case when exists (select 1 from mp_agreements a where a.partner_id = r.id and a.kind = 'partner' and a.status <> 'void')
                                         then 'active' else 'approved' end,
           decision_note = p_note, updated_at = now() where id = p_partner returning * into r;
  else
    raise exception 'Unknown decision %', p_decision;
  end if;
  return r;
end $$;

create or replace function mp_admin_set_terms(p_partner text, p_rate_override numeric, p_admin_notes text)
returns mp_partners language plpgsql security definer set search_path = public as $$
declare r mp_partners;
begin
  perform mp_admin_guard();
  if p_rate_override is not null and (p_rate_override < 0 or p_rate_override > 1) then
    raise exception 'Rate must be between 0 and 100%%.';
  end if;
  update mp_partners set rate_override = p_rate_override, admin_notes = p_admin_notes, updated_at = now()
   where id = p_partner returning * into r;
  return r;
end $$;

create or replace function mp_admin_review_lead(p_lead text, p_decision text, p_note text, p_extend_days int)
returns mp_leads language plpgsql security definer set search_path = public as $$
declare r mp_leads;
begin
  perform mp_admin_guard();
  update mp_leads set
     review_status = case p_decision when 'approve' then 'approved' when 'reject' then 'rejected' else review_status end,
     review_note = coalesce(p_note, review_note),
     protected_until = case when coalesce(p_extend_days,0) > 0 then greatest(protected_until, current_date) + p_extend_days else protected_until end
   where id = p_lead returning * into r;
  if not found then raise exception 'Lead not found.'; end if;
  return r;
end $$;

-- Credit an adopted course to a partner. Rate defaults to the partner's
-- effective rate today (override per deal with p_rate).
create or replace function mp_admin_attribute(p_partner text, p_lead text, p_product text, p_course_id text,
  p_course_label text, p_professor_email text, p_institution text, p_starts_at date, p_rate numeric, p_note text)
returns mp_attributions language plpgsql security definer set search_path = public as $$
declare s mp_settings; r mp_attributions; st date := coalesce(p_starts_at, current_date); l mp_leads;
begin
  perform mp_admin_guard();
  select * into s from mp_settings where id = 'default';
  if p_lead is not null then
    select * into l from mp_leads where id = p_lead and partner_id = p_partner;
    if not found then raise exception 'That lead does not belong to this partner.'; end if;
  end if;
  insert into mp_attributions (partner_id, lead_id, product, course_id, course_label, professor_email, institution,
                               starts_at, ends_at, rate, note, created_by)
  values (p_partner, p_lead, p_product, nullif(btrim(coalesce(p_course_id,'')),''), p_course_label,
          lower(coalesce(nullif(btrim(coalesce(p_professor_email,'')),''), l.prof_email)),
          coalesce(nullif(btrim(coalesce(p_institution,'')),''), l.institution),
          st, (st + make_interval(months => s.attribution_months))::date,
          coalesce(p_rate, mp_effective_rate(p_partner)), p_note, auth.uid()::text)
  returning * into r;
  if p_lead is not null then
    perform set_config('mp.internal', '1', true);
    update mp_leads set stage = 'adopted' where id = p_lead and stage <> 'adopted';
  end if;
  return r;
end $$;

create or replace function mp_admin_set_attribution_status(p_id text, p_status text)
returns mp_attributions language plpgsql security definer set search_path = public as $$
declare r mp_attributions;
begin
  perform mp_admin_guard();
  update mp_attributions set status = p_status where id = p_id returning * into r;
  return r;
end $$;

-- Record revenue against an attributed course (institutional invoice, manual
-- Stripe entry, or adjustment). Commission is computed here, never typed.
create or replace function mp_admin_add_revenue(p_attribution text, p_source text, p_source_ref text,
  p_description text, p_gross_cents int, p_fees_cents int, p_refund_cents int, p_earned_on date)
returns mp_ledger language plpgsql security definer set search_path = public as $$
declare a mp_attributions; r mp_ledger; d date := coalesce(p_earned_on, current_date);
begin
  perform mp_admin_guard();
  select * into a from mp_attributions where id = p_attribution;
  if not found then raise exception 'Attribution not found.'; end if;
  if a.status = 'void' then raise exception 'That attribution is void.'; end if;
  if d < a.starts_at or d >= a.ends_at then
    raise exception 'Revenue dated % is outside this course''s commission window (% to %).', d, a.starts_at, a.ends_at;
  end if;
  insert into mp_ledger (partner_id, attribution_id, source, source_ref, description, gross_cents, fees_cents,
                         refund_cents, rate, commission_cents, earned_on, created_by)
  values (a.partner_id, a.id, p_source, nullif(btrim(coalesce(p_source_ref,'')),''), p_description,
          coalesce(p_gross_cents,0), coalesce(p_fees_cents,0), coalesce(p_refund_cents,0), a.rate,
          round((coalesce(p_gross_cents,0) - coalesce(p_fees_cents,0) - coalesce(p_refund_cents,0)) * a.rate)::int,
          d, auth.uid()::text)
  returning * into r;
  return r;
end $$;

create or replace function mp_admin_set_ledger_status(p_ids text[], p_status text, p_payout_ref text)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform mp_admin_guard();
  if p_status not in ('pending','approved','paid','void') then raise exception 'Bad status'; end if;
  update mp_ledger set status = p_status,
         paid_at = case when p_status = 'paid' then now() else null end,
         payout_ref = case when p_status = 'paid' then coalesce(p_payout_ref, payout_ref) else payout_ref end
   where id = any(p_ids) and status <> 'paid';   -- paid rows are final
  get diagnostics n = row_count;
  return n;
end $$;

-- Publish a new version of an agreement template (old signed copies keep their snapshot).
create or replace function mp_admin_publish_template(p_kind text, p_title text, p_body text)
returns mp_agreement_templates language plpgsql security definer set search_path = public as $$
declare v int; r mp_agreement_templates;
begin
  perform mp_admin_guard();
  select coalesce(max(version),0) + 1 into v from mp_agreement_templates where kind = p_kind;
  update mp_agreement_templates set is_current = false where kind = p_kind;
  insert into mp_agreement_templates (kind, version, title, body, is_current, created_by)
  values (p_kind, v, p_title, p_body, true, auth.uid()::text) returning * into r;
  return r;
end $$;

create or replace function mp_admin_countersign(p_agreement text)
returns mp_agreements language plpgsql security definer set search_path = public as $$
declare r mp_agreements;
begin
  perform mp_admin_guard();
  update mp_agreements set status = 'countersigned', countersigned_at = now(), countersigned_by = auth.uid()::text
   where id = p_agreement and status = 'signed' returning * into r;
  return r;
end $$;

create or replace function mp_admin_overview() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform mp_admin_guard();
  return jsonb_build_object(
    'applications',   (select count(*) from mp_partners where status = 'applied'),
    'awaiting_sign',  (select count(*) from mp_partners where status = 'approved'),
    'active',         (select count(*) from mp_partners where status = 'active'),
    'conflicts',      (select count(*) from mp_leads where review_status = 'conflict'),
    'leads_open',     (select count(*) from mp_leads where stage in ('contacted','demo','pilot')),
    'pilots',         (select count(*) from mp_leads where stage = 'pilot'),
    'courses',        (select count(*) from mp_attributions where status = 'active'),
    'revenue_cents',  (select coalesce(sum(net_cents),0) from mp_ledger where status <> 'void'),
    'owed_cents',     (select coalesce(sum(commission_cents),0) from mp_ledger where status in ('pending','approved')),
    'paid_cents',     (select coalesce(sum(commission_cents),0) from mp_ledger where status = 'paid'),
    'clicks_30d',     (select count(*) from mp_clicks where at > now() - interval '30 days'),
    'funnel', jsonb_build_object(
       'contacted', (select count(*) from mp_leads),
       'demo',      (select count(*) from mp_leads where stage in ('demo','pilot','adopted')),
       'pilot',     (select count(*) from mp_leads where stage in ('pilot','adopted')),
       'adopted',   (select count(*) from mp_leads where stage = 'adopted'))
  );
end $$;

-- Admin view of leads with the owning partner's name and any competing claims.
drop function if exists mp_admin_leads();
create or replace function mp_admin_leads() returns table
  (id text, partner_id text, partner_name text, prof_name text, prof_email text, institution text,
   course_taught text, est_students int, stage text, review_status text, conflict_reason text,
   protected_until date, created_at timestamptz, updated_at timestamptz, other_claims text)
language plpgsql stable security definer set search_path = public as $$
begin
  perform mp_admin_guard();
  return query select l.id, l.partner_id, p.full_name, l.prof_name, l.prof_email, l.institution, l.course_taught,
                      l.est_students, l.stage, l.review_status, l.conflict_reason, l.protected_until, l.created_at, l.updated_at,
                      (select string_agg(op.full_name || ' (registered ' || to_char(o.created_at, 'Mon DD') || ', ' || o.stage || ')', '; ' order by o.created_at)
                         from mp_leads o join mp_partners op on op.id = o.partner_id
                        where o.prof_email_norm = l.prof_email_norm and o.id <> l.id and o.review_status <> 'rejected')
                 from mp_leads l join mp_partners p on p.id = l.partner_id
                order by (l.review_status = 'conflict') desc, l.updated_at desc;
end $$;

-- ---------------------------------------------------------------------------
-- 11. Grants
-- ---------------------------------------------------------------------------
do $$ declare f record; begin
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'mp\_%' loop
    execute 'revoke all on function ' || f.sig || ' from public, anon';
    execute 'grant execute on function ' || f.sig || ' to authenticated';
  end loop;
end $$;
-- Public (signed-out) entry points, whichever files are installed.
do $$ declare f record; begin
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('mp_log_click','mp_referral_info','mp_referral_signup',
                                                         'mp_request_order','mp_request_prefill','mp_invoice_view') loop
    execute 'grant execute on function ' || f.sig || ' to anon';
  end loop;
end $$;
do $$ declare f record; begin
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'mp\_\_%' loop
    execute 'revoke all on function ' || f.sig || ' from authenticated';
  end loop;
end $$;
grant select on mp_partners, mp_agreement_templates, mp_agreements, mp_leads, mp_lead_events, mp_clicks,
               mp_attributions, mp_ledger, mp_resources, mp_settings, mp_admins to authenticated;
grant insert on mp_lead_events to authenticated;
grant insert, update, delete on mp_resources to authenticated;
grant update on mp_settings to authenticated;
-- Nothing is granted to anon except mp_log_click.
revoke all on mp_partners, mp_agreement_templates, mp_agreements, mp_leads, mp_lead_events, mp_clicks,
              mp_attributions, mp_ledger, mp_resources, mp_settings, mp_admins from anon;
