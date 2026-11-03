// ============================================================================
//  im-stripe-webhook — Supabase Edge Function (Deno)
//
//  Listens for Stripe checkout completion and flips the buyer's im_enrollment
//  to 'active'. The $25 Intro Micro purchase unlocks the WHOLE suite (all
//  arenas + gradebook) per Dr. Sharma's choice.
//
//  How the buyer is matched to an account:
//    The checkout is created with client_reference_id = the Supabase user_id
//    (set by the app when it sends the student to Stripe). The webhook reads
//    it back here. If a purchase arrives with no matching im_person yet (paid
//    before signing in), we stash it in im_enrollment keyed by email via a
//    'pending_email' row that the app reconciles on first sign-in.
//
//  PRODUCT GUARD (added 2026-11): every MacroNations product shares ONE Stripe
//  account, so Stripe delivers every completed checkout to this endpoint.
//  Before this guard, a Strategy Arena / Econometrics / tournament purchase
//  could create a stray Intro Micro person + active enrollment (or a parked
//  pending activation by email). isIntroMicroCheckout() below acknowledges and
//  ignores anything that belongs to another product. Behaviour for genuine
//  Intro Micro checkouts is unchanged.
//
//  Deploy:  supabase functions deploy im-stripe-webhook --no-verify-jwt
//    (Stripe calls this with a signature, not a Supabase JWT.)
//
//  Env to set:
//    STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET,
//    SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//  Optional:
//    IM_PAYMENT_LINK_IDS  comma-separated Stripe payment-link ids (plink_...)
//                         that sell Intro Micro. When set, a checkout with NO
//                         client_reference_id is accepted only if it came
//                         from one of these links.
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14?target=deno";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2024-06-20",
  httpClient: Stripe.createFetchHttpClient(),
});
const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET")!;

// Returns a reason string if the checkout belongs to ANOTHER product, else "".
function otherProductReason(session: Stripe.Checkout.Session): string {
  const ref = session.client_reference_id || "";
  // Strategy Arena family:  studentId__courseId
  if (ref.indexOf("__") !== -1) return "strategy-arena-style reference";
  // Econometrics (eq|...) and the new standard  <course>|student|course  format.
  // Intro Micro may adopt "im|<user_id>" later; that is accepted below.
  if (ref.indexOf("|") !== -1 && ref.indexOf("im|") !== 0) return "prefixed reference for another course";
  // Tournament entry fees are created by Create-checkout with metadata.team_id.
  const md = (session.metadata || {}) as Record<string, string>;
  if (md.team_id) return "tournament entry fee";
  // Optional allow-list of Intro Micro payment links, for reference-less checkouts.
  if (!ref) {
    const list = (Deno.env.get("IM_PAYMENT_LINK_IDS") || "")
      .split(",").map((s) => s.trim()).filter((s) => s.length > 0);
    const plink = typeof session.payment_link === "string" ? session.payment_link : "";
    if (list.length > 0 && list.indexOf(plink) === -1) return "payment link is not an Intro Micro link";
  }
  return "";
}

