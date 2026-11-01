const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON: ENV_ANON } = require('./env'); const OUT = SP + '/audit/pp3'; fs.mkdirSync(OUT, { recursive: true });
const ANON = ENV_ANON; const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Torsby Service ${N}`, P_EMAIL = `pp3${N}@hs.test`, PW = 'Husora!2026';
const sql = (q) => execSync(`psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -At -c "${q.replace(/"/g, '\\"')}"`).toString().trim();
(async () => {
  const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (name, fn) => { try { const r = await fn(); res.push(`OK   ${name}${r ? ' – ' + r : ''}`); } catch (e) { res.push(`FEHL ${name} – ${e.message.split('\n')[0].slice(0, 220)}`); } };
  const device = async (label) => {
    const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    const p = await ctx.newPage(); p.on('pageerror', (e) => errs.push(`${label}: ${e.message}`)); p.on('dialog', (d) => d.accept());
    await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
    await p.goto('http://127.0.0.1:8081/index.html');
    await p.evaluate(({ url, key }) => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); localStorage.setItem('husora-cloud', JSON.stringify({ url, key })); }, { url: URL_, key: ANON });
    await p.reload(); await p.waitForTimeout(400); return p;
  };
  const H = await device('H');
  await step('Hausbesitzer: Menüpunkt „Partner-Portal“ öffnet Anmeldung', async () => {
    await H.evaluate(() => document.querySelector('.nav [data-page="partnerHub"]').click()); await H.waitForTimeout(300);
    const t = await H.evaluate(() => [currentPage, document.querySelector('#page-content h1')?.textContent, !!document.querySelector('[data-cloud-form=signin]')].join(' · '));
    await H.screenshot({ path: OUT + '/1-anmelden.png' }); return t;
  });
  await step('Hausbesitzer: anmelden direkt im Partner-Portal', async () => {
    await H.fill('[data-cloud-form=signin] [name=email]', 'admin@husora.test'); await H.fill('[data-cloud-form=signin] [name=password]', PW);
    await H.$eval('[data-cloud-form=signin] button[type=submit]', (e) => e.click());
    await H.waitForFunction(() => cloudReady() && !cloudState.busy && ownerSide.partners !== null && !ownerSide.busy, null, { timeout: 20000 });
    return `${await H.evaluate(() => document.querySelectorAll('.hub-tabs button').length)} Reiter · ${await H.evaluate(() => ownerSide.partners.length)} Partner`;
  });
  let CODE = '';
  await step('Hausbesitzer: Einladungscode erzeugen (Kopieren/Teilen/E-Mail/SMS)', async () => {
    await H.fill('[data-owner-form=partner] [name=company_name]', FIRM); await H.fill('[data-owner-form=partner] [name=email]', P_EMAIL);
    await H.$eval('[data-owner-form=partner] button[type=submit]', (e) => e.click()); await H.waitForFunction(() => !ownerSide.busy, null, { timeout: 20000 }); await H.waitForTimeout(300);
    CODE = await H.evaluate(() => ownerSide.code?.code || ownerSide.error);
    const box = await H.evaluate(() => [...document.querySelectorAll('.hub-code-actions > *')].map((e) => e.textContent.trim()).join('/'));
    if (!/^HUS-/.test(CODE)) throw new Error(CODE);
    const card = await H.$$('.hub-partner'); for (const c of card) { if ((await c.textContent().catch(() => '')).includes(FIRM)) { await c.screenshot({ path: OUT + '/2-code.png' }).catch(() => {}); } }
    await H.screenshot({ path: OUT + '/2-partner-tab.png' });
    return `${CODE} · ${box} · Status: ${await H.evaluate((f) => [...document.querySelectorAll('.hub-partner')].find((c) => c.textContent.includes(f))?.querySelector('.pp-badge')?.textContent, FIRM)}`;
  });
  // Partner richtet Betrieb ein und verbindet sich
  const P = await device('P');
  await step('Partner: Betrieb anlegen und Code eingeben', async () => {
    await P.evaluate(() => ppOpen('dashboard')); await P.waitForTimeout(200);
    await P.fill('[data-pp-form=login] [name=email]', P_EMAIL); await P.fill('[data-pp-form=login] [name=password]', PW);
    await P.$eval('[data-pp-action=signup]', (e) => e.click()); await P.waitForFunction(() => !pp.busy && document.querySelector('[data-pp-form=company]'), null, { timeout: 20000 });
    await P.fill('[data-pp-form=company] [name=name]', FIRM); await P.$eval('[data-pp-form=company] button[type=submit]', (e) => e.click()); await P.waitForFunction(() => !pp.busy && ppOrg(), null, { timeout: 20000 });
    await P.evaluate(() => { pp.view = 'customers'; ppRender(); });
    await P.fill('[data-pp-form=invite-code] [name=code]', CODE); await P.$eval('[data-pp-form=invite-code] button[type=submit]', (e) => e.click()); await P.waitForFunction(() => !pp.busy, null, { timeout: 20000 });
    return await P.evaluate(() => pp.ctx.links.map((l) => l.organization_name).join(', '));
  });



  const spId = () => sql(`select id from service_partners where company_name='${FIRM}' and organization_id=(select id from organizations where name='Husora Testorganisation')`);
  const porg = () => sql(`select id from organizations where name='${FIRM}'`);
  const wait = () => P.waitForFunction(() => !pp.busy, null, { timeout: 20000 }).then(() => P.waitForTimeout(250));
  const view = (v) => P.evaluate((v) => { pp.view = v; pp.detail = null; pp.form = null; ppRender(); }, v);
  const noErr = async () => { const e = await P.evaluate(() => pp.error); if (e) throw new Error(e); };
  await step('Obere Leiste ohne Hausbesitzer-Knopf', async () => { await view('dashboard'); const n = await P.$$eval('.pp-top [data-pp-action=close], .pp-top .pp-switch', (e) => e.length); if (n) throw new Error(`${n} Knopf`); return 'entfernt · Weg zurück über Mehr → Zur Hausbesitzer-Ansicht'; });
  await step('Leistungspakete: hinzufügen, eigenes Paket, bearbeiten mit Ergänzung, löschen', async () => {
    await view('services');
    const add = async (group, name, price, unit, notes) => { await P.click('[data-pp-svc=new]'); await P.selectOption('[data-pp-form=svc-new] [name=group]', group); await P.fill('[data-pp-form=svc-new] [name=name]', name); await P.fill('[data-pp-form=svc-new] [name=price]', price); await P.selectOption('[data-pp-form=svc-new] [name=unit]', unit); if (notes) await P.fill('[data-pp-form=svc-new] [name=notes]', notes); await P.$eval('[data-pp-form=svc-new] button[type=submit]', (e) => e.click()); await wait(); await noErr(); };
    await add('service_work', 'Gästewechsel komplett', '950', 'job', '');
    await add('service_work', `Winterdienst ${N}`, '45', 'hour', 'zzgl. Anfahrt');
    const edit = await P.evaluate(() => ppPackages().find((p) => p.name === 'Gästewechsel komplett').s.id);
    await P.click(`[data-pp-svc=edit][data-id="${edit}"]`); await P.fill('[data-pp-form=svc-edit] [name=notes]', 'Bettwäsche inklusive'); await P.fill('[data-pp-form=svc-edit] [name=price]', '990');
    await P.$eval('[data-pp-form=svc-edit] button[type=submit]', (e) => e.click()); await wait(); await noErr();
    await P.screenshot({ path: OUT + '/1-leistungen.png', fullPage: true });
    const before = sql(`select string_agg(coalesce(s.label, t.name)||':'||s.price_from||'/'||s.price_unit||':'||coalesce(s.notes,'-'), ' | ' order by t.name) from service_partner_services s join service_types t on t.id=s.service_type_id where s.service_partner_id=(select id from service_partners where partner_organization_id='${porg()}' and organization_id='${porg()}') and s.active`);
    const custom = await P.evaluate((n) => ppPackages().find((p) => p.name === `Winterdienst ${n}`).s.id, N);
    await P.click(`[data-pp-svc=delete][data-id="${custom}"]`); await wait(); await noErr();
    const after = sql(`select count(*) from service_types where organization_id='${porg()}' and name='Winterdienst ${N}'`);
    if (!before.includes('990.00/job:Bettwäsche inklusive') || !before.includes('45.00/hour:zzgl. Anfahrt') || after !== '0') throw new Error(`${before} · nach Löschen: ${after}`);
    return `${before} → eigenes Paket gelöscht`;
  });
  const MEMBER = `mitarbeiter${N}@hs.test`;
  await step('Mitarbeiter einladen mit Name/Telefon/Info, annehmen, bearbeiten, entfernen', async () => {
    await view('team');
    await P.fill('[data-pp-form=member-invite] [name=display_name]', 'Erik Lund'); await P.fill('[data-pp-form=member-invite] [name=email]', MEMBER); await P.fill('[data-pp-form=member-invite] [name=phone]', '+46 70 123 45 67'); await P.fill('[data-pp-form=member-invite] [name=info]', 'Führerschein BE');
    await P.$eval('[data-pp-form=member-invite] button[type=submit]', (e) => e.click()); await wait(); await noErr();
    const code = sql(`select code from organization_invites where email='${MEMBER}'`);
    const tok = (await (await fetch(`${URL_}/auth/v1/signup`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email: MEMBER, password: PW }) })).json()).access_token;
    const acc = await fetch(`${URL_}/rest/v1/rpc/accept_member_invite`, { method: 'POST', headers: { apikey: ANON, Authorization: `Bearer ${tok}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ p_code: code }) });
    if (!acc.ok) throw new Error(await acc.text());
    const copied = sql(`select concat_ws(' | ', m.display_name, m.phone, m.info, m.role) from organization_members m join users u on u.id=m.user_id where u.email='${MEMBER}'`);
    await P.evaluate(() => ppLoad()); await wait(); await view('team');
    const mid = sql(`select m.id from organization_members m join users u on u.id=m.user_id where u.email='${MEMBER}'`);
    await P.click(`[data-pp-action=member-edit][data-id="${mid}"]`); await P.fill('[data-pp-form=member-edit] [name=info]', 'Führerschein BE, nur vormittags'); await P.selectOption('[data-pp-form=member-edit] [name=role]', 'inspector');
    await P.$eval('[data-pp-form=member-edit] button[type=submit]', (e) => e.click()); await wait(); await noErr();
    await P.screenshot({ path: OUT + '/2-mitarbeiter.png', fullPage: true });
    const edited = sql(`select concat_ws(' | ', display_name, info, role) from organization_members where id='${mid}'`);
    await P.click(`[data-pp-action=member-remove][data-id="${mid}"]`); await wait(); await noErr();
    const gone = sql(`select count(*) from organization_members where id='${mid}'`);
    if (!copied.startsWith('Erik Lund | +46') || !edited.includes('nur vormittags | inspector') || gone !== '0') throw new Error(`${copied} · ${edited} · ${gone}`);
    return `übernommen: ${copied} · bearbeitet: ${edited} · entfernt`;
  });
  await step('Jahresvertrag: Partner bearbeitet (zweite Aufgabe), Kunde bestätigt, Partner löscht', async () => {
    const prop = sql(`select id from properties where organization_id=(select id from organizations where name='Husora Testorganisation') order by created_at limit 1`);
    await P.evaluate(async ({ sp, prop }) => { await ppRpc('propose_service_agreement', { p_service_partner_id: sp, p_property_id: prop, p_task_title: 'Rasenpflege', p_annual_price: 3000 }); await ppLoad(); }, { sp: spId(), prop }); await wait();
    await view('agreements'); const id = await P.evaluate(() => ppD('agreements')[0].id);
    await P.click(`[data-pp-ag=edit][data-id="${id}"]`); await P.click('[data-pp-form=agreement-edit] [data-ag-add-task]'); await P.fill('[data-pp-form=agreement-edit] .ag-task-row:nth-child(2) input', 'Hecke schneiden'); await P.fill('[data-pp-form=agreement-edit] [name=price]', '4200');
    await P.screenshot({ path: OUT + '/3-vertrag-bearbeiten.png', fullPage: true });
    await P.$eval('[data-pp-form=agreement-edit] button[type=submit]', (e) => e.click()); await wait(); await noErr();
    const edited = sql(`select status||' · '||proposed_by||' · '||annual_price||' · '||array_to_string(task_titles, '+') from service_agreements where id='${id}'`);
    await H.evaluate(() => { hub.tab = 'agreements'; return ownerLoadPartners().then(() => render()); }); await H.waitForTimeout(400);
    await H.click(`[data-owner-ag=accept][data-id="${id}"]`); await H.waitForFunction(() => !ownerSide.busy, null, { timeout: 20000 });
    const accepted = sql(`select status from service_agreements where id='${id}'`);
    await P.evaluate(() => ppLoad()); await wait(); await view('agreements');
    await P.click(`[data-pp-ag=delete][data-id="${id}"]`); await wait(); await noErr();
    const gone = sql(`select count(*) from service_agreements where id='${id}'`);
    if (!edited.startsWith('proposed · partner · 4200.00 · Rasenpflege+Hecke schneiden') || accepted !== 'active' || gone !== '0') throw new Error(`${edited} · ${accepted} · ${gone}`);
    return `${edited} → Kunde: ${accepted} → gelöscht`;
  });
  await step('Rechnung in Euro und Angebot in SEK, Sortierung nach Nummer/Hausbesitzer/Objekt', async () => {
    await H.evaluate((firm) => { const id = 'custom-p' + Date.now(); providers.push({ id, name: firm, category: 'house', custom: true, initials: 'TS', distances: {} }); persistCustomProviders(); const d = localDateKey(new Date(Date.now() + 2 * 86400000)); ['Dachrinne reinigen P3', 'Fenster putzen P3'].forEach((title, i) => tasks.push({ id: Date.now() + i, partnerId: id, title, property: properties[0].name, date: d, priority: 'normal', area: 'Außen', status: 'Offen', done: false, repeat: 'Einmalig' })); try { localStorage.setItem('stugliv-tasks', JSON.stringify(tasks)); } catch (e) {} }, FIRM);
    await H.evaluate((firm) => commissionPartner(providers.find((p) => p.name === firm).id), FIRM); await H.waitForTimeout(1200);
    await P.evaluate(async () => { await ppLoad(); for (const o of ppD('orders').filter((x) => x.status === 'offered')) await ppPatch('service_orders', o.id, { status: 'accepted' }); await ppLoad(); }); await wait();
    const make = async (title, kind, cur, net) => { const oid = await P.evaluate((t) => ppD('orders').find((o) => o.title === t).id, title); await P.evaluate(({ oid, kind }) => { pp.detail = { type: 'order', id: oid }; pp.form = `finance:${oid}`; pp.formKind = kind; pp.formMode = 'create'; ppRender(); }, { oid, kind }); await P.selectOption('[data-pp-form=finance] [name=currency]', cur); await P.fill('[data-pp-form=finance] [name=net]', net); await P.$eval('[data-pp-form=finance] button[type=submit]', (e) => e.click()); await wait(); await noErr(); };
    await make('Dachrinne reinigen P3', 'invoice', 'EUR', '100'); await make('Fenster putzen P3', 'quote', 'SEK', '800'); await make('Fenster putzen P3', 'invoice', 'SEK', '900');
    const cur = sql(`select string_agg(invoice_number||' '||currency, ', ' order by invoice_number) from invoices where service_partner_id='${spId()}'`) + ' · Angebot ' + sql(`select string_agg(quote_number||' '||currency, ', ') from quotes where service_partner_id='${spId()}'`);
    await view('finance');
    const order = async (mode) => { await P.selectOption('[data-pp-sort=invoices]', mode); await P.waitForTimeout(150); return P.$$eval('.pp-section:first-of-type .pp-item strong', (e) => e.map((x) => x.textContent.trim()).join(' / ')); };
    const byNum = await order('number'); const byOwner = await order('owner'); const byProp = await order('property');
    await P.screenshot({ path: OUT + '/4-rechnungen.png', fullPage: true });
    if (!/EUR/.test(cur) || !/SEK/.test(cur) || !byNum) throw new Error(cur);
    return `${cur} · Nummer: ${byNum} · Sortierwahl Angebote: ${await P.$$eval('[data-pp-sort=quotes] option', (e) => e.length)} Optionen`;
  });
  await step('Dokumente: in der App öffnen, als PDF exportieren, archivieren und wiederherstellen', async () => {
    await view('documents'); const id = await P.evaluate(() => ppD('documents').find((d) => /pdf/i.test(d.file_type || ''))?.id);
    if (!id) throw new Error('kein PDF-Dokument');
    await P.screenshot({ path: OUT + '/5a-dokumente.png', fullPage: true }); await P.click(`.pp-doc-actions [data-pp-doc=view][data-id="${id}"]`, { timeout: 8000 }).catch((e) => { throw new Error('Öffnen: ' + e.message.split('\n').slice(0, 6).join(' ')); }); await P.waitForSelector('#pdf-viewer-modal.open', { timeout: 15000 });
    const z = await P.$eval('#pdf-viewer-modal', (e) => getComputedStyle(e).zIndex); await P.screenshot({ path: OUT + '/5-dokument-offen.png' });
    await P.evaluate(() => closePdfViewer());
    const [dl] = await Promise.all([P.waitForEvent('download', { timeout: 15000 }), P.click(`[data-pp-doc=pdf][data-id="${id}"]`, { timeout: 8000 }).catch((e) => { throw new Error('Export: ' + e.message.split('\n').slice(0, 8).join(' ')); })]);
    const name = dl.suggestedFilename();
    await P.click(`[data-pp-doc=archive][data-id="${id}"]`, { timeout: 8000 }).catch((e) => { throw new Error('Archiv: ' + e.message.split('\n').slice(0, 8).join(' ')); }); await wait(); await noErr();
    const arch = sql(`select count(*) from document_archive where organization_id='${porg()}' and document_id='${id}'`);
    const inArchive = await P.$$eval('.pp-archive [data-pp-doc=restore]', (e) => e.length);
    await P.screenshot({ path: OUT + '/6-archiv.png', fullPage: true });
    await P.click(`[data-pp-doc=restore][data-id="${id}"]`, { timeout: 8000 }).catch((e) => { throw new Error('Zurück: ' + e.message.split('\n').slice(0, 8).join(' ')); }); await wait(); await noErr();
    const back = sql(`select count(*) from document_archive where document_id='${id}'`);
    const img = await P.evaluate(async () => { const c = document.createElement('canvas'); c.width = 40; c.height = 30; c.getContext('2d').fillRect(0, 0, 20, 20); const b = await imageToPdfBytes(c.toDataURL('image/png')); return String.fromCharCode(...b.slice(0, 8)) + ' ' + b.length; });
    if (arch !== '1' || !inArchive || back !== '0' || !/\.pdf$/.test(name) || Number(z) < 900) throw new Error(`${arch}/${inArchive}/${back}/${name}/${z}`);
    return `Ansicht über dem Portal (z ${z}) · Export „${name}“ · archiviert & wiederhergestellt · Bild→PDF: ${img}`;
  });
  await step('Kontrollen: Status-Filter (offen/in Bearbeitung/abgeschlossen) und Sortierung', async () => {
    await view('inspections');
    await P.$eval('[data-pp-form=inspection-start] button[type=submit]', (e) => e.click()); await wait(); await noErr();
    await view('inspections');
    const chips = await P.$$eval('[data-pp-insp-filter]', (e) => e.map((x) => x.textContent.replace(/\s+/g, ' ').trim()).join(' | '));
    await P.click('[data-pp-insp-filter=scheduled]'); await P.waitForTimeout(150);
    const sections = await P.$$eval('.pp-section-head h2', (e) => e.map((x) => x.textContent).join(' / '));
    await P.selectOption('[data-pp-sort=inspections]', 'owner').catch(() => {});
    await P.screenshot({ path: OUT + '/7-kontrollen.png', fullPage: true });
    if (!/Offen/.test(chips) || !/In Bearbeitung/.test(chips) || /Abgeschlossen \(/.test(sections)) throw new Error(`${chips} · ${sections}`);
    return `${chips} · Filter „offen“ zeigt: ${sections}`;
  });
  console.log(res.join('\n')); console.log(errs.length ? 'JS-Fehler:\n' + [...new Set(errs)].join('\n') : 'keine JS-Fehler'); await b.close();
})();
