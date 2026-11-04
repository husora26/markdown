// Hausbesitzer-App, Einstellungen: jede Karte auf-/zuklappbar, Zustand bleibt, „Alle zuklappen/aufklappen“ je Bereich
const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (name, fn) => { try { const r = await fn(); res.push(`OK   ${name}${r ? ' – ' + r : ''}`); } catch (e) { res.push(`FEHL ${name} – ${e.message.split('\n')[0].slice(0, 220)}`); } };
  const p = await b.newPage({ viewport: { width: 390, height: 844 } }); p.on('pageerror', (e) => errs.push(e.message));
  await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
  await p.goto('http://127.0.0.1:8081/index.html');
  await p.evaluate(() => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); });
  await p.reload(); await p.waitForTimeout(600);
  const open = async (view = 'settings-home') => { await p.evaluate((v) => { currentPage = 'settings'; settingsView = v; render(); }, view); await p.waitForTimeout(300); };
  await open();
  await step('Alle Karten haben eine Klappfunktion', async () => {
    const n = await p.$$eval('.settings-group .settings-grid > section.card', (e) => [e.length, e.filter((c) => c.classList.contains('fold-card')).length]);
    if (!n[0] || n[0] !== n[1]) throw new Error(n.join('/')); return `${n[1]} Karten`;
  });
  await step('Karte zuklappen und wieder aufklappen', async () => {
    const card = '#settings-home .fold-card:nth-child(1)';
    await p.click(`${card} > .fold-head`); await p.waitForTimeout(150);
    const zu = await p.$eval(card, (e) => e.classList.contains('folded') && getComputedStyle(e.children[1]).display === 'none');
    await p.click(`${card} > .fold-head`); await p.waitForTimeout(150);
    const auf = await p.$eval(card, (e) => !e.classList.contains('folded'));
    if (!zu || !auf) throw new Error(`${zu}/${auf}`); return 'ok';
  });
  await step('Zustand bleibt nach Neuzeichnen und Neuladen', async () => {
    await p.click('#settings-home .fold-card:nth-child(2) > .fold-head'); await p.waitForTimeout(150);
    await p.evaluate(() => render()); await p.waitForTimeout(200);
    const a = await p.$eval('#settings-home .fold-card:nth-child(2)', (e) => e.classList.contains('folded'));
    await p.reload(); await p.waitForTimeout(600); await open();
    const b2 = await p.$eval('#settings-home .fold-card:nth-child(2)', (e) => e.classList.contains('folded'));
    if (!a || !b2) throw new Error(`${a}/${b2}`); return 'bleibt zugeklappt';
  });
  await step('Alle zuklappen / Alle aufklappen', async () => {
    await p.click('#settings-home [data-settings-fold-all]'); await p.waitForTimeout(150);
    const zu = await p.$$eval('#settings-home .fold-card', (e) => e.every((c) => c.classList.contains('folded')));
    const label = await p.$eval('#settings-home [data-settings-fold-all]', (e) => e.textContent);
    await p.click('#settings-home [data-settings-fold-all]'); await p.waitForTimeout(150);
    const auf = await p.$$eval('#settings-home .fold-card', (e) => e.every((c) => !c.classList.contains('folded')));
    if (!zu || !auf || label !== 'Alle aufklappen') throw new Error(`${zu}/${auf}/${label}`); return 'ok';
  });
  await step('Bedienelemente in aufgeklappten Karten funktionieren weiter', async () => {
    await open('settings-look');
    const before = await p.evaluate(() => displaySettings.textSize);
    await p.click('#settings-look [data-display-size="large"], #settings-look button:has-text("Groß")').catch(() => {});
    await p.waitForTimeout(200);
    const after = await p.evaluate(() => displaySettings.textSize);
    await p.evaluate(() => { displaySettings.textSize = 'normal'; });
    if (before === after) throw new Error(`${before} → ${after}`); return `${before} → ${after}`;
  });
  console.log(res.join('\n')); if (errs.length) console.log('JS-Fehler:\n' + errs.join('\n'));
  await b.close();
})();
