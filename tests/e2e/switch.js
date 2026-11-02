const { chromium } = require('playwright');
const { SP, ANON } = require('./env'); const OUT = SP + '/audit/switch'; require('fs').mkdirSync(OUT, { recursive: true });
const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000; const PW = 'Husora!2026';
const { execSync } = require('child_process');
const sql = (q) => execSync(`psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -At -c "${q.replace(/"/g, '\\"')}"`).toString().trim();
(async () => { const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (n, f) => { try { res.push(`OK   ${n} – ${await f()}`); } catch (e) { res.push(`FEHL ${n} – ${e.message.split('\n')[0].slice(0, 240)}`); } };
  const ctx = await b.newContext({ viewport: { width: 390, height: 844 } }); const p = await ctx.newPage(); p.on('pageerror', (e) => errs.push(e.message)); p.on('dialog', (d) => d.accept());
  await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|google|jsdelivr|tile|supabase\.co/, (r) => r.abort());
  await p.goto('http://127.0.0.1:8081/index.html');
  await p.evaluate(({ url, key }) => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); localStorage.setItem('husora-cloud', JSON.stringify({ url, key })); }, { url: URL_, key: ANON });
  await p.reload(); await p.waitForTimeout(500);
  const B = `wechsel${N}@hs.test`;
  let orgA = '';
  await step('Konto A (Hausbesitzer) angemeldet', async () => {
    await p.evaluate(() => { currentPage = 'settings'; settingsView = 'settings-data'; render(); });
    await p.fill('[data-cloud-form=signin] [name=email]', 'admin@husora.test'); await p.fill('[data-cloud-form=signin] [name=password]', PW);
    await p.$eval('[data-cloud-form=signin] button[type=submit]', (e) => e.click()); await p.waitForFunction(() => cloudReady() && !cloudState.busy, null, { timeout: 20000 });
    orgA = await p.evaluate(() => cloud.org.id); return await p.evaluate(() => cloud.org.name);
  });
  await step('Im Partner-Portal neues Konto B anlegen', async () => {
    await p.evaluate(() => ppOpen('dashboard')); await p.waitForTimeout(300);
    await p.evaluate(() => { if (cloudSignedIn()) { cloud.session = null; persistCloud(); ppRender(); } });
    await p.fill('[data-pp-form=login] [name=email]', B); await p.fill('[data-pp-form=login] [name=password]', PW);
    await p.$eval('[data-pp-action=signup]', (e) => e.click()); await p.waitForFunction(() => !pp.busy && document.querySelector('[data-pp-form=company]'), null, { timeout: 20000 });
    await p.fill('[data-pp-form=company] [name=name]', `Wechsel Service ${N}`); await p.$eval('[data-pp-form=company] button[type=submit]', (e) => e.click()); await p.waitForFunction(() => !pp.busy && ppOrg(), null, { timeout: 20000 });
    return await p.evaluate(() => `${ppOrg().name} · Hausbesitzer-Org im Speicher: ${cloud.org ? cloud.org.name : 'keine'}`);
  });
  await step('Zur Hausbesitzer-Ansicht: eigene Organisation statt der von Konto A', async () => {
    await p.evaluate(() => ppClose()); await p.waitForFunction(() => cloudReady(), null, { timeout: 20000 });
    const org = await p.evaluate(() => cloud.org); if (org.id === orgA) throw new Error('noch Organisation von Konto A');
    return `${org.name} (${org.role})`;
  });
  await step('Konto B (FREE) sieht im Partner-Portal den Tarif-Hinweis statt „Keine Berechtigung“', async () => {
    await p.evaluate(() => { currentPage = 'partnerHub'; hub.tab = 'partners'; render(); }); await p.waitForTimeout(800);
    const text = await p.textContent('#page-content');
    if (/Keine Berechtigung/.test(text)) throw new Error('Berechtigungsfehler sichtbar');
    return /ab PRO/.test(text) ? 'Partner-Portal ist ab PRO verfügbar' : text.slice(0, 80);
  });
  await step('Zurück zu Konto A: Einladungscode für einen Servicepartner erzeugen', async () => {
    await p.evaluate(() => { currentPage = 'settings'; settingsView = 'settings-data'; cloud.session = null; persistCloud(); render(); });
    await p.fill('[data-cloud-form=signin] [name=email]', 'admin@husora.test'); await p.fill('[data-cloud-form=signin] [name=password]', PW);
    await p.$eval('[data-cloud-form=signin] button[type=submit]', (e) => e.click()); await p.waitForFunction(() => cloudReady() && !cloudState.busy, null, { timeout: 20000 });
    const org = await p.evaluate(() => cloud.org.id); if (org !== orgA) throw new Error('falsche Organisation');
    await p.evaluate(() => { currentPage = 'partnerHub'; hub.tab = 'partners'; render(); }); await p.waitForFunction(() => ownerSide.partners !== null && !ownerSide.busy, null, { timeout: 20000 });
    await p.fill('[data-owner-form=partner] [name=company_name]', 'Testbetrieb'); await p.fill('[data-owner-form=partner] [name=email]', `betrieb${N}@hs.test`);
    await p.$eval('[data-owner-form=partner] button[type=submit]', (e) => e.click()); await p.waitForFunction(() => !ownerSide.busy, null, { timeout: 20000 }); await p.waitForTimeout(300);
    const r = await p.evaluate(() => ownerSide.code?.code || ownerSide.error); if (!/^HUS-/.test(r)) throw new Error(r); return r;
  });
  await step('Alter falscher Stand im Speicher wird beim Start repariert', async () => {
    const orgB = sql(`select o.id from organizations o join organization_members m on m.organization_id=o.id join users u on u.id=m.user_id where u.email='${B}' and o.org_type='homeowner'`);
    await p.evaluate((orgB) => { cloud.org = { id: orgB, name: 'fremd', role: 'admin' }; persistCloud(); }, orgB);
    await p.reload(); await p.waitForFunction((orgA) => cloud.org && cloud.org.id === orgA, orgA, { timeout: 20000 });
    return `fremde Organisation verworfen → wieder ${await p.evaluate(() => cloud.org.name)}`;
  });
  console.log(res.join('\n')); console.log(errs.length ? 'JS-Fehler:\n' + [...new Set(errs)].join('\n') : 'keine JS-Fehler'); await b.close();
})();
