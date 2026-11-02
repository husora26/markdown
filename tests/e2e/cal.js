// Phase 5: Kennzahlen auf der Partner-Startseite, Kalender mit Tag/Woche/Monat und Filtern
const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON } = require('./env'); const OUT = SP + '/audit/cal'; fs.mkdirSync(OUT, { recursive: true });
const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Kalender Service ${N}`, P_EMAIL = `kal${N}@hs.test`, PW = 'Husora!2026', TITLE = `Einsatz ${N}`;
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
  await step('Startseite: Kennzahlen heute / überfällig / wartet / Umsatz', async () => {
    await P.evaluate(async () => { await ppLoad(); pp.view = 'dashboard'; pp.detail = null; ppRender(); }); await P.waitForTimeout(300);
    const k = await P.$$eval('.pp-kpi', (e) => e.map((x) => x.textContent.replace(/\s+/g, ' ').trim()));
    await P.screenshot({ path: OUT + '/1-kpis.png' });
    const t = k.join(' | ');
    if (!/^1\s?Heute/.test(k[0]) || !/^1\s?Überfällig/.test(k[1]) || !/^1\s?Wartet/.test(k[2]) || !/1[\s.]?000/.test(k[4] || '')) throw new Error(t); return t;
  });
  await step('Kennzahl „Wartet“ öffnet die Aufträge mit Filter', async () => {
    await P.click('[data-pp-kpi=waiting]'); await P.waitForTimeout(200);
    const r = await P.evaluate(() => `${pp.view}/${pp.filter}`); if (r !== 'orders/waiting') throw new Error(r); return r;
  });
  await step('Kalender: Wochenansicht mit 7 Tagen, Tagesansicht', async () => {
    await P.evaluate(() => { pp.view = 'calendar'; pp.calMode = 'month'; pp.calDay = ppToday(); ppRender(); }); await P.waitForTimeout(200);
    await P.click('[data-pp-cal-mode=week]'); await P.waitForTimeout(200);
    const days = await P.$$eval('.pp-cal-dayblock', (e) => e.length);
    await P.screenshot({ path: OUT + '/2-woche.png', fullPage: true });
    await P.click('[data-pp-cal-mode=day]'); await P.waitForTimeout(200);
    const dayText = await P.textContent('#partner-portal .pp-main');
    await P.click('[data-pp-cal-nav="1"]'); await P.waitForTimeout(150); const next = await P.evaluate(() => pp.calDay);
    if (days !== 7 || !dayText.includes(`${TITLE} heute`)) throw new Error(`${days} · ${dayText.slice(0, 120)}`); return `7 Tage · heute sichtbar · weiter → ${next}`;
  });
  await step('Kalender-Filter: Mitarbeiter und Auftragsart', async () => {
    await P.evaluate(() => { pp.calMode = 'week'; pp.calDay = ppToday(); ppRender(); }); await P.waitForTimeout(150);
    await P.selectOption('[data-pp-cal-filter=member]', techId); await P.waitForTimeout(200);
    const onlyTech = await P.$$eval('.pp-cal-dayblock .pp-item strong', (e, t) => e.map((x) => x.textContent).filter((x) => x.startsWith(t)), TITLE);
    await P.selectOption('[data-pp-cal-filter=member]', ''); await P.selectOption('[data-pp-cal-filter=type]', 'repair'); await P.waitForTimeout(200);
    const onlyRepair = await P.$$eval('.pp-cal-dayblock .pp-item strong', (e, t) => e.map((x) => x.textContent).filter((x) => x.startsWith(t)), TITLE);
    await P.selectOption('[data-pp-cal-filter=type]', '');
    if (onlyTech.join() !== `${TITLE} heute` || onlyRepair.join() !== `${TITLE} wartet`) throw new Error(`${onlyTech} / ${onlyRepair}`);
    return `Mitarbeiter: ${onlyTech} · Reparatur: ${onlyRepair}`;
  });

  console.log(res.join('\n')); if (errs.length) console.log('JS-Fehler:\n' + errs.join('\n'));
  await b.close();
})();
