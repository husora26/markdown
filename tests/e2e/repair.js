// Mangel: Partner fragt Beseitigung an → Hausbesitzer nimmt unter Mängel & Reparaturen an → Auftrag beim Partner
const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON } = require('./env'); const OUT = SP + '/audit/repair'; fs.mkdirSync(OUT, { recursive: true });
const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Reparatur Service ${N}`, P_EMAIL = `rep${N}@hs.test`, PW = 'Husora!2026', TITLE = `Einsatz ${N}`;
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


  const HOUSE = 'dddddddd-0000-4000-8000-000000000001';
  const ORDER = sql(`insert into service_orders (organization_id, property_id, service_partner_id, title, status) values ('cccccccc-0000-4000-8000-000000000001', '${HOUSE}', '${spId}', '${TITLE} Hausservice', 'offered') returning id`).split('\n')[0];
  sql(`update service_orders set status='accepted' where id='${ORDER}'`);
  const MANGEL = `Dachrinne undicht ${N}`;
  await step('Partner: im Auftrag „Mangel festgestellt“ → beim Kunden anfragen', async () => {
    await P.evaluate(async (id) => { await ppLoad(); pp.view = 'orders'; pp.detail = { type: 'order', id }; pp.form = null; ppRender(); }, ORDER); await P.waitForTimeout(300);
    await P.click(`[data-pp-action=repair-form-order][data-id="${ORDER}"]`); await P.waitForTimeout(200);
    await P.fill('[data-pp-form=repair-offer] [name=title]', MANGEL); await P.fill('[data-pp-form=repair-offer] [name=description]', 'Rinne an der Nordseite tropft'); await P.fill('[data-pp-form=repair-offer] [name=cost]', '1200');
    await P.selectOption('[data-pp-form=repair-offer] [name=priority]', 'high');
    await P.click('[data-pp-form=repair-offer] button[type=submit]'); await wait(); await noErr();
    const r = sql(`select status||'/'||estimated_cost||'/'||priority from repairs where title='${MANGEL}'`);
    if (r !== 'reported/1200.00/high') throw new Error(r); return r;
  });
  await step('Partner: Mängel zeigt „Beim Kunden angefragt“', async () => {
    await P.evaluate(() => { pp.view = 'defects'; pp.detail = null; ppRender(); }); await P.waitForTimeout(200);
    const t = await P.textContent('#partner-portal .pp-main'); if (!t.includes('Beim Kunden angefragt') || !t.includes(MANGEL)) throw new Error(t.slice(0, 200)); return 'angefragt sichtbar';
  });
  await step('Hausbesitzer: Mangel unter Mängel & Reparaturen mit Angebot', async () => {
    await H.evaluate(() => { ownerSide.repairsAsked = false; currentPage = 'repairs'; render(); }); await H.waitForTimeout(400);
    await H.evaluate(() => ownerLoadPartners().then(() => render())); await H.waitForTimeout(500);
    const card = await H.evaluate((m) => [...document.querySelectorAll('.issue-card')].find((c) => c.textContent.includes(m))?.textContent.replace(/\s+/g, ' '), MANGEL);
    const st = await H.evaluate((m) => issues.find((i) => i.text === m)?.status, MANGEL);
    await H.evaluate((m) => [...document.querySelectorAll('.issue-card')].find((c) => c.textContent.includes(m))?.scrollIntoView(), MANGEL); await H.screenshot({ path: OUT + '/1-besitzer-angebot.png' });
    if (!card || !card.includes('bietet die Beseitigung an') || st !== 'open') throw new Error(`${st} · ${card}`); return `${st} · ${card.slice(0, 120)}`;
  });
  await step('Hausbesitzer nimmt an → In Arbeit, Auftrag beim Partner', async () => {
    const rid = sql(`select id from repairs where title='${MANGEL}'`);
    await H.click(`[data-repair-offer="${rid}"][data-accept="1"]`); await H.waitForSelector('[data-cost-confirm="ok"]'); await H.click('[data-cost-confirm="ok"]'); await H.waitForTimeout(1500);
    const st = await H.evaluate((m) => issues.find((i) => i.text === m)?.status, MANGEL);
    const order = sql(`select o.status||'/'||o.order_type||'/'||o.priority from repairs r join service_orders o on o.id=r.service_order_id where r.id='${rid}'`);
    if (st !== 'in_progress' || order !== 'accepted/repair/high') throw new Error(`${st} · ${order}`); return `Hausbesitzer: ${st} · Auftrag: ${order}`;
  });
  await step('Partner: Auftrag unter Mängel „Beauftragt – Termin festlegen“, Termin + Abschluss', async () => {
    await P.evaluate(async () => { await ppLoad(); pp.view = 'defects'; pp.detail = null; ppRender(); }); await P.waitForTimeout(300);
    const t = await P.textContent('#partner-portal .pp-main');
    await P.screenshot({ path: OUT + '/2-partner-maengel.png', fullPage: true });
    if (!t.includes('Beauftragt – Termin festlegen') || !t.includes(`Mangelbeseitigung: ${MANGEL}`)) throw new Error(t.slice(0, 300));
    const oid = sql(`select service_order_id from repairs where title='${MANGEL}'`);
    await P.evaluate((id) => { pp.view = 'orders'; pp.detail = { type: 'order', id }; ppRender(); }, oid); await P.waitForTimeout(250);
    const d = new Date(Date.now() + 2 * 86400000); const local = `${d.toISOString().slice(0, 10)}T09:00`;
    await P.fill('[data-pp-field=sched]', local); await P.click(`[data-pp-action=schedule][data-id="${oid}"]`); await wait();
    await P.evaluate((id) => { pp.detail = { type: 'order', id }; ppRender(); }, oid); await P.click(`[data-pp-action=start][data-id="${oid}"]`); await wait();
    const mid = sql(`select status from repairs where title='${MANGEL}'`);
    await P.evaluate((id) => { pp.detail = { type: 'order', id }; ppRender(); }, oid); await P.click(`[data-pp-action=complete][data-id="${oid}"]`); await wait(); await noErr();
    const end = sql(`select status from repairs where title='${MANGEL}'`);
    if (mid !== 'in_progress' || end !== 'completed') throw new Error(`${mid} → ${end}`); return `Mangel: ${mid} → ${end}`;
  });
  await step('Hausbesitzer: Mangel behoben', async () => {
    await H.evaluate(() => ownerLoadPartners().then(() => render())); await H.waitForTimeout(600);
    const st = await H.evaluate((m) => issues.find((i) => i.text === m)?.status, MANGEL); if (st !== 'fixed') throw new Error(st); return st;
  });

  console.log(res.join('\n')); if (errs.length) console.log('JS-Fehler:\n' + errs.join('\n'));
  await b.close();
})();
