const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON: ENV_ANON } = require('./env'); const OUT = SP + '/audit/dispatch'; fs.mkdirSync(OUT, { recursive: true });
const ANON = ENV_ANON; const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Husora Service ${N}`, P_EMAIL = `service${N}@hs.test`, PW = 'Husora!2026';
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
  await step('Hausbesitzer: Menüpunkt „Partner-Portal“ öffnet Anmeldung', async () => {
    await H.evaluate(() => document.querySelector('.nav [data-page="partnerHub"]').click()); await H.waitForTimeout(300);
    const t = await H.evaluate(() => [currentPage, document.querySelector('#page-content h1')?.textContent, !!document.querySelector('[data-cloud-form=signin]')].join(' · '));
    await H.screenshot({ path: OUT + '/1-anmelden.png' }); return t;
  });
  await step('Hausbesitzer: anmelden direkt im Partner-Portal', async () => {
    await H.fill('[data-cloud-form=signin] [name=email]', 'admin@husora.test'); await H.fill('[data-cloud-form=signin] [name=password]', PW);
    await H.$eval('[data-cloud-form=signin] button[type=submit]', (e) => e.click());
    await H.waitForFunction(() => cloudReady() && !cloudState.busy && ownerSide.partners !== null && !ownerSide.busy, null, { timeout: 20000 });
    return `${await H.evaluate(() => document.querySelectorAll('.hub-tabs button').length)} Reiter · ${await H.evaluate(() => ownerSide.partners.length)} Partner`;
  });
  let CODE = '';
  await step('Hausbesitzer: Einladungscode erzeugen (Kopieren/Teilen/E-Mail/SMS)', async () => {
    await H.fill('[data-owner-form=partner] [name=company_name]', FIRM); await H.fill('[data-owner-form=partner] [name=email]', P_EMAIL);
    await H.$eval('[data-owner-form=partner] button[type=submit]', (e) => e.click()); await H.waitForFunction(() => !ownerSide.busy, null, { timeout: 20000 }); await H.waitForTimeout(300);
    CODE = await H.evaluate(() => ownerSide.code?.code || ownerSide.error);
    const box = await H.evaluate(() => [...document.querySelectorAll('.hub-code-actions > *')].map((e) => e.textContent.trim()).join('/'));
    if (!/^HUS-/.test(CODE)) throw new Error(CODE);
    const card = await H.$$('.hub-partner'); for (const c of card) { if ((await c.textContent()).includes(FIRM)) { await c.screenshot({ path: OUT + '/2-code.png' }); } }
    await H.screenshot({ path: OUT + '/2-partner-tab.png' });
    return `${CODE} · ${box} · Status: ${await H.evaluate((f) => [...document.querySelectorAll('.hub-partner')].find((c) => c.textContent.includes(f))?.querySelector('.pp-badge')?.textContent, FIRM)}`;
  });
  // Partner richtet Betrieb ein und verbindet sich
  const P = await device('P');
  await step('Partner: Betrieb anlegen und Code eingeben', async () => {
    await P.evaluate(() => ppOpen('dashboard')); await P.waitForTimeout(200);
    await P.fill('[data-pp-form=login] [name=email]', P_EMAIL); await P.fill('[data-pp-form=login] [name=password]', PW);
    await P.$eval('[data-pp-action=signup]', (e) => e.click()); await P.waitForFunction(() => !pp.busy && document.querySelector('[data-pp-form=company]'), null, { timeout: 20000 });
    await P.fill('[data-pp-form=company] [name=name]', FIRM); await P.$eval('[data-pp-form=company] button[type=submit]', (e) => e.click()); await P.waitForFunction(() => !pp.busy && ppOrg(), null, { timeout: 20000 });
    await P.evaluate(() => { pp.view = 'customers'; ppRender(); });
    await P.fill('[data-pp-form=invite-code] [name=code]', CODE); await P.$eval('[data-pp-form=invite-code] button[type=submit]', (e) => e.click()); await P.waitForFunction(() => !pp.busy, null, { timeout: 20000 });
    return await P.evaluate(() => pp.ctx.links.map((l) => l.organization_name).join(', '));
  });

  await step('Hausbesitzer: eigener Partner mit gleichem Namen + 2 Aufgaben zugeordnet (wie bei dir)', async () => {
    await H.evaluate((firm) => {
      currentPage = 'dashboard'; render();
      const id = 'custom-test' + Date.now(); providers.push({ id, name: firm, category: 'house', custom: true, initials: 'HS', distances: {} }); persistCustomProviders();
      const prop = properties[0];
      tasks.push({ id: Date.now(), partnerId: id, title: 'Rasen mähen', property: prop.name, date: '2026-11-05', priority: 'normal', area: 'Außen', status: 'Offen', done: false, repeat: 'Einmalig' });
      tasks.push({ id: Date.now() + 1, partnerId: id, title: 'Heizung prüfen', property: prop.name, date: '2026-11-06', priority: 'soon', area: 'Technik', status: 'Offen', done: false, repeat: 'Einmalig' });
      tasks.push({ id: Date.now() + 2, partnerId: id, title: 'Schon erledigt', property: prop.name, date: '2026-10-01', priority: 'low', status: 'Erledigt', done: true, repeat: 'Einmalig' });
      persistTasks();
    }, FIRM);
    return 'angelegt';
  });
  await step('Sync → Aufträge automatisch an den verbundenen Partner gesendet', async () => {
    await H.evaluate(() => cloudUpload()); await H.waitForTimeout(500);
    await H.waitForFunction(() => !ownerSide.dispatching, null, { timeout: 15000 }); await H.evaluate(() => ownerDispatchOrders()); await H.waitForTimeout(500);
    const r = sql(`select string_agg(o.title||' ('||o.status||')', ', ' order by o.title) from service_orders o join service_partners sp on sp.id=o.service_partner_id where sp.company_name='${FIRM}'`);
    const toast = await H.evaluate(() => document.querySelector('.toast, #toast')?.textContent || '');
    if (!/Heizung.*Rasen/.test(r) || /erledigt/i.test(r)) throw new Error(r); return `${r} · Hinweis: ${toast.trim().slice(0, 90)}`;
  });
  await step('Kein doppelter Versand beim nächsten Abgleich', async () => {
    await H.evaluate(() => ownerDispatchOrders()); await H.evaluate(() => msgPoll()); await H.waitForTimeout(500);
    return sql(`select count(*) from service_orders o join service_partners sp on sp.id=o.service_partner_id where sp.company_name='${FIRM}'`) + ' Aufträge';
  });
  await step('Servicepartner sieht die Aufträge im Partner-Portal', async () => {
    await P.evaluate(() => { pp.view = 'orders'; pp.detail = null; }); await P.evaluate(() => ppLoad()); await P.waitForFunction(() => !pp.busy, null, { timeout: 15000 }); await P.waitForTimeout(300);
    await P.screenshot({ path: OUT + '/partner-auftraege.png' });
    const titles = await P.evaluate(() => ppD('orders').map((o) => `${o.title} [${o.status}]`).join(', '));
    if (!/Rasen/.test(titles)) throw new Error(titles || 'keine'); return titles;
  });
  await step('Neue Zuordnung in der App wird nach dem Sync ebenfalls gesendet', async () => {
    await H.evaluate(() => { const t = tasks.find((x) => !x.partnerId && !x.done) || tasks.find((x) => !x.done && x.title !== 'Rasen mähen' && x.title !== 'Heizung prüfen'); const own = providers.find((p) => p.custom && p.name.startsWith('Husora Service')); t.partnerId = own.id; t.title = 'Neu zugeordnet'; persistTasks(); });
    await H.evaluate(() => cloudUpload()); await H.waitForTimeout(1500); await H.waitForFunction(() => !ownerSide.dispatching, null, { timeout: 15000 });
    return sql(`select string_agg(o.title, ', ' order by o.title) from service_orders o join service_partners sp on sp.id=o.service_partner_id where sp.company_name='${FIRM}'`);
  });
  console.log(res.join('\n')); console.log(errs.length ? 'JS-Fehler:\n' + [...new Set(errs)].join('\n') : 'keine JS-Fehler'); await b.close();
})();
