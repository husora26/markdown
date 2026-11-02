// HUSORA · Edge Function „notify-dispatch“ (Phase 9)
// Wird vom Datenbank-Trigger private.notification_dispatch() per pg_net aufgerufen, sobald eine
// Benachrichtigung entsteht und der Empfänger Push oder E-Mail für diese Kategorie eingeschaltet hat.
// Versendet Web-Push an alle Geräte des Empfängers und optional eine E-Mail.
//
// Deploy ohne JWT-Prüfung (Aufruf kommt aus der Datenbank, geprüft wird das gemeinsame Geheimnis):
//   supabase functions deploy notify-dispatch --no-verify-jwt
// Secrets (Supabase → Edge Functions → Secrets, nie im Code):
//   NOTIFY_DISPATCH_SECRET   gleicher Wert wie im Vault 'notify_dispatch_secret'
//   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (z. B. mailto:info@husora.de)
//   RESEND_API_KEY, NOTIFY_FROM_EMAIL (optional, für E-Mails)
// Vault (SQL Editor):
//   select vault.create_secret('https://<projekt>.supabase.co/functions/v1/notify-dispatch', 'notify_dispatch_url');
//   select vault.create_secret('<zufälliger langer Wert>', 'notify_dispatch_secret');
// Öffentlichen VAPID-Schlüssel für die App eintragen:
//   update public.app_config set value = jsonb_build_object('vapid_public_key', '<VAPID_PUBLIC_KEY>') where key = 'push';
import webpush from 'npm:web-push@3.6.7';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const SECRET = Deno.env.get('NOTIFY_DISPATCH_SECRET') || '';
const VAPID_PUBLIC = Deno.env.get('VAPID_PUBLIC_KEY') || '';
const VAPID_PRIVATE = Deno.env.get('VAPID_PRIVATE_KEY') || '';
const VAPID_SUBJECT = Deno.env.get('VAPID_SUBJECT') || 'mailto:info@husora.de';
const RESEND = Deno.env.get('RESEND_API_KEY') || '';
const FROM = Deno.env.get('NOTIFY_FROM_EMAIL') || '';
const APP_URL = Deno.env.get('HUSORA_APP_URL') || 'https://husora26.github.io/markdown/';

if (VAPID_PUBLIC && VAPID_PRIVATE) webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC, VAPID_PRIVATE);

async function rest(path: string, init: RequestInit = {}) {
  const response = await fetch(`${SUPABASE_URL}${path}`, { ...init, headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json', ...(init.headers || {}) } });
  const text = await response.text();
  if (!response.ok) throw new Error(`Supabase ${response.status}: ${text}`);
  return text ? JSON.parse(text) : null;
}
// Vergleich in konstanter Zeit
function sameSecret(a: string, b: string) {
  if (!a || !b || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  if (!sameSecret(req.headers.get('x-husora-secret') || '', SECRET)) return new Response('Forbidden', { status: 403 });
  let id = '';
  try { id = String((await req.json())?.notification_id || ''); } catch { /* leer */ }
  if (!/^[0-9a-f-]{36}$/.test(id)) return new Response('Bad request', { status: 400 });
  try {
    const [n] = await rest(`/rest/v1/notifications?id=eq.${id}&select=id,user_id,category,title,message,entity_type,entity_id`);
    if (!n) return new Response('not found', { status: 404 });
    const [pref] = await rest(`/rest/v1/notification_preferences?user_id=eq.${n.user_id}&category=eq.${n.category}&select=push,email`);
    const push = pref ? pref.push : true;
    const email = pref ? pref.email : false;
    const result = { push: 0, removed: 0, email: false };
    if (push && VAPID_PUBLIC && VAPID_PRIVATE) {
      const subs = await rest(`/rest/v1/push_subscriptions?user_id=eq.${n.user_id}&select=id,endpoint,p256dh,auth_key`);
      // Nur Titel/Kurztext und Ziel – keine weiteren Inhalte im Push
      const payload = JSON.stringify({ title: n.title, body: String(n.message || '').slice(0, 140), tag: `${n.entity_type || 'husora'}:${n.entity_id || n.id}`, url: APP_URL, category: n.category });
      for (const s of subs) {
        try {
          await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth_key } }, payload, { TTL: 86400 });
          result.push += 1;
          await rest(`/rest/v1/push_subscriptions?id=eq.${s.id}`, { method: 'PATCH', body: JSON.stringify({ last_used_at: new Date().toISOString() }), headers: { Prefer: 'return=minimal' } });
        } catch (error) {
          const code = (error as { statusCode?: number }).statusCode;
          if (code === 404 || code === 410) { await rest(`/rest/v1/push_subscriptions?id=eq.${s.id}`, { method: 'DELETE', headers: { Prefer: 'return=minimal' } }); result.removed += 1; }
        }
      }
    }
    if (email && RESEND && FROM) {
      const [u] = await rest(`/rest/v1/users?id=eq.${n.user_id}&select=email,first_name`);
      if (u?.email) {
        const html = `<p>Hallo ${esc(u.first_name || '')},</p><p><strong>${esc(n.title)}</strong></p>${n.message ? `<p>${esc(String(n.message))}</p>` : ''}<p><a href="${APP_URL}">In Husora öffnen</a></p><p style="color:#777;font-size:12px">Du erhältst diese E-Mail, weil du sie in Husora unter Benachrichtigungen eingeschaltet hast.</p>`;
        const res = await fetch('https://api.resend.com/emails', { method: 'POST', headers: { Authorization: `Bearer ${RESEND}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ from: FROM, to: u.email, subject: n.title, html }) });
        result.email = res.ok;
      }
    }
    return Response.json(result);
  } catch (error) {
    console.error('notify-dispatch', error);
    return new Response('error', { status: 500 });
  }
});
