// Zugangscodes unter „Notfall & Zugang“ mit PIN schützen (nur Browser, ohne Server)
const { chromium } = require('playwright'); const fs = require('fs');
const { SP } = require('./env'); const OUT = SP + '/audit/codepin'; fs.mkdirSync(OUT, { recursive: true });
(async () => {
  const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (name, fn) => { try { const r = await fn(); res.push(`OK   ${name}${r ? ' – ' + r : ''}`); } catch (e) { res.push(`FEHL ${name} – ${e.message.split('\n')[0].slice(0, 220)}`); } };
  const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  const p = await ctx.newPage(); p.on('pageerror', (e) => errs.push(e.message));
  const dialogs = []; p.on('dialog', (d) => { dialogs.push(d.message()); d.accept(); });
  await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr|supabase\.co/, (r) => r.abort());
  await p.goto('http://127.0.0.1:8081/index.html');
  await p.evaluate(() => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"demo"}'); localStorage.setItem('stugliv-test-plan', 'ultimate'); });
  await p.reload(); await p.waitForTimeout(600);
  const open = () => p.evaluate(() => { currentPage = 'emergency'; render(); });
  const secretInputs = () => p.$$eval('#emergency-form input[name=keyCode], #emergency-form input[name=alarm], #emergency-form input[name=wifi]', (els) => els.length);
  const domHas = (text) => p.evaluate((t) => document.getElementById('page-content').innerHTML.includes(t), text);

  await step('Code eintragen und speichern (ohne PIN)', async () => {
    await open(); await p.fill('#emergency-form [name=keyCode]', '4711'); await p.fill('#emergency-form [name=keyLocation]', 'Box links');
    await p.$eval('#emergency-form button[type=submit]', (e) => e.click()); await p.waitForTimeout(200);
    const v = await p.evaluate(() => emergencyFor(sectionProperty().id).keyCode); if (v !== '4711') throw new Error(v); return 'Code gespeichert';
  });
  await step('PIN festlegen sperrt die Codes', async () => {
    await p.click('[data-code-pin-setup]'); await p.fill('#code-pin-form [name=pin]', '2468'); await p.fill('#code-pin-form [name=pin2]', '2468');
    await p.click('#code-pin-form button[type=submit]'); await p.waitForTimeout(300);
    const stored = await p.evaluate(() => JSON.parse(localStorage.getItem('husora-code-pin'))); if (!stored?.hash || JSON.stringify(stored).includes('2468')) throw new Error('PIN nicht gehasht');
    if (await secretInputs() !== 0) throw new Error('Codefelder noch editierbar'); if (await domHas('4711')) throw new Error('Code im DOM');
    await p.screenshot({ path: OUT + '/1-gesperrt.png' }); return 'Codes nicht im DOM';
  });
  await step('Speichern im gesperrten Zustand behält den Code', async () => {
    await p.fill('#emergency-form [name=keyLocation]', 'Box rechts'); await p.$eval('#emergency-form button[type=submit]', (e) => e.click()); await p.waitForTimeout(200);
    const d = await p.evaluate(() => emergencyFor(sectionProperty().id)); if (d.keyCode !== '4711' || d.keyLocation !== 'Box rechts') throw new Error(JSON.stringify(d)); return 'Code unverändert';
  });
  await step('Falsche PIN wird abgelehnt', async () => {
    await p.fill('#code-pin-form [name=pin]', '1111'); await p.click('#code-pin-form button[type=submit]'); await p.waitForTimeout(300);
    if (await secretInputs() !== 0) throw new Error('entsperrt'); return 'gesperrt';
  });
  await step('Richtige PIN entsperrt und zeigt den Code', async () => {
    await p.fill('#code-pin-form [name=pin]', '2468'); await p.click('#code-pin-form button[type=submit]'); await p.waitForTimeout(300);
    const v = await p.inputValue('#emergency-form [name=keyCode]'); if (v !== '4711') throw new Error(v);
    await p.screenshot({ path: OUT + '/2-entsperrt.png' }); return 'Code sichtbar';
  });
  await step('Seite verlassen sperrt wieder', async () => {
    await p.evaluate(() => { currentPage = 'dashboard'; render(); }); await open(); await p.waitForTimeout(200);
    if (await secretInputs() !== 0) throw new Error('noch entsperrt'); return 'gesperrt';
  });
  await step('Partner-Zugang wird ohne Codes vorausgefüllt, solange gesperrt', async () => {
    const t = await p.evaluate(() => hubAccessDefaultText({ property: { app_ref: sectionProperty().id } })); if (t.includes('4711') || !t.includes('Box rechts')) throw new Error(t); return t.replace(/\n/g, ' / ');
  });
  await step('PIN vergessen löscht Codes und PIN', async () => {
    await p.click('[data-code-pin-forgot]'); await p.waitForTimeout(300);
    const d = await p.evaluate(() => ({ code: emergencyFor(sectionProperty().id).keyCode, loc: emergencyFor(sectionProperty().id).keyLocation, pin: localStorage.getItem('husora-code-pin') }));
    if (d.code || d.pin || d.loc !== 'Box rechts') throw new Error(JSON.stringify(d)); if (await secretInputs() !== 3) throw new Error('Felder fehlen'); return 'zurückgesetzt';
  });
  await step('PIN wird nicht in die Cloud übertragen', async () => {
    await p.evaluate(() => localStorage.setItem('husora-code-pin', JSON.stringify({ salt: 'x', hash: 'y' })));
    const keys = await p.evaluate(() => cloudLocalEntries().map(([k]) => k)); if (keys.some((k) => /pin/.test(k))) throw new Error(keys.join(',')); return `${keys.length} Schlüssel, keiner mit PIN`;
  });
  console.log(res.join('\n')); console.log(errs.length ? 'JS-Fehler:\n' + errs.join('\n') : 'keine JS-Fehler');
  await b.close();
})();
