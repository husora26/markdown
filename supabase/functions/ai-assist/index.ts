// HUSORA · Edge Function „ai-assist“ (Phase 12): KI-VORSCHLÄGE – nie automatisch übernommen
//   inspection_report  Kontrollbericht auswerten (Zusammenfassung, Prioritäten, nächste Schritte)
//   photo_damage       Schaden auf einem Foto erkennen
//   cost_estimate      Kosten für einen Mangel schätzen (Spanne)
// Sicherheit:
//   * Zugriff auf Objekt und Daten ausschließlich mit dem Token des Nutzers (RLS entscheidet).
//   * Nur das Ergebnis schreibt die Function mit service_role (ai_complete) – fälschungssicher.
//   * Datensparsam: keine Namen, Adressen, Kontaktdaten oder Nachrichten an das Modell.
// Secrets (Supabase → Edge Functions → Secrets): ANTHROPIC_API_KEY
// Deploy: supabase functions deploy ai-assist      (JWT-Prüfung bleibt an)
// Einschalten: update public.app_config set value = '{"enabled": true, "daily_limit": 50}' where key = 'ai';
import Anthropic from 'npm:@anthropic-ai/sdk';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const MODEL = 'claude-opus-5-5';
const anthropic = Deno.env.get('ANTHROPIC_API_KEY') ? new Anthropic() : null;
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };

