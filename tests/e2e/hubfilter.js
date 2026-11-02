// Hausbesitzer: Aufträge an Partner filtern, Anfrage zurückziehen, Erledigte archivieren; Kachel-Aussehen
const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON } = require('./env'); const OUT = SP + '/audit/hubfilter'; fs.mkdirSync(OUT, { recursive: true });
const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Filter Service ${N}`, P_EMAIL = `filter${N}@hs.test`, PW = 'Husora!2026', TITLE = `Hecke schneiden ${N}`;
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
  const mk = (t, st) => sql(`insert into service_orders (organization_id, property_id, service_partner_id, title, status) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', '${spId}', '${TITLE} ${t}', 'offered') returning id`).split('\n')[0];
  const A = mk('A'), B = mk('B'), C = mk('C');
  sql(`update service_orders set status='accepted' where id in ('${B}','${C}')`); sql(`update service_orders set status='in_progress' where id='${C}'`); sql(`update service_orders set status='completed' where id='${C}'`);
  const load = async () => { await H.evaluate(() => { currentPage = 'partnerHub'; hub.tab = 'orders'; hub.orderFilter = 'all'; render(); }); await H.evaluate(() => ownerLoadPartners().then(() => render())); await H.waitForTimeout(500); };
  const titles = () => H.$$eval('.hub-order > .hub-partner-head > div > strong', (e, t) => e.map((x) => x.textContent).filter((x) => x.startsWith(`${t} `)).map((x) => x.slice(t.length + 1)).sort().join(','), TITLE);
  await step('Filter: Neue Anfrage / Angenommen / Erledigt', async () => {
    await load(); const res = [];
    for (const f of ['offered', 'accepted', 'completed']) { await H.click(`[data-hub-order-filter=${f}]`); await H.waitForTimeout(150); res.push(`${f}=${await titles()}`); }
    await H.screenshot({ path: OUT + '/1-filter.png' });
    if (res.join(' ') !== 'offered=A accepted=B completed=C') throw new Error(res.join(' ')); return res.join(' ');
  });
  await step('Neue Anfrage zurückziehen', async () => {
    await H.click('[data-hub-order-filter=offered]'); await H.waitForTimeout(150);
    await H.click(`[data-hub-withdraw="${A}"]`); await H.waitForFunction(() => !ownerSide.busy, null, { timeout: 20000 }); await H.waitForTimeout(300);
    const st = sql(`select status||' · '||response_note from service_orders where id='${A}'`);
    if (!st.startsWith('cancelled')) throw new Error(st); return st;
  });
  await step('Erledigten Auftrag ins Archiv und zurück', async () => {
    await H.click('[data-hub-order-filter=completed]'); await H.waitForTimeout(150);
    await H.click(`[data-hub-archive="${C}"]`); await H.waitForTimeout(200);
    const inDone = await titles(); await H.click('[data-hub-order-filter=archive]'); await H.waitForTimeout(150); const inArch = await titles();
    if (inDone.includes('C') || !inArch.includes('C')) throw new Error(`${inDone} / ${inArch}`);
    await H.click(`[data-hub-archive="${C}"]`); await H.waitForTimeout(150);
    return `archiviert und wiederhergestellt`;
  });
  await step('Kachel-Aussehen: Farbe auf beiden Seiten', async () => {
    await H.evaluate(() => { currentPage = 'settings'; settingsView = 'settings-home'; render(); }); await H.click('[data-owner-tile-look=color]'); await H.click('[data-owner-tile-swatch="#7048e8"]');
    const owner = await H.evaluate(() => [document.documentElement.classList.contains('owner-tiles-color'), displaySettings.tileColor].join('/'));
    await P.evaluate(() => { pp.view = 'settings'; ppRender(); }); await P.click('[data-pp-tile-look=rainbow]');
    const partner = await P.evaluate(() => document.getElementById('partner-portal').className);
    if (owner !== 'true/#7048e8' || !partner.includes('pp-tiles-rainbow')) throw new Error(`${owner} / ${partner}`); return `${owner} · ${partner}`;
  });

  console.log(res.join('\n')); if (errs.length) console.log('JS-Fehler:\n' + errs.join('\n'));
  await b.close();
})();
