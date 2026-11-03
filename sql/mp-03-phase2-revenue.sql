-- ============================================================================
--  MacroNations Partner Program — Phase 2: automatic revenue + referrals
--  Run after mp-01 / mp-02. Additive and re-runnable.
--
--  * mp_payments / mp_refunds: raw copies of Stripe checkouts and refunds,
--    written by the mp-stripe-sync edge function (service role only).
--  * mp_process_payments(): matches each payment to a course, and when that
--    course is credited to a partner (inside its earning window) writes the
--    commission to mp_ledger automatically. Refunds become negative rows.
--  * mp_admin_course_suggestions(): new courses whose instructor is a
--    professor a partner registered, for one-click crediting.
--  * mp_referral_info / mp_referral_signup: the partner-link landing page,
--    where a professor can leave their details and join that partner's
--    pipeline.
--  No existing course table is altered; course tables are only read.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Small additions to Phase 1 tables
-- ---------------------------------------------------------------------------
alter table mp_leads add column if not exists source text not null default 'partner';
do $$ begin
  alter table mp_leads add constraint mp_leads_source_chk check (source in ('partner','link'));
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- 1. Stripe mirror tables (admin-readable only)
-- ---------------------------------------------------------------------------
create table if not exists mp_payments (
  id                    text primary key,            -- Stripe checkout session id
  created_at_stripe     timestamptz not null,
  payment_intent        text,
  amount_cents          int not null default 0,
  fees_cents            int,                         -- null = not reported by Stripe
  currency              text,
  email                 text,
  client_reference_id   text,
  metadata              jsonb not null default '{}'::jsonb,
  payment_link          text,
  product               text,
  course_id             text,
  student_ref           text,
  match_status          text not null default 'new'
                        check (match_status in ('new','credited','course_not_credited','unmatched','outside_window','ignored')),
  match_note            text,
  attribution_id        text references mp_attributions(id),
  manual_attribution_id text references mp_attributions(id),
  ledger_id             text,
  refunded_cents        int not null default 0,
  synced_at             timestamptz not null default now()
);
create index if not exists mp_payments_pi on mp_payments(payment_intent);
create index if not exists mp_payments_status on mp_payments(match_status, created_at_stripe);
alter table mp_payments enable row level security;
drop policy if exists mp_pay_sel on mp_payments;
create policy mp_pay_sel on mp_payments for select to authenticated using (mp_is_admin());

create table if not exists mp_refunds (
  id                text primary key,                -- Stripe refund id
  payment_intent    text,
  amount_cents      int not null,
  created_at_stripe timestamptz not null,
  status            text,
  processed         boolean not null default false,
  ledger_id         text,
  synced_at         timestamptz not null default now()
);
create index if not exists mp_refunds_pi on mp_refunds(payment_intent);
alter table mp_refunds enable row level security;
drop policy if exists mp_ref_sel on mp_refunds;
create policy mp_ref_sel on mp_refunds for select to authenticated using (mp_is_admin());

create table if not exists mp_sync_state (
  id              text primary key,                  -- 'stripe'
  cursor_created  bigint,                            -- unix seconds
  refund_cursor   bigint,
  last_run        timestamptz,
  last_ok         timestamptz,
  last_error      text,
  last_counts     jsonb
);
insert into mp_sync_state (id) values ('stripe') on conflict do nothing;
alter table mp_sync_state enable row level security;
drop policy if exists mp_sync_sel on mp_sync_state;
create policy mp_sync_sel on mp_sync_state for select to authenticated using (mp_is_admin());

-- Token the scheduled job sends to the sync function. Nobody but the
-- service role can read it (RLS on, no policies, no grants).
create table if not exists mp_secrets (id text primary key, value text not null);
alter table mp_secrets enable row level security;
insert into mp_secrets (id, value)
values ('cron', md5(random()::text || clock_timestamp()::text) || md5(clock_timestamp()::text || random()::text))
on conflict do nothing;
revoke all on mp_secrets from anon, authenticated;

create table if not exists mp_suggestion_dismissals (
  product    text not null,
  course_id  text not null,
  lead_id    text not null,
  at         timestamptz not null default now(),
  primary key (product, course_id, lead_id)
);
alter table mp_suggestion_dismissals enable row level security;
drop policy if exists mp_dis_sel on mp_suggestion_dismissals;
create policy mp_dis_sel on mp_suggestion_dismissals for select to authenticated using (mp_is_admin());

