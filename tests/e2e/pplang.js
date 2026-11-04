// Servicepartner-Portal: Sprache direkt in der Kopfleiste wechseln (DE / EN / SV), danach bleibt das Portal offen
const { chromium } = require('playwright'); const fs = require('fs');
const { SP } = require('./env'); const OUT = SP + '/audit/pplang'; fs.mkdirSync(OUT, { recursive: true });
(async () => {
  const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (name, fn) => { try { const r = await fn(); res.push(`OK   ${name}${r ? ' – ' + r : ''}`); } catch (e) { res.push(`FEHL ${name} – ${e.message.split('\n')[0].slice(0, 220)}`); } };
  const p = await b.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 }); p.on('pageerror', (e) => errs.push(e.message));
  await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
  await p.goto('http://127.0.0.1:8081/index.html');
  await p.evaluate(() => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); });
  await p.reload(); await p.waitForTimeout(600);
  await p.evaluate(() => ppOpen('dashboard')); await p.waitForTimeout(300);
  await step('Sprachknopf in der Kopfleiste zeigt „DE“', async () => {
    const t = await p.$eval('#partner-portal .pp-top [data-pp-lang-toggle]', (e) => e.textContent.trim());
    if (t !== 'DE') throw new Error(t); return t;
  });
  await step('Tipp öffnet die Auswahl Deutsch / English / Svenska', async () => {
    await p.click('#partner-portal [data-pp-lang-toggle]'); await p.waitForTimeout(200);
    const items = await p.$$eval('#partner-portal .pp-lang-menu [data-pp-lang]', (e) => e.map((x) => x.textContent.trim()));
    const box = await p.$eval('#partner-portal .pp-lang-menu', (e) => { const r = e.getBoundingClientRect(); return { left: r.left, right: r.right, vis: getComputedStyle(e).visibility }; });
    await p.screenshot({ path: OUT + '/1-auswahl.png' });
    if (items.join('|') !== 'DE Deutsch|EN English|SV Svenska' || box.left < 0 || box.right > 390) throw new Error(`${items.join('|')} ${JSON.stringify(box)}`);
    return items.join(', ');
  });
  await step('Klick außerhalb schließt die Auswahl', async () => {
    await p.mouse.click(30, 600); await p.waitForTimeout(200);
    if (await p.$('#partner-portal .pp-lang-menu')) throw new Error('noch offen'); return 'geschlossen';
  });
  await step('Englisch wählen → App startet neu, Partner-Portal bleibt offen und ist englisch', async () => {
    await p.click('#partner-portal [data-pp-lang-toggle]'); await p.waitForTimeout(150);
    await Promise.all([p.waitForNavigation(), p.click('#partner-portal [data-pp-lang="en"]')]); await p.waitForTimeout(900);
    const st = await p.evaluate(() => ({ open: pp.open, lang: appLang, btn: document.querySelector('#partner-portal [data-pp-lang-toggle]')?.textContent.trim(), text: document.querySelector('#partner-portal')?.textContent || '' }));
    await p.screenshot({ path: OUT + '/2-englisch.png' });
    if (!st.open || st.lang !== 'en' || st.btn !== 'EN' || !/Sign in|Log in|Email|Password/i.test(st.text)) throw new Error(JSON.stringify({ ...st, text: st.text.slice(0, 120) }));
    return 'EN, Portal offen';
  });
  await step('Schwedisch wählen', async () => {
    await p.click('#partner-portal [data-pp-lang-toggle]'); await p.waitForTimeout(150);
    await Promise.all([p.waitForNavigation(), p.click('#partner-portal [data-pp-lang="sv"]')]); await p.waitForTimeout(900);
    const st = await p.evaluate(() => ({ open: pp.open, lang: appLang, btn: document.querySelector('#partner-portal [data-pp-lang-toggle]')?.textContent.trim() }));
    await p.screenshot({ path: OUT + '/3-schwedisch.png' });
    if (!st.open || st.lang !== 'sv' || st.btn !== 'SV') throw new Error(JSON.stringify(st)); return 'SV, Portal offen';
  });
  await step('Zurück auf Deutsch', async () => {
    await p.click('#partner-portal [data-pp-lang-toggle]'); await p.waitForTimeout(150);
    await Promise.all([p.waitForNavigation(), p.click('#partner-portal [data-pp-lang="de"]')]); await p.waitForTimeout(900);
    const st = await p.evaluate(() => ({ open: pp.open, lang: appLang }));
    if (!st.open || st.lang !== 'de') throw new Error(JSON.stringify(st)); return 'DE';
  });
  console.log(res.join('\n')); if (errs.length) console.log('JS-Fehler:\n' + errs.join('\n'));
  await b.close();
})();
