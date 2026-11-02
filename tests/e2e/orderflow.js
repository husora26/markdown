// Phase 2: Status-Engine und Auftragsverlauf – unterbrechen, fortsetzen, abschließen, wieder öffnen
const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON } = require('./env'); const OUT = SP + '/audit/orderflow'; fs.mkdirSync(OUT, { recursive: true });
const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Flow Service ${N}`, P_EMAIL = `flow${N}@hs.test`, PW = 'Husora!2026', TITLE = `Abwesenheitskontrolle ${N}`;
const sql = (q) => execSync(`psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -At -c "${q.replace(/"/g, '\\"')}"`).toString().trim();
(async () => {
  const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (name, fn) => { try { const r = await fn(); res.push(`OK   ${name}${r ? ' – ' + r : ''}`); } catch (e) { res.push(`FEHL ${name} – ${e.message.split('\n')[0].slice(0, 220)}`); } };
  const device = async (label) => {
    const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    const p = await ctx.newPage(); p.on('pageerror', (e) => errs.push(`${label}: ${e.message}`)); p.on('dialog', (d) => d.accept());
    await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
    await p.goto('http://127.0.0.1:8081/index.html');
    await p.evaluate(({ url, key }) => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); localStorage.setItem('husora-cloud', JSON.stringify({ url, key })); }, { url: URL_, key: ANON });
    await p.reload(); await p.waitForTimeout(400); return p;
  };

  const H = await device('H');
  await step('Hausbesitzer: anmelden im Partner-Portal', async () => {
    await H.evaluate(() => document.querySelector('.nav [data-page="partnerHub"]').click()); await H.waitForTimeout(300);
    await H.fill('[data-cloud-form=signin] [name=email]', 'admin@husora.test'); await H.fill('[data-cloud-form=signin] [name=password]', PW);
    await H.$eval('[data-cloud-form=signin] button[type=submit]', (e) => e.click());
    await H.waitForFunction(() => cloudReady() && !cloudState.busy && ownerSide.partners !== null && !ownerSide.busy, null, { timeout: 20000 });
    return `${await H.evaluate(() => ownerSide.partners.length)} Partner`;
  });
  let CODE = '';
  await step('Hausbesitzer: Partner einladen', async () => {
    await H.fill('[data-owner-form=partner] [name=company_name]', FIRM); await H.fill('[data-owner-form=partner] [name=email]', P_EMAIL);
    await H.$eval('[data-owner-form=partner] button[type=submit]', (e) => e.click()); await H.waitForFunction(() => !ownerSide.busy, null, { timeout: 20000 }); await H.waitForTimeout(300);
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
  const ORDER = sql(`insert into service_orders (organization_id, property_id, service_partner_id, title, status, estimated_cost) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', '${spId}', '${TITLE}', 'offered', 500) returning id`).split('\n')[0];
  const dbStatus = () => sql(`select status from service_orders where id='${ORDER}'`);
  const open = async () => { await P.evaluate(async (id) => { await ppLoad(); pp.view = 'orders'; pp.detail = { type: 'order', id }; pp.form = null; ppRender(); }, ORDER); await P.waitForTimeout(500); };
  const timeline = async () => { await P.waitForFunction(() => document.querySelector('[data-order-events] .hub-history-list'), null, { timeout: 15000 }); return P.$eval('[data-order-events]', (e) => e.textContent); };

  await step('Auftragsart vom Server abgeleitet', async () => { const t = sql(`select order_type from service_orders where id='${ORDER}'`); if (t !== 'inspection') throw new Error(t); return t; });
  await step('Partner: Anfrage annehmen und starten', async () => {
    await open(); await P.click(`[data-pp-action=accept][data-id="${ORDER}"]`); await wait(); await noErr();
    await open(); await P.click(`[data-pp-action=start][data-id="${ORDER}"]`); await wait(); await noErr();
    if (dbStatus() !== 'in_progress') throw new Error(dbStatus()); return `Status ${dbStatus()} · Start ${sql(`select started_at is not null from service_orders where id='${ORDER}'`)}`;
  });
  await step('Partner: unterbrechen „Wartet auf Material“ mit Grund', async () => {
    await open(); await P.fill('[data-pp-field=wait-note]', 'Ersatzteil bestellt');
    await P.click(`[data-pp-action=wait][data-status=waiting_parts][data-id="${ORDER}"]`); await wait(); await noErr();
    await open();
    const badge = await P.$eval('.pp-detail-head .pp-badge', (e) => e.textContent.trim());
    const text = await timeline();
    await P.screenshot({ path: OUT + '/1-wartet.png', fullPage: true });
    if (dbStatus() !== 'waiting_parts' || badge !== 'Wartet auf Material' || !text.includes('Ersatzteil bestellt')) throw new Error(`${dbStatus()} · ${badge} · ${text}`);
    return `${badge} · Verlauf: ${text.replace(/\s+/g, ' ').slice(0, 160)}`;
  });
  await step('Partner: Filter „Wartet“ zählt den Auftrag', async () => {
    await P.evaluate(() => { pp.detail = null; pp.view = 'orders'; pp.filter = 'waiting'; ppRender(); });
    const n = await P.$eval('[data-pp-filter=waiting] b', (e) => e.textContent); const items = await P.$$eval('.pp-item', (e) => e.length);
    if (n !== '1' || items !== 1) throw new Error(`${n} / ${items}`); return `${n} wartend`;
  });
  await step('Partner: weiter arbeiten und abschließen', async () => {
    await open(); await P.click(`[data-pp-action=resume][data-id="${ORDER}"]`); await wait(); await noErr();
    if (dbStatus() !== 'in_progress') throw new Error(dbStatus());
    await open(); await P.click(`[data-pp-action=complete][data-id="${ORDER}"]`); await wait(); await noErr();
    if (dbStatus() !== 'completed') throw new Error(dbStatus()); return dbStatus();
  });
  await step('Server: completed → in_progress direkt abgelehnt', async () => {
    const r = await P.evaluate(async (id) => { try { await ppPatch('service_orders', id, { status: 'in_progress' }); return 'durchgegangen'; } catch (e) { return e.message; } }, ORDER);
    if (!/nicht erlaubt/.test(r) || dbStatus() !== 'completed') throw new Error(`${r} · ${dbStatus()}`); return r;
  });
  await step('Partner: wieder öffnen nur mit Grund', async () => {
    await open(); await P.click('.pp-reopen summary');
    await P.click(`[data-pp-action=reopen][data-id="${ORDER}"]`); await P.waitForTimeout(300);
    if (dbStatus() !== 'completed') throw new Error('ohne Grund geöffnet');
    await P.fill('[data-pp-field=reopen-note]', 'Fenster noch undicht'); await P.click(`[data-pp-action=reopen][data-id="${ORDER}"]`); await wait(); await noErr();
    await open(); const text = await timeline();
    await P.screenshot({ path: OUT + '/2-wieder-offen.png', fullPage: true });
    if (dbStatus() !== 'in_progress' || !text.includes('Wieder geöffnet') || !text.includes('Fenster noch undicht')) throw new Error(`${dbStatus()} · ${text}`);
    return `${dbStatus()} · ${sql(`select count(*) from service_order_events where service_order_id='${ORDER}'`)} Ereignisse`;
  });
  await step('Hausbesitzer: Verlauf im Auftrag mit Partner-Schritten', async () => {
    await H.evaluate(() => { currentPage = 'partnerHub'; hub.tab = 'orders'; render(); }); await H.evaluate(() => hubRefresh()); await H.waitForTimeout(800);
    await H.waitForFunction((t) => (ownerSide.orders || []).some((o) => o.title === t), TITLE, { timeout: 20000 }); await H.evaluate(() => render()); await H.waitForTimeout(300);
    const id = await H.evaluate((t) => ownerSide.orders.find((o) => o.title === t).id, TITLE);
    await H.$eval(`[data-hub-history="${id}"] summary`, (e) => e.click());
    await H.waitForFunction((id) => document.querySelector(`[data-hub-history="${id}"] .hub-history-list`), id, { timeout: 15000 });
    const text = await H.$eval(`[data-hub-history="${id}"]`, (e) => e.textContent.replace(/\s+/g, ' '));
    const card = await H.$(`[data-hub-history="${id}"]`); await card.evaluate((e) => e.closest('.hub-order').scrollIntoView()); await H.screenshot({ path: OUT + '/3-besitzer-verlauf.png' });
    for (const need of ['Anfrage gesendet', 'Angenommen', 'Wartet auf Material', 'Arbeit fortgesetzt', 'Erledigt', 'Wieder geöffnet', 'Fenster noch undicht', FIRM]) if (!text.includes(need)) throw new Error(`fehlt „${need}“: ${text.slice(0, 300)}`);
    return text.slice(0, 200);
  });
  await step('Hausbesitzer: Benachrichtigungen zu Wartezustand und Wiedereröffnung', async () => {
    const n = sql(`select string_agg(title, ' | ' order by created_at) from notifications where entity_id='${ORDER}' and organization_id='cccccccc-0000-4000-8000-000000000001' and user_id=(select id from users where email='admin@husora.test')`);
    if (!n.includes('Wartet auf Material') || !n.includes('wieder geöffnet')) throw new Error(n); return n.slice(0, 200);
  });
  await step('Englisch: neue Statustexte übersetzt', async () => {
    await P.evaluate(() => localStorage.setItem('husora-lang', 'en')); await P.reload(); await P.waitForTimeout(600);
    await P.evaluate(() => ppOpen('orders')); await P.waitForFunction(() => !pp.busy && ppOrg(), null, { timeout: 20000 });
    await P.evaluate((id) => { pp.detail = { type: 'order', id }; ppRender(); }, ORDER); await P.waitForTimeout(400);
    const t = await P.$eval('.pp-wait h3', (e) => e.textContent); await P.evaluate(() => localStorage.setItem('husora-lang', 'de'));
    if (t !== 'Pause order') throw new Error(t); return t;
  });

  console.log(res.join('\n')); if (errs.length) console.log('JS-Fehler:\n' + errs.join('\n'));
  await b.close();
})();
