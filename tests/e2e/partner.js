const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const OUT = require('./env').SP + '/audit/partner'; fs.mkdirSync(OUT, { recursive: true });
const { SP, ANON: ENV_ANON } = require('./env');
const ANON = ENV_ANON;
const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const TASK = `Abwesenheitskontrolle Dezember ${N}`, TID = 70000 + N;
const FIRM = `Nordic Hausservice ${N} AB`;
const P_EMAIL = `inhaber${N}@firma.test`, T_EMAIL = `technik${N}@firma.test`, PW = 'Husora!2026';
const sql = (q) => execSync(`psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -At -c "${q.replace(/"/g, '\\"')}"`).toString().trim();
(async () => {
  const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (name, fn) => { try { const r = await fn(); res.push(`OK   ${name}${r ? ' – ' + r : ''}`); } catch (e) { res.push(`FEHL ${name} – ${e.message.split('\n')[0].slice(0, 220)}`); } };
  const device = async (label, { onboarding = false } = {}) => {
    const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    const p = await ctx.newPage(); p.on('pageerror', (e) => errs.push(`${label}: ${e.message}`)); p.on('dialog', (d) => d.accept());
    await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
    await p.goto('http://127.0.0.1:8081/index.html');
    await p.evaluate(({ onboarding, url, key }) => { localStorage.clear(); if (!onboarding) localStorage.setItem('stugliv-onboarding', JSON.stringify({ status: 'done' })); localStorage.setItem('husora-cloud', JSON.stringify({ url, key })); }, { onboarding, url: URL_, key: ANON });
    await p.reload(); await p.waitForTimeout(500);
    return p;
  };
  const idle = (p) => p.waitForFunction(() => !pp.busy, null, { timeout: 30000 });
  const ownerIdle = (p) => p.waitForFunction(() => !ownerSide.busy && !cloudState.busy, null, { timeout: 30000 });
  const shot = (p, name) => p.screenshot({ path: `${OUT}/${name}.png` });

  // ---------- Hausbesitzer ----------
  const H = await device('H');
  await step('Hausbesitzer: anmelden und Daten hochladen', async () => {
    await H.evaluate(({ TID, TASK }) => { tasks = [...tasks, { id: TID, title: TASK, property: properties[0].name, propertyId: properties[0].id, date: localDateKey(new Date(Date.now() + 3 * 86400000)), priority: 'normal', status: 'Offen', done: false }]; persistTasks(); currentPage = 'settings'; settingsView = 'settings-data'; render(); }, { TID, TASK });
    await H.fill('[data-cloud-form=signin] [name=email]', 'admin@husora.test'); await H.fill('[data-cloud-form=signin] [name=password]', PW);
    await H.$eval('[data-cloud-form=signin] button[type=submit]', (e) => e.click()); await H.waitForFunction(() => cloudReady() && !cloudState.busy, null, { timeout: 20000 });
    await H.waitForTimeout(800);
    await H.$eval('[data-cloud-action=upload]', (e) => e.click());
    await H.waitForFunction(() => /hochgeladen/.test(cloudState.notice) || cloudState.error, null, { timeout: 30000 });
    const upErr = await H.evaluate(() => cloudState.error); if (upErr) throw new Error(upErr);
    return `${await H.evaluate(() => cloud.org.name)} · ${await H.evaluate(() => cloudState.notice.slice(0, 40))}`;
  });
  let CODE = '';
  await step('Hausbesitzer: Servicepartner einladen → Code', async () => {
    await H.evaluate(() => { currentPage = 'partnerHub'; hub.tab = 'partners'; render(); }); await H.waitForFunction(() => ownerSide.partners !== null && !ownerSide.busy, null, { timeout: 20000 }); await H.waitForTimeout(300);
    await H.fill('[data-owner-form=partner] [name=company_name]', FIRM); await H.fill('[data-owner-form=partner] [name=email]', P_EMAIL);
    await H.$eval('[data-owner-form=partner] button[type=submit]', (e) => e.click()); await ownerIdle(H); await H.waitForTimeout(300);
    CODE = await H.evaluate(() => ownerSide.code?.code || ownerSide.error);
    if (!/^HUS-/.test(CODE)) throw new Error(CODE);
    return CODE;
  });

  // ---------- Partner (Inhaber) ----------
  const P = await device('P', { onboarding: true });
  await step('Partner: Rollenwahl im Onboarding → Portal', async () => {
    await P.waitForSelector('#onboarding-modal.open', { timeout: 5000 }); await shot(P, 'onboarding-rollenwahl');
    await P.$eval('[data-ob-role=partner]', (e) => e.click()); await P.waitForTimeout(300);
    return `Portal offen: ${await P.evaluate(() => pp.open)} · Login sichtbar: ${Boolean(await P.$('[data-pp-form=login]'))}`;
  });
  await step('Partner: Konto erstellen', async () => {
    await P.fill('[data-pp-form=login] [name=email]', P_EMAIL); await P.fill('[data-pp-form=login] [name=password]', PW);
    await P.$eval('[data-pp-action=signup]', (e) => e.click()); await idle(P); await P.waitForTimeout(300);
    if (!(await P.$('[data-pp-form=company]'))) throw new Error(await P.evaluate(() => pp.error || pp.notice)); await shot(P, 'betrieb-anlegen');
  });
  await step('Partner: Betrieb anlegen (Onboarding-Daten)', async () => {
    const f = async (n, v) => P.fill(`[data-pp-form=company] [name=${n}]`, v);
    await f('name', FIRM); await f('legal_form', 'AB'); await f('contact_name', 'Nils Nordin'); await f('street', 'Storgatan 12'); await f('postal_code', '686 31'); await f('city', 'Sunne'); await f('phone', '+46 70 123 45 67'); await f('vat_id', 'SE559900112201'); await f('service_radius_km', '70');
    await P.$eval('[data-pp-form=company] [value=service_work]', (e) => { e.checked = true; });
    await P.$eval('[data-pp-form=company] button[type=submit]', (e) => e.click()); await idle(P); await P.waitForTimeout(500);
    const org = await P.evaluate(() => ppOrg()?.name); if (!org) throw new Error(await P.evaluate(() => pp.error));
    await shot(P, 'dashboard-leer');
    return `${org} · Rolle ${await P.evaluate(() => ppRole())} · ${await P.evaluate(() => ppD('templates').length)} Vorlagen · ${await P.evaluate(() => ppD('services').length)} Leistungen`;
  });
  await step('Partner: Einladungscode eingeben → Kunde verbunden', async () => {
    await P.$eval('[data-pp-view=customers]', (e) => e.click()); await P.waitForTimeout(200);
    await P.fill('[data-pp-form=invite-code] [name=code]', CODE.toLowerCase()); await P.$eval('[data-pp-form=invite-code] button[type=submit]', (e) => e.click()); await idle(P); await P.waitForTimeout(300);
    const links = await P.evaluate(() => pp.ctx.links.map((l) => l.organization_name).join(', ')); if (!links) throw new Error(await P.evaluate(() => pp.error));
    await shot(P, 'kunden'); return links;
  });

  // ---------- Hausbesitzer beauftragt ----------
  await step('Hausbesitzer: Aufgabe an verbundenen Partner senden', async () => {
    await H.evaluate(() => { currentPage = 'partnerHub'; hub.tab = 'orders'; render(); hubRefresh(); }); await ownerIdle(H); await H.waitForTimeout(300);
    await H.evaluate((FIRM) => { hub.partner = ownerSide.partners.find((p) => p.company_name === FIRM)?.id; hubRerender(); }, FIRM);
    const label = await H.evaluateHandle((TASK) => [...document.querySelectorAll('.hub-pick')].find((l) => l.textContent.includes(TASK) && !l.classList.contains('done')), TASK);
    if (!(await label.evaluate((l) => !!l))) throw new Error('Aufgabe fehlt: ' + await H.evaluate(() => ownerSide.error + ' tasks=' + ownerSide.tasks.length));
    await label.evaluate((l) => l.querySelector('input').click()); await H.waitForTimeout(150);
    await H.click('[data-hub-send-picked]'); await ownerIdle(H); await H.waitForTimeout(300);
    return await H.evaluate((FIRM) => ownerSide.orders.filter((o) => o.partner?.company_name === FIRM).map((o) => `${o.order_number} ${o.status}`).join(', ') || ownerSide.error, FIRM);
  });

  // ---------- Partner arbeitet ----------
  let ORDER = '';
  await step('Partner: neue Anfrage auf dem Dashboard', async () => {
    await P.$eval('[data-pp-action=reload]', (e) => e.click()); await idle(P); await P.$eval('[data-pp-view=dashboard]', (e) => e.click()); await P.waitForTimeout(200);
    ORDER = await P.evaluate((TASK) => ppD('orders').find((o) => o.title === TASK)?.id, TASK); if (!ORDER) throw new Error('kein Auftrag');
    await shot(P, 'dashboard'); return `Neue Anfragen: ${await P.evaluate(() => ppD('orders').filter((o) => o.status === 'offered').length)}`;
  });
  await step('Partner: Auftrag öffnen und annehmen (mit Termin)', async () => {
    await P.$eval(`[data-pp-open="order:${ORDER}"]`, (e) => e.click()); await P.waitForTimeout(200); await shot(P, 'auftrag-anfrage');
    await P.fill('[data-pp-field=accept-date]', new Date(Date.now() + 3 * 86400000 - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 11) + '09:00');
    await P.fill('[data-pp-field=accept-note]', 'Gerne, wir kommen um 9 Uhr.');
    await P.$eval(`[data-pp-action=accept][data-id="${ORDER}"]`, (e) => e.click()); await idle(P); await P.waitForTimeout(300);
    const stored = sql(`select to_char(scheduled_at, 'HH24:MI')||' '||coalesce(response_note,'') from service_orders where id='${ORDER}'`);
    if (!stored.startsWith('09:00') || !stored.includes('9 Uhr')) throw new Error('Termin/Notiz nicht übernommen: ' + stored);
    return await P.evaluate((id) => ppD('orders').find((o) => o.id === id).status + ' · ' + ppDateTime(ppD('orders').find((o) => o.id === id).scheduled_at), ORDER) + ' · DB ' + stored;
  });
  await step('Partner: Foto zum Auftrag hochladen', async () => {
    const png = await P.evaluate(() => { const c = document.createElement('canvas'); c.width = 320; c.height = 240; const g = c.getContext('2d'); g.fillStyle = '#7a4b2a'; g.fillRect(0, 0, 320, 240); g.fillStyle = '#fff'; g.fillText('Briefkasten', 20, 40); return c.toDataURL('image/png').split(',')[1]; });
    fs.writeFileSync(OUT + '/foto.png', Buffer.from(png, 'base64'));
    await P.setInputFiles(`[data-pp-upload="order:${ORDER}"][capture]`, OUT + '/foto.png'); await idle(P); await P.waitForTimeout(800);
    return `${await P.evaluate((id) => ppD('photos').filter((x) => x.service_order_id === id).length, ORDER)} Foto(s) · DB: ${sql(`select count(*) from photos where service_order_id='${ORDER}'`)}`;
  });
  await step('Partner: Nachricht an den Kunden', async () => {
    await P.fill('[data-pp-form=message] [name=message]', 'Schlüssel bitte im Tresor hinterlegen.'); await P.$eval('[data-pp-form=message] button[type=submit]', (e) => e.click()); await idle(P);
    return sql(`select count(*) from messages where service_order_id='${ORDER}'`) + ' Nachricht(en)';
  });
  let INSP = '';
  await step('Partner: Kontrolle aus dem Auftrag starten (Ferienhaus-Vorlage)', async () => {
    await P.$eval('[data-pp-field=tpl]', (e) => { e.value = [...e.options].find((o) => o.textContent.includes('Ferienhaus')).value; });
    await P.$eval('[data-pp-action=start-inspection]', (e) => e.click()); await idle(P); await P.waitForTimeout(300);
    INSP = await P.evaluate(() => pp.detail?.type === 'inspection' ? pp.detail.id : ''); if (!INSP) throw new Error(await P.evaluate(() => pp.error));
    return `${await P.evaluate((id) => ppD('inspections').find((i) => i.id === id).items.length, INSP)} Prüfpunkte`;
  });
  await step('Partner: Checkliste ausfüllen, Mangel mit Notiz', async () => {
    const ids = await P.evaluate((id) => ppD('inspections').find((i) => i.id === id).items.map((x) => [x.id, x.name]), INSP);
    for (const [itemId, name] of ids) { await P.$eval(`[data-pp-check="${itemId}"][data-status="${name.startsWith('Dach') ? 'defect' : 'ok'}"]`, (e) => e.click()); await P.waitForTimeout(15); }
    await P.waitForTimeout(800); await P.evaluate(() => ppRender());
    const dach = ids.find(([, n]) => n.startsWith('Dach'))[0];
    await P.fill(`[data-pp-note="${dach}"]`, 'Dachrinne an der Nordseite gerissen'); await P.$eval(`[data-pp-note="${dach}"]`, (e) => e.dispatchEvent(new Event('change', { bubbles: true })));
    await P.fill(`[data-pp-cost="${dach}"]`, '1800'); await P.$eval(`[data-pp-cost="${dach}"]`, (e) => e.dispatchEvent(new Event('change', { bubbles: true })));
    await P.waitForTimeout(800); await shot(P, 'kontrolle-checkliste');
    return `DB: ${sql(`select string_agg(status||'='||cnt, ', ') from (select status, count(*) cnt from inspection_items where inspection_id='${INSP}' group by status) x`)} · Status ${sql(`select status from inspections where id='${INSP}'`)}`;
  });
  await step('Partner: Kontrolle abschließen → Prüfbericht-PDF + Reparatur beim Kunden', async () => {
    await P.fill('[data-pp-field=summary]', 'Haus in gutem Zustand, Dachrinne muss repariert werden.');
    await P.$eval(`[data-pp-action=inspection-complete][data-id="${INSP}"]`, (e) => e.click()); await idle(P); await P.waitForTimeout(500);
    const doc = sql(`select file_name||' '||file_size from documents where inspection_id='${INSP}'`);
    const rep = sql(`select title||' ('||priority||')' from repairs where inspection_id='${INSP}'`);
    const obj = sql(`select count(*) from storage.objects where name like '%/inspections/%' and bucket_id='husora-documents'`);
    if (!doc) throw new Error('kein Bericht: ' + await P.evaluate(() => pp.error));
    const pdfPath = sql(`select storage_path from documents where inspection_id='${INSP}'`);
    return `Bericht ${doc} (Storage-Objekte: ${obj}) · Reparatur: ${rep || 'keine (Regel fehlt?)'}`;
  });
  await step('Partner: Rechnung zum Auftrag einreichen', async () => {
    await P.evaluate((id) => { pp.detail = { type: 'order', id }; ppRender(); }, ORDER);
    await P.$eval('[data-pp-action=finance-form][data-kind=invoice]', (e) => e.click()); await P.waitForTimeout(200);
    await P.fill('[data-pp-form=finance] [name=net]', '520'); await P.$eval('[data-pp-form=finance] button[type=submit]', (e) => e.click()); await idle(P);
    return sql(`select invoice_number||' '||amount_net||'+'||tax_amount||'='||amount_gross||' '||status from invoices where service_order_id='${ORDER}'`);
  });
  let TCODE = '';
  await step('Partner: Techniker einladen', async () => {
    await P.evaluate(() => { pp.view = 'team'; pp.detail = null; ppRender(); });
    await P.fill('[data-pp-form=member-invite] [name=email]', T_EMAIL); await P.$eval('[data-pp-form=member-invite] button[type=submit]', (e) => e.click()); await idle(P);
    TCODE = await P.evaluate(() => ppD('invites')[0]?.code); if (!TCODE) throw new Error(await P.evaluate(() => pp.error)); await shot(P, 'team'); return TCODE;
  });
  await step('Partner: eigener Kunde + Objekt + Auftrag', async () => {
    await P.evaluate(() => { pp.view = 'customers'; pp.detail = null; ppRender(); });
    await P.$eval('[data-pp-action=new-customer]', (e) => e.click()); await P.waitForTimeout(100);
    await P.fill('[data-pp-form=customer] [name=first_name]', 'Greta'); await P.fill('[data-pp-form=customer] [name=last_name]', 'Gärtner'); await P.fill('[data-pp-form=customer] [name=city]', 'Arvika');
    await P.$eval('[data-pp-form=customer] button[type=submit]', (e) => e.click()); await idle(P);
    const cid = await P.evaluate(() => ppD('customers').find((c) => c.last_name === 'Gärtner')?.id);
    await P.$eval(`[data-pp-open="customer:${cid}"]`, (e) => e.click()); await P.waitForTimeout(100);
    await P.fill('[data-pp-form=property] [name=name]', 'Villa Greta'); await P.$eval('[data-pp-form=property] button[type=submit]', (e) => e.click()); await idle(P); const perr = await P.evaluate(() => pp.error); if (perr) throw new Error('Objekt: ' + perr);
    await P.$eval('[data-pp-action=order-for]', (e) => e.click()); await P.waitForTimeout(100);
    await P.fill('[data-pp-form=new-order] [name=title]', 'Rasen mähen'); await P.fill('[data-pp-form=new-order] [name=estimated_cost]', '400');
    await P.$eval('[data-pp-form=new-order] button[type=submit]', (e) => e.click()); await idle(P);
    return `${await P.evaluate(() => pp.detail?.type)} · ${sql(`select title||' '||status from service_orders where title='Rasen mähen'`)}`;
  });

  // ---------- Techniker ----------
  const T = await device('T', { onboarding: false });
  await step('Techniker: Konto erstellen und Team beitreten', async () => {
    await T.evaluate(() => ppOpen('dashboard')); await T.waitForTimeout(200);
    await T.fill('[data-pp-form=login] [name=email]', T_EMAIL); await T.fill('[data-pp-form=login] [name=password]', PW);
    await T.$eval('[data-pp-action=signup]', (e) => e.click()); await idle(T); await T.waitForTimeout(200);
    await T.fill('[data-pp-form=join] [name=code]', TCODE); await T.$eval('[data-pp-form=join] button[type=submit]', (e) => e.click()); await idle(T); await T.waitForTimeout(300);
    return `${await T.evaluate(() => ppOrg()?.name)} · Rolle ${await T.evaluate(() => ppRole())} · sieht ${await T.evaluate(() => ppD('orders').length)} Aufträge`;
  });
  await step('Partner: Techniker dem Auftrag zuweisen', async () => {
    await P.$eval('[data-pp-action=reload]', (e) => e.click()); await idle(P);
    await P.evaluate((id) => { pp.detail = { type: 'order', id }; ppRender(); }, ORDER);
    const uid = await P.evaluate((email) => ppD('members').find((m) => m.user?.email === email)?.user_id, T_EMAIL);
    await P.selectOption(`[data-pp-assign="${ORDER}"]`, uid); await idle(P);
    return sql(`select u.email from service_orders o join users u on u.id=o.assigned_user_id where o.id='${ORDER}'`);
  });
  await step('Techniker: sieht nur den zugewiesenen Auftrag, startet und erledigt ihn', async () => {
    await T.$eval('[data-pp-action=reload]', (e) => e.click()); await idle(T);
    const titles = await T.evaluate(() => ppD('orders').map((o) => o.title)); if (titles.length !== 1) throw new Error('sieht: ' + titles.join(', '));
    await T.evaluate((id) => { pp.detail = { type: 'order', id }; ppRender(); }, ORDER);
    await T.$eval(`[data-pp-action=start][data-id="${ORDER}"]`, (e) => e.click()); await idle(T);
    await shot(T, 'techniker-auftrag');
    await T.fill('[data-pp-field=actual]', '650'); await T.fill('[data-pp-field=done-note]', 'Kontrolle durchgeführt, Briefkasten geleert.');
    await T.$eval(`[data-pp-action=complete][data-id="${ORDER}"]`, (e) => e.click()); await idle(T);
    return `${titles[0]} → ${sql(`select status||' '||actual_cost from service_orders where id='${ORDER}'`)} · Rechnungen sichtbar: ${await T.evaluate(() => ppD('invoices').length)}`;
  });

  // ---------- Hausbesitzer sieht Ergebnis ----------
  await step('Hausbesitzer: Status kommt an, lokale Aufgabe erledigt', async () => {
    await H.evaluate(() => { currentPage = 'partnerHub'; hub.tab = 'orders'; render(); hubRefresh(); }); await ownerIdle(H); await H.waitForTimeout(300);
    const local = await H.evaluate((TID) => taskStatus(tasks.find((t) => t.id === TID)), TID);
    return `Auftrag: ${await H.evaluate((TASK) => ownerSide.orders.find((o) => o.title === TASK)?.status, TASK)} · lokale Aufgabe: ${local}`;
  });
  await step('Hausbesitzer: nächster Upload überschreibt den Partner-Fortschritt nicht', async () => {
    await H.evaluate(() => { currentPage = 'settings'; render(); }); await H.$eval('[data-cloud-action=upload]', (e) => e.click()); await H.waitForFunction(() => !cloudState.busy, null, { timeout: 30000 });
    return sql(`select t.status from service_tasks t join service_orders o on o.service_task_id=t.id where o.id='${ORDER}'`);
  });
  await step('Fremde Firma sieht nichts davon (Datenbank)', async () => {
    const r = await fetch(`${URL_}/auth/v1/signup`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email: `fremd${N}@x.test`, password: PW }) }).then((x) => x.json());
    const h = { apikey: ANON, Authorization: `Bearer ${r.access_token}`, 'Content-Type': 'application/json' };
    await fetch(`${URL_}/rest/v1/rpc/create_partner_organization`, { method: 'POST', headers: h, body: JSON.stringify({ p_profile: { name: 'Fremd AB' } }) });
    const counts = await Promise.all(['service_orders', 'inspections', 'customers', 'photos', 'invoices', 'messages'].map((t) => fetch(`${URL_}/rest/v1/${t}?select=id`, { headers: h }).then((x) => x.json()).then((rows) => `${t}=${rows.length}`)));
    return counts.join(' ');
  });
  await P.evaluate(() => { pp.view = 'calendar'; pp.detail = null; ppRender(); }); await shot(P, 'kalender');
  await P.evaluate(() => { pp.view = 'documents'; ppRender(); }); await P.waitForTimeout(800); await shot(P, 'dokumente');
  await P.evaluate(() => { pp.view = 'dashboard'; ppRender(); }); await shot(P, 'dashboard-final');
  console.log(res.join('\n')); console.log(errs.length ? 'JS-Fehler:\n' + [...new Set(errs)].join('\n') : 'keine JS-Fehler'); await b.close();
})();