-- ---------------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------------
-- Admin, or a trusted backend (service role / database owner).
create or replace function mp__trusted() returns boolean
language sql stable security definer set search_path = public as $$
  -- No request claims at all = a direct database session (SQL editor, cron).
  select mp_is_admin()
      or coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') = 'service_role'
      or nullif(current_setting('request.jwt.claims', true), '') is null
$$;

-- Why a new lead for this professor would need review, or null if clear.
create or replace function mp__lead_conflict(p_partner text, p_email text) returns text
language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from mp_attributions a where lower(a.professor_email) = lower(p_email) and a.status = 'active')
      then 'This professor already has a MacroNations course credited to a partner.'
    when exists (select 1 from mp_leads o where o.prof_email_norm = lower(p_email) and o.partner_id <> p_partner
                   and o.stage <> 'lost' and o.review_status in ('clear','approved') and o.protected_until >= current_date)
      then 'Another partner registered this professor recently.'
  end
$$;

-- Intro Micro: which course a student (user id or student id) is enrolled in.
create or replace function mp__im_course_for(p_student text) returns text
language plpgsql stable security definer set search_path = public as $$
declare c text;
begin
  if p_student is null or p_student = '' then return null; end if;
  select e.course_id::text into c from im_enrollment e
   where (e.user_id = p_student or e.student_id = p_student) and e.course_id is not null
   order by coalesce(e.enrolled_at, e.created_at) desc nulls last limit 1;
  return c;
end $$;

create or replace function mp__im_student_by_email(p_email text) returns text
language sql stable security definer set search_path = public as $$
  select p.user_id from im_person p where lower(p.email) = lower(p_email) limit 1
$$;

-- ---------------------------------------------------------------------------
-- 3. The matcher: payments → courses → partner commission
-- ---------------------------------------------------------------------------
create or replace function mp_process_payments() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r mp_payments; ref text; pfx text; stu text; crs text; d date;
  a mp_attributions; ptn mp_partners; lid text; note text; st text;
  n_credit int := 0; n_refund int := 0; n_open int := 0;
  f record; pay mp_payments; l mp_ledger; target int; current_total int; n_inst int := 0;
