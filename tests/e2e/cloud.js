const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const OUT = require('./env').SP + '/audit/cloud'; fs.mkdirSync(OUT, { recursive: true });
const { SP, ANON: ENV_ANON } = require('./env');
const ANON = ENV_ANON; const SRV = require('./env').SERVICE;
const URL_ = 'http://127.0.0.1:54321'; const EMAIL = `cloudtest${Date.now() % 100000}@husora.test`; const PW = 'Husora!2026';
const sql = (q) => execSync(`psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -At -c "${q.replace(/"/g, '\\"')}"`).toString().trim();
(async () => {
  const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (name, fn) => { try { const r = await fn(); res.push(`OK   ${name}${r ? ' – ' + r : ''}`); } catch (e) { res.push(`FEHL ${name} – ${e.message.split('\n')[0].slice(0, 200)}`); } };
  const device = async (label) => {
    const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    const p = await ctx.newPage(); p.on('pageerror', (e) => errs.push(`${label}: ${e.message}`)); p.on('dialog', (d) => d.accept());
    await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
    await p.goto('http://127.0.0.1:8081/index.html');
    await p.evaluate(() => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', JSON.stringify({ status: 'done' })); });
    await p.reload(); await p.waitForTimeout(400);
    if (label === 'A') res.push(`OK   Frische App: mit Husora-Projekt vorverbunden – ${await p.evaluate(() => `${cloudConnected()} · ${cloud.url}`)}`);
    await p.evaluate(() => { localStorage.setItem('husora-cloud', JSON.stringify({ url: '', key: '', disconnected: true })); }); await p.reload(); await p.waitForTimeout(300);
    return p;
  };
  const openCloud = (p) => p.evaluate(() => { currentPage = 'settings'; settingsView = 'settings-data'; render(); });
  const waitIdle = (p) => p.waitForFunction(() => !cloudState.busy, null, { timeout: 20000 });
  const A = await device('A');
  await step('A: Testdaten anlegen', async () => {
    await A.evaluate(() => {
      const d = new Date(); d.setDate(d.getDate() + 5); const s = localDateKey(d); d.setDate(d.getDate() + 4); const e = localDateKey(d);
      bookings.push({ id: 'b-cloud', propertyId: properties[0].id, guestName: 'Familie Wolke', startDate: s, endDate: e, guestCount: 4, arrivalTime: '16:00' }); persistBookings(bookings);
      const png = 'data:image/png;base64,' + 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
      const jpg = (c) => { const cv = document.createElement('canvas'); cv.width = 64; cv.height = 48; const g = cv.getContext('2d'); g.fillStyle = c; g.fillRect(0, 0, 64, 48); return cv.toDataURL('image/jpeg', 0.9); };
      const pdf = 'data:application/pdf;base64,' + btoa('%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n' + 'x'.repeat(400));
      properties = properties.map((pr, i) => (i ? pr : { ...pr, photo: jpg('#2d6a4f'), photos: [jpg('#2d6a4f'), jpg('#b5651d')] })); localStorage.setItem('stugliv-properties', JSON.stringify(properties));
      persistDocuments([{ id: 'doc-pdf', propertyId: properties[0].id, name: 'Versicherung-2026.pdf', type: 'application/pdf', size: 500, dataUrl: pdf, category: 'insurance', createdIso: s }, { id: 'doc-img', propertyId: properties[0].id, name: 'Zaehler.png', type: 'image/png', size: 70, dataUrl: png + 'A'.repeat(0), category: 'other', createdIso: s }]);
      tasks = [...tasks, { id: 991, title: 'Cloud-Testaufgabe', property: properties[0].name, propertyId: properties[0].id, date: s, priority: 'soon', status: 'Offen', done: false }]; persistTasks();
    });
    return `${await A.evaluate(() => properties.length)} Haus, ${await A.evaluate(() => bookings.length)} Buchung, ${await A.evaluate(() => tasks.length)} Aufgaben`;
  });
  await step('A: geheimer service_role-Key wird abgewiesen', async () => {
    await openCloud(A); await A.fill('[data-cloud-form=connect] [name=url]', URL_); await A.fill('[data-cloud-form=connect] [name=key]', SRV);
    await A.$eval('[data-cloud-form=connect] button[type=submit]', (e) => e.click()); await waitIdle(A);
    const err = await A.evaluate(() => cloudState.error); if (!/geheime/.test(err)) throw new Error('nicht abgewiesen: ' + err); return err.slice(0, 60);
  });
  await step('A: mit Supabase verbinden', async () => {
    await A.fill('[data-cloud-form=connect] [name=url]', URL_ + '/'); await A.fill('[data-cloud-form=connect] [name=key]', ANON);
    await A.$eval('[data-cloud-form=connect] button[type=submit]', (e) => e.click()); await waitIdle(A);
    if (!(await A.$('[data-cloud-form=signin]'))) throw new Error(await A.evaluate(() => cloudState.error)); return await A.evaluate(() => cloudState.notice);
  });
  await step('A: falsches Passwort → verständliche Meldung', async () => {
    await A.fill('[data-cloud-form=signin] [name=email]', EMAIL); await A.fill('[data-cloud-form=signin] [name=password]', 'falsch123');
    await A.$eval('[data-cloud-form=signin] button[type=submit]', (e) => e.click()); await waitIdle(A); return await A.evaluate(() => cloudState.error);
  });
  await step('A: Konto erstellen (Organisation wird angelegt)', async () => {
    await A.fill('[data-cloud-form=signin] [name=email]', EMAIL); await A.fill('[data-cloud-form=signin] [name=password]', PW);
    await A.$eval('[data-cloud-action=signup]', (e) => e.click()); await waitIdle(A);
    const org = await A.evaluate(() => cloud.org); if (!org?.id) throw new Error(await A.evaluate(() => cloudState.error)); await A.screenshot({ path: OUT + '/1-angemeldet.png', fullPage: false });
    return `${org.name} (${org.role})`;
  });
  await step('A: alles hochladen', async () => {
    await A.$eval('[data-cloud-action=upload]', (e) => e.click()); await waitIdle(A);
    const n = await A.evaluate(() => cloudState.notice); if (!/hochgeladen/.test(n)) throw new Error(await A.evaluate(() => cloudState.error)); return n;
  });
  const org = await A.evaluate(() => cloud.org.id);
  await step('DB: komplette App-Daten in app_data', async () => {
    const local = await A.evaluate(() => cloudLocalEntries().length); const cloudCount = sql(`select count(*) from app_data where organization_id='${org}'`);
    if (String(local) !== cloudCount) throw new Error(`lokal ${local}, Cloud ${cloudCount}`); return `${cloudCount} Bereiche, ${sql(`select pg_size_pretty(sum(size_bytes)::bigint) from app_data where organization_id='${org}'`)}`;
  });
  await step('DB: Häuser/Buchungen/Aufgaben in Fachtabellen', async () => {
    const r = sql(`select (select count(*) from properties where organization_id='${org}' and app_ref is not null)||' Häuser, '||(select count(*) from bookings where organization_id='${org}' and app_ref is not null)||' Buchungen, '||(select count(*) from service_tasks where organization_id='${org}' and app_ref is not null)||' Aufgaben'`);
    const status = sql(`select string_agg(key||': '||projection_status, ' | ' order by key) from app_data where organization_id='${org}' and projection_status is not null`);
    const b = sql(`select guest_first_name||'/'||guest_last_name||' '||to_char(check_in at time zone 'Europe/Stockholm','YYYY-MM-DD HH24:MI')||' '||source||' '||status from bookings where app_ref='b-cloud'`);
    const t = sql(`select title||' '||priority||' '||status from service_tasks where app_ref='991'`);
    if (!b || !t) throw new Error('Buchung oder Aufgabe fehlt: ' + status); return `${r} · ${b} · ${t}`;
  });
  await step('Storage: Dateien als echte Objekte, in app_data nur Verweise', async () => {
    const objs = sql(`select string_agg(bucket_id||':'||regexp_replace(name,'^organization/[^/]+/',''),' | ' order by name) from storage.objects where name like 'organization/${org}/%'`);
    const inline = sql(`select count(*) from app_data where organization_id='${org}' and value like '%data:image%' or (organization_id='${org}' and value like '%data:application%')`);
    if (!objs || inline !== '0') throw new Error(`Objekte: ${objs} · noch eingebettet: ${inline}`);
    return objs.replace(/[0-9a-f]{40}/g, '…').replace(/[0-9a-f-]{36}/g, '{haus}');
  });
  await step('DB: Metadaten in documents/photos', async () => sql(`select (select string_agg(file_name||' → '||document_type||' ('||storage_bucket||')', ', ') from documents where organization_id='${org}')||' · '||(select count(*) from photos where organization_id='${org}')||' Hausfotos'`));
  await step('App: Speicheranzeige (frei)', async () => { await openCloud(A); await A.waitForTimeout(300); const t = await A.$$eval('.cloud-usage .storage-meter-top', (els) => els.map((e) => e.textContent.trim())); if (!t.length) throw new Error('keine Anzeige'); return t.join(' | '); });
  await step('DB: keine Automationen für App-Buchungen (keine Doppel-Aufgaben)', async () => sql(`select count(*) from automation_runs where organization_id='${org}'`) + ' Läufe');
  await step('A: automatische Synchronisierung einer Änderung', async () => {
    await A.evaluate(() => { tasks = [...tasks, { id: 992, title: 'Nachträgliche Aufgabe', property: properties[0].name, propertyId: properties[0].id, date: localDateKey(new Date()), priority: 'urgent', status: 'Offen', done: false }]; persistTasks(); });
    await A.waitForFunction(() => cloudDirty.size === 0 && !cloudState.busy, null, { timeout: 15000 });
    const t = sql(`select title||' '||priority from service_tasks where app_ref='992'`); if (!t) throw new Error('nicht in der DB'); return `${t} · ${await A.evaluate(() => cloudStatusText())}`;
  });
  await step('A: Aufgabe löschen wird übernommen', async () => {
    await A.evaluate(() => { tasks = tasks.filter((t) => t.id !== 992); persistTasks(); }); await A.waitForFunction(() => cloudDirty.size === 0 && !cloudState.busy, null, { timeout: 15000 });
    return sql(`select count(*) from service_tasks where app_ref='992'`) === '0' ? 'gelöscht' : (() => { throw new Error('noch vorhanden'); })();
  });
  await openCloud(A); await A.waitForTimeout(300); await A.screenshot({ path: OUT + '/2-synchronisiert.png', fullPage: false });
  const cardA = await A.$('#settings-cloud'); if (cardA) await cardA.screenshot({ path: OUT + '/karte.png' });
  // Gerät B
  const B = await device('B');
  await step('B: verbinden + anmelden', async () => {
    await openCloud(B); await B.fill('[data-cloud-form=connect] [name=url]', URL_); await B.fill('[data-cloud-form=connect] [name=key]', ANON);
    await B.$eval('[data-cloud-form=connect] button[type=submit]', (e) => e.click()); await waitIdle(B);
    await B.fill('[data-cloud-form=signin] [name=email]', EMAIL); await B.fill('[data-cloud-form=signin] [name=password]', PW);
    await B.$eval('[data-cloud-form=signin] button[type=submit]', (e) => e.click()); await waitIdle(B);
    const s = await B.evaluate(() => cloudState.summary); if (!s?.count) throw new Error(await B.evaluate(() => cloudState.error)); return `${s.count} Bereiche in der Cloud · ${await B.evaluate(() => cloudState.notice)}`;
  });
  await step('B: aus der Cloud laden', async () => {
    await B.$eval('[data-cloud-action=download]', (e) => e.click()); await B.waitForLoadState('load'); await B.waitForTimeout(800);
    const has = await B.evaluate(() => ({ t: tasks.some((t) => t.title === 'Cloud-Testaufgabe'), b: bookings.some((x) => x.id === 'b-cloud'), n: tasks.length }));
    const files = await B.evaluate(() => ({ photo: (properties[0].photo || '').slice(0, 15), photos: (properties[0].photos || []).filter((x) => x.startsWith('data:image')).length, docs: documents.filter((d) => String(d.dataUrl).startsWith('data:')).map((d) => d.name).join('+') }));
    has.files = files; if (!files.photo.startsWith('data:image') || files.photos !== 2 || !files.docs.includes('Versicherung')) throw new Error('Dateien fehlen: ' + JSON.stringify(files));
    if (!has.t || !has.b) throw new Error(JSON.stringify(has)); return `${has.n} Aufgaben, Buchung, Dateien ${JSON.stringify(has.files)}, Toast: ${await B.evaluate(() => document.querySelector('.toast')?.textContent || '')}`;
  });
  await step('B: Änderung → A erkennt neuere Cloud-Daten', async () => {
    await B.evaluate(() => { tasks = tasks.map((t) => (t.id === 991 ? { ...t, done: true, status: 'Erledigt' } : t)); persistTasks(); });
    await B.waitForFunction(() => cloudDirty.size === 0 && !cloudState.busy, null, { timeout: 15000 });
    await A.reload(); await A.waitForTimeout(1500);
    const st = sql(`select status from service_tasks where app_ref='991'`);
    return `DB-Status: ${st} · A: remoteNewer=${await A.evaluate(() => cloudState.remoteNewer)} · „${await A.evaluate(() => cloudStatusText())}“`;
  });
  await step('A: blockiert Auto-Upload, solange Cloud neuer ist', async () => {
    await A.evaluate(() => { tasks = [...tasks, { id: 993, title: 'Konflikt', property: properties[0].name, propertyId: properties[0].id, date: localDateKey(new Date()), priority: 'normal', status: 'Offen', done: false }]; persistTasks(); });
    await A.waitForTimeout(5500); return sql(`select count(*) from service_tasks where app_ref='993'`) === '0' ? 'nicht hochgeladen (richtig)' : 'hochgeladen (falsch)';
  });
  await step('RLS: anderes Konto kommt nicht an die Dateien', async () => {
    const r = await fetch(`${URL_}/auth/v1/signup`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email: 'y' + EMAIL, password: PW }) }).then((x) => x.json());
    const name = sql(`select bucket_id||'/'||name from storage.objects where name like 'organization/${org}/%' limit 1`);
    const own = await fetch(`${URL_}/storage/v1/object/authenticated/${name}`, { headers: { apikey: ANON, Authorization: `Bearer ${r.access_token}` } }).then((x) => x.status);
    const pub = await fetch(`${URL_}/storage/v1/object/public/${name}`).then((x) => x.status);
    return `fremdes Konto: HTTP ${own}, öffentlicher Link: HTTP ${pub}`;
  });
  await step('RLS: anderes Konto sieht diese Daten nicht', async () => {
    const r = await fetch(`${URL_}/auth/v1/signup`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email: 'x' + EMAIL, password: PW }) }).then((x) => x.json());
    const rows = await fetch(`${URL_}/rest/v1/app_data?select=key`, { headers: { apikey: ANON, Authorization: `Bearer ${r.access_token}` } }).then((x) => x.json());
    const anon = await fetch(`${URL_}/rest/v1/app_data?select=key`, { headers: { apikey: ANON } }).then((x) => x.status);
    return `fremdes Konto: ${rows.length} Zeilen, anon: HTTP ${anon}`;
  });
  await step('A: abmelden', async () => { await openCloud(A); await A.$eval('[data-cloud-action=signout]', (e) => e.click()); await A.waitForTimeout(200); return (await A.$('[data-cloud-form=signin]')) ? 'Anmeldeformular sichtbar' : 'fehlt'; });
  console.log(res.join('\n')); console.log(errs.length ? 'JS-Fehler:\n' + [...new Set(errs)].join('\n') : 'keine JS-Fehler'); await b.close();
})();
