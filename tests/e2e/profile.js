// Phase 4: Leistungsprofil, Servicegebiete, Preisart, Abwesenheiten, automatische Annahme
const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON } = require('./env'); const OUT = SP + '/audit/profile'; fs.mkdirSync(OUT, { recursive: true });
const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Profil Service ${N}`, P_EMAIL = `profil${N}@hs.test`, PW = 'Husora!2026', TITLE = `Rasen mähen ${N}`;
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
  const view = async (v) => { await P.evaluate((v) => { pp.view = v; pp.detail = null; pp.form = null; ppRender(); }, v); await P.waitForTimeout(250); };
  await step('Firma: Leistungsprofil speichern (Notdienst, Auto-Annahme, Preise)', async () => {
    await view('company');
    await P.check('[data-pp-form=company-edit] [name=emergency_service]'); await P.check('[data-pp-form=company-edit] [name=auto_accept_orders]');
    await P.fill('[data-pp-form=company-edit] [name=hourly_rate]', '650'); await P.fill('[data-pp-form=company-edit] [name=travel_fee]', '150'); await P.fill('[data-pp-form=company-edit] [name=minimum_order_value]', '300');
    await P.click('[data-pp-form=company-edit] button[type=submit]'); await wait(); await noErr();
    const r = sql(`select concat_ws('|', emergency_service, auto_accept_orders, hourly_rate, travel_fee, minimum_order_value) from organizations where id='${porg}'`);
    if (r !== 't|t|650.00|150.00|300.00') throw new Error(r); return r;
  });
  await step('Firma: zweites Servicegebiet mit PLZ-Bereich, pausieren', async () => {
    await view('company');
    await P.fill('[data-pp-form=area-new] [name=name]', 'Värmland Nord'); await P.fill('[data-pp-form=area-new] [name=postal_code_prefix]', '686'); await P.fill('[data-pp-form=area-new] [name=radius_km]', '40');
    await P.click('[data-pp-form=area-new] button[type=submit]'); await wait(); await noErr();
    const id = sql(`select a.id from service_partner_areas a join service_partners sp on sp.id=a.service_partner_id where sp.organization_id='${porg}' and a.name='Värmland Nord'`);
    await view('company'); await P.click(`[data-pp-area=toggle][data-id="${id}"]`); await wait();
    await P.$eval('.pp-areas', (e) => e.scrollIntoView()); await P.screenshot({ path: OUT + '/1-gebiete.png' });
    const r = sql(`select postal_code_prefix||'/'||radius_km||'/'||active from service_partner_areas where id='${id}'`);
    if (r !== '686/40.00/false') throw new Error(r); return r;
  });
  await step('Leistungen: Paket mit „Preis auf Anfrage“', async () => {
    await view('services');
    await P.click('[data-pp-svc=new]'); await P.selectOption('[data-pp-form=svc-new] [name=group]', 'service_work');
    await P.fill('[data-pp-form=svc-new] [name=name]', `Notdienst Heizung ${N}`); await P.selectOption('[data-pp-form=svc-new] [name=price_type]', 'quote');
    await P.click('[data-pp-form=svc-new] button[type=submit]'); await wait(); await noErr();
    const r = sql(`select price_type||'/'||coalesce(price_from::text,'-') from service_partner_services s join service_partners sp on sp.id=s.service_partner_id where sp.organization_id='${porg}' and (s.label = 'Notdienst Heizung ${N}' or s.service_type_id in (select id from service_types where name='Notdienst Heizung ${N}'))`);
    const shown = await P.evaluate((n) => [...document.querySelectorAll('.pp-package')].find((e) => e.textContent.includes(`Notdienst Heizung ${n}`))?.querySelector('.pp-package-price')?.textContent, N);
    if (r !== 'quote/-' || shown !== 'Preis auf Anfrage') throw new Error(`${r} · ${shown}`); return `${r} · ${shown}`;
  });
  await step('Team: Betriebsferien eintragen, im Kalender sichtbar', async () => {
    await view('team');
    const from = new Date(Date.now() + 2 * 86400000).toISOString().slice(0, 10); const to = new Date(Date.now() + 4 * 86400000).toISOString().slice(0, 10);
    await P.fill('[data-pp-form=absence-new] [name=from]', from); await P.fill('[data-pp-form=absence-new] [name=to]', to); await P.fill('[data-pp-form=absence-new] [name=reason]', 'Betriebsferien');
    await P.click('[data-pp-form=absence-new] button[type=submit]'); await wait(); await noErr();
    const n = sql(`select count(*) from service_partner_absences where organization_id='${porg}' and user_id is null and reason='Betriebsferien'`);
    await P.evaluate((d) => { pp.view = 'calendar'; pp.calMonth = d.slice(0, 7); pp.calDay = d; ppRender(); }, from); await P.waitForTimeout(300);
    const away = await P.$$eval('.pp-cal-dots i.away', (e) => e.length); const txt = await P.textContent('#partner-portal .pp-main');
    await P.screenshot({ path: OUT + '/2-kalender.png', fullPage: true });
    if (n !== '1' || away < 1 || !txt.includes('Ganzer Betrieb abwesend')) throw new Error(`${n} · ${away}`); return `${away} Tage markiert`;
  });
  await step('Automatische Annahme: neue Anfrage wird angenommen', async () => {
    const id = sql(`insert into service_orders (organization_id, property_id, service_partner_id, title, status, estimated_cost) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', '${spId}', '${TITLE}', 'offered', 500) returning id`).split('\n')[0];
    const r = sql(`select status||' · '||response_note from service_orders where id='${id}'`);
    if (r !== 'accepted · Automatisch angenommen') throw new Error(r); return r;
  });

  console.log(res.join('\n')); if (errs.length) console.log('JS-Fehler:\n' + errs.join('\n'));
  await b.close();
})();