begin
  if not mp__trusted() then raise exception 'Not allowed.'; end if;

  -- Institutional-order payments (mp-05) are matched to their order first.
  if exists (select 1 from pg_proc where proname = 'mp__match_institutional') then
    execute 'select mp__match_institutional()' into n_inst;
  end if;

  -- Keep each payment's refunded total current.
  update mp_payments p set refunded_cents = x.total
    from (select payment_intent, sum(amount_cents)::int total from mp_refunds
           where coalesce(status, 'succeeded') = 'succeeded' group by payment_intent) x
   where p.payment_intent = x.payment_intent and p.refunded_cents is distinct from x.total;

  for r in select * from mp_payments
            where match_status in ('new','course_not_credited','unmatched','outside_window')
            order by created_at_stripe loop
    ref := coalesce(r.client_reference_id, ''); pfx := null; stu := null; crs := null; a := null; note := null;
    d := (r.created_at_stripe at time zone 'America/New_York')::date;

    if ref like 'inst|%' then continue; end if;          -- institutional orders (mp-05)

    if r.metadata ? 'team_id' then
      update mp_payments set match_status = 'ignored', product = 'tournament', match_note = 'Tournament entry fee' where id = r.id;
      continue;
    end if;

    if position('|' in ref) > 0 then                     -- eq|student|course, or <course>|student|course
      pfx := split_part(ref, '|', 1);
      stu := nullif(split_part(ref, '|', 2), '');
      crs := nullif(split_part(ref, '|', 3), '');
      if pfx = 'im' and crs is null then crs := mp__im_course_for(stu); end if;
    elsif position('__' in ref) > 0 then                 -- Strategy Arena family: student__course
      pfx := 'sa'; stu := split_part(ref, '__', 1); crs := nullif(split_part(ref, '__', 2), '');
    elsif ref <> '' then                                 -- Intro Micro: bare user id
      pfx := 'im'; stu := ref; crs := mp__im_course_for(ref);
    elsif r.email is not null then                       -- no reference: try Intro Micro by email
      stu := mp__im_student_by_email(r.email);
      if stu is not null then pfx := 'im'; crs := mp__im_course_for(stu); end if;
    end if;

    if r.manual_attribution_id is not null then
      select * into a from mp_attributions where id = r.manual_attribution_id and status <> 'void';
    elsif crs is not null then
      select * into a from mp_attributions
       where course_id = crs and status <> 'void' and d >= starts_at - 1 and d < ends_at
       order by created_at desc limit 1;
    end if;

    if a.id is null then
      if crs is null then st := 'unmatched'; note := 'No course could be identified from this payment.';
      elsif exists (select 1 from mp_attributions x where x.course_id = crs and x.status <> 'void') then
        st := 'outside_window'; note := 'The course is credited, but this payment falls outside its earning window.';
      else st := 'course_not_credited'; note := null;
      end if;
      update mp_payments set product = coalesce(pfx, product), course_id = crs, student_ref = stu,
             match_status = st, match_note = note where id = r.id;
      n_open := n_open + 1;
      continue;
    end if;

    select * into ptn from mp_partners where id = a.partner_id;
    if ptn.status <> 'active' then
      update mp_payments set product = a.product, course_id = coalesce(crs, a.course_id), student_ref = stu,
             match_status = 'course_not_credited', match_note = 'The partner credited with this course is not active.'
       where id = r.id;
      n_open := n_open + 1;
      continue;
    end if;

    -- Student details never go into the ledger: partners can read it.
    insert into mp_ledger (partner_id, attribution_id, source, source_ref, description, gross_cents, fees_cents,
                           refund_cents, rate, commission_cents, earned_on, created_by)
    values (a.partner_id, a.id, 'stripe', r.id, 'Student payment', r.amount_cents, coalesce(r.fees_cents, 0),
            r.refunded_cents, a.rate,
            greatest(0, round((r.amount_cents - coalesce(r.fees_cents, 0) - r.refunded_cents) * a.rate))::int, d, 'stripe-sync')
    on conflict (source, source_ref) where source_ref is not null do nothing
    returning id into lid;
    if lid is null then select id into lid from mp_ledger where source = 'stripe' and source_ref = r.id; end if;

    update mp_payments set product = a.product, course_id = coalesce(crs, a.course_id), student_ref = stu,
           match_status = 'credited', match_note = null, attribution_id = a.id, ledger_id = lid where id = r.id;
    -- Refunds already known were netted into that row.
    update mp_refunds set processed = true, ledger_id = lid
     where payment_intent = r.payment_intent and r.payment_intent is not null and not processed;
    n_credit := n_credit + 1;
  end loop;

  -- Refunds that arrive after a payment was credited: claw back the commission.
  for f in select * from mp_refunds where not processed and coalesce(status, 'succeeded') = 'succeeded' loop
    select * into pay from mp_payments where payment_intent = f.payment_intent and f.payment_intent is not null limit 1;
    if pay.id is null or pay.ledger_id is null then continue; end if;
    select * into l from mp_ledger where id = pay.ledger_id;
    -- Bring this sale's total commission to what it should be after all its
    -- refunds, never below zero (a refund never costs the partner money).
    select greatest(0, round((pay.amount_cents - coalesce(pay.fees_cents, 0) - coalesce(sum(x.amount_cents), 0)) * l.rate))::int
      into target
      from mp_refunds x where x.payment_intent = pay.payment_intent and (x.processed or x.id = f.id)
       and coalesce(x.status, 'succeeded') = 'succeeded';
    select l.commission_cents + coalesce(sum(m.commission_cents), 0) into current_total
      from mp_ledger m join mp_refunds x on x.ledger_id = m.id and m.source_ref = x.id
     where x.payment_intent = pay.payment_intent and x.processed;
    insert into mp_ledger (partner_id, attribution_id, source, source_ref, description, gross_cents, fees_cents,
                           refund_cents, rate, commission_cents, earned_on, created_by)
    values (l.partner_id, l.attribution_id, 'stripe', f.id, 'Refund of a student payment', 0, 0, f.amount_cents,
            l.rate, least(0, target - current_total),
            (f.created_at_stripe at time zone 'America/New_York')::date, 'stripe-sync')
    on conflict (source, source_ref) where source_ref is not null do nothing
    returning id into lid;
    update mp_refunds set processed = true, ledger_id = coalesce(lid, ledger_id) where id = f.id;
    n_refund := n_refund + 1;
  end loop;

  return jsonb_build_object('credited', n_credit, 'refunds', n_refund, 'open', n_open, 'institutional', n_inst);
end $$;

