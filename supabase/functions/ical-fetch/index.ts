// HUSORA · Edge Function „ical-fetch“: Kalender-Links (Airbnb, Booking.com, Vrbo) serverseitig abrufen
// Ersetzt die fremden Weiterleitungsdienste (allorigins.win, cors.lol), die den Kalender-Link sehen konnten.
// Sicherheit:
//   * Nur für angemeldete Husora-Nutzer (JWT-Prüfung von Supabase bleibt an, zusätzlich /auth/v1/user).
//   * Nur https und nur bekannte Kalender-Anbieter (kein Abruf beliebiger Adressen, keine IP-Adressen).
//   * Zeitlimit 10 s, höchstens 2 MB, Antwort muss ein iCalendar (BEGIN:VCALENDAR) sein.
//   * Der Link wird nicht gespeichert und nicht protokolliert.
// Deploy: supabase functions deploy ical-fetch      (JWT-Prüfung bleibt an)
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const ALLOWED = [/(^|\.)airbnb\.[a-z.]{2,8}$/i, /(^|\.)booking\.com$/i, /(^|\.)vrbo\.com$/i, /(^|\.)homeaway\.[a-z.]{2,8}$/i, /(^|\.)abritel\.fr$/i, /(^|\.)fewo-direkt\.de$/i];
const MAX_BYTES = 2 * 1024 * 1024;

const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

export function allowedUrl(raw: unknown): URL | null {
  if (typeof raw !== 'string' || raw.length > 2000) return null;
  let url: URL;
  try { url = new URL(raw); } catch { return null; }
  if (url.protocol !== 'https:' || url.username || url.password || (url.port && url.port !== '443')) return null;
  if (/^[\d.]+$/.test(url.hostname) || url.hostname.includes(':')) return null;
  return ALLOWED.some((pattern) => pattern.test(url.hostname)) ? url : null;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json(405, { error: 'Nur POST' });
  const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
  const who = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: ANON, Authorization: `Bearer ${token}` } });
  if (!who.ok) return json(401, { error: 'Bitte mit deinem Husora-Konto anmelden.' });
  let body: { url?: unknown } = {};
  try { body = await req.json(); } catch { return json(400, { error: 'Ungültige Anfrage.' }); }
  const url = allowedUrl(body.url);
  if (!url) return json(400, { error: 'Nur Kalender-Links von Airbnb, Booking.com und Vrbo (https) werden abgerufen.' });
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 10000);
  try {
    // Weiterleitungen einzeln prüfen: jedes Ziel muss ein erlaubter Anbieter sein (höchstens 5 Sprünge)
    let target: URL = url;
    let response: Response | null = null;
    for (let hop = 0; hop <= 5; hop++) {
      response = await fetch(target, { redirect: 'manual', signal: controller.signal, headers: { Accept: 'text/calendar, text/plain;q=0.8', 'User-Agent': 'Husora-Kalender/1.0' } });
      if (response.status < 300 || response.status >= 400) break;
      const next = allowedUrl(new URL(response.headers.get('Location') || '', target).toString());
      await response.body?.cancel();
      if (!next) return json(400, { error: 'Der Link leitet zu einer nicht erlaubten Adresse weiter.' });
      if (hop === 5) return json(508, { error: 'Zu viele Weiterleitungen.' });
      target = next;
    }
    if (!response) return json(502, { error: 'Der Kalender konnte nicht geladen werden.' });
    if (!response.ok) return json(502, { error: `Der Anbieter antwortet mit Fehler ${response.status}.` });
    const reader = response.body?.getReader();
    const chunks: Uint8Array[] = [];
    let size = 0;
    while (reader) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_BYTES) { controller.abort(); return json(413, { error: 'Der Kalender ist zu groß.' }); }
      chunks.push(value);
    }
    const all = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) { all.set(chunk, offset); offset += chunk.byteLength; }
    const text = new TextDecoder().decode(all);
    if (!/BEGIN:VCALENDAR/i.test(text)) return json(422, { error: 'Der Link liefert keinen gültigen Kalender.' });
    return new Response(text, { status: 200, headers: { ...cors, 'Content-Type': 'text/calendar; charset=utf-8', 'Cache-Control': 'no-store' } });
  } catch (error) {
    return json(504, { error: (error as Error).name === 'AbortError' ? 'Der Anbieter antwortet nicht.' : 'Der Kalender konnte nicht geladen werden.' });
  } finally {
    clearTimeout(timer);
  }
});