Deno.serve(async (req: Request) => {
  const sig = req.headers.get("stripe-signature");
  if (!sig) return new Response("missing signature", { status: 400 });

  const body = await req.text();
  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, sig, webhookSecret);
  } catch (err) {
    return new Response("bad signature: " + (err as Error).message, { status: 400 });
  }

  // Only care about completed checkouts.
  if (event.type !== "checkout.session.completed") {
    return new Response("ignored", { status: 200 });
  }

  const session = event.data.object as Stripe.Checkout.Session;

  // ---- Product guard: acknowledge-and-ignore other products' checkouts ------
  const notOurs = otherProductReason(session);
  if (notOurs) {
    return new Response("ignored: " + notOurs, { status: 200 });
  }

  let userId = session.client_reference_id;            // = Supabase user_id, if set
  if (userId && userId.indexOf("im|") === 0) userId = userId.slice(3) || null;
  const email = session.customer_details?.email ?? session.customer_email ?? null;
  const stripeRef = session.id;

  // ---- Email notification via Resend (best-effort; never blocks activation) --
  // Env: RESEND_API_KEY (required to send), NOTIFY_EMAIL (where admin alerts go),
  //      FROM_EMAIL (a verified Resend sender, e.g. "MacroNations <no-reply@yourdomain>").
  async function sendEmail(to: string, subject: string, html: string): Promise<void> {
    const key = Deno.env.get("RESEND_API_KEY");
    const from = Deno.env.get("FROM_EMAIL") ?? "MacroNations <onboarding@resend.dev>";
    if (!key || !to) return;                       // silently skip if unconfigured
    try {
      await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          "Authorization": "Bearer " + key,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ from, to, subject, html }),
      });
    } catch (_e) {
      // Never let an email failure break the webhook / payment activation.
    }
  }

  const PORTAL_URL = Deno.env.get("PORTAL_URL")
    ?? "https://amarendra-sharma.github.io/microeconomics/";
  const amountStr = session.amount_total != null
    ? "$" + (session.amount_total / 100).toFixed(2)
    : "";

  async function notifyOnActivation(studentEmail: string | null): Promise<void> {
    const adminTo = Deno.env.get("NOTIFY_EMAIL");
    // 1) Alert the admin (you).
    if (adminTo) {
      await sendEmail(
        adminTo,
        "New Intro Micro subscription" + (amountStr ? " (" + amountStr + ")" : ""),
        "<h2>New subscription</h2>" +
        "<p>A student just subscribed to Introduction to Microeconomics.</p>" +
        "<ul>" +
        "<li><b>Student email:</b> " + (studentEmail ?? "unknown") + "</li>" +
        "<li><b>Amount:</b> " + (amountStr || "n/a") + "</li>" +
        "<li><b>Stripe session:</b> " + stripeRef + "</li>" +
        "<li><b>Activated:</b> " + nowIso + "</li>" +
        "</ul>" +
        "<p>Their access was activated automatically.</p>",
      );
    }
    // 2) Welcome / receipt to the student.
    if (studentEmail) {
      await sendEmail(
        studentEmail,
        "Welcome to Introduction to Microeconomics",
        "<h2>You're all set!</h2>" +
        "<p>Thank you for subscribing to <b>Introduction to Microeconomics</b>. " +
        "Your full access is active now &mdash; all 17 chapters, every arena, exams, and your gradebook.</p>" +
        (amountStr ? ("<p><b>Amount paid:</b> " + amountStr + "</p>") : "") +
        "<p><a href='" + PORTAL_URL + "' style='display:inline-block;padding:10px 18px;" +
        "background:#0f3d9e;color:#fff;text-decoration:none;border-radius:8px;font-weight:600;'>" +
        "Open the course portal</a></p>" +
        "<p style='color:#666;font-size:13px;'>If the button doesn't work, visit " + PORTAL_URL + "</p>" +
        "<p style='color:#666;font-size:13px;'>&mdash; MacroNations</p>",
      );
    }
  }

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const nowIso = new Date().toISOString();

  if (userId) {
    // Ensure a person row exists (defensive; the app usually creates it first).
    await admin.from("im_person").upsert(
      { user_id: userId, email: email ?? "unknown", updated_at: nowIso },
      { onConflict: "user_id" },
    );
    const { error } = await admin.from("im_enrollment").upsert({
      user_id: userId,
      status: "active",
      source: "stripe",
      stripe_ref: stripeRef,
      activated_at: nowIso,
    }, { onConflict: "user_id" });
    if (error) return new Response("db error: " + error.message, { status: 500 });
    await notifyOnActivation(email);
    return new Response("activated:" + userId, { status: 200 });
  }

  // Paid before signing in: park an activation the app reconciles by email.
  if (email) {
    await admin.from("im_pending_activation").upsert({
      email: email.toLowerCase(),
      stripe_ref: stripeRef,
      created_at: nowIso,
    }, { onConflict: "email" });
    // Notify admin + student even for parked payments (student gets access on sign-in).
    await notifyOnActivation(email);
    return new Response("parked:" + email, { status: 200 });
  }

  return new Response("no user or email on session", { status: 200 });
});
