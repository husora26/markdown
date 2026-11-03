// Eingaben und Scroll-Position bleiben bei Hintergrund-Aktualisierungen erhalten; nach dem Senden wird das Feld leer,
// die Ansicht springt nicht nach oben (Hausbesitzer-App und Partner-Portal).
const { chromium } = require('playwright'); const fs = require('fs');
const { SP, ANON } = require('./env'); const OUT = SP + '/audit/drafts'; fs.mkdirSync(OUT, { recursive: true });
const URL_ = 'http://127.0.0.1:54321'; const PW = 'Husora!2026';
(async () => {
  const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (name, fn) => { try { const r = await fn(); res.push(`OK   ${name}${r ? ' – ' + r : ''}`); } catch (e) { res.push(`FEHL ${name} – ${e.message.split('\n')[0].slice(0, 220)}`); } };
  const ctx = await b.newContext({ viewport: { width: 390, height: 700 }, isMobile: true, hasTouch: true });
  const p = await ctx.newPage(); p.on('pageerror', (e) => errs.push(e.message)); p.on('dialog', (d) => d.accept());
  await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
  await p.goto('http://127.0.0.1:8081/index.html');
  await p.evaluate(({ url, key }) => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); localStorage.setItem('husora-cloud', JSON.stringify({ url, key })); }, { url: URL_, key: ANON });
  await p.reload(); await p.waitForTimeout(900);
  await p.evaluate(() => { document.getElementById('consent-sheet')?.remove(); document.querySelector('.nav [data-page="partnerHub"]').click(); }); await p.waitForTimeout(300);
  await p.fill('[data-cloud-form=signin] [name=email]', 'admin@husora.test'); await p.fill('[data-cloud-form=signin] [name=password]', PW);
  await p.$eval('[data-cloud-form=signin] button[type=submit]', (e) => e.click());
  await p.waitForFunction(() => cloudReady() && !cloudState.busy, null, { timeout: 20000 }); await p.waitForTimeout(800);
  await p.evaluate(() => document.getElementById('legal-accept')?.remove());

  await step('Hausbesitzer: getippter Text und Cursor überstehen das Neuzeichnen der Seite', async () => {
    const sel = await p.evaluate(() => {
      for (const page of ['profile', 'help', 'tasks', 'documents', 'settings', 'partnerHub']) {
        currentPage = page; render();
        const el = [...document.querySelectorAll('#page-content textarea, #page-content input[type=text], #page-content input:not([type])')].find((x) => x.offsetParent && !x.disabled && !x.readOnly);
        if (el) { el.setAttribute('data-test-draft', '1'); return page; }
      }
      return null;
    });
    if (!sel) throw new Error('kein Textfeld auf der Seite');
    await p.click('[data-test-draft]'); await p.keyboard.type('Entwurf ohne Senden');
    const before = await p.$eval('[data-test-draft]', (el) => ({ v: el.value, s: el.selectionStart }));
    await p.evaluate(() => { render(); render(); });  // wie eine Hintergrund-Aktualisierung
    const after = await p.evaluate(() => { const a = document.activeElement; return { v: a?.value, s: a?.selectionStart, tag: a?.tagName }; });
    if (after.v !== before.v || after.s !== before.s) throw new Error(JSON.stringify({ before, after }));
    return `Seite ${sel}: „${after.v}“ bleibt, Cursor an Position ${after.s}, Fokus bleibt im Feld`;
  });
  await step('Hausbesitzer: Scroll-Position bleibt beim Neuzeichnen derselben Seite', async () => {
    await p.evaluate(() => { currentPage = 'settings'; render(); window.scrollTo(0, 600); }); await p.waitForTimeout(200);
    const y = await p.evaluate(() => { render(); return window.scrollY; });
    if (y < 550) throw new Error(`scrollY ${y}`); return `scrollY ${y}`;
  });
  await step('Hausbesitzer: Nachricht an Partner senden – Feld danach leer, kein Sprung nach oben', async () => {
    await p.evaluate(() => { currentPage = 'partnerHub'; render(); }); await p.waitForTimeout(1500);
    const chat = await p.$('[data-hub-chat]'); if (!chat) throw new Error('kein verbundener Partner');
    await chat.click(); await p.waitForSelector('[data-hub-send] textarea', { timeout: 15000 });
    await p.fill('[data-hub-send] textarea', 'Testnachricht Entwurf');
    await p.evaluate(() => hubRefresh({ quiet: true })); await p.waitForTimeout(1500);
    const kept = await p.$eval('[data-hub-send] textarea', (el) => el.value);
    await p.evaluate(() => window.scrollTo(0, document.body.scrollHeight)); const y0 = await p.evaluate(() => window.scrollY);
    await p.$eval('[data-hub-send] button[type=submit]', (el) => el.click()); await p.waitForTimeout(2500);
    const after = await p.evaluate(() => ({ v: document.querySelector('[data-hub-send] textarea')?.value, y: window.scrollY }));
    await p.screenshot({ path: OUT + '/1-hub-gesendet.png' });
    if (kept !== 'Testnachricht Entwurf' || after.v !== '' || (y0 > 200 && after.y < 100)) throw new Error(JSON.stringify({ kept, y0, after }));
    return `Entwurf blieb bei Aktualisierung · nach Senden leer · scrollY ${y0} → ${after.y}`;
  });
  await step('Partner-Portal: Entwurf + Fokus überstehen Neuzeichnen, Scroll-Position bleibt', async () => {
    await p.evaluate(() => ppOpen('customers')); await p.waitForTimeout(2500);
    const has = await p.evaluate(() => { const el = [...document.querySelectorAll('#pp-main input.form-control, #pp-main textarea')].find((x) => x.offsetParent); if (!el) return false; el.setAttribute('data-test-draft', '2'); return true; });
    if (!has) throw new Error('kein Eingabefeld im Partner-Portal');
    await p.click('[data-test-draft="2"]'); await p.keyboard.type('HUS-ABCD');
    await p.evaluate(() => { const m = document.querySelector('#pp-main'); m.scrollTop = Math.min(250, m.scrollHeight); });
    const top0 = await p.evaluate(() => document.querySelector('#pp-main').scrollTop);
    await p.evaluate(() => ppRender());
    const r = await p.evaluate(() => ({ v: document.activeElement?.value, top: document.querySelector('#pp-main').scrollTop }));
    if (r.v !== 'HUS-ABCD' || Math.abs(r.top - top0) > 2) throw new Error(JSON.stringify({ top0, r }));
    return `„${r.v}“ bleibt mit Fokus · scrollTop ${top0} → ${r.top}`;
  });
  console.log(res.join('\n'));
  if (errs.length) console.log('JS-Fehler:\n' + errs.join('\n'));
  await b.close();
})();
