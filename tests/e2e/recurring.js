// Phase 10: Vertragsbesuche automatisch planen (Partner/Hausbesitzer), Cloud-Regel Mangel → Reparaturauftrag
const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON } = require('./env'); const OUT = SP + '/audit/recurring'; fs.mkdirSync(OUT, { recursive: true });
const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Plan Service ${N}`, P_EMAIL = `plan${N}@hs.test`, PW = 'Husora!2026', TITLE = `Rasen ${N}`;
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
  sql(`delete from automation_rules where organization_id = 'cccccccc-0000-4000-8000-000000000001' and action_config->>'type' = 'create_repair_order'`);

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
  const AG = sql(`insert into service_agreements (organization_id, property_id, service_partner_id, title, task_title, task_titles, visits_per_year, annual_price, currency, starts_on, ends_on, status, proposed_by) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', '${spId}', 'Rasenpflege ${N}', '${TITLE}', array['${TITLE}'], 26, 1300, 'SEK', current_date - 2, current_date + 360, 'active', 'owner') returning id`).split('\n')[0];
  await step('Partner: „Besuche automatisch planen“ im Jahresvertrag', async () => {
    await P.evaluate(async () => { await ppLoad(); pp.view = 'agreements'; pp.detail = null; ppRender(); }); await P.waitForTimeout(400);
    await P.$eval(`[data-ag-auto="${AG}"]`, (el) => { el.checked = true; el.dispatchEvent(new Event('change', { bubbles: true })); }); await wait(); await noErr();
    const r = sql(`select a.auto_schedule||'/'||(select count(*) from service_orders o where o.agreement_id=a.id and o.recurrence_key is not null) from service_agreements a where a.id='${AG}'`);
    await P.evaluate((id) => document.querySelector(`[data-ag-auto="${id}"]`)?.closest('article')?.scrollIntoView(), AG); await P.screenshot({ path: OUT + '/1-partner-vertrag.png' });
    const [on, n] = r.split('/'); if (on !== 'true' || Number(n) < 1) throw new Error(r); return `${n} Besuche geplant`;
  });
  await step('Partner: geplante Besuche erscheinen als Aufträge', async () => {
    const t = await P.evaluate(() => ppD('orders').filter((o) => o.recurrence_key).length);
    if (t < 1) throw new Error(String(t)); return `${t} Aufträge im Portal`;
  });
  await step('Hausbesitzer: Schalter im Jahresvertrag sichtbar und an', async () => {
    await H.evaluate(async () => { await ownerLoadPartners(); currentPage = 'partnerHub'; hub.tab = 'agreements'; render(); }); await H.waitForTimeout(400);
    const on = await H.evaluate((id) => document.querySelector(`[data-ag-auto="${id}"]`)?.checked, AG);
    if (on !== true) throw new Error(String(on)); return 'an';
  });
  await step('Hausbesitzer: Cloud-Regel „Mangel sofort beauftragen“ einschalten', async () => {
    await H.evaluate(() => { currentPage = 'automation'; render(); }); await H.waitForTimeout(1200);
    await H.$eval('[data-cloud-rule="repair_order"]', (el) => { el.checked = true; el.dispatchEvent(new Event('change', { bubbles: true })); }); await H.waitForTimeout(1200);
    await H.evaluate(() => document.querySelector('[data-cloud-rule]')?.closest('section')?.scrollIntoView()); await H.screenshot({ path: OUT + '/2-besitzer-regel.png' });
    const r = sql(`select active from automation_rules where organization_id='cccccccc-0000-4000-8000-000000000001' and action_config->>'type'='create_repair_order'`);
    if (r !== 't') throw new Error(r); return 'Regel aktiv';
  });
  await step('Mangel in Partner-Kontrolle → Reparaturauftrag beim Partner', async () => {
    const insp = sql(`insert into inspections (organization_id, property_id, service_partner_id, status) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', '${spId}', 'in_progress') returning id`).split('\n')[0];
    sql(`insert into inspection_items (inspection_id, category, name, status) values ('${insp}', 'Dach', 'Rinne ${N}', 'ok')`);
    sql(`update inspection_items set status='defect' where inspection_id='${insp}'`);
    const r = sql(`select o.status||'/'||o.order_type from service_orders o where o.title='Mangelbeseitigung: Rinne ${N}' and o.service_partner_id='${spId}'`);
    if (r !== 'accepted/repair') throw new Error(r); return r;
  });
  sql(`delete from automation_rules where organization_id = 'cccccccc-0000-4000-8000-000000000001' and action_config->>'type' = 'create_repair_order'`);
  console.log(res.join('\n')); if (errs.length) console.log('JS-Fehler:\n' + errs.join('\n'));
  await b.close();
})();
