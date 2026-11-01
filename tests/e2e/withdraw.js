const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON: ENV_ANON } = require('./env'); const OUT = SP + '/audit/withdraw'; fs.mkdirSync(OUT, { recursive: true });
const ANON = ENV_ANON; const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Torsby Hemservice ${N}`, P_EMAIL = `wd${N}@hs.test`, PW = 'Husora!2026';
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
    const card = await H.$$('.hub-partner'); for (const c of card) { if ((await c.textContent().catch(() => '')).includes(FIRM)) { await c.screenshot({ path: OUT + '/2-code.png' }).catch(() => {}); } }
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




  const orderOf = (title) => sql(`select o.status from service_orders o join service_partners sp on sp.id=o.service_partner_id where sp.company_name='${FIRM}' and o.title='${title}' order by o.created_at desc limit 1`);
  await step('Drei Aufgaben beauftragen, eine davon nimmt der Partner an', async () => {
    await H.evaluate((firm) => {
      const id = 'custom-w' + Date.now(); providers.push({ id, name: firm, category: 'house', custom: true, initials: 'TH', distances: {} }); persistCustomProviders();
      const d = (n) => localDateKey(new Date(Date.now() + n * 86400000));
      ['Dachfenster prüfen', 'Rasen vertikutieren', 'Brennholz stapeln'].forEach((title, n) => tasks.push({ id: Date.now() + n, partnerId: id, title, property: properties[0].name, date: d(3 + n), priority: 'normal', area: 'Außen', status: 'Offen', done: false, repeat: 'Einmalig' }));
      try { localStorage.setItem('stugliv-tasks', JSON.stringify(tasks)); } catch (e) {}
    }, FIRM);
    await H.evaluate((firm) => commissionPartner(providers.find((p) => p.name === firm).id), FIRM); await H.waitForTimeout(800);
    await P.evaluate(() => ppLoad()); await P.waitForFunction(() => !pp.busy, null, { timeout: 20000 });
    await P.evaluate(() => { pp.detail = { type: 'order', id: ppD('orders').find((o) => o.title === 'Brennholz stapeln').id }; ppRender(); });
    await P.click('[data-pp-action=accept]'); await P.waitForFunction(() => !pp.busy, null, { timeout: 15000 });
    return ['Dachfenster prüfen', 'Rasen vertikutieren', 'Brennholz stapeln'].map((t) => `${t}: ${orderOf(t)}`).join(' · ');
  });
  await step('Eigenleistung + abgehakt + (angenommene) neu vergeben → nur offene Anfragen zurückgezogen', async () => {
    await H.evaluate(() => { const by = (t) => tasks.find((x) => x.title === t); by('Dachfenster prüfen').selfService = true; setTaskStatus(by('Rasen vertikutieren'), 'Erledigt'); const other = providers.find((p) => !p.custom); by('Brennholz stapeln').partnerId = other.id; persistTasks(); });
    await H.evaluate(() => cloudUpload({ full: false, keys: new Set(['stugliv-tasks']) })); await H.waitForTimeout(600); await H.waitForFunction(() => !ownerSide.dispatching, null, { timeout: 15000 }); await H.evaluate(() => ownerDispatchOrders()); await H.waitForTimeout(500);
    const r = ['Dachfenster prüfen', 'Rasen vertikutieren', 'Brennholz stapeln'].map((t) => `${t}: ${orderOf(t)}`).join(' · ');
    const msg = sql(`select count(*) from messages m join service_orders o on o.id=m.service_order_id join service_partners sp on sp.id=o.service_partner_id where sp.company_name='${FIRM}' and m.message like 'Anfrage%zurückgezogen%'`);
    const note = sql(`select response_note from service_orders o join service_partners sp on sp.id=o.service_partner_id where sp.company_name='${FIRM}' and o.title='Dachfenster prüfen'`);
    if (!/Dachfenster prüfen: cancelled/.test(r) || !/Brennholz stapeln: accepted/.test(r)) throw new Error(r); return `${r} · Nachrichten an Partner: ${msg} · Notiz: ${note}`;
  });
  await step('Partner sieht die zurückgezogene Anfrage nicht mehr als offen', async () => {
    await P.evaluate(() => ppLoad()); await P.waitForFunction(() => !pp.busy, null, { timeout: 20000 });
    return await P.evaluate(() => ppOpenOrders().map((o) => `${o.title} (${o.status})`).join(', '));
  });
  console.log(res.join('\n')); console.log(errs.length ? 'JS-Fehler:\n' + [...new Set(errs)].join('\n') : 'keine JS-Fehler'); await b.close();
})();
