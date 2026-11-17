const { chromium } = require('playwright'); const fs = require('fs');
const { SP, ANON: ENV_ANON } = require('./env'); const OUT = SP + '/audit/plans'; fs.mkdirSync(OUT, { recursive: true });
const ANON = ENV_ANON; const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
(async () => { const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (n, f) => { try { res.push(`OK   ${n} – ${await f()}`); } catch (e) { res.push(`FEHL ${n} – ${e.message.split('\n')[0].slice(0, 220)}`); } };
  const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true }); const p = await ctx.newPage();
  p.on('pageerror', (e) => errs.push(e.message)); p.on('dialog', (d) => d.accept());
  await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr|tile/, (r) => r.abort());
  await p.goto('http://127.0.0.1:8081/index.html?test=0');
  await p.evaluate(({ url, key }) => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); localStorage.setItem('husora-cloud', JSON.stringify({ url, key })); }, { url: URL_, key: ANON });
  await p.reload(); await p.waitForTimeout(800);
  await step('Tarife aus der Datenbank (Preise nicht im Code)', async () => { await p.evaluate(() => { planOverride = null; currentPage = 'plans'; render(); }); await p.waitForTimeout(300);
    const r = await p.$$eval('.plan-card', (e) => e.map((c) => `${c.querySelector('h2').textContent} ${c.querySelector('.plan-price strong').textContent}`).join(' | '));
    await p.screenshot({ path: OUT + '/1-tarife.png' }); if (!/PLUS 7,90 €/.test(r)) throw new Error(r); return r; });
  await step('Vergleichstabelle mit Häkchen', async () => {
    const r = await p.evaluate(() => { const t = document.querySelector('.pm-table'); const rows = [...t.querySelectorAll('tbody tr:not(.pm-group)')]; const portal = rows.find((x) => x.textContent.includes('Servicepartner-Portal')); return `${rows.length} Zeilen · Portal: ${[...portal.querySelectorAll('td')].map((td) => (td.querySelector('.pm-yes') ? '✓' : '–')).join(' ')} · Häuser: ${[...rows[0].querySelectorAll('td')].map((td) => td.textContent).join('/')}`; });
    await p.evaluate(() => document.querySelector('.plan-matrix').scrollIntoView()); await p.screenshot({ path: OUT + '/2-vergleich.png' });
    if (!/Portal: – – ✓ ✓/.test(r)) throw new Error(r); return r; });
  await step('FREE: gesperrte Bereiche erklären sich bei Direktaufruf, im Menü/Kacheln/Reitern ausgeblendet', async () => {
    const r = []; for (const page of ['renovations', 'automation', 'house3d', 'partnerHub', 'contracts']) { await p.evaluate((page) => { currentPage = page; render(); }, page); await p.waitForTimeout(150); r.push(`${page}:${await p.evaluate(() => !!document.querySelector('.plan-locked'))}`); }
    await p.evaluate(() => { currentPage = 'renovations'; render(); }); await p.screenshot({ path: OUT + '/3-gesperrt.png' });
    await p.evaluate(() => { currentPage = 'repairs'; render(); }); await p.waitForTimeout(150);
    if (await p.evaluate(() => !!document.querySelector('.plan-locked'))) throw new Error('Reparatur & Instandhaltung ist in FREE gesperrt');
    if (r.some((x) => x.endsWith('false'))) throw new Error(r.join(' '));
    const hidden = await p.evaluate(() => { currentPage = 'dashboard'; render(); const navShown = (page) => { const el = document.querySelector(`.nav [data-page="${page}"]`); return el && getComputedStyle(el).display !== 'none'; };
      const locked = ['renovations', 'automation', 'house3d', 'partnerHub', 'contracts'];
      const tiles = [...document.querySelectorAll('#page-content .stat[data-page]')].map((el) => el.dataset.page);
      currentPage = 'repairs'; render(); const tabs = [...document.querySelectorAll('.section-tabs [data-page]')].map((el) => el.dataset.page);
      return { nav: locked.filter(navShown), tiles: tiles.filter((t) => locked.includes(t)), tabs: tabs.filter((t) => locked.includes(t)), repairsNav: navShown('repairs'), tags: document.querySelectorAll('.plan-tag, .section-tab-plan').length }; });
    if (hidden.nav.length || hidden.tiles.length || hidden.tabs.length || !hidden.repairsNav || hidden.tags) throw new Error(JSON.stringify(hidden));
    return `${r.join(' ')} · ausgeblendet in Menü, Kacheln und Reitern`; });
  await step('FREE: 6. aktive Aufgabe wird blockiert', async () => {
    await p.evaluate(() => { const prop = properties[0].name; tasks = tasks.filter((t) => t.done); for (let n = 0; n < 5; n++) tasks.push({ id: Date.now() + n, title: 'T' + n, property: prop, date: localDateKey(new Date()), priority: 'normal', status: 'Offen', done: false, repeat: 'Einmalig' }); persistTasks(); currentPage = 'tasks'; render(); openTaskModal(); });
    await p.waitForTimeout(200); await p.fill('#task-form [name=title]', 'Sechste Aufgabe'); await p.$eval('#task-form button[type=submit]', (e) => e.click()); await p.waitForTimeout(200);
    return `${await p.evaluate(() => tasks.some((t) => t.title === 'Sechste Aufgabe') ? 'angelegt (falsch)' : 'blockiert')} · ${await p.evaluate(() => document.getElementById('toast').textContent.slice(0, 100))}`; });
  await step('Testschalter PRO → Bereiche frei, Aufgabe möglich', async () => {
    await p.evaluate(() => { planOverride = 'pro'; currentPage = 'repairs'; render(); }); await p.waitForTimeout(200);
    const free = await p.evaluate(() => !document.querySelector('.plan-locked'));
    await p.evaluate(() => { currentPage = 'tasks'; render(); openTaskModal(); }); await p.waitForTimeout(150); await p.fill('#task-form [name=title]', 'Sechste Aufgabe'); await p.$eval('#task-form button[type=submit]', (e) => e.click()); await p.waitForTimeout(200);
    return `Reparaturen frei: ${free} · Aufgabe: ${await p.evaluate(() => tasks.some((t) => t.title === 'Sechste Aufgabe'))}`; });
  await step('Angemeldet: Tarif kommt vom Server (Testorganisation = ULTIMATE)', async () => {
    await p.evaluate(() => { planOverride = null; currentPage = 'settings'; settingsView = 'settings-data'; render(); });
    await p.fill('[data-cloud-form=signin] [name=email]', 'admin@husora.test'); await p.fill('[data-cloud-form=signin] [name=password]', 'Husora!2026');
    await p.$eval('[data-cloud-form=signin] button[type=submit]', (e) => e.click()); await p.waitForFunction(() => cloudReady() && !cloudState.busy, null, { timeout: 20000 }); await p.waitForTimeout(1500);
    return await p.evaluate(() => `${currentPlanId()} · Status ${orgPlan?.status} · Kopfzeile: ${document.getElementById('plan-info').textContent.trim()}`); });
  await step('Server-Sperre: FREE-Organisation darf kein Partner-Portal nutzen', async () => {
    const email = `free${N}@husora.test`;
    const r = await p.evaluate(async ({ url, key, email }) => {
      const signup = await (await fetch(`${url}/auth/v1/signup`, { method: 'POST', headers: { apikey: key, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: 'Husora!2026' }) })).json();
      const token = signup.access_token; const h = { apikey: key, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
      const org = await (await fetch(`${url}/rest/v1/rpc/ensure_my_organization`, { method: 'POST', headers: h, body: JSON.stringify({ p_name: 'Freie Häuser' }) })).json();
      const orgId = (Array.isArray(org) ? org[0] : org).organization_id;
      const plan = await (await fetch(`${url}/rest/v1/rpc/my_plan`, { method: 'POST', headers: h, body: JSON.stringify({ p_organization_id: orgId }) })).json();
      const sp = await (await fetch(`${url}/rest/v1/service_partners`, { method: 'POST', headers: { ...h, Prefer: 'return=representation' }, body: JSON.stringify({ organization_id: orgId, company_name: 'Test' }) })).json();
      const inv = await fetch(`${url}/rest/v1/rpc/create_service_partner_invite`, { method: 'POST', headers: h, body: JSON.stringify({ p_service_partner_id: sp[0].id }) });
      const sub = await fetch(`${url}/rest/v1/subscriptions`, { method: 'POST', headers: h, body: JSON.stringify({ organization_id: orgId, plan_id: 'ultimate' }) });
      return `Tarif ${plan.plan_id} · Einladung: HTTP ${inv.status} ${(await inv.json()).message} · eigenes Abo eintragen: HTTP ${sub.status}`;
    }, { url: URL_, key: ANON, email });
    if (!/HTTP 4\d\d .*PRO.*HTTP 4\d\d/.test(r)) throw new Error(r); return r; });
  console.log(res.join('\n')); console.log(errs.length ? 'JS-Fehler:\n' + [...new Set(errs)].join('\n') : 'keine JS-Fehler'); await b.close(); })();
