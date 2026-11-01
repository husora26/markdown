const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON: ENV_ANON } = require('./env'); const OUT = SP + '/audit/open'; fs.mkdirSync(OUT, { recursive: true });
const ANON = ENV_ANON; const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Sunne Nyckelservice ${N}`, P_EMAIL = `access${N}@hs.test`, PW = 'Husora!2026';
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




  await step('Auftrag beauftragt und vom Partner angenommen', async () => {
    await H.evaluate((firm) => { const id = 'custom-a' + Date.now(); providers.push({ id, name: firm, category: 'house', custom: true, initials: 'SN', distances: {} }); persistCustomProviders();
      tasks.push({ id: Date.now(), partnerId: id, title: 'Heizung entlüften', property: properties[0].name, date: localDateKey(new Date(Date.now() + 2 * 86400000)), priority: 'normal', area: 'Technik', status: 'Offen', done: false, repeat: 'Einmalig' });
      emergencyData = { ...emergencyData, [properties[0].id]: { ...(emergencyData[properties[0].id] || {}), keyLocation: 'Schlüsselbox links neben der Tür', keyCode: '4711' } };
      try { localStorage.setItem('stugliv-tasks', JSON.stringify(tasks)); } catch (e) {} }, FIRM);
    await H.evaluate((firm) => commissionPartner(providers.find((p) => p.name === firm).id), FIRM); await H.waitForTimeout(800);
    await P.evaluate(() => ppLoad()); await P.waitForFunction(() => !pp.busy, null, { timeout: 20000 });
    await P.evaluate(() => { pp.detail = { type: 'order', id: ppD('orders').find((o) => o.title === 'Heizung entlüften').id }; ppRender(); });
    await P.click('[data-pp-action=accept]'); await P.waitForFunction(() => !pp.busy, null, { timeout: 15000 }); await P.waitForTimeout(500);
    return `Partner sieht vor Freigabe einen Zugang: ${await P.evaluate(() => !!document.querySelector('.pp-access'))}`; });
  await step('Hausbesitzer teilt Zugang (vorausgefüllt aus Notfall & Zugang)', async () => {
    await H.evaluate(() => { currentPage = 'partnerHub'; hub.tab = 'orders'; render(); }); await H.evaluate(() => hubRefresh()); await H.waitForTimeout(400);
    const oid = await H.evaluate(() => ownerSide.orders.find((o) => o.title === 'Heizung entlüften').id);
    await H.click(`[data-hub-access="${oid}"]`); await H.waitForTimeout(200);
    const pre = await H.$eval(`[data-hub-access-form="${oid}"] textarea`, (e) => e.value);
    await H.evaluate((oid) => document.querySelector(`[data-hub-access-form="${oid}"]`).scrollIntoView(), oid); await H.screenshot({ path: OUT + '/access-owner.png' });
    await H.$eval(`[data-hub-access-form="${oid}"] button[type=submit]`, (e) => e.click()); await H.waitForFunction(() => !ownerSide.busy, null, { timeout: 15000 }); await H.waitForTimeout(300);
    return `vorausgefüllt: ${pre.replace(/\n/g, ' | ')} · angezeigt: ${await H.evaluate(() => document.querySelector('.hub-access.active strong')?.textContent)}`; });
  await step('Partner sieht den Zugang im Auftrag, Abruf wird gezählt', async () => {
    await P.evaluate(() => ppLoad()); await P.waitForFunction(() => !pp.busy, null, { timeout: 20000 });
    await P.evaluate(() => { pp.detail = { type: 'order', id: ppD('orders').find((o) => o.title === 'Heizung entlüften').id }; ppRender(); }); await P.waitForTimeout(1000);
    const t = await P.evaluate(() => document.querySelector('.pp-access')?.innerText.replace(/\s+/g, ' '));
    await P.evaluate(() => document.querySelector('.pp-access')?.scrollIntoView()); await P.screenshot({ path: OUT + '/access-partner.png' });
    const views = sql(`select view_count from order_access_shares s join service_orders o on o.id=s.service_order_id where o.title='Heizung entlüften' order by s.created_at desc limit 1`);
    const table = await P.evaluate(async () => { try { return JSON.stringify(await cloudFetch('/rest/v1/order_access_shares?select=access_text')); } catch (e) { return e.message; } });
    if (!/4711/.test(t || '')) throw new Error(t); return `${t.slice(0, 110)} · Abrufe: ${views} · direkter Tabellenzugriff Partner: ${table}`; });
  await step('Zurückziehen → Partner sieht nichts mehr', async () => {
    await H.evaluate(() => hubRefresh()); await H.waitForTimeout(400); await H.click('[data-hub-access-revoke]'); await H.waitForFunction(() => !ownerSide.busy, null, { timeout: 15000 });
    await P.evaluate(() => ppLoad()); await P.waitForFunction(() => !pp.busy, null, { timeout: 20000 });
    await P.evaluate(() => { pp.detail = { type: 'order', id: ppD('orders').find((o) => o.title === 'Heizung entlüften').id }; ppRender(); }); await P.waitForTimeout(1000);
    return `Partner sieht Zugang: ${await P.evaluate(() => !!document.querySelector('.pp-access'))} · Hausbesitzer-Anzeige aktiv: ${await H.evaluate(() => !!document.querySelector('.hub-access.active'))}`; });
  console.log(res.join('\n')); console.log(errs.length ? 'JS-Fehler:\n' + [...new Set(errs)].join('\n') : 'keine JS-Fehler'); await b.close();
})();
