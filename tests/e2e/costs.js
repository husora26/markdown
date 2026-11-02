// Phase 8: Zeit/Material/Anfahrt je Auftrag, Rechnungsbetrag daraus, Mehrkosten-Freigabe mit Auto-Limit
const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON } = require('./env'); const OUT = SP + '/audit/costs'; fs.mkdirSync(OUT, { recursive: true });
const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Kosten Service ${N}`, P_EMAIL = `cost${N}@hs.test`, PW = 'Husora!2026', TITLE = `Kosten-Einsatz ${N}`;
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
  sql(`update organizations set auto_approval_limit = null where id = 'cccccccc-0000-4000-8000-000000000001'`);

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
  sql(`update organizations set hourly_rate = 60, travel_fee = 45 where id='${porg}'`);
  const ORDER = sql(`insert into service_orders (organization_id, property_id, service_partner_id, title, status, estimated_cost, currency) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', '${spId}', '${TITLE}', 'offered', 300, 'SEK') returning id`).split('\n')[0];
  sql(`update service_orders set status='accepted' where id='${ORDER}'`); sql(`update service_orders set status='in_progress' where id='${ORDER}'`);
  const openOrder = () => P.evaluate(async (id) => { await ppLoad(); pp.view = 'orders'; pp.detail = { type: 'order', id }; pp.form = null; ppRender(); }, ORDER).then(() => P.waitForTimeout(300));

  await step('Partner: Zeiterfassung Start/Stopp → Minuten und Betrag', async () => {
    await openOrder();
    await P.click(`[data-pp-action=timer-start][data-id="${ORDER}"]`); await wait(); await noErr();
    const running = await P.evaluate(() => Boolean(document.querySelector('.pp-timer-dot')));
    sql(`update service_order_cost_items set started_at = now() - interval '30 minutes' where service_order_id='${ORDER}' and kind='work'`);
    await openOrder();
    const tid = sql(`select id from service_order_cost_items where service_order_id='${ORDER}' and kind='work'`);
    await P.click(`[data-pp-action=timer-stop][data-id="${tid}"]`); await wait(); await noErr();
    const r = sql(`select minutes||'/'||amount||'/'||(organization_id='${porg}') from service_order_cost_items where id='${tid}'`);
    if (!running || r !== '30/30.00/true') throw new Error(`${running} ${r}`); return `läuft: ${running} · ${r}`;
  });
  await step('Partner: Material und Anfahrt (Pauschale vorbelegt)', async () => {
    await openOrder();
    await P.click(`[data-pp-action=cost-form][data-kind=material]`); await P.waitForTimeout(200);
    await P.fill('[data-pp-form=cost-item] [name=description]', 'Silikon'); await P.fill('[data-pp-form=cost-item] [name=quantity]', '2'); await P.fill('[data-pp-form=cost-item] [name=unit]', 'Stk'); await P.fill('[data-pp-form=cost-item] [name=unit_price]', '9.5');
    await P.click('[data-pp-form=cost-item] button[type=submit]'); await wait(); await noErr();
    await P.evaluate((id) => { pp.detail = { type: 'order', id }; ppRender(); }, ORDER);
    await P.click(`[data-pp-action=cost-form][data-kind=travel]`); await P.waitForTimeout(200);
    const fee = await P.inputValue('[data-pp-form=cost-item] [name=unit_price]');
    await P.click('[data-pp-form=cost-item] button[type=submit]'); await wait(); await noErr();
    const r = sql(`select string_agg(kind||':'||amount, ' ' order by kind) from service_order_cost_items where service_order_id='${ORDER}'`);
    if (fee !== '45' || r !== 'material:19.00 travel:45.00 work:30.00') throw new Error(`${fee} ${r}`); return r;
  });
  await step('Partner: Abschluss übernimmt die Summe (netto + MwSt.)', async () => {
    await openOrder();
    const v = await P.evaluate(() => ({ gross: document.querySelector('[data-pp-form=complete-invoice] [name=gross]')?.value, vat: document.querySelector('[data-pp-form=complete-invoice] [name=vat]')?.value, hint: document.querySelector('.pp-cost-hint')?.textContent }));
    const expect = Math.round(94 * (1 + Number(v.vat) / 100) * 100) / 100;
    await P.evaluate(() => document.querySelector('[data-pp-costs]')?.scrollIntoView()); await P.screenshot({ path: OUT + '/1-partner-kosten.png' });
    if (Number(v.gross) !== expect || !v.hint?.includes('übernommen')) throw new Error(JSON.stringify(v)); return `brutto ${v.gross} (MwSt. ${v.vat} %)`;
  });
  await step('Partner: Mehrkosten 180 zur Freigabe anfragen', async () => {
    await P.click(`[data-pp-action=approval-form][data-id="${ORDER}"]`); await P.waitForTimeout(200);
    await P.fill('[data-pp-form=approval] [name=title]', 'Zusätzliches Rohrstück'); await P.fill('[data-pp-form=approval] [name=amount]', '180'); await P.fill('[data-pp-form=approval] [name=description]', 'Altes Rohr korrodiert');
    await P.click('[data-pp-form=approval] button[type=submit]'); await wait(); await noErr();
    const r = sql(`select status||'/'||auto_approved from approval_requests where service_order_id='${ORDER}'`);
    const t = await P.textContent('#partner-portal .pp-main');
    if (r !== 'pending/false' || !t.includes('Wartet auf Freigabe')) throw new Error(r); return r;
  });
  await step('Hausbesitzer: Freigabe im Reiter Aufträge, freigeben', async () => {
    await H.evaluate(async () => { await ownerLoadPartners(); hub.tab = 'orders'; render(); }); await H.waitForTimeout(400);
    const card = await H.evaluate(() => document.querySelector('.hub-approvals-card')?.textContent.replace(/\s+/g, ' '));
    const badge = await H.evaluate(() => document.querySelector('[data-hub-tab=orders] .hub-count')?.textContent);
    await H.screenshot({ path: OUT + '/2-besitzer-freigabe.png' });
    if (!card?.includes('Zusätzliches Rohrstück') || !(Number(badge) >= 1)) throw new Error(`${badge} ${card}`);
    const aid = sql(`select id from approval_requests where service_order_id='${ORDER}'`);
    await H.click(`.hub-approvals-card [data-hub-approval="${aid}"][data-approve="1"]`); await hWait();
    const r = sql(`select a.status||'/'||o.estimated_cost||'/'||o.approval_status from approval_requests a join service_orders o on o.id=a.service_order_id where a.id='${aid}'`);
    if (r !== 'approved/480.00/approved') throw new Error(r); return r;
  });
  await step('Hausbesitzer: Freigabelimit 100 speichern', async () => {
    await H.evaluate(() => { hub.tab = 'partners'; render(); }); await H.waitForTimeout(300);
    await H.fill('[data-hub-limit-form] [name=limit]', '100'); await H.click('[data-hub-limit-form] button[type=submit]'); await hWait();
    const r = sql(`select auto_approval_limit from organizations where id='cccccccc-0000-4000-8000-000000000001'`);
    if (r !== '100.00') throw new Error(r || ownerSide.error); return r;
  });
  await step('Partner: 60 unter dem Limit → automatisch freigegeben', async () => {
    await openOrder();
    await P.click(`[data-pp-action=approval-form][data-id="${ORDER}"]`); await P.waitForTimeout(200);
    await P.fill('[data-pp-form=approval] [name=title]', 'Dichtungen'); await P.fill('[data-pp-form=approval] [name=amount]', '60');
    await P.click('[data-pp-form=approval] button[type=submit]'); await wait(); await noErr();
    await P.evaluate((id) => { pp.detail = { type: 'order', id }; ppRender(); }, ORDER); await P.waitForTimeout(200);
    const t = await P.textContent('#partner-portal .pp-main');
    const r = sql(`select status||'/'||auto_approved from approval_requests where service_order_id='${ORDER}' and title='Dichtungen'`);
    if (r !== 'approved/true' || !t.includes('Automatisch freigegeben')) throw new Error(r); return r;
  });
  await step('Partner fragt 500 an → Hausbesitzer lehnt ab', async () => {
    await P.click(`[data-pp-action=approval-form][data-id="${ORDER}"]`); await P.waitForTimeout(200);
    await P.fill('[data-pp-form=approval] [name=title]', 'Neue Pumpe'); await P.fill('[data-pp-form=approval] [name=amount]', '500');
    await P.click('[data-pp-form=approval] button[type=submit]'); await wait(); await noErr();
    await H.evaluate(async () => { await ownerLoadPartners(); hub.tab = 'orders'; render(); }); await H.waitForTimeout(300);
    const aid = sql(`select id from approval_requests where service_order_id='${ORDER}' and title='Neue Pumpe'`);
    await H.click(`.hub-approvals-card [data-hub-approval="${aid}"][data-approve="0"]`); await hWait();
    const r = sql(`select a.status||'/'||o.estimated_cost from approval_requests a join service_orders o on o.id=a.service_order_id where a.id='${aid}'`);
    if (r !== 'rejected/540.00') throw new Error(r); return r;
  });
  await step('Verlauf: Freigaben im Auftragsverlauf', async () => {
    const n = sql(`select count(*) from service_order_events where service_order_id='${ORDER}' and event_type='note'`);
    await openOrder(); await P.waitForTimeout(800);
    await P.evaluate(() => document.querySelector('.pp-approval')?.scrollIntoView()); await P.screenshot({ path: OUT + '/3-partner-freigaben.png' });
    if (Number(n) < 5) throw new Error(n); return `${n} Einträge`;
  });
  sql(`update organizations set auto_approval_limit = null where id = 'cccccccc-0000-4000-8000-000000000001'`);
  console.log(res.join('\n')); if (errs.length) console.log('JS-Fehler:\n' + errs.join('\n'));
  await b.close();
})();