-- Admin: point a payment at a credited course by hand, or set it aside.
create or replace function mp_admin_assign_payment(p_payment text, p_attribution text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform mp_admin_guard();
  if not exists (select 1 from mp_payments where id = p_payment and match_status <> 'credited') then
    raise exception 'That payment is already credited, or does not exist.';
  end if;
  if not exists (select 1 from mp_attributions where id = p_attribution and status <> 'void') then
    raise exception 'Course credit not found.';
  end if;
  update mp_payments set manual_attribution_id = p_attribution, match_status = 'new' where id = p_payment;
  return mp_process_payments();
end $$;

create or replace function mp_admin_ignore_payment(p_payment text, p_ignore boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform mp_admin_guard();
  update mp_payments set match_status = case when p_ignore then 'ignored' else 'new' end,
         match_note = case when p_ignore then 'Set aside by admin' else null end
   where id = p_payment and match_status <> 'credited';
  if not p_ignore then perform mp_process_payments(); end if;
end $$;

-- Crediting a course now immediately picks up payments already received.
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
  perform mp_process_payments();
  return r;
end $$;

-- Re-check open payments when a credit's status changes (e.g. reinstated).
create or replace function mp_admin_set_attribution_status(p_id text, p_status text)
returns mp_attributions language plpgsql security definer set search_path = public as $$
declare r mp_attributions;
begin
  perform mp_admin_guard();
  update mp_attributions set status = p_status where id = p_id returning * into r;
  perform mp_process_payments();
  return r;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Payments view + sync status for the admin console
-- ---------------------------------------------------------------------------
create or replace function mp_admin_payments(p_status text default null) returns table
  (id text, created_at_stripe timestamptz, amount_cents int, fees_cents int, refunded_cents int, currency text,
   email text, product text, course_id text, match_status text, match_note text,
   attribution_id text, course_label text, partner_name text, commission_cents int)
language plpgsql stable security definer set search_path = public as $$
begin
  perform mp_admin_guard();
  return query
    select p.id, p.created_at_stripe, p.amount_cents, p.fees_cents, p.refunded_cents, p.currency, p.email,
           p.product, p.course_id, p.match_status, p.match_note, p.attribution_id, a.course_label, pt.full_name,
           (l.commission_cents + coalesce((select sum(m.commission_cents) from mp_refunds x
                                             join mp_ledger m on m.id = x.ledger_id and m.source_ref = x.id
                                            where x.payment_intent = p.payment_intent and p.payment_intent is not null), 0))::int
      from mp_payments p
      left join mp_attributions a on a.id = p.attribution_id
      left join mp_partners pt on pt.id = a.partner_id
      left join mp_ledger l on l.id = p.ledger_id
     where p_status is null or p.match_status = p_status
        or (p_status = 'open' and p.match_status in ('unmatched','course_not_credited','outside_window'))
     order by p.created_at_stripe desc
     limit 500;
end $$;

create or replace function mp_admin_sync_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s mp_sync_state;
begin
  perform mp_admin_guard();
  select * into s from mp_sync_state where id = 'stripe';
  return jsonb_build_object(
    'last_run', s.last_run, 'last_ok', s.last_ok, 'last_error', s.last_error, 'last_counts', s.last_counts,
    'total',      (select count(*) from mp_payments),
    'credited',   (select count(*) from mp_payments where match_status = 'credited'),
    'open',       (select count(*) from mp_payments where match_status in ('unmatched','course_not_credited','outside_window')),
    'ignored',    (select count(*) from mp_payments where match_status = 'ignored'),
    'not_credited_courses', (select count(distinct course_id) from mp_payments where match_status = 'course_not_credited'));
end $$;

-- ---------------------------------------------------------------------------
-- 5. New courses by professors that partners registered
--    (the four courses whose data lives in this project)
-- ---------------------------------------------------------------------------
create or replace function mp_admin_course_suggestions() returns table
  (product text, course_id text, course_title text, course_term text, course_created timestamptz,
   owner_email text, lead_id text, partner_id text, partner_name text, prof_name text, institution text,
   course_taught text, lead_created timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform mp_admin_guard();
  return query
    with courses as (
      select 'im'::text pr, c.id::text cid, c.title::text ttl, c.term::text trm, c.created_at cat, c.owner_id::text own from im_course c
      union all select 'ma', c.id::text, c.title::text, c.term::text, c.created_at, c.owner_id::text from ma_course c
      union all select 'it', c.id::text, c.title::text, c.term::text, c.created_at, c.owner_id::text from it_courses c
      union all select 'eq', c.id::text, c.title::text, c.term::text, c.created_at, c.owner_id::text from eq_courses c
    )
    select c.pr, c.cid, c.ttl, c.trm, c.cat, lower(u.email)::text, l.id, l.partner_id, pt.full_name, l.prof_name,
           l.institution, l.course_taught, l.created_at
      from courses c
      join auth.users u on u.id::text = c.own
      join mp_leads l on l.prof_email_norm = lower(u.email)
                     and l.review_status in ('clear','approved') and l.stage <> 'lost'
      join mp_partners pt on pt.id = l.partner_id and pt.status = 'active'
     where c.cat >= l.created_at
       and c.cat::date <= l.protected_until
       and not exists (select 1 from mp_attributions a where a.course_id = c.cid and a.status <> 'void')
       and not exists (select 1 from mp_suggestion_dismissals x
                        where x.product = c.pr and x.course_id = c.cid and x.lead_id = l.id)
     order by c.cat desc;
end $$;

create or replace function mp_admin_dismiss_suggestion(p_product text, p_course_id text, p_lead_id text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform mp_admin_guard();
  insert into mp_suggestion_dismissals (product, course_id, lead_id) values (p_product, p_course_id, p_lead_id)
  on conflict do nothing;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Partner-link landing page (anonymous visitors)
-- ---------------------------------------------------------------------------
create or replace function mp_referral_info(p_code text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('first_name', split_part(full_name, ' ', 1))
    from mp_partners where code = upper(btrim(coalesce(p_code, ''))) and status = 'active'
$$;

create or replace function mp_referral_signup(p_code text, p_name text, p_email text, p_institution text, p_course text)
returns boolean language plpgsql security definer set search_path = public as $$
declare p mp_partners; s mp_settings; em text; why text; l mp_leads;
begin
  select * into p from mp_partners where code = upper(btrim(coalesce(p_code, ''))) and status = 'active';
  if not found then return false; end if;
  em := lower(btrim(coalesce(p_email, '')));
  if em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Please enter a valid email address.'; end if;
  if coalesce(btrim(p_name), '') = '' or coalesce(btrim(p_institution), '') = '' then
    raise exception 'Please enter your name and institution.';
  end if;
  -- Already in this partner's pipeline: nothing to do.
  if exists (select 1 from mp_leads where partner_id = p.id and prof_email_norm = em and stage <> 'lost') then return true; end if;
  -- Throttle: at most 25 link sign-ups per partner per day.
  if (select count(*) from mp_leads where partner_id = p.id and source = 'link' and created_at > now() - interval '1 day') >= 25 then
    return true;
  end if;
  select * into s from mp_settings where id = 'default';
  why := mp__lead_conflict(p.id, em);
  insert into mp_leads (partner_id, prof_name, prof_email, institution, course_taught, notes, protected_until,
                        review_status, conflict_reason, source)
  values (p.id, left(btrim(p_name), 120), em, left(btrim(p_institution), 160), left(nullif(btrim(coalesce(p_course,'')), ''), 160),
          'Left their details on your partner link.', current_date + s.lead_protection_days,
          case when why is null then 'clear' else 'conflict' end, why, 'link')
  returning * into l;
  insert into mp_lead_events (lead_id, partner_id, kind, detail) values (l.id, p.id, 'created', 'via your link');
  return true;
end $$;

-- Partners' own registration uses the shared conflict helper too.
create or replace function mp_register_lead(p_prof_name text, p_prof_email text, p_institution text,
  p_department text, p_course_taught text, p_est_students int, p_notes text)
returns mp_leads language plpgsql security definer set search_path = public as $$
declare p mp_partners; s mp_settings; em text; why text; l mp_leads;
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
  why := mp__lead_conflict(p.id, em);
  insert into mp_leads (partner_id, prof_name, prof_email, institution, department, course_taught,
                        est_students, notes, protected_until, review_status, conflict_reason)
  values (p.id, btrim(p_prof_name), em, btrim(p_institution), p_department, p_course_taught,
          p_est_students, p_notes, current_date + s.lead_protection_days,
          case when why is null then 'clear' else 'conflict' end, why)
  returning * into l;
  insert into mp_lead_events (lead_id, partner_id, kind, detail) values (l.id, p.id, 'created', null);
  return l;
end $$;

-- ---------------------------------------------------------------------------
-- 7. Grants
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
-- Internal helpers are not callable from the browser at all.
revoke all on function mp__trusted() from authenticated;
revoke all on function mp__lead_conflict(text,text) from authenticated;
revoke all on function mp__im_course_for(text) from authenticated;
revoke all on function mp__im_student_by_email(text) from authenticated;
grant select on mp_payments, mp_refunds, mp_sync_state, mp_suggestion_dismissals to authenticated;
-- The sync function runs as the service role.
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant select, insert, update on mp_payments, mp_refunds, mp_sync_state to service_role';
    execute 'grant select on mp_secrets, mp_admins to service_role';
    execute 'grant execute on function mp_process_payments() to service_role';
  end if;
end $$;
revoke all on mp_payments, mp_refunds, mp_sync_state, mp_suggestion_dismissals, mp_secrets from anon;
