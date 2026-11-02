// Phase 6: Auftragsliste mit Suche, Priorität, Art, Sortierung; Haus-Detail mit Beträgen und Grafik
const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON } = require('./env'); const OUT = SP + '/audit/orders6'; fs.mkdirSync(OUT, { recursive: true });
const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Auftrag Service ${N}`, P_EMAIL = `auf${N}@hs.test`, PW = 'Husora!2026', TITLE = `Einsatz ${N}`;
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
  const porg = sql(`select id from organizations where name='${FIRM}'`);
    // Mitarbeiter direkt anlegen (Einladung ist in anderen Tests abgedeckt)
  const TECH = `tech${N}@hs.test`;
  sql(`insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', '${TECH}', '', now(), '{"provider":"email","providers":["email"]}', '{"first_name":"Tina","last_name":"Technik"}', now(), now())`);
  sql(`insert into organization_members (organization_id, user_id, role, status) select '${porg}', id, 'technician', 'active' from users where email='${TECH}'`);
  const techId = sql(`select id from users where email='${TECH}'`);

  const mk = (t, when, status, type, tech) => sql(`insert into service_orders (organization_id, property_id, service_partner_id, title, status, scheduled_at, order_type) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', '${spId}', '${TITLE} ${t}', 'offered', now() + interval '${when}', '${type}') returning id`).split('\n')[0];
  const today = mk('heute', '1 minute', 'scheduled', 'cleaning');
  const late = mk('gestern', '-1 day', 'accepted', 'garden');
  const waitO = mk('wartet', '2 days', 'waiting_parts', 'repair');
  sql(`update service_orders set status='accepted' where id in ('${today}','${late}','${waitO}')`); sql(`update service_orders set status='scheduled', assigned_user_id='${techId}' where id='${today}'`);
  sql(`update service_orders set status='in_progress' where id='${waitO}'`); sql(`update service_orders set status='waiting_parts' where id='${waitO}'`);
  sql(`insert into invoices (organization_id, property_id, service_order_id, service_partner_id, invoice_number, amount_net, tax_amount, amount_gross, currency, status, invoice_date) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', '${late}', '${spId}', 'K-${N}', 800, 200, 1000, 'SEK', 'received', current_date)`);

  sql(`update service_orders set priority='urgent' where id='${late}'`); sql(`update service_orders set priority='high' where id='${waitO}'`);
  sql(`update service_orders set status='completed' where id='${late}'`);
  const open = async () => { await P.evaluate(async () => { await ppLoad(); pp.view = 'orders'; pp.filter = 'all'; pp.detail = null; pp.orderQuery = ''; pp.orderPrio = ''; pp.orderType = ''; pp.orderSort = 'date'; ppRender(); }); await P.waitForTimeout(300); };
  const names = () => P.$$eval('.pp-list .pp-item strong', (e, t) => e.map((x) => x.textContent).filter((x) => x.includes(t)).map((x) => x.replace(/^(Dringend|Wichtig|Notfall|Niedrig)/, '').replace(`${t} `, '')), TITLE);
  await step('Auftragsliste: Dringend-Kennzeichnung und Art sichtbar', async () => {
    await open(); const txt = await P.textContent('#partner-portal .pp-list');
    await P.screenshot({ path: OUT + '/1-liste.png', fullPage: true });
    if (!txt.includes('Dringend') || !txt.includes('Garten') || !txt.includes('Reinigung')) throw new Error(txt.slice(0, 200)); return 'Dringend · Wichtig · Art je Auftrag';
  });
  await step('Filter Priorität „Dringend & Notfall“', async () => {
    await P.selectOption('[data-pp-order-opt=orderPrio]', 'urgent'); await P.waitForTimeout(200);
    const n = await names(); if (n.join() !== 'gestern') throw new Error(n.join()); return n.join();
  });
  await step('Filter Auftragsart und Suche', async () => {
    await P.selectOption('[data-pp-order-opt=orderPrio]', ''); await P.selectOption('[data-pp-order-opt=orderType]', 'repair'); await P.waitForTimeout(200);
    const byType = (await names()).join();
    await P.selectOption('[data-pp-order-opt=orderType]', ''); await P.fill('[data-pp-order-q]', 'heute'); await P.waitForTimeout(500);
    const bySearch = (await names()).join(); const focused = await P.evaluate(() => document.activeElement?.hasAttribute('data-pp-order-q'));
    await P.fill('[data-pp-order-q]', ''); await P.waitForTimeout(400);
    if (byType !== 'wartet' || bySearch !== 'heute' || !focused) throw new Error(`${byType} / ${bySearch} / ${focused}`); return `Art: ${byType} · Suche: ${bySearch} · Fokus bleibt`;
  });
  await step('Sortierung nach Priorität', async () => {
    await P.selectOption('[data-pp-order-opt=orderSort]', 'priority'); await P.waitForTimeout(200);
    const n = await names(); if (n.slice(0, 2).join() !== 'gestern,wartet') throw new Error(n.join()); return n.join(' → ');
  });
  await step('Kunde → Ferienhaus: Aufträge mit Status, Beträgen und Grafik', async () => {
    const cid = sql(`select id from customers where organization_id=(select id from organizations where name='${FIRM}') limit 1`);
    await P.evaluate((id) => { pp.view = 'customers'; pp.detail = { type: 'customer', id }; pp.openProps = new Set(['dddddddd-0000-4000-8000-000000000001']); ppRender(); }, cid); await P.waitForTimeout(300);
    const box = '[data-pp-prop-orders="dddddddd-0000-4000-8000-000000000001"]';
    const kpis = await P.$eval(`${box} .pp-prop-kpis`, (e) => e.textContent.replace(/\s+/g, ' '));
    const bars = await P.$$eval(`${box} .pp-chart-bar`, (e) => e.filter((x) => Number(x.getAttribute('height')) > 0).length);
    const legend = await P.$eval(`${box} .pp-statlegend`, (e) => e.textContent.replace(/\s+/g, ' '));
    const rows = await P.$$eval(`${box} .pp-prop-row`, (e) => e.length);
    await P.$eval(box, (e) => e.scrollIntoView()); await P.screenshot({ path: OUT + '/2-haus.png', fullPage: true });
    if (!/1\.000/.test(kpis) || bars < 1 || !legend.includes('Erledigt') || rows < 3) throw new Error(`${kpis} · ${bars} · ${legend} · ${rows}`);
    return `${kpis.trim()} · ${bars} Monatsbalken · ${legend.trim()}`;
  });

  console.log(res.join('\n')); if (errs.length) console.log('JS-Fehler:\n' + errs.join('\n'));
  await b.close();
})();
