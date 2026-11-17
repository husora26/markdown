// Hausbesitzer-Seite auf Englisch und Schwedisch: Umschalter in den Einstellungen, Texte und Muster
const { chromium } = require('playwright'); const fs = require('fs');
const { SP } = require('./env'); const OUT = SP + '/audit/ownerlang'; fs.mkdirSync(OUT, { recursive: true });
(async () => {
  const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (name, fn) => { try { const r = await fn(); res.push(`OK   ${name}${r ? ' – ' + r : ''}`); } catch (e) { res.push(`FEHL ${name} – ${e.message.split('\n')[0].slice(0, 220)}`); } };
  const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  const p = await ctx.newPage(); p.on('pageerror', (e) => errs.push(e.message)); p.on('dialog', (d) => d.accept());
  await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr|supabase\.co/, (r) => r.abort());
  await p.goto('http://127.0.0.1:8081/index.html');
  await p.evaluate(() => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); localStorage.setItem('stugliv-test-plan', 'ultimate'); });
  await p.reload(); await p.waitForTimeout(600);
  const go = (page, extra) => p.evaluate(({ page, extra }) => { if (extra === 'look') settingsView = 'settings-look'; if (page === 'settings' && extra === undefined) return; if (page === 'propertyDetail') sectionPropertyId = properties[0]?.id; currentPage = page; render(); }, { page, extra }).then(() => p.waitForTimeout(250));
  const text = () => p.evaluate(() => document.getElementById('page-content').innerText);

  await step('Einstellungen zeigen den Sprachumschalter für die App', async () => {
    await go('settings', 'look'); const t = await text();
    if (!t.includes('Sprache der App')) throw new Error('kein Umschalter'); if (t.includes('bleibt auf Deutsch')) throw new Error('alter Hinweis');
    if (await p.$$eval('#page-content [data-app-lang]', (els) => els.length) !== 3) throw new Error('nicht 3 Sprachen'); return 'DE · EN · SV';
  });
  await step('Umschalten auf Englisch lädt die App neu', async () => {
    await Promise.all([p.waitForNavigation(), p.click('#page-content [data-app-lang=en]')]); await p.waitForTimeout(700);
    if (await p.evaluate(() => localStorage.getItem('husora-lang')) !== 'en') throw new Error('nicht gespeichert');
    if (await p.evaluate(() => document.documentElement.lang) !== 'en') throw new Error('lang-Attribut');
  });
  const checkPage = async (page, must, mustNot) => {
    await go(page); const t = await text();
    for (const m of must) if (!t.toLowerCase().includes(m.toLowerCase())) throw new Error(`fehlt „${m}“`);
    for (const m of mustNot) if (t.toLowerCase().includes(m.toLowerCase())) throw new Error(`noch deutsch: „${m}“`);
  };
  await step('Startseite auf Englisch', async () => { await checkPage('dashboard', ['overdue'], ['Was steht an?', 'Aufgaben sind überfällig']); await p.screenshot({ path: OUT + '/1-start-en.png' }); });
  await step('Kosten auf Englisch (Muster mit Jahr)', async () => checkPage('costs', ['actual 20', 'annual planning'], ['ist 20', 'jahresplanung']));
  await step('Aufgaben auf Englisch, Datum mit englischem Monat', async () => {
    await go('tasks'); const t = await text(); if (/\d (Okt|Dez|März|Mai)\b/.test(t)) throw new Error('deutscher Monat'); if (t.includes('Als erledigt markieren')) throw new Error('deutsch');
  });
  await step('Aria-Labels mit Aufgabentitel übersetzt', async () => {
    const labels = await p.$$eval('#page-content [aria-label]', (els) => els.map((e) => e.getAttribute('aria-label')));
    const de = labels.filter((l) => /^(Als erledigt markieren|Aufgabe bearbeiten|Status für)/.test(l)); if (de.length) throw new Error(de[0]); return `${labels.length} Labels`;
  });
  await step('Einstellungen auf Englisch', async () => go('settings', 'look').then(() => checkPage('settings', ['App language'], ['Die App selbst bleibt auf Deutsch'])));
  await step('Schwedisch', async () => {
    await go('settings', 'look'); await Promise.all([p.waitForNavigation(), p.click('#page-content [data-app-lang=sv]')]); await p.waitForTimeout(700);
    await checkPage('dashboard', ['försenade'], ['Was steht an?']); await p.screenshot({ path: OUT + '/2-start-sv.png' }); return 'sv';
  });
  await step('Zurück auf Deutsch', async () => {
    await go('settings', 'look'); await Promise.all([p.waitForNavigation(), p.click('#page-content [data-app-lang=de]')]); await p.waitForTimeout(700);
    await checkPage('dashboard', ['Was steht an?'], []); return 'de';
  });
  console.log(res.join('\n')); console.log(errs.length ? 'JS-Fehler:\n' + errs.join('\n') : 'keine JS-Fehler');
  await b.close();
})();
