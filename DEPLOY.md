# MacroNations Partner Portal — deploy notes

Live at https://partners.macronations.com (GitHub Pages, this repo). Backend: Supabase project `rtaiivegcqqmdchpguzn`.
Everything here is additive: no existing course table, function or page is changed by the partner program.

## Database (MacroNation Tournament project) — all applied
Run in order; each file is safe to re-run.

1. `sql/mp-01-partners-phase1.sql` — partners, agreements, professors (leads), credits, commission ledger, security rules.
2. `sql/mp-02-seed-agreement-toolkit.sql` — draft partner agreement v1 and starter toolkit.
3. `sql/mp-03-phase2-revenue.sql` — Stripe payment mirror, automatic commission matching, refunds, new-course suggestions, partner-link landing page.
4. `sql/mp-04-schedule-sync.sql` — hourly job (minute 17) that calls the `mp-stripe-sync` function.
5. `sql/mp-05-institutional-orders.sql` — institutional billing: orders, invoices, seat tracking, payments, access switching.

Always run them in this order; re-running an earlier file after a later one is safe for grants, but re-run the later files afterwards so their newer function versions win.

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

## Institutional billing (a university or department pays)
- **Request form:** `https://partners.macronations.com/?billing` (optionally `&product=im&course=<id>&title=…&term=…`). Anyone can request; you approve under **Institutional orders**. The Intro Micro console's course settings link to it pre-filled; other consoles get the same one-line link as they're updated.
- **Approving** gives the section's students access straight away: Micro, Macro and International Trade get a course-wide fee waiver (note "Institutional order MN-…"); Econometrics has `requires_payment` turned off. Game Theory, Finance and Economics & Film live in the other Supabase project — set the section to free in that console.
- **Invoice:** each order has an online invoice page (`?invoice=<token>`) to email, print or save as PDF, and pay.
- **Paying online:** create one Stripe payment link with "Customers choose what to pay" on, and paste it in **Settings → Institutional billing**. Invoices add `client_reference_id=inst|<order id>`, so the hourly sync matches payments to orders automatically. Cheques, wires and ACH: **Record a payment** on the order.
- **Seats:** enrolment is counted for Micro, Macro, International Trade and Econometrics. If it passes the paid seats, the order is flagged and you can invoice a top-up; students are never locked out.
- **Partners:** payments on an order whose course is credited to a partner (or that you link to a partner credit) add commission automatically.

## Before partners can sign
- Have counsel review the agreement (**Settings → Partner agreement**), then tick **Agreement signing open**.

## Still to come
- Phase 3: customer agreements (pilot, adoption, institutional licence).
- Phase 4: Stripe Connect payouts. Until then, mark commissions paid with a payout reference.
