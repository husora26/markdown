// Gästemappe für Vermieter: ausfüllen, Vorschau, je Buchung senden (nur Browser, ohne Server)
const { chromium } = require('playwright'); const fs = require('fs');
const { SP } = require('./env'); const OUT = SP + '/audit/guide'; fs.mkdirSync(OUT, { recursive: true });
(async () => {
  const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (name, fn) => { try { const r = await fn(); res.push(`OK   ${name}${r ? ' – ' + r : ''}`); } catch (e) { res.push(`FEHL ${name} – ${e.message.split('\n')[0].slice(0, 220)}`); } };
  const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  const p = await ctx.newPage(); p.on('pageerror', (e) => errs.push(e.message));
  const dialogs = []; let answer = true; p.on('dialog', (d) => { dialogs.push(d.message()); if (answer) d.accept(); else d.dismiss(); });
  await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr|supabase\.co/, (r) => r.abort());
  await p.addInitScript(() => { window.__shared = []; try { Object.defineProperty(navigator, 'share', { value: undefined, configurable: true }); } catch (e) {} Object.defineProperty(navigator, 'clipboard', { value: { writeText: async (t) => { window.__shared.push(t); } }, configurable: true }); });
  await p.goto('http://127.0.0.1:8081/index.html');
  await p.evaluate(() => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"demo"}'); localStorage.setItem('stugliv-test-plan', 'ultimate'); });
  await p.reload(); await p.waitForTimeout(600);
  let BID = '';
  const openList = () => p.evaluate(() => { bookingView = 'list'; currentPage = 'bookings'; render(); });

  await step('Testbuchung in 2 Tagen + Schlüsselcode/WLAN unter Notfall & Zugang', async () => {
    BID = await p.evaluate(() => {
      const pid = properties[0].id; const today = localDateKey(new Date());
      const booking = { id: 'guide-test', propertyId: pid, guestName: 'Anna Svensson', guestCount: '2', arrivalTime: '15:00', startDate: shiftDateKey(today, 2), endDate: shiftDateKey(today, 6), notes: '' };
      bookings = [...bookings.filter((x) => x.propertyId !== pid || x.endDate < today || x.startDate > shiftDateKey(today, 10)), booking]; saveStore('stugliv-bookings', bookings);
      emergencyData = { ...emergencyData, [pid]: { ...emergencyFor(pid), keyLocation: 'Box links neben der Tür', keyCode: '4711', wifi: 'Stuga / sommar123' } }; saveStore('stugliv-emergency', emergencyData);
      return booking.id;
    });
    const reminder = await p.evaluate((id) => collectReminders().find((r) => r.id === `guide-${id}`)?.title, BID);
    if (!reminder) throw new Error('keine Erinnerung'); return reminder;
  });
  await step('Gästemappe ausfüllen und speichern', async () => {
    await openList(); await p.click('[data-guide-details] summary');
    await p.fill('#guide-form [name=rules]', 'Nichtraucherhaus. Ruhe ab 22 Uhr.'); await p.fill('#guide-form [name=waste]', 'Tonnen hinter dem Schuppen.');
    await p.fill('#guide-form [name=host]', 'Familie Berg'); await p.fill('#guide-form [name=hostPhone]', '+46 70 123 45 67');
    await p.click('#guide-form button[type=submit]'); await p.waitForTimeout(200);
    const g = await p.evaluate(() => guideFor(properties[0].id)); if (g.rules !== 'Nichtraucherhaus. Ruhe ab 22 Uhr.' || g.host !== 'Familie Berg') throw new Error(JSON.stringify(g));
    const stored = await p.evaluate(() => localStorage.getItem('stugliv-guestguide')); if (stored.includes('4711')) throw new Error('Code in der Mappe gespeichert');
    return 'gespeichert, ohne Codes';
  });
  await step('Vorschau verdeckt die Codes', async () => {
    await p.click('[data-guide-preview]'); await p.waitForTimeout(150);
    const text = await p.textContent('.guide-preview'); if (!/Hallo Anna/.test(text) || !/HAUSREGELN/.test(text) || !/••••/.test(text) || text.includes('4711')) throw new Error(text.slice(0, 200));
    await p.screenshot({ path: OUT + '/1-vorschau.png', fullPage: false }); return 'Name, Hausregeln, Codes als ••••';
  });
  await step('Gästemappe senden: Text mit Codes, Aufgabe/Erinnerung erledigt', async () => {
    await p.click(`[data-guide-send="${BID}"]`); await p.waitForTimeout(300);
    const text = await p.evaluate(() => window.__shared.at(-1) || '');
    for (const part of ['Hallo Anna', 'Willkommen in', 'Box links neben der Tür', '4711', 'Stuga / sommar123', 'Nichtraucherhaus', '112', 'Familie Berg']) if (!text.includes(part)) throw new Error(`fehlt: ${part}`);
    const state = await p.evaluate((id) => ({ sent: Boolean(guideSent[id]), reminder: collectReminders().some((r) => r.id === `guide-${id}`), label: document.querySelector(`[data-guide-send="${id}"]`)?.textContent }), BID);
    if (!state.sent || state.reminder || !/gesendet/.test(state.label)) throw new Error(JSON.stringify(state));
    return state.label;
  });
  await step('Englische Mappe', async () => {
    await p.selectOption('#guide-form [name=lang]', 'en'); await p.click('#guide-form button[type=submit]'); await p.waitForTimeout(150);
    const text = await p.evaluate((id) => guestGuideText(bookings.find((x) => x.id === id), false), BID);
    if (!/^Hi Anna,/.test(text) || !/HOUSE RULES/.test(text) || text.includes('4711')) throw new Error(text.slice(0, 160)); return 'Hi Anna … HOUSE RULES, ohne Codes';
  });
  await step('Mit PIN: Abbrechen sendet ohne Codes', async () => {
    await p.evaluate(async () => { const salt = 'ab'; localStorage.setItem('husora-code-pin', JSON.stringify({ salt, hash: await codePinHash('2468', salt) })); codePinState.until = 0; });
    answer = false; await openList(); await p.click(`[data-guide-send="${BID}"]`); await p.waitForTimeout(300); answer = true;
    const text = await p.evaluate(() => window.__shared.at(-1) || ''); if (text.includes('4711') || text.includes('sommar123')) throw new Error('Codes trotz Sperre');
    if (!/PIN gesperrt/.test(dialogs.at(-1) || '')) throw new Error('keine Rückfrage'); return 'ohne Codes gesendet';
  });
  await step('Mit PIN: OK → PIN eingeben → Mappe mit Codes, zurück bei Buchungen', async () => {
    const before = await p.evaluate(() => window.__shared.length);
    await p.click(`[data-guide-send="${BID}"]`); await p.waitForTimeout(300);
    if (await p.evaluate(() => currentPage) !== 'emergency') throw new Error('keine PIN-Abfrage');
    await p.fill('#code-pin-form [name=pin]', '2468'); await p.click('#code-pin-form button[type=submit]'); await p.waitForTimeout(500);
    const r = await p.evaluate((n) => ({ page: currentPage, text: window.__shared.slice(n).join('\n') }), before);
    if (r.page !== 'bookings' || !r.text.includes('4711')) throw new Error(JSON.stringify({ page: r.page, len: r.text.length })); return 'gesendet mit Codes';
  });
  await step('Eigennutzung bekommt keinen Senden-Knopf', async () => {
    await p.evaluate(() => { const today = localDateKey(new Date()); bookings = [...bookings, { id: 'own-test', kind: 'owner', propertyId: properties[0].id, guestName: 'Eigennutzung', guestCount: '2', startDate: shiftDateKey(today, 20), endDate: shiftDateKey(today, 22), notes: '' }]; render(); });
    const own = await p.evaluate(() => isOwnerStay(bookings.find((x) => x.id === 'own-test')));
    const btn = await p.$('[data-guide-send="own-test"]'); if (own && btn) throw new Error('Knopf bei Eigennutzung'); return own ? 'kein Knopf' : 'Eigennutzung anders markiert – übersprungen';
  });
  console.log(res.join('\n')); console.log(errs.length ? 'JS-Fehler:\n' + errs.join('\n') : 'keine JS-Fehler');
  await b.close();
})();
