const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON: ENV_ANON } = require('./env'); const OUT = SP + '/audit/ppinvoices'; fs.mkdirSync(OUT, { recursive: true });
const ANON = ENV_ANON; const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Rechnungsdienst ${N}`, P_EMAIL = `ppinv${N}@hs.test`, PW = 'Husora!2026';
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


  const PDF = Buffer.from('%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj 2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj 3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF');
  await step('Hausbesitzer: 2 Aufgaben für den Partner, Hausdaten (Baujahr/Fläche) gesetzt', async () => {
    await H.evaluate((firm) => {
      currentPage = 'dashboard'; render();
      const id = 'custom-ppinv' + Date.now(); providers.push({ id, name: firm, category: 'house', custom: true, initials: 'SS', distances: {} }); persistCustomProviders();
      const prop = properties[0];
      const d = (n) => localDateKey(new Date(Date.now() + n * 86400000));
      tasks.push({ id: Date.now(), partnerId: id, title: 'Dachrinne reinigen', property: prop.name, date: d(2), time: '10:00', priority: 'normal', area: 'Außen', status: 'Offen', done: false, repeat: 'Einmalig' });
      tasks.push({ id: Date.now() + 1, partnerId: id, title: 'Heizung warten', property: prop.name, date: d(5), priority: 'soon', area: 'Technik', status: 'Offen', done: false, repeat: 'Einmalig' });
      persistTasks();
    }, FIRM);
    await H.evaluate(() => cloudUpload()); await H.waitForTimeout(1500); await H.waitForFunction(() => !ownerSide.dispatching, null, { timeout: 15000 }); await H.evaluate(() => ownerDispatchOrders());
    const pid = sql(`select o.property_id from service_orders o join service_partners sp on sp.id=o.service_partner_id where sp.company_name='${FIRM}' limit 1`);
    const org = sql(`select organization_id from properties where id='${pid}'`);
    await H.evaluate(async ({ org, pid }) => { const c = document.createElement('canvas'); c.width = 320; c.height = 220; const g = c.getContext('2d'); const gr = g.createLinearGradient(0, 0, 0, 220); gr.addColorStop(0, '#8fb8d8'); gr.addColorStop(1, '#3e6b4a'); g.fillStyle = gr; g.fillRect(0, 0, 320, 220); g.fillStyle = '#a3362b'; g.fillRect(90, 100, 140, 80); g.fillStyle = '#5a2a20'; g.beginPath(); g.moveTo(80, 100); g.lineTo(160, 50); g.lineTo(240, 100); g.fill(); g.fillStyle = '#fff'; g.fillRect(110, 120, 25, 25); g.fillRect(185, 120, 25, 25);
      const path = `organization/${org}/property/${pid}/photos/test-${Date.now()}.jpg`; await cloudPutFile('husora-property-photos', path, c.toDataURL('image/jpeg', .85), 'image/jpeg');
      await cloudFetch('/rest/v1/photos', { method: 'POST', body: { organization_id: org, property_id: pid, storage_bucket: 'husora-property-photos', storage_path: path, caption: 'Hausansicht' }, headers: { Prefer: 'return=minimal' } }); }, { org, pid });
    sql(`update properties set year_built=1978, living_area_m2=86, land_area_m2=1450, bedrooms=3, max_guests=6 where id='${pid}'`);
    return `${sql(`select count(*) from service_orders o join service_partners sp on sp.id=o.service_partner_id where sp.company_name='${FIRM}'`)} Aufträge · Fotos zum Haus: ${sql(`select count(*) from photos where property_id='${pid}' and service_order_id is null`)}`;
  });
  await P.evaluate(() => ppLoad()); await P.waitForFunction(() => !pp.busy, null, { timeout: 15000 });
  const view = async (v) => { await P.evaluate((v) => { pp.detail = null; pp.form = null; pp.view = v; ppRender(); }, v); await P.waitForTimeout(300); };
  const idle = () => P.waitForFunction(() => !pp.busy, null, { timeout: 20000 }).then(() => P.waitForTimeout(250));
  const mine = `service_partner_id in (select id from service_partners where company_name='${FIRM}')`;
  const year = new Date().getFullYear();
  await step('Vorbereitung: zwei Rechnungen (Husora-PDF und eigenes PDF), eine aufs Vorjahr datiert', async () => {
    for (const [title, upload] of [['Dachrinne reinigen', false], ['Heizung warten', true]]) {
      await P.evaluate((t) => { pp.detail = { type: 'order', id: ppD('orders').find((o) => o.title === t).id }; ppRender(); }, title);
      if (await P.$('[data-pp-action=accept]')) { await P.click('[data-pp-action=accept]'); await idle(); }
      await P.click(upload ? '[data-pp-action=finance-form][data-mode=upload]' : '[data-pp-action=finance-form][data-kind=invoice]:not([data-mode])'); await P.waitForTimeout(150);
      if (upload) { await P.setInputFiles('[data-pp-form=finance] [name=pdf]', { name: 'Faktura-alt.pdf', mimeType: 'application/pdf', buffer: PDF }); await P.fill('[data-pp-form=finance] [name=number]', `F-${N}`); }
      await P.fill('[data-pp-form=finance] [name=net]', upload ? '400' : '1000');
      await P.$eval('[data-pp-form=finance] button[type=submit]', (e) => e.click()); await idle();
    }
    sql(`update invoices set invoice_date='${year - 1}-11-20', due_date='${year - 1}-12-20' where invoice_number='F-${N}' and ${mine}`);
    await P.evaluate(() => ppLoad()); await idle();
    await H.evaluate(() => { currentPage = 'partnerHub'; hub.tab = 'orders'; render(); }); await H.evaluate(() => hubRefresh()); await H.waitForTimeout(3000);
    const r = sql(`select string_agg(invoice_number||' '||amount_gross||' '||status, ', ' order by invoice_number) from invoices where ${mine}`);
    if (r.split(',').length !== 2) throw new Error(r + ' ' + await P.evaluate(() => pp.error)); return r;
  });
  await step('Finanzen: Kennzahlen, Filter und Einnahmen-Diagramm', async () => {
    await view('finance'); await P.screenshot({ path: OUT + '/1-finanzen.png' }); await (await P.$('.pp-rev')).screenshot({ path: OUT + '/1b-diagramm.png' });
    const t = await P.evaluate(() => ({ tiles: [...document.querySelectorAll('.pp-tiles .pp-tile')].map((e) => e.innerText.replace(/\s+/g, ' ')).join(' | '), rows: document.querySelectorAll('[data-pp-open^="invoice:"]').length, bars: document.querySelectorAll('.pp-rev-col').length, filters: [...document.querySelectorAll('[data-pp-invf]')].map((e) => e.dataset.ppInvf).join(',') }));
    if (t.rows !== 2 || !t.bars || !/range,from,to,property,customer,status/.test(t.filters)) throw new Error(JSON.stringify(t)); return `${t.tiles} · ${t.rows} Rechnungen · ${t.bars} Balken`;
  });
  await step('Filter: Zeitraum „Dieses Jahr“ / „Letztes Jahr“ / eigener Zeitraum', async () => {
    const rows = () => P.$$eval('[data-pp-open^="invoice:"] strong', (e) => e.map((x) => x.textContent).join(', '));
    await P.selectOption('[data-pp-invf=range]', 'year'); await P.waitForTimeout(200); const a = await rows();
    await P.selectOption('[data-pp-invf=range]', 'lastyear'); await P.waitForTimeout(200); const b = await rows();
    const cap = await P.evaluate(() => document.querySelector('.pp-rev-head strong')?.textContent);
    await P.fill('[data-pp-invf=from]', `${year - 1}-11-01`); await P.dispatchEvent('[data-pp-invf=from]', 'change'); await P.waitForTimeout(200);
    const c = await rows(); const range = await P.evaluate(() => pp.invFilter.range);
    await P.screenshot({ path: OUT + '/2-filter-zeitraum.png', fullPage: true });
    if (a.includes(`F-${N}`) || !b.includes(`F-${N}`) || b.split(',').length !== 1 || range !== 'custom' || c.split(',').length !== 1) throw new Error(`${a} / ${b} / ${c} / ${range}`);
    return `dieses Jahr: ${a} · letztes Jahr: ${b} (${cap}) · eigener Zeitraum: ${c}`;
  });
  await step('Filter: Haus, Kunde und Status, zurücksetzen', async () => {
    await P.click('[data-pp-invf-reset]'); await P.waitForTimeout(200);
    const houses = await P.$$eval('[data-pp-invf=property] option', (e) => e.map((x) => x.textContent).join('/'));
    const customers = await P.$$eval('[data-pp-invf=customer] option', (e) => e.map((x) => x.textContent).join('/'));
    await P.selectOption('[data-pp-invf=property]', { index: 1 }); await P.waitForTimeout(200);
    const byHouse = await P.$$eval('[data-pp-open^="invoice:"]', (e) => e.length);
    await P.selectOption('[data-pp-invf=customer]', { index: 1 }); await P.waitForTimeout(200);
    const byCustomer = await P.$$eval('[data-pp-open^="invoice:"]', (e) => e.length);
    await P.selectOption('[data-pp-invf=status]', 'paid'); await P.waitForTimeout(200);
    const paid = await P.$$eval('[data-pp-open^="invoice:"]', (e) => e.length);
    await P.click('[data-pp-invf-reset]'); await P.waitForTimeout(200);
    const all = await P.$$eval('[data-pp-open^="invoice:"]', (e) => e.length);
    if (byHouse !== 2 || byCustomer !== 2 || paid !== 0 || all !== 2) throw new Error(`${byHouse}/${byCustomer}/${paid}/${all}`);
    return `Häuser: ${houses} · Kunden: ${customers} · Haus ${byHouse}, Kunde ${byCustomer}, bezahlt ${paid}, zurückgesetzt ${all}`;
  });
  let INV = '';
  await step('Detailansicht: Rechnung öffnen, Beträge, Bezug und PDF', async () => {
    INV = sql(`select id from invoices where ${mine} and invoice_number like 'R-%'`);
    await P.click(`[data-pp-open="invoice:${INV}"]`); await P.waitForTimeout(300);
    await P.screenshot({ path: OUT + '/3-detail.png' }); await (await P.$('.pp-main .pp-card')).screenshot({ path: OUT + '/3b-detail-karte.png' });
    const t = await P.evaluate(() => ({ title: pp.detail?.type, facts: document.querySelector('.pp-facts')?.innerText.replace(/\s+/g, ' '), pdf: !!document.querySelector('[data-pp-action=invoice-pdf]'), top: document.querySelector('.pp-top-title strong')?.textContent }));
    if (t.title !== 'invoice' || !/Brutto/.test(t.facts) || !/Dachrinne/.test(t.facts) || !t.pdf) throw new Error(JSON.stringify(t)); return `${t.top} · ${t.facts.slice(0, 160)}`;
  });
  await step('Bearbeiten: Betrag und Fälligkeit ändern → PDF neu erstellt, Kunde informiert', async () => {
    const oldDoc = sql(`select document_id from invoices where id='${INV}'`);
    await P.click('[data-pp-inv=edit]'); await P.waitForTimeout(200);
    await P.fill('[data-pp-form=inv-edit] [name=net]', '1200'); await P.fill('[data-pp-form=inv-edit] [name=due]', `${year}-12-30`);
    await P.fill('[data-pp-form=inv-edit] [name=note]', 'Zusatzarbeit am Fallrohr');
    await (await P.$('[data-pp-form=inv-edit]')).screenshot({ path: OUT + '/4-bearbeiten.png' });
    await P.$eval('[data-pp-form=inv-edit] button[type=submit]', (e) => e.click()); await idle();
    const r = sql(`select i.amount_net||' '||i.amount_gross||' '||i.due_date||' · '||d.file_name from invoices i join documents d on d.id=i.document_id where i.id='${INV}'`);
    const newDoc = sql(`select document_id from invoices where id='${INV}'`);
    const gone = sql(`select count(*) from documents where id='${oldDoc}'`);
    const msg = sql(`select message from messages where message like 'Rechnung % wurde korrigiert%' and organization_id=(select organization_id from invoices where id='${INV}') order by created_at desc limit 1`);
    if (!r.startsWith('1200.00') || newDoc === oldDoc || gone !== '0' || !/Fallrohr/.test(msg)) throw new Error(`${r} · ${oldDoc}→${newDoc} (${gone}) · ${msg} · ${await P.evaluate(() => pp.error)}`);
    return `${r} · altes PDF entfernt · Nachricht: ${msg}`;
  });
  await step('Eigenes PDF: korrigiertes PDF hochladen ersetzt das alte', async () => {
    const id = sql(`select id from invoices where invoice_number='F-${N}' and ${mine}`);
    await P.evaluate((id) => { pp.detail = { type: 'invoice', id }; pp.form = `inv-edit:${id}`; ppRender(); }, id); await P.waitForTimeout(200);
    await P.setInputFiles('[data-pp-form=inv-edit] [name=pdf]', { name: 'Faktura-korrigiert.pdf', mimeType: 'application/pdf', buffer: PDF });
    await P.$eval('[data-pp-form=inv-edit] button[type=submit]', (e) => e.click()); await idle();
    const r = sql(`select d.file_name from invoices i join documents d on d.id=i.document_id where i.id='${id}'`);
    if (r !== 'Faktura-korrigiert.pdf') throw new Error(r + ' ' + await P.evaluate(() => pp.error)); return r;
  });
  await step('Status: freigegebene Rechnung als bezahlt markieren und zurücknehmen (RPC)', async () => {
    sql(`update invoices set status='approved', approved_at=now() where id='${INV}'`);
    await P.evaluate(() => ppLoad()); await idle();
    await P.evaluate((id) => { pp.detail = { type: 'invoice', id }; pp.form = null; ppRender(); }, INV); await P.waitForTimeout(200);
    const editLocked = !(await P.$('[data-pp-inv=edit]'));
    await P.click('[data-pp-inv=paid]'); await idle();
    const paid = sql(`select status||' '||(paid_at is not null) from invoices where id='${INV}'`);
    await P.screenshot({ path: OUT + '/5-bezahlt.png', fullPage: true });
    await P.click('[data-pp-inv=unpaid]'); await idle();
    const back = sql(`select status||' '||(paid_at is null) from invoices where id='${INV}'`);
    await P.click('[data-pp-inv=paid]'); await idle();
    if (!editLocked || paid !== 'paid true' || back !== 'approved true') throw new Error(`${editLocked} ${paid} ${back} ${await P.evaluate(() => pp.error)}`);
    return `Bearbeiten gesperrt nach Freigabe · ${paid} · zurück: ${back}`;
  });
  await step('Stornieren: eingereichte Rechnung', async () => {
    const id = sql(`select id from invoices where invoice_number='F-${N}' and ${mine}`);
    await P.evaluate((id) => { pp.detail = { type: 'invoice', id }; pp.form = null; ppRender(); }, id); await P.waitForTimeout(200);
    await P.click('[data-pp-inv=cancel]'); await idle();
    const r = sql(`select status from invoices where id='${id}'`);
    if (r !== 'cancelled') throw new Error(r + ' ' + await P.evaluate(() => pp.error)); return r;
  });
  await step('Finanzen: bezahlt im Diagramm, Storno zählt nicht', async () => {
    await view('finance'); await (await P.$('.pp-rev')).screenshot({ path: OUT + '/6-diagramm-danach.png' });
    const t = await P.evaluate(() => ({ tiles: [...document.querySelectorAll('.pp-tiles .pp-tile')].map((e) => e.innerText.replace(/\s+/g, ' ')).join(' | '), paidBars: document.querySelectorAll('.pp-rev-paid').length }));
    if (!/^[\d.,]+ \w+ Einnahmen \(1\)/.test(t.tiles) || !t.paidBars) throw new Error(JSON.stringify(t)); return t.tiles;
  });
  await step('RPC: fremde Rechnung kann nicht geändert werden', async () => {
    const other = sql(`select id from invoices where not (${mine}) limit 1`);
    if (!other) return 'keine fremde Rechnung im Stack – übersprungen';
    const r = await P.evaluate(async (id) => { try { await ppRpc('partner_set_invoice_status', { p_invoice_id: id, p_status: 'paid' }); return 'erlaubt'; } catch (e) { return e.message; } }, other);
    if (r === 'erlaubt') throw new Error(r); return r.slice(0, 80);
  });
  await step('Hausbesitzer: korrigierte Rechnung wird in den Ist-Kosten nachgezogen', async () => {
    await H.evaluate(() => { currentPage = 'partnerHub'; hub.tab = 'orders'; render(); }); await H.evaluate(() => hubRefresh()); await H.waitForTimeout(3000);
    const gross = sql(`select amount_gross from invoices where id='${INV}'`);
    const r = await H.evaluate((id) => { const e = expenses.find((x) => x.id === `expense-cloud-invoice-${id}`); const d = documents.find((x) => x.id === `cloud-invoice-${id}`); return `${e?.originalAmount} ${e?.originalCurrency} · Dok ${d?.cloudDocId ? 'aktuell' : d ? 'alt' : 'fehlt'}`; }, INV);
    if (Number(r.split(' ')[0]) !== Number(gross) || !/aktuell/.test(r)) throw new Error(`${r} (DB ${gross})`); return `${r} (DB ${gross})`;
  });
  console.log(res.join('\n')); console.log(errs.length ? 'JS-Fehler:\n' + [...new Set(errs)].join('\n') : 'keine JS-Fehler'); await b.close();
})();
