const { chromium } = require('playwright'); const fs = require('fs');
const { SP, ANON: ENV_ANON } = require('./env'); const OUT = SP + '/audit/back'; fs.mkdirSync(OUT, { recursive: true });
const ANON = ENV_ANON; const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000; const PW = 'Husora!2026';
(async () => {
  const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (name, fn) => { try { const r = await fn(); res.push(`OK   ${name}${r ? ' – ' + r : ''}`); } catch (e) { res.push(`FEHL ${name} – ${e.message.split('\n')[0].slice(0, 220)}`); } };
  const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true }); const p = await ctx.newPage();
  p.on('pageerror', (e) => errs.push(e.message)); p.on('dialog', (d) => d.accept());
  await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
  await p.goto('http://127.0.0.1:8081/index.html');
  await p.evaluate(({ url, key }) => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); localStorage.setItem('husora-cloud', JSON.stringify({ url, key })); }, { url: URL_, key: ANON });
  await p.reload(); await p.waitForTimeout(400);
  const back = async () => { await p.click('.pp-top [data-pp-action=home]'); await p.waitForTimeout(400);
    return p.evaluate(() => [document.getElementById('partner-portal').hidden, currentPage, settingsView, !!document.getElementById('settings-partners'), localStorage.getItem('husora-mode')].join(' · ')); };
  await step('Einstellungen → „Ich bin Servicepartner“ öffnet Anmeldung', async () => {
    await p.evaluate(() => { currentPage = 'settings'; settingsView = 'settings-data'; render(); }); await p.click('#settings-partners [data-open-partner-portal]'); await p.waitForTimeout(300);
    await p.screenshot({ path: OUT + '/1-login.png' }); return `Login: ${!!(await p.$('[data-pp-form=login]'))}`;
  });
  await step('Symbol oben links (vor Anmeldung) → Einstellungen', async () => { const r = await back(); if (!r.startsWith('true · settings · settings-data · true')) throw new Error(r); return r; });
  await step('Anmelden + Betriebsdaten eingeben', async () => {
    await p.click('#settings-partners [data-open-partner-portal]'); await p.waitForTimeout(300);
    await p.fill('[data-pp-form=login] [name=email]', `zurueck${N}@sp.test`); await p.fill('[data-pp-form=login] [name=password]', PW);
    await p.$eval('[data-pp-action=signup]', (e) => e.click()); await p.waitForFunction(() => !pp.busy && document.querySelector('[data-pp-form=company]'), null, { timeout: 20000 });
    await p.screenshot({ path: OUT + '/2-betriebsdaten.png' });
    await p.fill('[data-pp-form=company] [name=name]', `Rückweg Service ${N}`); await p.$eval('[data-pp-form=company] button[type=submit]', (e) => e.click()); await p.waitForFunction(() => !pp.busy && ppOrg(), null, { timeout: 20000 });
    await p.screenshot({ path: OUT + '/3-portal.png' }); return await p.evaluate(() => ppOrg().name);
  });
  await step('Symbol oben links (nach Eingabe) → Start des Partner-Portals', async () => { await p.evaluate(() => { pp.view = 'company'; ppRender(); }); await p.click('.pp-top [data-pp-action=home]'); await p.waitForTimeout(300); const r = await p.evaluate(() => `${!document.getElementById('partner-portal').hidden} · ${pp.view}`); if (r !== 'true · dashboard') throw new Error(r); return r; });
  await step('Mehr → „Zur Hausbesitzer-Ansicht“ → Einstellungen → wieder ins Partner-Portal', async () => {
    await p.evaluate(() => { pp.view = 'more'; pp.detail = null; ppRender(); }); if (await p.$('.pp-top [data-pp-action=close]')) throw new Error('Hausbesitzer-Knopf noch oben'); await p.click('#partner-portal .pp-tip [data-pp-action=close]'); await p.waitForTimeout(300); await p.evaluate(() => { currentPage = 'settings'; settingsView = 'settings-data'; render(); });
    await p.click('#settings-partners [data-open-partner-portal]'); await p.waitForTimeout(800);
    return await p.evaluate(() => `${!document.getElementById('partner-portal').hidden} · ${ppOrg()?.name}`);
  });
  await step('Neu laden: App startet nicht mehr gefangen im Portal', async () => {
    await p.evaluate(() => { pp.view = 'more'; pp.detail = null; ppRender(); }); if (await p.$('.pp-top [data-pp-action=close]')) throw new Error('Hausbesitzer-Knopf noch oben'); await p.click('#partner-portal .pp-tip [data-pp-action=close]'); await p.waitForTimeout(300); await p.reload(); await p.waitForTimeout(600); return await p.evaluate(() => `Portal offen: ${!document.getElementById('partner-portal')?.hidden && !!document.getElementById('partner-portal')} · Modus ${localStorage.getItem('husora-mode')}`);
  });
  console.log(res.join('\n')); console.log(errs.length ? 'JS-Fehler:\n' + [...new Set(errs)].join('\n') : 'keine JS-Fehler'); await b.close();
})();
