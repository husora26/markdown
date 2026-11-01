const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON: ENV_ANON } = require('./env'); const OUT = SP + '/audit/home'; fs.mkdirSync(OUT, { recursive: true });
const ANON = ENV_ANON; const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Arvika Service ${N}`, P_EMAIL = `home${N}@hs.test`, PW = 'Husora!2026';
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



  const wait = () => P.waitForFunction(() => !pp.busy, null, { timeout: 20000 }).then(() => P.waitForTimeout(250));
  await step('Startseite: Kopfleiste wie Hausbesitzer, Betrieb mit Rolle, 6 Kacheln', async () => {
    await P.evaluate(() => { pp.view = 'dashboard'; pp.detail = null; ppRender(); }); await wait();
    const top = await P.$eval('.pp-top', (e) => [e.querySelector('.pp-top-logo') ? 'Logo' : '', e.querySelector('.breadcrumb-brand')?.textContent, e.querySelector('.brand-region')?.textContent].join(' · '));
    const company = await P.textContent('.pp-company');
    const tiles = await P.$$eval('.pp-home-tile .pp-home-tile-head > span:first-child', (e) => e.map((x) => x.textContent).join(', '));
    const hallo = await P.evaluate(() => document.querySelector('#partner-portal .pp-main').textContent.includes('Hallo'));
    await P.screenshot({ path: OUT + '/1-start.png', fullPage: true });
    if (tiles !== 'Aufträge, Kontrollen, Mängel, Angebote & Rechnungen, Kalender, Kunden & Objekte' || hallo || !company.includes(FIRM) || !company.includes('Inhaber')) throw new Error(`${tiles} · ${company} · Hallo ${hallo}`);
    return `${top} · ${company.replace(/\s+/g, ' ').trim().slice(0, 80)} · ${tiles}`;
  });
  await step('Kachel öffnet Bereich (Mängel)', async () => { await P.click('.pp-home-tile[data-pp-view=defects]'); await wait(); return `${await P.evaluate(() => pp.view)} · ${await P.textContent('.pp-page-head h1')}`; });
  await step('Einstellungen: Kacheln wählen (Nachrichten an, Kalender aus)', async () => {
    await P.click('.pp-top [data-pp-view=settings]'); await wait();
    await P.check('[data-pp-tile-toggle=messages]'); await P.uncheck('[data-pp-tile-toggle=calendar]');
    await P.screenshot({ path: OUT + '/2-einstellungen.png', fullPage: true });
    await P.evaluate(() => { pp.view = 'dashboard'; ppRender(); });
    const tiles = await P.$$eval('.pp-home-tile', (e) => e.map((x) => x.dataset.ppView).join(','));
    if (!tiles.includes('messages') || tiles.includes('calendar')) throw new Error(tiles); return tiles;
  });
  await step('Einstellungen: Dunkel und große Schrift', async () => {
    await P.evaluate(() => { pp.view = 'settings'; ppRender(); }); await P.click('#partner-portal [data-display-theme=dark]'); await P.click('#partner-portal [data-display-size=large]'); await P.waitForTimeout(300);
    const r = await P.evaluate(() => `${document.documentElement.classList.contains('dark')} · ${document.documentElement.classList.contains('ts-large')} · zoom ${getComputedStyle(document.querySelector('.pp-main')).zoom}`);
    await P.evaluate(() => { pp.view = 'dashboard'; ppRender(); }); await P.screenshot({ path: OUT + '/3-dunkel.png', fullPage: true });
    await P.evaluate(() => { pp.view = 'settings'; ppRender(); }); await P.click('#partner-portal [data-display-theme=light]'); await P.click('#partner-portal [data-display-size=normal]');
    if (!r.startsWith('true · true')) throw new Error(r); return r;
  });
  await step('Über Husora: Impressum öffnet über dem Portal', async () => {
    await P.evaluate(() => { pp.view = 'settings'; ppRender(); }); await P.click('#partner-portal [data-legal-open=imprint]'); await P.waitForTimeout(400);
    const r = await P.evaluate(() => { const m = document.getElementById('legal-modal'); return `${m.classList.contains('open')} · z ${getComputedStyle(m).zIndex} · ${document.getElementById('legal-modal-title')?.textContent}`; });
    await P.screenshot({ path: OUT + '/4-impressum.png' }); await P.evaluate(() => closeLegalModal());
    if (!r.startsWith('true')) throw new Error(r); return r;
  });
  for (const [lang, expect] of [['en', 'Orders'], ['sv', 'Uppdrag']]) {
    await step(`Sprache ${lang}: Partner-Portal und Hausbesitzer-Ansicht übersetzt`, async () => {
      await P.evaluate(() => { pp.view = 'settings'; ppRender(); }); await Promise.all([P.waitForNavigation({ timeout: 20000 }), P.click(`[data-app-lang=${lang}]`)]);
      await P.waitForTimeout(1500); await P.evaluate(() => { if (!pp.open) ppOpen('dashboard'); pp.view = 'dashboard'; ppRender(); }); await P.waitForTimeout(500);
      const tiles = await P.$$eval('.pp-home-tile .pp-home-tile-head > span:first-child', (e) => e.map((x) => x.textContent).join(', '));
      const nav = await P.$$eval('.pp-nav button', (e) => e.map((x) => x.textContent.trim()).join(', '));
      await P.screenshot({ path: OUT + `/5-${lang}-start.png`, fullPage: true });
      await P.evaluate(() => { pp.view = 'settings'; ppRender(); }); await P.waitForTimeout(200); await P.screenshot({ path: OUT + `/5-${lang}-einstellungen.png`, fullPage: true });
      await P.evaluate(() => ppClose()); await P.evaluate(() => { currentPage = 'dashboard'; render(); }); await P.waitForTimeout(300);
      const menu = await P.$$eval('.nav [data-page] > span', (e) => e.slice(0, 8).map((x) => x.textContent).join(', '));
      await P.screenshot({ path: OUT + `/6-${lang}-hausbesitzer.png` });
      await P.evaluate(() => ppOpen('dashboard'));
      if (!tiles.includes(expect)) throw new Error(`${tiles} · ${nav}`);
      return `Kacheln: ${tiles} · Leiste: ${nav} · Menü: ${menu}`;
    });
  }
  await step('Zurück auf Deutsch', async () => { await P.evaluate(() => { pp.view = 'settings'; ppRender(); }); await Promise.all([P.waitForNavigation({ timeout: 20000 }), P.click('[data-app-lang=de]')]); await P.waitForTimeout(800); return await P.evaluate(() => `${document.documentElement.lang || 'de'} · ${appLang}`); });
  console.log(res.join('\n')); console.log(errs.length ? 'JS-Fehler:\n' + [...new Set(errs)].join('\n') : 'keine JS-Fehler'); await b.close();
})();
