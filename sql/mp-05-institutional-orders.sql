-- ============================================================================
--  MacroNations — Institutional billing (a university or department pays
--  for a course section's students). Run after mp-01 … mp-04. Re-runnable.
--
--  * mp_orders: one order per course section (plus top-ups), per-seat or flat
--    licence pricing with optional discount, PO number, invoice number,
--    online invoice page (secret token), seat tracking.
--  * Approving an order gives the section's students access at once:
--      Micro / Macro / International Trade  → a course-wide fee waiver row
--      Econometrics                          → requires_payment = false
--      Game Theory / Finance / Econ & Film   → other project: done by hand
--  * Payments: online through one Stripe payment link (client_reference_id
--    inst|<order id>, picked up by the hourly Stripe sync), or recorded by
--    hand (cheque, wire, ACH). Each payment flows to the partner ledger when
--    the course is credited to a partner.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Settings and default prices
-- ---------------------------------------------------------------------------
alter table mp_settings add column if not exists inst_payment_link  text;
alter table mp_settings add column if not exists inst_remit_text    text not null default
  'Pay online with the button on this page (card or bank account), or by bank transfer or cheque. Please quote the invoice number with your payment.';
alter table mp_settings add column if not exists inst_company_block text not null default
  'MacroNations LLC' || chr(10) || 'New York, NY' || chr(10) || 'billing@macronations.com';
alter table mp_settings add column if not exists inst_terms_days    int  not null default 30;

create table if not exists mp_price_defaults (
  product            text primary key,
  label              text not null,
  student_price_cents int not null default 2500,
  seat_price_cents   int not null default 2500
);
insert into mp_price_defaults (product, label) values
  ('im','Introduction to Microeconomics'), ('ma','Macroeconomics'), ('sa','Game Theory'),
  ('eq','Econometrics'), ('it','International Trade'), ('fin','Finance'), ('ef','Economics & Film')
on conflict do nothing;
alter table mp_price_defaults enable row level security;
drop policy if exists mp_pd_sel on mp_price_defaults;
create policy mp_pd_sel on mp_price_defaults for select to authenticated using (true);
drop policy if exists mp_pd_upd on mp_price_defaults;
create policy mp_pd_upd on mp_price_defaults for update to authenticated using (mp_is_admin()) with check (mp_is_admin());
grant select, update on mp_price_defaults to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Orders and their payments
-- ---------------------------------------------------------------------------
create sequence if not exists mp_invoice_seq;

create table if not exists mp_orders (
  id                text primary key default gen_random_uuid()::text,
  number            text unique,
  status            text not null default 'requested'
                    check (status in ('requested','approved','invoiced','partially_paid','paid','cancelled')),
  source            text not null default 'admin' check (source in ('admin','request')),
  parent_order_id   text references mp_orders(id),
  product           text not null check (product in ('im','ma','sa','eq','it','fin','ef','institutional')),
  course_id         text,
  course_label      text not null,
  term              text,
  institution       text not null,
  department        text,
  contact_name      text,
  contact_email     text,
  billing_address   text,
  po_number         text,
  seats             int  not null default 0 check (seats >= 0),
  pricing           text not null default 'per_seat' check (pricing in ('per_seat','flat')),
  unit_price_cents  int  not null default 0 check (unit_price_cents >= 0),
  discount_pct      numeric(5,2) not null default 0 check (discount_pct >= 0 and discount_pct <= 100),
  flat_amount_cents int  not null default 0 check (flat_amount_cents >= 0),
  total_cents       int  not null default 0,
  paid_cents        int  not null default 0,
  attribution_id    text references mp_attributions(id),
  access_granted    boolean not null default false,
  access_note       text,
  invoice_token     text unique default md5(random()::text || clock_timestamp()::text) || md5(clock_timestamp()::text || random()::text),
  requester_name    text,
  requester_email   text,
  notes             text,
  admin_notes       text,
  due_date          date,
  created_at        timestamptz not null default now(),
  approved_at       timestamptz,
  invoiced_at       timestamptz,
  paid_at           timestamptz,
  cancelled_at      timestamptz,
  updated_at        timestamptz not null default now()
);
create index if not exists mp_orders_status on mp_orders(status, created_at);
create index if not exists mp_orders_course on mp_orders(product, course_id);
alter table mp_orders enable row level security;
drop policy if exists mp_ord_sel on mp_orders;
create policy mp_ord_sel on mp_orders for select to authenticated using (mp_is_admin());
grant select on mp_orders to authenticated;

create table if not exists mp_order_payments (
  id          text primary key default gen_random_uuid()::text,
  order_id    text not null references mp_orders(id),
  method      text not null check (method in ('stripe','ach','wire','check','card','other')),
  amount_cents int not null check (amount_cents <> 0),
  fees_cents  int not null default 0,
  reference   text,
  received_on date not null default current_date,
  ledger_id   text,
  created_by  text,
  created_at  timestamptz not null default now()
);
create unique index if not exists mp_op_ref on mp_order_payments(method, reference) where reference is not null;
alter table mp_order_payments enable row level security;
drop policy if exists mp_op_sel on mp_order_payments;
create policy mp_op_sel on mp_order_payments for select to authenticated using (mp_is_admin());
grant select on mp_order_payments to authenticated;

-- Stripe payments for orders get their own status in the payments mirror.
alter table mp_payments drop constraint if exists mp_payments_match_status_check;
alter table mp_payments add constraint mp_payments_match_status_check
  check (match_status in ('new','credited','course_not_credited','unmatched','outside_window','ignored','institutional'));

-- ---------------------------------------------------------------------------
-- 3. Helpers
-- ---------------------------------------------------------------------------
create or replace function mp__order_total(o mp_orders) returns int
language sql immutable as $$
  select case when o.pricing = 'flat' then o.flat_amount_cents
              else round(o.seats * o.unit_price_cents * (1 - o.discount_pct / 100.0))::int end
$$;

-- Students currently enrolled in a section (courses in this project only).
create or replace function mp__seats_used(p_product text, p_course text) returns int
language plpgsql stable security definer set search_path = public as $$
declare n int;
begin
  if p_course is null then return null; end if;
  if p_product = 'im' then
    select count(*) into n from im_enrollment where course_id::text = p_course and status::text = 'active';
  elsif p_product = 'ma' then
    select count(*) into n from ma_enrollment where course_id::text = p_course and status::text = 'active';
  elsif p_product = 'it' then
    select count(*) into n from it_enrollments where course_id::text = p_course and coalesce(status, 'active') = 'active';
  elsif p_product = 'eq' then
    select count(*) into n from eq_enrollments where course_id::text = p_course;
  else
    return null;
  end if;
  return n;
end $$;

-- Give / remove section-wide access for an order.
create or replace function mp__set_course_access(o mp_orders, p_on boolean) returns text
language plpgsql security definer set search_path = public as $$
declare v_note text := 'Institutional order ' || coalesce(o.number, o.id);
begin
  if o.course_id is null then return 'No course id on this order, so access was not changed.'; end if;
  begin
    if o.product = 'im' then
      if p_on then
        insert into im_fee_waiver (course_id, student_id, note, waived_by)
        select o.course_id::uuid, null, v_note, auth.uid()::text
         where not exists (select 1 from im_fee_waiver w where w.course_id = o.course_id::uuid and w.student_id is null and w.note = v_note);
        perform im_activate_free_pending(o.course_id::uuid);
      else
        delete from im_fee_waiver where course_id = o.course_id::uuid and student_id is null and im_fee_waiver.note = v_note;
      end if;
      return case when p_on then 'Students have access (course-wide fee waiver).' else 'Course-wide waiver removed.' end;
    elsif o.product = 'ma' then
      if p_on then
        insert into ma_fee_waiver (course_id, student_id, note, waived_by)
        select o.course_id::uuid, null, v_note, auth.uid()::text
         where not exists (select 1 from ma_fee_waiver w where w.course_id = o.course_id::uuid and w.student_id is null and w.note = v_note);
        perform ma_activate_free_pending(o.course_id::uuid);
      else
        delete from ma_fee_waiver where course_id = o.course_id::uuid and student_id is null and ma_fee_waiver.note = v_note;
      end if;
      return case when p_on then 'Students have access (course-wide fee waiver).' else 'Course-wide waiver removed.' end;
    elsif o.product = 'it' then
      if p_on then
        insert into it_fee_waivers (course_id, student_id, note, waived_by)
        select o.course_id::uuid, null, v_note, auth.uid()
         where not exists (select 1 from it_fee_waivers w where w.course_id = o.course_id::uuid and w.student_id is null and w.note = v_note);
      else
        delete from it_fee_waivers where course_id = o.course_id::uuid and student_id is null and it_fee_waivers.note = v_note;
      end if;
      return case when p_on then 'Students have access (course-wide fee waiver).' else 'Course-wide waiver removed.' end;
    elsif o.product = 'eq' then
      update eq_courses set requires_payment = not p_on where id = o.course_id;
      return case when p_on then 'Student payment turned off for this section.' else 'Student payment turned back on.' end;
    else
      return 'This course is managed in the Game Theory / Finance / Film console: set the section to free there.';
    end if;
  exception when others then
    return 'Access could not be changed automatically (' || sqlerrm || '). Set it in the course console.';
  end;
end $$;

-- Record money against an order; credit the partner if the course is credited.
create or replace function mp__apply_order_payment(p_order text, p_method text, p_amount int, p_fees int,
  p_reference text, p_received date, p_ledger_source text, p_ledger_ref text)
returns mp_order_payments language plpgsql security definer set search_path = public as $$
declare o mp_orders; a mp_attributions; op mp_order_payments; lid text; d date := coalesce(p_received, current_date);
begin
  select * into o from mp_orders where id = p_order for update;
  if not found then raise exception 'Order not found.'; end if;
  insert into mp_order_payments (order_id, method, amount_cents, fees_cents, reference, received_on, created_by)
  values (o.id, p_method, p_amount, coalesce(p_fees, 0), nullif(btrim(coalesce(p_reference, '')), ''), d, coalesce(auth.uid()::text, 'stripe-sync'))
  returning * into op;

  if o.attribution_id is not null then
    select * into a from mp_attributions where id = o.attribution_id and status <> 'void';
  elsif o.course_id is not null then
    select * into a from mp_attributions
     where course_id = o.course_id and status <> 'void' and d >= starts_at - 1 and d < ends_at
     order by created_at desc limit 1;
  end if;
  if a.id is not null and exists (select 1 from mp_partners where id = a.partner_id and status = 'active') then
    insert into mp_ledger (partner_id, attribution_id, source, source_ref, description, gross_cents, fees_cents,
                           refund_cents, rate, commission_cents, earned_on, created_by)
    values (a.partner_id, a.id, p_ledger_source, coalesce(p_ledger_ref, 'order-payment:' || op.id),
            'Institutional payment — ' || o.institution, greatest(p_amount, 0), coalesce(p_fees, 0), greatest(-p_amount, 0),
            a.rate, round((p_amount - coalesce(p_fees, 0)) * a.rate)::int, d, coalesce(auth.uid()::text, 'stripe-sync'))
    on conflict (source, source_ref) where source_ref is not null do nothing
    returning id into lid;
    update mp_order_payments set ledger_id = lid where id = op.id;
    op.ledger_id := lid;
  end if;

  update mp_orders set paid_cents = paid_cents + p_amount,
         status = case when status = 'cancelled' then status
                       when paid_cents + p_amount >= total_cents and total_cents > 0 then 'paid'
                       when paid_cents + p_amount > 0 then 'partially_paid' else status end,
         paid_at = case when paid_cents + p_amount >= total_cents and total_cents > 0 then coalesce(paid_at, now()) else paid_at end,
         updated_at = now()
   where id = o.id;
  return op;
end $$;

create or replace function mp__new_invoice_number() returns text
language sql volatile set search_path = public as $$
  select 'MN-' || to_char(current_date, 'YYYY') || '-' || lpad(nextval('mp_invoice_seq')::text, 4, '0')
$$;

-- ---------------------------------------------------------------------------
-- 4. Requests from instructors / department staff (no sign-in needed)
-- ---------------------------------------------------------------------------
create or replace function mp_request_order(p_product text, p_course_id text, p_course_label text, p_term text,
  p_institution text, p_department text, p_contact_name text, p_contact_email text, p_billing_address text,
  p_po_number text, p_seats int, p_requester_name text, p_requester_email text, p_notes text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare pd mp_price_defaults; em text := lower(btrim(coalesce(p_requester_email, ''))); ce text := lower(btrim(coalesce(p_contact_email, ''))); o mp_orders;
begin
  if p_product not in ('im','ma','sa','eq','it','fin','ef') then raise exception 'Please choose the course.'; end if;
  if em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Please enter your email address.'; end if;
  if ce <> '' and ce !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Please check the billing contact''s email address.'; end if;
  if coalesce(btrim(p_institution), '') = '' or coalesce(btrim(p_requester_name), '') = '' then
    raise exception 'Please enter your name and institution.';
  end if;
  if coalesce(p_seats, 0) < 1 or p_seats > 5000 then raise exception 'Please enter the number of students (seats).'; end if;
  if (select count(*) from mp_orders where requester_email = em and created_at > now() - interval '1 day') >= 10 then
    raise exception 'We have received several requests from this address today. Please email us instead.';
  end if;
  select * into pd from mp_price_defaults where product = p_product;
  insert into mp_orders (number, status, source, product, course_id, course_label, term, institution, department,
                         contact_name, contact_email, billing_address, po_number, seats, pricing, unit_price_cents,
                         requester_name, requester_email, notes)
  values (mp__new_invoice_number(), 'requested', 'request', p_product, nullif(btrim(coalesce(p_course_id, '')), ''),
          left(coalesce(nullif(btrim(coalesce(p_course_label, '')), ''), pd.label), 200), left(p_term, 60),
          left(btrim(p_institution), 200), left(p_department, 200), left(coalesce(nullif(btrim(coalesce(p_contact_name,'')),''), p_requester_name), 120),
          coalesce(nullif(ce, ''), em), left(p_billing_address, 600), left(p_po_number, 80), p_seats, 'per_seat',
          coalesce(pd.seat_price_cents, 0), left(btrim(p_requester_name), 120), em, left(p_notes, 2000))
  returning * into o;
  update mp_orders set total_cents = mp__order_total(o) where id = o.id;
  return jsonb_build_object('number', o.number);
end $$;

-- Course details for the request form, so it can be pre-filled from a console link.
create or replace function mp_request_prefill(p_product text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('label', label, 'seat_price_cents', seat_price_cents) from mp_price_defaults where product = p_product
$$;

-- ---------------------------------------------------------------------------
-- 5. Online invoice page (anyone holding the link)
-- ---------------------------------------------------------------------------
create or replace function mp_invoice_view(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o mp_orders; s mp_settings;
begin
  if coalesce(length(p_token), 0) < 32 then return null; end if;
  select * into o from mp_orders where invoice_token = p_token and status not in ('requested','cancelled');
  if not found then return null; end if;
  select * into s from mp_settings where id = 'default';
  return jsonb_build_object(
    'number', o.number, 'status', o.status, 'issued', coalesce(o.invoiced_at, o.approved_at, o.created_at)::date,
    'due', o.due_date, 'institution', o.institution, 'department', o.department, 'contact_name', o.contact_name,
    'billing_address', o.billing_address, 'po_number', o.po_number, 'course_label', o.course_label, 'term', o.term,
    'seats', o.seats, 'pricing', o.pricing, 'unit_price_cents', o.unit_price_cents, 'discount_pct', o.discount_pct,
    'flat_amount_cents', o.flat_amount_cents, 'total_cents', o.total_cents, 'paid_cents', o.paid_cents,
    'balance_cents', greatest(o.total_cents - o.paid_cents, 0), 'is_topup', o.parent_order_id is not null,
    'pay_url', case when coalesce(s.inst_payment_link, '') <> '' and o.total_cents > o.paid_cents
                    then s.inst_payment_link || case when position('?' in s.inst_payment_link) > 0 then '&' else '?' end
                         || 'client_reference_id=inst%7C' || o.id
                         || case when coalesce(o.contact_email, '') <> '' then '&prefilled_email=' || replace(o.contact_email, '@', '%40') else '' end
               end,
    'remit', s.inst_remit_text, 'company', s.inst_company_block);
end $$;

-- ---------------------------------------------------------------------------
-- 6. Admin actions
-- ---------------------------------------------------------------------------
create or replace function mp_admin_save_order(p jsonb) returns mp_orders
language plpgsql security definer set search_path = public as $$
declare o mp_orders; pd mp_price_defaults; pid text := nullif(p ->> 'id', ''); v_new boolean := (nullif(p ->> 'id', '') is null); msg text;
begin
  perform mp_admin_guard();
  if coalesce(btrim(p ->> 'institution'), '') = '' then raise exception 'Enter the institution.'; end if;
  if coalesce(p ->> 'product', '') = '' then raise exception 'Choose the course.'; end if;
  select * into pd from mp_price_defaults where product = p ->> 'product';
  if pid is null then
    insert into mp_orders (number, status, source, product, course_label, institution)
    values (mp__new_invoice_number(), 'approved', 'admin', p ->> 'product', coalesce(nullif(p ->> 'course_label', ''), pd.label, 'Course'), p ->> 'institution')
    returning id into pid;
    update mp_orders set approved_at = now() where id = pid;
  end if;
  update mp_orders set
    product = p ->> 'product',
    course_id = nullif(btrim(coalesce(p ->> 'course_id', '')), ''),
    course_label = coalesce(nullif(p ->> 'course_label', ''), course_label),
    term = nullif(p ->> 'term', ''),
    institution = btrim(p ->> 'institution'),
    department = nullif(p ->> 'department', ''),
    contact_name = nullif(p ->> 'contact_name', ''),
    contact_email = nullif(lower(btrim(coalesce(p ->> 'contact_email', ''))), ''),
    billing_address = nullif(p ->> 'billing_address', ''),
    po_number = nullif(p ->> 'po_number', ''),
    seats = coalesce((p ->> 'seats')::int, seats),
    pricing = coalesce(nullif(p ->> 'pricing', ''), pricing),
    unit_price_cents = coalesce((p ->> 'unit_price_cents')::int, unit_price_cents, pd.seat_price_cents, 0),
    discount_pct = coalesce((p ->> 'discount_pct')::numeric, discount_pct),
    flat_amount_cents = coalesce((p ->> 'flat_amount_cents')::int, flat_amount_cents),
    attribution_id = nullif(p ->> 'attribution_id', ''),
    admin_notes = nullif(p ->> 'admin_notes', ''),
    due_date = coalesce(nullif(p ->> 'due_date', '')::date, due_date),
    updated_at = now()
  where id = pid;
  select * into o from mp_orders where id = pid;
  update mp_orders set total_cents = mp__order_total(o),
         status = case when status in ('paid','partially_paid') and mp__order_total(o) > paid_cents then 'partially_paid'
                       when status in ('invoiced','partially_paid') and mp__order_total(o) <= paid_cents and mp__order_total(o) > 0 then 'paid'
                       else status end
   where id = pid returning * into o;
  if v_new and coalesce((p ->> 'grant_access')::boolean, true) then
    msg := mp__set_course_access(o, true);
    update mp_orders set access_granted = (msg like 'Students%' or msg like 'Student payment turned off%'), access_note = msg
     where id = pid returning * into o;
  end if;
  return o;
end $$;

create or replace function mp_admin_order_action(p_order text, p_action text, p_end_access boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o mp_orders; s mp_settings; msg text := null;
begin
  perform mp_admin_guard();
  select * into o from mp_orders where id = p_order;
  if not found then raise exception 'Order not found.'; end if;
  select * into s from mp_settings where id = 'default';
  if p_action = 'approve' then
    if o.status <> 'requested' then raise exception 'This order is already approved.'; end if;
    update mp_orders set status = 'approved', approved_at = now(), updated_at = now() where id = o.id returning * into o;
    msg := mp__set_course_access(o, true);
    update mp_orders set access_granted = (msg like 'Students%' or msg like 'Student payment turned off%'), access_note = msg where id = o.id;
  elsif p_action = 'grant_access' then
    msg := mp__set_course_access(o, true);
    update mp_orders set access_granted = (msg like 'Students%' or msg like 'Student payment turned off%'), access_note = msg where id = o.id;
  elsif p_action = 'sent' then
    if o.status = 'requested' then raise exception 'Approve the order first.'; end if;
    update mp_orders set status = case when status = 'approved' then 'invoiced' else status end,
           invoiced_at = coalesce(invoiced_at, now()),
           due_date = coalesce(due_date, current_date + s.inst_terms_days), updated_at = now() where id = o.id;
    msg := 'Marked as sent.';
  elsif p_action = 'cancel' then
    if o.paid_cents > 0 then raise exception 'This order has payments recorded. Record a refund instead of cancelling.'; end if;
    update mp_orders set status = 'cancelled', cancelled_at = now(), updated_at = now() where id = o.id;
    if p_end_access and o.access_granted then
      msg := mp__set_course_access(o, false);
      update mp_orders set access_granted = false, access_note = msg where id = o.id;
    else
      msg := 'Order cancelled. Student access was left as it is.';
    end if;
  elsif p_action = 'reopen' then
    if o.status <> 'cancelled' then raise exception 'Only cancelled orders can be reopened.'; end if;
    update mp_orders set status = 'approved', cancelled_at = null, updated_at = now() where id = o.id;
    msg := 'Order reopened.';
  else
    raise exception 'Unknown action.';
  end if;
  return jsonb_build_object('message', msg);
end $$;

create or replace function mp_admin_record_order_payment(p_order text, p_method text, p_amount_cents int,
  p_fees_cents int, p_reference text, p_received date)
returns mp_order_payments language plpgsql security definer set search_path = public as $$
declare o mp_orders;
begin
  perform mp_admin_guard();
  select * into o from mp_orders where id = p_order;
  if not found then raise exception 'Order not found.'; end if;
  if o.status in ('requested','cancelled') then raise exception 'Approve the order before recording a payment.'; end if;
  if coalesce(p_amount_cents, 0) = 0 then raise exception 'Enter the amount received.'; end if;
  return mp__apply_order_payment(o.id, p_method, p_amount_cents, p_fees_cents, p_reference, p_received, 'invoice', null);
end $$;

create or replace function mp_admin_create_topup(p_order text, p_seats int) returns mp_orders
language plpgsql security definer set search_path = public as $$
declare o mp_orders; n mp_orders;
begin
  perform mp_admin_guard();
  select * into o from mp_orders where id = p_order;
  if not found then raise exception 'Order not found.'; end if;
  if coalesce(p_seats, 0) < 1 then raise exception 'Enter the number of extra seats.'; end if;
  insert into mp_orders (number, status, source, parent_order_id, product, course_id, course_label, term, institution,
                         department, contact_name, contact_email, billing_address, po_number, seats, pricing,
                         unit_price_cents, discount_pct, attribution_id, access_granted, approved_at, notes)
  values (mp__new_invoice_number(), 'approved', 'admin', o.id, o.product, o.course_id, o.course_label, o.term, o.institution,
          o.department, o.contact_name, o.contact_email, o.billing_address, o.po_number, p_seats, 'per_seat',
          o.unit_price_cents, o.discount_pct, o.attribution_id, o.access_granted, now(),
          'Additional seats for ' || o.number)
  returning * into n;
  update mp_orders set total_cents = mp__order_total(n) where id = n.id returning * into n;
  return n;
end $$;

create or replace function mp_admin_orders() returns table
  (id text, number text, status text, source text, parent_number text, product text, course_id text, course_label text,
   term text, institution text, department text, contact_name text, contact_email text, billing_address text,
   po_number text, seats int, seats_used int, pricing text, unit_price_cents int, discount_pct numeric,
   flat_amount_cents int, total_cents int, paid_cents int, attribution_id text, partner_name text,
   access_granted boolean, access_note text, invoice_token text, requester_name text, requester_email text,
   notes text, admin_notes text, due_date date, created_at timestamptz, overdue boolean, topup_seats int)
language plpgsql stable security definer set search_path = public as $$
begin
  perform mp_admin_guard();
  return query
    with base as (
      select o.*, mp__seats_used(o.product, o.course_id) used,
             (select coalesce(sum(t.seats), 0) from mp_orders t
               where t.status <> 'cancelled' and t.product = o.product and t.course_id = o.course_id
                 and (t.id = o.id or t.parent_order_id = o.id))::int covered
        from mp_orders o
    )
    select b.id, b.number, b.status, b.source, (select x.number from mp_orders x where x.id = b.parent_order_id),
           b.product, b.course_id, b.course_label, b.term, b.institution, b.department, b.contact_name, b.contact_email,
           b.billing_address, b.po_number, b.seats, b.used, b.pricing, b.unit_price_cents, b.discount_pct,
           b.flat_amount_cents, b.total_cents, b.paid_cents, b.attribution_id,
           coalesce((select pt.full_name from mp_attributions a join mp_partners pt on pt.id = a.partner_id where a.id = b.attribution_id),
                    (select pt.full_name from mp_attributions a join mp_partners pt on pt.id = a.partner_id
                      where a.course_id = b.course_id and a.status = 'active' limit 1)),
           b.access_granted, b.access_note, b.invoice_token, b.requester_name, b.requester_email, b.notes, b.admin_notes,
           b.due_date, b.created_at,
           (b.status in ('invoiced','partially_paid') and b.due_date < current_date),
           case when b.parent_order_id is null and b.pricing = 'per_seat' and b.status <> 'cancelled' and b.used is not null
                     and b.used > b.covered then b.used - b.covered else 0 end
      from base b
     order by (b.status = 'requested') desc, b.created_at desc;
end $$;

create or replace function mp_admin_order_payments(p_order text) returns setof mp_order_payments
language plpgsql stable security definer set search_path = public as $$
begin
  perform mp_admin_guard();
  return query select * from mp_order_payments where order_id = p_order order by received_on, created_at;
end $$;

-- ---------------------------------------------------------------------------
-- 7. Stripe: payments made through the institutional link (inst|<order id>)
-- ---------------------------------------------------------------------------
create or replace function mp__match_institutional() returns int
language plpgsql security definer set search_path = public as $$
declare r mp_payments; oid text; op mp_order_payments; n int := 0;
begin
  for r in select * from mp_payments
            where match_status in ('new','unmatched','course_not_credited')
              and client_reference_id like 'inst|%' loop
    oid := split_part(r.client_reference_id, '|', 2);
    if not exists (select 1 from mp_orders where id = oid) then
      update mp_payments set match_status = 'unmatched', match_note = 'Institutional payment for an unknown order.' where id = r.id;
      continue;
    end if;
    if exists (select 1 from mp_order_payments where method = 'stripe' and reference = r.id) then
      select * into op from mp_order_payments where method = 'stripe' and reference = r.id;
    else
      op := mp__apply_order_payment(oid, 'stripe', r.amount_cents, coalesce(r.fees_cents, 0), r.id,
                                    (r.created_at_stripe at time zone 'America/New_York')::date, 'stripe', r.id);
    end if;
    update mp_payments set match_status = case when op.ledger_id is not null then 'credited' else 'institutional' end,
           product = (select product from mp_orders where id = oid), course_id = (select course_id from mp_orders where id = oid),
           match_note = 'Institutional order ' || (select number from mp_orders where id = oid),
           ledger_id = op.ledger_id,
           attribution_id = (select attribution_id from mp_ledger where id = op.ledger_id)
     where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- mp_process_payments() (mp-03) calls mp__match_institutional() first when it exists.

-- Admin overview: open order counts.
create or replace function mp_admin_order_counts() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform mp_admin_guard();
  return jsonb_build_object(
    'requested', (select count(*) from mp_orders where status = 'requested'),
    'awaiting',  (select count(*) from mp_orders where status in ('approved','invoiced','partially_paid')),
    'overdue',   (select count(*) from mp_orders where status in ('invoiced','partially_paid') and due_date < current_date),
    'topups',    (select count(*) from mp_admin_orders() x where x.topup_seats > 0),
    'outstanding_cents', (select coalesce(sum(greatest(total_cents - paid_cents, 0)), 0) from mp_orders where status in ('approved','invoiced','partially_paid')));
end $$;

-- ---------------------------------------------------------------------------
-- 8. Grants
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
-- Internal helpers: not callable from the browser.
do $$ declare f record; begin
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'mp\_\_%' loop
    execute 'revoke all on function ' || f.sig || ' from authenticated';
  end loop;
end $$;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function mp_process_payments() to service_role';
  end if;
end $$;
revoke all on mp_orders, mp_order_payments, mp_price_defaults from anon;
