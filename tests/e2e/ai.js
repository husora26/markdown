// Phase 12: KI-Vorschläge (Kontrollbericht, Kostenschätzung) – Edge Function im Test simuliert, Speichern/Entscheiden echt
const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON } = require('./env'); const OUT = SP + '/audit/ai'; fs.mkdirSync(OUT, { recursive: true });
const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `KI Service ${N}`, P_EMAIL = `ki${N}@hs.test`, PW = 'Husora!2026', TITLE = `KI ${N}`;
const sql = (q) => execSync(`psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -At -c "${q.replace(/"/g, '\\"')}"`).toString().trim();
(async () => {
  const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (name, fn) => { try { const r = await fn(); res.push(`OK   ${name}${r ? ' – ' + r : ''}`); } catch (e) { res.push(`FEHL ${name} – ${e.message.split('\n')[0].slice(0, 220)}`); } };
  const device = async (label, width = 390) => {
    const ctx = await b.newContext({ viewport: { width, height: 844 }, isMobile: width < 600, hasTouch: true });
    const p = await ctx.newPage(); p.on('pageerror', (e) => errs.push(`${label}: ${e.message}`)); p.on('dialog', (d) => d.accept());
    await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
    await p.goto('http://127.0.0.1:8081/index.html');
    await p.evaluate(({ url, key }) => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); localStorage.setItem('husora-cloud', JSON.stringify({ url, key })); }, { url: URL_, key: ANON });
    await p.reload(); await p.waitForTimeout(400); return p;
  };
  sql(`update app_config set value = '{"enabled": true, "daily_limit": 50}' where key = 'ai'`);

  const H = await device('H');
  const hWait = () => H.waitForFunction(() => !ownerSide.busy, null, { timeout: 20000 }).then(() => H.waitForTimeout(300));
  await step('Hausbesitzer: anmelden', async () => {
    await H.evaluate(() => document.querySelector('.nav [data-page="partnerHub"]').click()); await H.waitForTimeout(300);
    await H.fill('[data-cloud-form=signin] [name=email]', 'admin@husora.test'); await H.fill('[data-cloud-form=signin] [name=password]', PW);
    await H.$eval('[data-cloud-form=signin] button[type=submit]', (e) => e.click());
    await H.waitForFunction(() => cloudReady() && !cloudState.busy && ownerSide.partners !== null && !ownerSide.busy, null, { timeout: 20000 });
  });
  let CODE = '';
  await step('Hausbesitzer: Partner einladen', async () => {
    await H.fill('[data-owner-form=partner] [name=company_name]', FIRM); await H.fill('[data-owner-form=partner] [name=email]', P_EMAIL);
    await H.$eval('[data-owner-form=partner] button[type=submit]', (e) => e.click()); await hWait();
    CODE = await H.evaluate(() => ownerSide.code?.code || ownerSide.error); if (!/^HUS-/.test(CODE)) throw new Error(CODE); return CODE;
  });
  const P = await device('P');
  const wait = () => P.waitForFunction(() => !pp.busy, null, { timeout: 20000 }).then(() => P.waitForTimeout(300));
  const noErr = async () => { const e = await P.evaluate(() => pp.error); if (e) throw new Error(e); };
  await step('Partner: Betrieb anlegen und verbinden', async () => {
    await P.evaluate(() => ppOpen('dashboard')); await P.waitForTimeout(200);
    await P.fill('[data-pp-form=login] [name=email]', P_EMAIL); await P.fill('[data-pp-form=login] [name=password]', PW);
    await P.$eval('[data-pp-action=signup]', (e) => e.click()); await P.waitForFunction(() => !pp.busy && document.querySelector('[data-pp-form=company]'), null, { timeout: 20000 });
    await P.fill('[data-pp-form=company] [name=name]', FIRM); await P.$eval('[data-pp-form=company] button[type=submit]', (e) => e.click()); await P.waitForFunction(() => !pp.busy && ppOrg(), null, { timeout: 20000 });
    await P.evaluate(() => { pp.view = 'customers'; ppRender(); });
    await P.fill('[data-pp-form=invite-code] [name=code]', CODE); await P.$eval('[data-pp-form=invite-code] button[type=submit]', (e) => e.click()); await wait();
    return await P.evaluate(() => pp.ctx.links.map((l) => l.organization_name).join(', '));
  });
  const spId = sql(`select id from service_partners where company_name='${FIRM}' and organization_id='cccccccc-0000-4000-8000-000000000001'`);
  const porg = sql(`select id from organizations where name='${FIRM}'`);
  const INSP = sql(`insert into inspections (organization_id, property_id, service_partner_id, status, started_at, completed_at) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', '${spId}', 'completed', now() - interval '1 hour', now()) returning id`).split('\n')[0];
  const ITEM = sql(`insert into inspection_items (inspection_id, category, name, status, notes) values ('${INSP}', 'Dach', 'Dachrinne ${N}', 'defect', 'Rinne lose') returning id`).split('\n')[0];
  // Edge Function simulieren: Eintrag wie der Server anlegen (Status „Vorschlag“), Ergebnis zurückgeben
  let calls = 0;
  await P.route('**/functions/v1/ai-assist', async (route) => {
    calls += 1;
    const req = JSON.parse(route.request().postData() || '{}');
    const result = req.kind === 'inspection_report'
      ? { summary: 'Dachrinne lose, sonst in Ordnung', overall: 'attention', priorities: [{ title: 'Dachrinne befestigen', reason: 'Wasser läuft an der Fassade', priority: 'high' }], next_steps: ['Termin mit Dachdecker'] }
      : { low: 1500, high: 2500, currency: 'SEK', assumptions: ['3 m Rinne', 'Halterungen tauschen'], trade: 'Dachdecker' };
    const user = sql(`select id from users where email='${P_EMAIL}'`);
    const id = sql(`insert into ai_suggestions (requester_org_id, entity_org_id, requested_by, kind, entity_type, entity_id, status, result, model) values ('${porg}', 'cccccccc-0000-4000-8000-000000000001', '${user}', '${req.kind}', '${req.entity_type}', '${req.entity_id}', 'suggested', '${JSON.stringify(result)}', 'test') returning id`).split('\n')[0];
    await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id, result }) });
  });
  await step('Partner: abgeschlossene Kontrolle → „Bericht mit KI auswerten“', async () => {
    await P.evaluate(async (id) => { await ppLoad(); aiS().enabled = null; pp.view = 'inspections'; pp.detail = { type: 'inspection', id }; ppRender(); }, INSP); await P.waitForTimeout(1200);
    await P.click(`[data-ai-run="inspection_report|inspection|${INSP}"]`); await P.waitForTimeout(800);
    const t = await P.evaluate(() => document.querySelector('#partner-portal .ai-card')?.textContent.replace(/\s+/g, ' '));
    await P.evaluate(() => document.querySelector('#partner-portal .ai-card')?.scrollIntoView()); await P.screenshot({ path: OUT + '/1-ki-bericht.png' });
    if (!t?.includes('KI-Vorschlag') || !t.includes('Dachrinne befestigen') || !t.includes('bitte prüfen')) throw new Error(t); return t.slice(0, 90);
  });
  await step('Vorschlag übernehmen (nur durch den Nutzer)', async () => {
    const before = sql(`select status from ai_suggestions where entity_id='${INSP}'`);
    await P.click(`#partner-portal [data-ai-decide][data-entity="${INSP}"][data-accept="1"]`); await P.waitForTimeout(800);
    const after = sql(`select status from ai_suggestions where entity_id='${INSP}'`);
    if (before !== 'suggested' || after !== 'accepted') throw new Error(`${before} → ${after}`); return `${before} → ${after}`;
  });
  await step('Kostenschätzung im Mangel-Formular → Mittelwert übernehmen', async () => {
    await P.evaluate(({ item }) => { pp.detail = null; pp.view = 'defects'; pp.form = `repair:${item}`; ppRender(); }, { id: INSP, item: ITEM }); await P.waitForTimeout(800);
    await P.click(`[data-ai-run="cost_estimate|inspection_item|${ITEM}"]`); await P.waitForTimeout(800);
    await P.click(`#partner-portal [data-ai-decide][data-entity="${ITEM}"][data-accept="1"]`); await P.waitForTimeout(800);
    const v = await P.inputValue('#partner-portal [data-pp-form="repair-offer"] [name=cost]');
    const st = sql(`select status from ai_suggestions where entity_id='${ITEM}'`);
    await P.screenshot({ path: OUT + '/2-ki-kosten.png' });
    if (v !== '2000' || st !== 'accepted') throw new Error(`${v} ${st}`); return `Kosten ${v} SEK · ${st}`;
  });
  await step('KI ausgeschaltet → keine KI-Schaltflächen', async () => {
    sql(`update app_config set value = '{"enabled": false, "daily_limit": 50}' where key = 'ai'`);
    await P.evaluate((id) => { aiS().enabled = null; aiS().items = {}; pp.form = null; pp.detail = { type: 'inspection', id }; ppRender(); }, INSP); await P.waitForTimeout(1200);
    const n = await P.evaluate(() => document.querySelectorAll('#partner-portal [data-ai-run]').length);
    if (n !== 0) throw new Error(String(n)); return `keine Schaltfläche · ${calls} simulierte Aufrufe`;
  });
  console.log(res.join('\n')); if (errs.length) console.log('JS-Fehler:\n' + errs.join('\n'));
  await b.close();
})();
