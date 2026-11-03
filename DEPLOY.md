# MacroNations Partner Portal — Phase 1 deploy

Everything here is additive. Nothing in an existing course table, function, or page changes.

## 1. Database (MacroNation Tournament project)
Run in the Supabase SQL editor, in this order:

1. `sql/mp-01-partners-phase1.sql`: tables, security rules, functions. It also makes your existing Intro Micro admin login the partner super-admin.
2. `sql/mp-02-seed-agreement-toolkit.sql`: draft partner agreement v1 and three starter toolkit items.

Both are safe to re-run. `sql/mp-99-uninstall.sql` removes every `mp_` object if you ever want it gone.

## 2. Site
1. Create a GitHub repo `partners` under amarendra-sharma and add `index.html` and `CNAME`.
2. Turn on GitHub Pages (main branch, root).
3. In your DNS, add a CNAME record: `partners` → `amarendra-sharma.github.io`.
4. In Supabase → Auth → URL Configuration → Redirect URLs, add `https://partners.macronations.com`. This makes confirmation and password-reset emails return to the portal.

## 3. Before partners can sign
- Have counsel review the agreement under **Settings → Partner agreement**. Edit it there and publish a new version if needed.
- Then tick **Agreement signing open** in Settings. Until you do, approved partners can read the draft but not sign.

## 4. Smoke test
1. Sign in at partners.macronations.com with your usual login. You should see the admin overview.
2. In a private window, create a test partner account and apply. Approve it under **Partners**.
3. Open signing, sign as the test partner, and add a professor.
4. Credit that professor's course from the **Deal desk**, then record a $100 test revenue line. Void the line afterwards.

## Intro Micro webhook fix (separate)
`im-stripe-webhook/index.ts` replaces the deployed function. It makes Intro Micro ignore checkouts that belong to other products: Strategy Arena, Econometrics, other courses' prefixed checkouts, and tournament entry fees. Intro Micro's own checkouts behave exactly as before.

Deploy:
```
supabase functions deploy im-stripe-webhook --no-verify-jwt --project-ref rtaiivegcqqmdchpguzn
```

Optional extra guard: set the secret `IM_PAYMENT_LINK_IDS` to your Intro Micro payment-link id(s) (`plink_...`, comma-separated). Checkouts with no reference are then accepted only from those links.

## What Phase 1 does not do yet
- **Phase 2:** read Stripe payments automatically and capture `?ref=` codes on macronations.com and the course consoles. Until then, credit courses and record revenue by hand in the admin view.
- **Phase 3:** customer agreements (pilot, adoption, institutional license).
- **Phase 4:** Stripe Connect payouts. Until then, mark commissions paid with a payout reference.
