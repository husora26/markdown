const { chromium } = require('playwright');
const { SP, ANON } = require('./env'); const OUT = SP + '/audit/open';
const URL_ = 'http://127.0.0.1:54321'; const PW = 'Husora!2026';
(async () => { const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (n, f) => { try { res.push(`OK   ${n} – ${await f()}`); } catch (e) { res.push(`FEHL ${n} – ${e.message.split('\n')[0].slice(0, 240)}`); } };
  const ctx = await b.newContext({ viewport: { width: 1280, height: 900 } }); const p = await ctx.newPage(); p.on('pageerror', (e) => errs.push(e.message)); p.on('dialog', (d) => d.accept());
  await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|google|jsdelivr|tile|supabase\.co/, (r) => r.abort());
  await p.goto('http://127.0.0.1:8081/index.html');
  await p.evaluate(({ url, key }) => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); localStorage.setItem('husora-cloud', JSON.stringify({ url, key })); }, { url: URL_, key: ANON });
  await p.reload(); await p.waitForTimeout(800);
  const open = async () => { await p.evaluate(() => { document.querySelectorAll('.open').forEach((e) => e.classList.remove('open')); currentPage = 'portfolio'; render(); }); await p.waitForTimeout(300); };
  await step('FREE: Portfolio gesperrt mit Hinweis auf ULTIMATE', async () => { await open(); const t = await p.textContent('#page-content'); if (!/ab ULTIMATE verfügbar/.test(t)) throw new Error('kein Sperrhinweis'); return 'gesperrt'; });
  await step('ULTIMATE (Testmodus): Score, Prognose, Eskalationen, Budget', async () => {
    await p.evaluate(() => { localStorage.setItem('stugliv-dev', '1'); localStorage.setItem('stugliv-test-plan', 'ultimate'); }); await p.reload(); await p.waitForTimeout(800); await open();
    const score = await p.$eval('.pf-score', (e) => Number(e.textContent));
    if (!(score >= 0 && score <= 100)) throw new Error('Score fehlt');
    const kpis = await p.$$eval('.pf-kpi > span', (e) => e.map((x) => x.textContent));
    for (const k of ['Ø Zustands-Score', 'Prognose Jahresende', 'Eskalationen']) if (!kpis.some((x) => x.includes(k))) throw new Error(`KPI fehlt: ${k}`);
    const esc = await p.$$eval('.pf-esc li', (e) => e.length);
    const bell = await p.evaluate(() => collectReminders().filter((r) => /^Eskalation/.test(r.title)).length);
    await p.screenshot({ path: OUT + '/portfolio.png', fullPage: true });
    return `Score ${score} · KPIs ${kpis.length} · Eskalationen ${esc} · Glocke ${bell} · Budget-Karte ${await p.$$eval('.pf-card .card-title', (e) => e.some((x) => /Budgetwarnungen/.test(x.textContent)))}`; });
  await step('Budgetwarnung bei Ausgabe über Plan', async () => {
    const r = await p.evaluate(() => { const pr = properties[0]; const rows = costFigures(pr, costsOf(pr.id)).rows; const row = rows.find((x) => x.plan > 0); expenses.push({ id: 'e2e-over', propertyId: pr.id, category: row.category.id, amount: row.plan + 500, date: localDateKey(new Date()), title: 'Test' }); const f = costForecast(pr); expenses.pop(); return { label: row.category.label, alerts: f.alerts.filter((a) => a.over).map((a) => a.label) }; });
    if (!r.alerts.includes(r.label)) throw new Error(JSON.stringify(r)); return `${r.label} über Plan erkannt`; });
  await step('Aktivitätsprotokoll (Admin, Cloud)', async () => {
    await p.evaluate(() => { currentPage = 'settings'; settingsView = 'settings-data'; render(); });
    await p.fill('[data-cloud-form=signin] [name=email]', 'admin@husora.test'); await p.fill('[data-cloud-form=signin] [name=password]', PW);
    await p.$eval('[data-cloud-form=signin] button[type=submit]', (e) => e.click()); await p.waitForFunction(() => cloudReady() && !cloudState.busy, null, { timeout: 20000 });
    await open(); await p.waitForFunction(() => activity.rows !== null && !activity.loading, null, { timeout: 15000 }); await p.waitForTimeout(300);
    const n = await p.$$eval('.activity-list li', (e) => e.length);
    if (!n) throw new Error('keine Einträge: ' + (await p.textContent('[data-activity-slot]')).slice(0, 160));
    return `${n} Einträge · erster: ${(await p.textContent('.activity-list li')).slice(0, 90)}`; });
  console.log(res.join('\n')); console.log(errs.length ? 'JS-Fehler:\n' + [...new Set(errs)].join('\n') : 'keine JS-Fehler'); await b.close(); })();
