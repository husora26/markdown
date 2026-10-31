const { chromium } = require('playwright'); const fs = require('fs');
const OUT = require('./env').SP + '/audit/bulk'; fs.mkdirSync(OUT, { recursive: true });
(async () => { const b = await chromium.launch(); const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true }); const p = await ctx.newPage(); const errs = []; p.on('pageerror', (e) => errs.push(e.message));
  await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
  await p.goto('http://127.0.0.1:8081/index.html'); await p.evaluate(() => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); }); await p.reload(); await p.waitForTimeout(400);
  await p.evaluate(() => { const ids = providers.filter((x) => !x.custom).slice(0, 3).map((x) => x.id); localStorage.setItem('stugliv-provider-assignments', JSON.stringify({ [properties[0].id]: ids })); }); await p.reload(); await p.waitForTimeout(400);
  const res = []; const step = async (n, f) => { try { res.push(`OK   ${n} – ${await f()}`); } catch (e) { res.push(`FEHL ${n} – ${e.message.split('\n')[0].slice(0, 200)}`); } };
  await step('Zugeordnete Servicepartner: Entfernen-Knopf auf jeder Karte', async () => {
    await p.evaluate(() => { currentPage = 'assignedProviders'; render(); }); await p.waitForTimeout(300);
    const before = await p.$$eval('.ap-card', (e) => e.map((x) => x.querySelector('h3').textContent));
    await p.screenshot({ path: OUT + '/1-zugeordnet.png' });
    await p.click('.ap-card .ap-remove'); await p.waitForTimeout(300);
    const after = await p.$$eval('.ap-card', (e) => e.map((x) => x.querySelector('h3').textContent));
    const stored = await p.evaluate(() => JSON.parse(localStorage.getItem('stugliv-provider-assignments'))[properties[0].id].length);
    if (after.length !== before.length - 1) throw new Error(`${before.length} → ${after.length}`); return `${before.length} → ${after.length} Partner (entfernt: ${before.find((x) => !after.includes(x))}) · gespeichert: ${stored}`;
  });
  await step('Serviceaufgaben nach Partner: ankreuzen, Partner wählen, mit einem Klick zuordnen', async () => {
    await p.evaluate(() => { currentPage = 'tasks'; taskView = 'partners'; render(); }); await p.waitForTimeout(300);
    const unassigned = await p.$$eval('.partner-task-card.unassigned [data-bulk-task]', (e) => e.length);
    await p.evaluate(() => document.querySelector('.partner-task-card.unassigned [data-bulk-group]').click()); await p.waitForTimeout(200);
    const bar = await p.evaluate(() => document.querySelector('.bulk-bar').innerText.replace(/\s+/g, ' '));
    const target = await p.evaluate(() => [...document.querySelectorAll('[data-bulk-target] option')].find((o) => o.value && !o.value.startsWith('__')).value);
    await p.selectOption('[data-bulk-target]', target); await p.waitForTimeout(150);
    await p.evaluate(() => document.querySelector('.bulk-bar').scrollIntoView()); await p.screenshot({ path: OUT + '/2-auswahl.png' });
    await p.click('[data-bulk-assign]'); await p.waitForTimeout(300);
    const r = await p.evaluate((target) => `${tasks.filter((t) => t.partnerId === target && !t.done).length} Aufgaben bei ${providerById(target).name} · ohne Partner noch: ${document.querySelectorAll('.partner-task-card.unassigned [data-bulk-task]').length} · Hinweis: ${document.querySelector('.toast, #toast')?.textContent.trim().slice(0, 80)}`, target);
    return `ohne Partner: ${unassigned} · Leiste: „${bar}“ · ${r}`;
  });
  await step('Einzelne Aufgabe ankreuzen → Eigenleistung', async () => {
    await p.evaluate(() => document.querySelector('[data-bulk-task]').click()); await p.waitForTimeout(150);
    const id = await p.evaluate(() => [...bulkTasks][0]);
    await p.selectOption('[data-bulk-target]', '__self'); await p.click('[data-bulk-assign]'); await p.waitForTimeout(200);
    const r = await p.evaluate((id) => { const t = tasks.find((x) => String(x.id) === id); return `${t.title}: selfService=${t.selfService}`; }, id);
    if (!/true/.test(r)) throw new Error(r); return r;
  });
  console.log(res.join('\n')); console.log(errs.length ? 'JS-Fehler:\n' + errs.join('\n') : 'keine JS-Fehler'); await b.close(); })();
