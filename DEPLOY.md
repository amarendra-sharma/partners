# MacroNations Partner Portal — deploy notes

Live at https://partners.macronations.com (GitHub Pages, this repo). Backend: Supabase project `rtaiivegcqqmdchpguzn`.
Everything here is additive: no existing course table, function or page is changed by the partner program.

## Database (MacroNation Tournament project) — all applied
Run in order; each file is safe to re-run.

1. `sql/mp-01-partners-phase1.sql` — partners, agreements, professors (leads), credits, commission ledger, security rules.
2. `sql/mp-02-seed-agreement-toolkit.sql` — draft partner agreement v1 and starter toolkit.
3. `sql/mp-03-phase2-revenue.sql` — Stripe payment mirror, automatic commission matching, refunds, new-course suggestions, partner-link landing page.
4. `sql/mp-04-schedule-sync.sql` — hourly job (minute 17) that calls the `mp-stripe-sync` function.

`sql/mp-99-uninstall.sql` removes every `mp_` object. To stop the hourly job only: `select cron.unschedule('mp-stripe-sync');`

## Edge functions (deployed)
- `mp-stripe-sync` (verify JWT off; does its own checks). Reads checkout sessions and refunds from Stripe — never writes to Stripe — and credits commissions.
  It needs a Stripe key that can read payments, in the project secret **`MP_STRIPE_SECRET_KEY`**. Best: a restricted key with *Read* on Checkout Sessions, Payment Intents, Charges, Balance transactions and Refunds.
  (The project's existing `STRIPE_SECRET_KEY` holds a key ID, `mk_…`, not a key, so it cannot be used. The course webhooks don't need it.)
- `im-stripe-webhook` v16 — Intro Micro now ignores other products' checkouts (Strategy Arena `student__course`, any `prefix|…` reference other than `im|`, tournament fees).
  Optional: secret `IM_PAYMENT_LINK_IDS` = Intro Micro payment-link ids (`plink_…`), to accept reference-less checkouts only from those links.

## How payments reach partners
1. A partner registers a professor (or the professor leaves their details on the partner's link).
2. The professor sets up a course. For Micro, Macro, International Trade and Econometrics the admin **Deal desk** lists it under *New courses to credit*; Game Theory, Finance and Economics & Film courses are credited by pasting the course id.
3. Once credited, every Stripe payment for that course becomes a commission line automatically (hourly, or *Check Stripe now* under **Stripe payments**). Refunds reduce it, never below zero. Payments already received inside the earning window are picked up as soon as the course is credited.
4. Institutional invoices: **Courses & revenue → Record revenue**.

Payments are matched by Stripe `client_reference_id`: `eq|student|course`, `student__course` (Strategy Arena family), a bare Intro Micro user id, or `<prefix>|student|course`. Payments that can't be matched appear under *Needs a look* and can be credited by hand. Partners never see student names or emails.

## Before partners can sign
- Have counsel review the agreement (**Settings → Partner agreement**), then tick **Agreement signing open**.

## Still to come
- Phase 3: customer agreements (pilot, adoption, institutional licence).
- Phase 4: Stripe Connect payouts. Until then, mark commissions paid with a payout reference.
