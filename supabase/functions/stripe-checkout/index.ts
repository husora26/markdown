// HUSORA · Edge Function „stripe-checkout“
// Erstellt eine Stripe-Checkout-Sitzung (Abo) bzw. öffnet das Kundenportal.
// Aufruf aus der App mit dem Nutzer-JWT:
//   POST /functions/v1/stripe-checkout  { "plan_id": "pro", "return_url": "https://…" }
//   POST /functions/v1/stripe-checkout  { "portal": true, "return_url": "https://…" }
// Benötigte Secrets (supabase secrets set …): STRIPE_SECRET_KEY
// SUPABASE_URL, SUPABASE_ANON_KEY und SUPABASE_SERVICE_ROLE_KEY stellt Supabase bereit.
// Der Preis kommt ausschließlich aus public.plans.stripe_price_id – nie aus dem Browser.

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const STRIPE_KEY = Deno.env.get('STRIPE_SECRET_KEY') || '';

async function rest(path: string, init: RequestInit & { token?: string } = {}) {
  const token = init.token || SERVICE;
  const response = await fetch(`${SUPABASE_URL}${path}`, { ...init, headers: { apikey: token === SERVICE ? SERVICE : ANON, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', ...(init.headers || {}) } });
  const text = await response.text();
  const data = text ? JSON.parse(text) : null;
  if (!response.ok) throw new Error(data?.message || data?.msg || `Supabase ${response.status}`);
  return data;
}
async function stripe(path: string, params: Record<string, string>) {
  const response = await fetch(`https://api.stripe.com/v1/${path}`, { method: 'POST', headers: { Authorization: `Bearer ${STRIPE_KEY}`, 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(params) });
  const data = await response.json();
  if (!response.ok) throw new Error(data?.error?.message || `Stripe ${response.status}`);
  return data;
}
const safeReturn = (url: unknown) => { try { const u = new URL(String(url)); return u.protocol === 'https:' || u.hostname === 'localhost' || u.hostname === '127.0.0.1' ? u.toString() : null; } catch { return null; } };

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'Nur POST' }, 405);
  if (!STRIPE_KEY) return json({ error: 'Online-Bezahlung ist noch nicht eingerichtet.' }, 503);
  try {
    const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
    if (!jwt) return json({ error: 'Nicht angemeldet' }, 401);
    const user = await rest('/auth/v1/user', { token: jwt });
    const body = await req.json().catch(() => ({}));
    const returnUrl = safeReturn(body.return_url);
    if (!returnUrl) return json({ error: 'Ungültige Rücksprungadresse' }, 400);

    // Organisation des Nutzers serverseitig ermitteln (nie aus dem Browser übernehmen)
    const [org] = await rest('/rest/v1/rpc/ensure_my_organization', { method: 'POST', token: jwt, body: JSON.stringify({ p_name: 'Meine Ferienhäuser' }) }).then((r) => (Array.isArray(r) ? r : [r]));
    if (!org?.organization_id || org.role !== 'admin') return json({ error: 'Nur Admins der Organisation können den Tarif ändern.' }, 403);
    const orgId = org.organization_id;
    const [sub] = await rest(`/rest/v1/subscriptions?organization_id=eq.${orgId}&select=stripe_customer_id`);
    let customer = sub?.stripe_customer_id as string | undefined;
    if (!customer) {
      const created = await stripe('customers', { email: user.email || '', 'metadata[organization_id]': orgId });
      customer = created.id;
      await rest('/rest/v1/subscriptions?on_conflict=organization_id', { method: 'POST', headers: { Prefer: 'resolution=merge-duplicates,return=minimal' }, body: JSON.stringify({ organization_id: orgId, plan_id: 'free', status: 'incomplete', stripe_customer_id: customer }) });
    }

    if (body.portal) {
      const portal = await stripe('billing_portal/sessions', { customer: customer!, return_url: returnUrl });
      return json({ url: portal.url });
    }

    // AGB + Widerrufshinweis müssen vor dem Bezahlfenster bestätigt sein; der Nachweis wird am Abo in Stripe gespeichert.
    const consent = body.consent || {};
    if (consent.terms !== true || consent.waiver !== true) return json({ error: 'Bitte AGB und Widerrufshinweis bestätigen.' }, 400);
    const consentAt = new Date().toISOString();
    const [plan] = await rest(`/rest/v1/plans?id=eq.${encodeURIComponent(String(body.plan_id || ''))}&active=eq.true&select=id,stripe_price_id`);
    if (!plan?.stripe_price_id) return json({ error: 'Für diesen Tarif ist noch kein Stripe-Preis hinterlegt.' }, 400);
    const session = await stripe('checkout/sessions', {
      mode: 'subscription',
      customer: customer!,
      'line_items[0][price]': plan.stripe_price_id,
      'line_items[0][quantity]': '1',
      success_url: `${returnUrl}${returnUrl.includes('?') ? '&' : '?'}checkout=success`,
      cancel_url: `${returnUrl}${returnUrl.includes('?') ? '&' : '?'}checkout=cancel`,
      client_reference_id: orgId,
      'subscription_data[metadata][organization_id]': orgId,
      'subscription_data[metadata][plan_id]': plan.id,
      'subscription_data[metadata][terms_accepted_at]': consentAt,
      'subscription_data[metadata][withdrawal_waiver_at]': consentAt,
      'subscription_data[metadata][accepted_by]': String(user.email || user.id || ''),
      allow_promotion_codes: 'true'
    });
    return json({ url: session.url });
  } catch (error) {
    console.error('stripe-checkout', error);
    return json({ error: error instanceof Error ? error.message : 'Unbekannter Fehler' }, 500);
  }
});
