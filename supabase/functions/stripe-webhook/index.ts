// HUSORA · Edge Function „stripe-webhook“
// Empfängt Stripe-Ereignisse und hält public.subscriptions aktuell (Upgrade,
// Downgrade, Kündigung, Zahlungsfehler). Signatur wird geprüft, jedes Ereignis
// nur einmal verarbeitet (public.stripe_events).
// Deploy ohne JWT-Prüfung: supabase functions deploy stripe-webhook --no-verify-jwt
// Secrets: STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET
// Stripe-Endpunkt: https://<projekt>.supabase.co/functions/v1/stripe-webhook
// Ereignisse: checkout.session.completed, customer.subscription.created|updated|deleted,
//             invoice.payment_failed

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const STRIPE_KEY = Deno.env.get('STRIPE_SECRET_KEY') || '';
const WEBHOOK_SECRET = Deno.env.get('STRIPE_WEBHOOK_SECRET') || '';

async function rest(path: string, init: RequestInit = {}) {
  const response = await fetch(`${SUPABASE_URL}${path}`, { ...init, headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json', ...(init.headers || {}) } });
  const text = await response.text();
  if (!response.ok) throw new Error(`Supabase ${response.status}: ${text}`);
  return text ? JSON.parse(text) : null;
}
async function stripeGet(path: string) {
  const response = await fetch(`https://api.stripe.com/v1/${path}`, { headers: { Authorization: `Bearer ${STRIPE_KEY}` } });
  const data = await response.json();
  if (!response.ok) throw new Error(data?.error?.message || `Stripe ${response.status}`);
  return data;
}

// Stripe-Signatur (v1, HMAC-SHA256) prüfen, Toleranz 5 Minuten
async function verify(payload: string, header: string | null) {
  if (!header || !WEBHOOK_SECRET) return false;
  const parts = Object.fromEntries(header.split(',').map((kv) => kv.split('=') as [string, string]));
  const timestamp = Number(parts.t);
  if (!timestamp || Math.abs(Date.now() / 1000 - timestamp) > 300) return false;
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(WEBHOOK_SECRET), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${timestamp}.${payload}`));
  const expected = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, '0')).join('');
  const given = header.split(',').filter((kv) => kv.startsWith('v1=')).map((kv) => kv.slice(3));
  return given.some((sig) => sig.length === expected.length && [...sig].reduce((acc, ch, i) => acc | (ch.charCodeAt(0) ^ expected.charCodeAt(i)), 0) === 0);
}

const iso = (seconds?: number | null) => (seconds ? new Date(seconds * 1000).toISOString() : null);

async function planForPrice(priceId: string | undefined) {
  if (!priceId) return null;
  const [plan] = await rest(`/rest/v1/plans?stripe_price_id=eq.${encodeURIComponent(priceId)}&select=id`);
  return plan?.id || null;
}

async function syncSubscription(sub: any) {
  const orgId = sub.metadata?.organization_id;
  if (!orgId) throw new Error(`Abo ${sub.id} ohne organization_id`);
  const planId = (await planForPrice(sub.items?.data?.[0]?.price?.id)) || sub.metadata?.plan_id || 'free';
  const status = sub.status === 'canceled' ? 'canceled' : sub.status; // trialing, active, past_due, unpaid, incomplete, paused …
  await rest('/rest/v1/subscriptions?on_conflict=organization_id', {
    method: 'POST',
    headers: { Prefer: 'resolution=merge-duplicates,return=minimal' },
    body: JSON.stringify({
      organization_id: orgId,
      plan_id: status === 'canceled' ? 'free' : planId,
      stripe_customer_id: typeof sub.customer === 'string' ? sub.customer : sub.customer?.id,
      stripe_subscription_id: sub.id,
      status,
      current_period_start: iso(sub.current_period_start ?? sub.items?.data?.[0]?.current_period_start),
      current_period_end: iso(sub.current_period_end ?? sub.items?.data?.[0]?.current_period_end),
      cancel_at_period_end: Boolean(sub.cancel_at_period_end)
    })
  });
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('Nur POST', { status: 405 });
  const payload = await req.text();
  if (!(await verify(payload, req.headers.get('Stripe-Signature')))) return new Response('Ungültige Signatur', { status: 400 });
  const event = JSON.parse(payload);
  try {
    // Idempotenz: Ereignis schon verarbeitet?
    const seen = await rest(`/rest/v1/stripe_events?id=eq.${encodeURIComponent(event.id)}&select=id`);
    if (seen.length) return new Response('bereits verarbeitet', { status: 200 });

    const obj = event.data?.object || {};
    switch (event.type) {
      case 'checkout.session.completed':
        if (obj.subscription) await syncSubscription(await stripeGet(`subscriptions/${obj.subscription}`));
        break;
      case 'customer.subscription.created':
      case 'customer.subscription.updated':
      case 'customer.subscription.deleted':
        await syncSubscription(obj);
        break;
      case 'invoice.payment_failed':
        if (obj.subscription) await syncSubscription(await stripeGet(`subscriptions/${obj.subscription}`));
        break;
      default:
        break; // andere Ereignisse ignorieren
    }
    await rest('/rest/v1/stripe_events', { method: 'POST', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ id: event.id, type: event.type, payload: { object: obj.id || null } }) });
    return new Response('ok', { status: 200 });
  } catch (error) {
    console.error('stripe-webhook', event?.type, error);
    return new Response('Fehler – Stripe versucht es erneut', { status: 500 }); // Stripe wiederholt automatisch
  }
});
