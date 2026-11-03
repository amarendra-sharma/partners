// ============================================================================
//  mp-stripe-sync — MacroNations Partner Program (Supabase Edge Function)
//
//  Copies completed Stripe checkouts and refunds into mp_payments / mp_refunds,
//  then calls mp_process_payments(), which credits partner commissions for
//  payments on courses that are credited to a partner.
//
//  Read-only towards Stripe: it only LISTS checkout sessions and refunds.
//  It never creates charges, changes customers, or touches course access.
//
//  Who may call it:
//    * the hourly scheduled job, which sends header  x-mp-token  (value kept
//      in table mp_secrets, readable only by the service role), or
//    * a signed-in partner-program admin ("Sync now" in the admin console).
//
//  Deploy with verify_jwt = false (the function does its own auth).
//  Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (automatic);
//           STRIPE_SECRET_KEY (already set in this project), or
//           MP_STRIPE_SECRET_KEY to use a separate restricted read-only key.
// ============================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SRK = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const STRIPE_KEY = Deno.env.get("MP_STRIPE_SECRET_KEY") || Deno.env.get("STRIPE_SECRET_KEY") || "";
const MAX_PAGES = 30;            // 30 × 100 sessions per run
const FIRST_RUN_DAYS = 120;      // history to import on the very first run

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-mp-token",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

// deno-lint-ignore no-explicit-any
type Obj = Record<string, any>;

async function stripeList(path: string, params: string[]): Promise<Obj[]> {
  const out: Obj[] = [];
  let after = "";
  for (let page = 0; page < MAX_PAGES; page++) {
    const q = params.concat(["limit=100"]).concat(after ? ["starting_after=" + encodeURIComponent(after)] : []);
    const res = await fetch("https://api.stripe.com/v1/" + path + "?" + q.join("&"), {
      headers: { Authorization: "Bearer " + STRIPE_KEY },
    });
    const body = await res.json();
    if (!res.ok) throw new Error("Stripe " + path + ": " + ((body && body.error && body.error.message) || res.status));
    const data = (body.data || []) as Obj[];
    out.push(...data);
    if (!body.has_more || data.length === 0) break;
    after = data[data.length - 1].id;
  }
  return out;
}

// Exported for tests: turn a Stripe checkout session into an mp_payments row.
export function sessionRow(s: Obj): Obj | null {
  if (s.status !== "complete" || s.payment_status !== "paid") return null;
  const pi = s.payment_intent && typeof s.payment_intent === "object" ? s.payment_intent : null;
  const piId = pi ? pi.id : (typeof s.payment_intent === "string" ? s.payment_intent : null);
  const ch = pi && pi.latest_charge && typeof pi.latest_charge === "object" ? pi.latest_charge : null;
  const bt = ch && ch.balance_transaction && typeof ch.balance_transaction === "object" ? ch.balance_transaction : null;
  const cd = s.customer_details || {};
  return {
    id: s.id,
    created_at_stripe: new Date(s.created * 1000).toISOString(),
    payment_intent: piId,
    amount_cents: s.amount_total || 0,
    fees_cents: bt ? bt.fee : null,
    currency: s.currency || null,
    email: cd.email || s.customer_email || null,
    client_reference_id: s.client_reference_id || null,
    metadata: s.metadata || {},
    payment_link: typeof s.payment_link === "string" ? s.payment_link : null,
    synced_at: new Date().toISOString(),
  };
}

export function refundRow(r: Obj): Obj {
  return {
    id: r.id,
    payment_intent: typeof r.payment_intent === "string" ? r.payment_intent : (r.payment_intent && r.payment_intent.id) || null,
    amount_cents: r.amount || 0,
    created_at_stripe: new Date(r.created * 1000).toISOString(),
    status: r.status || null,
    synced_at: new Date().toISOString(),
  };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const db = createClient(SB_URL, SRK, { auth: { persistSession: false } });

  // ---- who is calling ------------------------------------------------------
  let caller = "";
  const token = req.headers.get("x-mp-token") || "";
  if (token) {
    const { data } = await db.from("mp_secrets").select("value").eq("id", "cron").maybeSingle();
    if (data && data.value && data.value === token) caller = "schedule";
  }
  if (!caller) {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    if (jwt) {
      const u = await db.auth.getUser(jwt);
      const uid = u.data && u.data.user ? u.data.user.id : "";
      if (uid) {
        const { data } = await db.from("mp_admins").select("user_id").eq("user_id", uid).maybeSingle();
        if (data) caller = "admin";
      }
    }
  }
  if (!caller) return json({ error: "Not allowed." }, 401);
  if (!STRIPE_KEY) return json({ error: "No Stripe key is set for this project (STRIPE_SECRET_KEY)." }, 500);

  const started = new Date().toISOString();
  const { data: state } = await db.from("mp_sync_state").select("*").eq("id", "stripe").maybeSingle();
  const firstRun = Math.floor(Date.now() / 1000) - FIRST_RUN_DAYS * 86400;
  const since = state && state.cursor_created ? Number(state.cursor_created) - 3600 : firstRun;
  const refundSince = state && state.refund_cursor ? Number(state.refund_cursor) - 3600 : firstRun;

  try {
    const sessions = await stripeList("checkout/sessions", [
      "status=complete",
      "created[gte]=" + since,
      "expand[]=data.payment_intent.latest_charge.balance_transaction",
    ]);
    const rows = sessions.map(sessionRow).filter((r): r is Obj => r !== null);
    let maxCreated = since;
    for (const s of sessions) if (s.created > maxCreated) maxCreated = s.created;
    for (let i = 0; i < rows.length; i += 200) {
      const { error } = await db.from("mp_payments").upsert(rows.slice(i, i + 200), { onConflict: "id" });
      if (error) throw new Error("saving payments: " + error.message);
    }

    const refunds = await stripeList("refunds", ["created[gte]=" + refundSince]);
    const rrows = refunds.map(refundRow);
    let maxRefund = refundSince;
    for (const r of refunds) if (r.created > maxRefund) maxRefund = r.created;
    for (let i = 0; i < rrows.length; i += 200) {
      const { error } = await db.from("mp_refunds").upsert(rrows.slice(i, i + 200), { onConflict: "id" });
      if (error) throw new Error("saving refunds: " + error.message);
    }

    const proc = await db.rpc("mp_process_payments");
    if (proc.error) throw new Error("matching: " + proc.error.message);

    const counts = { caller, sessions_seen: sessions.length, payments_saved: rows.length,
                     refunds_saved: rrows.length, ...(proc.data || {}) };
    await db.from("mp_sync_state").update({
      cursor_created: maxCreated, refund_cursor: maxRefund, last_run: started,
      last_ok: new Date().toISOString(), last_error: null, last_counts: counts,
    }).eq("id", "stripe");
    return json({ ok: true, ...counts });
  } catch (e) {
    const msg = (e as Error).message || String(e);
    await db.from("mp_sync_state").update({ last_run: started, last_error: msg.slice(0, 500) }).eq("id", "stripe");
    return json({ ok: false, error: msg }, 500);
  }
});