async function asUser(token: string, path: string, init: RequestInit = {}) {
  const res = await fetch(`${SUPABASE_URL}${path}`, { ...init, headers: { apikey: ANON, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', ...(init.headers || {}) } });
  const text = await res.text();
  if (!res.ok) throw new Error(JSON.parse(text || '{}')?.message || `HTTP ${res.status}`);
  return text ? JSON.parse(text) : null;
}
async function complete(id: string, result: unknown, error: string | null) {
  await fetch(`${SUPABASE_URL}/rest/v1/rpc/ai_complete`, { method: 'POST', headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ p_id: id, p_result: result, p_model: MODEL, p_error: error }) });
}
const strict = (properties: Record<string, unknown>, required = Object.keys(properties)) => ({ type: 'object', properties, required, additionalProperties: false });
const PRIORITY = { type: 'string', enum: ['low', 'normal', 'high', 'urgent'] };
const SCHEMAS: Record<string, unknown> = {
  inspection_report: strict({
    summary: { type: 'string' },
    overall: { type: 'string', enum: ['good', 'attention', 'critical'] },
    priorities: { type: 'array', items: strict({ title: { type: 'string' }, reason: { type: 'string' }, priority: PRIORITY }) },
    next_steps: { type: 'array', items: { type: 'string' } },
  }),
  photo_damage: strict({
    damage_detected: { type: 'boolean' },
    findings: { type: 'array', items: strict({ label: { type: 'string' }, location: { type: 'string' }, severity: { type: 'string', enum: ['minor', 'moderate', 'severe'] } }) },
    recommendation: { type: 'string' },
    confidence: { type: 'string', enum: ['low', 'medium', 'high'] },
  }),
  cost_estimate: strict({
    low: { type: 'number' }, high: { type: 'number' }, currency: { type: 'string' },
    assumptions: { type: 'array', items: { type: 'string' } },
    trade: { type: 'string' },
  }),
};
const SYSTEM = 'Du unterstützt Ferienhaus-Besitzer und Servicebetriebe in Schweden und Deutschland. Antworte auf Deutsch, sachlich und knapp. Deine Antwort ist ein Vorschlag, den ein Mensch prüft – sage klar, wenn die Angaben nicht ausreichen, statt zu raten.';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405, headers: cors });
  const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
  if (!token) return Response.json({ error: 'Bitte anmelden' }, { status: 401, headers: cors });
  if (!anthropic) return Response.json({ error: 'KI ist noch nicht eingerichtet' }, { status: 503, headers: cors });
  let body: { kind?: string; entity_type?: string; entity_id?: string; organization_id?: string } = {};
  try { body = await req.json(); } catch { /* leer */ }
  const { kind = '', entity_type = '', entity_id = '' } = body;
  if (!SCHEMAS[kind] || !/^[0-9a-f-]{36}$/.test(entity_id)) return Response.json({ error: 'Ungültige Anfrage' }, { status: 400, headers: cors });

  let id = '';
  try {
    // 1) Berechtigung + Kontingent (RLS mit dem Nutzer-Token)
    id = await asUser(token, '/rest/v1/rpc/ai_begin', { method: 'POST', body: JSON.stringify({ p_kind: kind, p_entity_type: entity_type, p_entity_id: entity_id, p_organization_id: body.organization_id || null }) });
    // 2) Daten mit dem Nutzer-Token lesen – nur fachliche Angaben, keine Personendaten
    const propSel = 'property:properties(property_type,year_built,living_area_m2,region,country)';
    const content: Anthropic.ContentBlockParam[] = [];
    if (kind === 'inspection_report') {
      const [i] = await asUser(token, `/rest/v1/inspections?id=eq.${entity_id}&select=status,overall_status,notes,completed_at,${propSel},items:inspection_items(category,name,status,notes,estimated_cost)`);
      content.push({ type: 'text', text: `Werte diese Hauskontrolle aus. Nenne die wichtigsten Punkte nach Dringlichkeit und konkrete nächste Schritte.\n\n${JSON.stringify(i)}` });
    } else if (kind === 'photo_damage') {
      const [p] = await asUser(token, `/rest/v1/photos?id=eq.${entity_id}&select=storage_bucket,storage_path,caption`);
      const res = await fetch(`${SUPABASE_URL}/storage/v1/object/authenticated/${p.storage_bucket}/${p.storage_path}`, { headers: { apikey: ANON, Authorization: `Bearer ${token}` } });
      if (!res.ok) throw new Error('Foto nicht verfügbar');
      const bytes = new Uint8Array(await res.arrayBuffer());
      if (bytes.length > 5 * 1024 * 1024) throw new Error('Foto zu groß');
      let bin = ''; for (let k = 0; k < bytes.length; k += 0x8000) bin += String.fromCharCode(...bytes.subarray(k, k + 0x8000));
      const media = (res.headers.get('content-type') || 'image/jpeg').split(';')[0] as 'image/jpeg' | 'image/png' | 'image/webp';
      content.push({ type: 'image', source: { type: 'base64', media_type: media, data: btoa(bin) } });
      content.push({ type: 'text', text: `Erkennst du auf diesem Foto eines Ferienhauses Schäden (z. B. Feuchtigkeit, Risse, Fäulnis, Schimmel, lose Teile)? Beschreibe Ort und Schwere. Bildunterschrift: ${String(p.caption || '').slice(0, 200)}` });
    } else {
      const path = entity_type === 'repair'
        ? `/rest/v1/repairs?id=eq.${entity_id}&select=title,description,priority,estimated_cost,${propSel}`
        : `/rest/v1/inspection_items?id=eq.${entity_id}&select=category,name,status,notes,inspection:inspections(${propSel})`;
      const [r] = await asUser(token, path);
      content.push({ type: 'text', text: `Schätze die Kosten (Material + Arbeit, brutto) für die Beseitigung dieses Mangels als Spanne in der Landeswährung des Hauses (SEK in Schweden, sonst EUR). Nenne deine Annahmen und das passende Gewerk.\n\n${JSON.stringify(r)}` });
    }
    // 3) Modell fragen (strukturierte JSON-Antwort; serverseitiger Ausweichweg bei Ablehnung)
    const msg = await anthropic.beta.messages.create({
      model: MODEL,
      max_tokens: 16000,
      betas: ['server-side-fallback-2026-07-01'],
      fallbacks: 'default',
      system: SYSTEM,
      output_config: { effort: 'medium', format: { type: 'json_schema', schema: SCHEMAS[kind] } },
      messages: [{ role: 'user', content }],
    } as never) as Anthropic.Beta.BetaMessage;
    if (msg.stop_reason === 'refusal') throw new Error('Die KI hat diese Anfrage abgelehnt');
    if (msg.stop_reason === 'max_tokens') throw new Error('Antwort unvollständig');
    const text = msg.content.find((b) => b.type === 'text') as Anthropic.Beta.BetaTextBlock | undefined;
    const result = JSON.parse(text?.text || '{}');
    await complete(id, { ...result, suggestion: true }, null);
    return Response.json({ id, result }, { headers: cors });
  } catch (error) {
    const message = error instanceof Anthropic.APIError ? 'KI gerade nicht erreichbar – bitte später erneut versuchen' : (error as Error).message || 'Fehler';
    if (id) await complete(id, null, message);
    return Response.json({ error: message }, { status: id ? 502 : 403, headers: cors });
  }
});
