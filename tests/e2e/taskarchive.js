const { chromium } = require('playwright');
const { SP } = require('./env'); const OUT = SP + '/audit/taskarchive'; require('fs').mkdirSync(OUT, { recursive: true });
(async () => { const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (n, f) => { try { res.push(`OK   ${n} – ${await f()}`); } catch (e) { res.push(`FEHL ${n} – ${e.message.split('\n')[0].slice(0, 240)}`); } };
  const ctx = await b.newContext({ viewport: { width: 390, height: 900 }, acceptDownloads: true }); const p = await ctx.newPage(); p.on('pageerror', (e) => errs.push(e.message)); p.on('dialog', (d) => d.accept());
  await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|google|jsdelivr|tile|supabase\.co/, (r) => r.abort());
  await p.goto('http://127.0.0.1:8081/index.html');
  await p.evaluate(() => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); });
  await p.reload(); await p.waitForTimeout(600);
  await p.evaluate(() => {
    const p0 = properties[0]; const d = (n) => localDateKey(new Date(Date.now() - n * 86400000));
    tasks.push({ id: 900001, title: 'Alte Endreinigung', property: p0.name, propertyId: p0.id, date: d(10), status: 'Erledigt', done: true, priority: 'normal', area: 'Reinigung', repeat: 'Einmalig' });
    tasks.push({ id: 900002, title: 'Alter Winterdienst', property: p0.name, propertyId: p0.id, date: d(6), status: 'Erledigt', done: true, doneAt: d(5), priority: 'normal', area: 'Außen', repeat: 'Einmalig' });
    tasks.push({ id: 900003, title: 'Gestern erledigt', property: p0.name, propertyId: p0.id, date: d(1), status: 'Erledigt', done: true, doneAt: d(1), priority: 'normal', area: 'Außen', repeat: 'Einmalig' });
    persistTasks();
  });
  await p.reload(); await p.waitForTimeout(600);
  await step('Erledigte Aufgaben älter als 3 Tage im Archiv, frische bleiben in der Liste', async () => {
    await p.evaluate(() => { document.querySelectorAll('.open').forEach((e) => e.classList.remove('open')); currentPage = 'tasks'; taskFilter = 'all'; render(); });
    const inList = await p.$$eval('.tcard-title', (e) => e.map((x) => x.textContent));
    const archived = await p.evaluate(() => tasks.filter(isArchivedTask).map((t) => t.title));
    if (inList.includes('Alte Endreinigung') || !inList.includes('Gestern erledigt') || !archived.includes('Alte Endreinigung') || !archived.includes('Alter Winterdienst')) throw new Error(`Liste: ${inList.join(', ')} · Archiv: ${archived.join(', ')}`);
    return `Archiv: ${archived.join(', ')} · in der Liste bleibt „Gestern erledigt“`;
  });
  await step('Archiv öffnen, alle exportieren (CSV)', async () => {
    await p.click('[data-task-archive] summary'); await p.evaluate(() => document.querySelector('.task-archive').scrollIntoView());
    await p.screenshot({ path: OUT + '/1-archiv.png' });
    const [dl] = await Promise.all([p.waitForEvent('download'), p.click('[data-archive-export]')]);
    const file = OUT + '/' + dl.suggestedFilename(); await dl.saveAs(file);
    const csv = require('fs').readFileSync(file, 'utf8');
    if (!csv.includes('Alte Endreinigung') || !csv.includes('Erledigt am')) throw new Error(csv.slice(0, 120));
    return `${dl.suggestedFilename()} · ${csv.trim().split('\n').length - 1} Zeilen`;
  });
  await step('Eine Aufgabe wiederherstellen, eine löschen', async () => {
    await p.check('[data-archive-task="900002"]'); await p.click('[data-archive-restore]'); await p.waitForTimeout(200);
    const back = await p.evaluate(() => !isArchivedTask(tasks.find((t) => t.id === 900002)));
    await p.click('[data-task-archive] summary').catch(() => {}); await p.evaluate(() => { const d = document.querySelector('[data-task-archive]'); if (d) d.open = true; });
    await p.check('[data-archive-task="900001"]'); await p.click('[data-archive-delete]'); await p.waitForTimeout(200);
    const gone = await p.evaluate(() => !tasks.some((t) => t.id === 900001));
    if (!back || !gone) throw new Error(`wieder da: ${back} · gelöscht: ${gone}`); return 'wiederhergestellt und gelöscht';
  });
  console.log(res.join('\n')); console.log(errs.length ? 'JS-Fehler:\n' + [...new Set(errs)].join('\n') : 'keine JS-Fehler'); await b.close();
})();
