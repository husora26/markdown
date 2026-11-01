const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON: ENV_ANON } = require('./env'); const OUT = SP + '/audit/pp2'; fs.mkdirSync(OUT, { recursive: true });
const ANON = ENV_ANON; const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Stugservice ${N}`, P_EMAIL = `pp2${N}@hs.test`, PW = 'Husora!2026';
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
      const id = 'custom-pp2' + Date.now(); providers.push({ id, name: firm, category: 'house', custom: true, initials: 'SS', distances: {} }); persistCustomProviders();
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
  const view = async (v) => { await P.evaluate((v) => { pp.detail = null; pp.form = null; pp.view = v; ppRender(); }, v); await P.waitForTimeout(400); };
  await step('Kalender: Monatsansicht mit Terminen, Tag antippen', async () => {
    await view('calendar'); await P.screenshot({ path: OUT + '/1-kalender.png' });
    let days = await P.$$eval('.pp-cal-day.has:not(.other)', (els) => els.map((e) => e.dataset.ppCalDay));
    if (!days.length) { await P.click('[data-pp-cal-nav="1"]'); await P.waitForTimeout(150); days = await P.$$eval('.pp-cal-day.has:not(.other)', (els) => els.map((e) => e.dataset.ppCalDay)); }
    await P.click(`[data-pp-cal-day="${days[days.length - 1]}"]`); await P.waitForTimeout(200); await P.screenshot({ path: OUT + '/1-kalender.png', fullPage: false });
    const list = await P.evaluate(() => [...document.querySelectorAll('.pp-main .pp-section .pp-item strong')].map((e) => e.textContent).join(', '));
    await P.click('[data-pp-cal-nav="1"]'); await P.waitForTimeout(150); const next = await P.evaluate(() => document.querySelector('.pp-cal-head strong').textContent);
    await P.click('[data-pp-cal-nav="0"]'); await P.waitForTimeout(150);
    if (!days.length) throw new Error('keine markierten Tage'); return `${await P.$$eval('.pp-cal-day', (e) => e.length)} Tage im Raster · markiert: ${days.length} · Tag: ${list.slice(0, 80)} · weiter: ${next}`;
  });
  await step('Auftrag: Ferienhaus mit Foto/Adresse/Baujahr/Fläche', async () => {
    await P.evaluate(() => { pp.detail = { type: 'order', id: ppD('orders').find((o) => o.title === 'Dachrinne reinigen').id }; ppRender(); }); await P.waitForTimeout(900);
    await P.screenshot({ path: OUT + '/2-auftrag.png' });
    const t = await P.evaluate(() => document.querySelector('.pp-obj')?.innerText.replace(/\s+/g, ' '));
    if (!/Baujahr 1978/.test(t) || !/86 m²/.test(t)) throw new Error(t); return t.slice(0, 140) + ` · Foto: ${await P.evaluate(() => !!document.querySelector('.pp-obj-photo img')?.src)}`;
  });
  await step('Dokumente: keine Hausfotos mehr', async () => {
    await view('documents'); await P.screenshot({ path: OUT + '/3-dokumente.png' });
    const t = await P.evaluate(() => [document.querySelectorAll('.pp-main .pp-photo').length, [...document.querySelectorAll('.pp-main h2, .pp-main .pp-section-title')].map((e) => e.textContent).join('|')].join(' · '));
    if (!t.startsWith('0')) throw new Error(t); return t;
  });
  await step('Leistungen: nur 3 Gruppen, Preis je Arbeitspaket/Stunde, Speichern', async () => {
    await view('services'); await P.screenshot({ path: OUT + '/4-leistungen.png' });
    const names = await P.$$eval('.pp-service strong', (e) => e.map((x) => x.textContent).join(', '));
    const ids = await P.$$eval('.pp-service input[type=checkbox]', (e) => e.map((x) => x.name.split(':')[1]));
    await P.check(`[name="type:${ids[0]}"]`); await P.fill(`[name="price:${ids[0]}"]`, '450'); await P.selectOption(`[name="unit:${ids[0]}"]`, 'job');
    await P.check(`[name="type:${ids[1]}"]`); await P.fill(`[name="price:${ids[1]}"]`, '520'); await P.selectOption(`[name="unit:${ids[1]}"]`, 'hour');
    await P.$eval('[data-pp-form=services] button[type=submit]', (e) => e.click()); await P.waitForFunction(() => !pp.busy, null, { timeout: 15000 }); await P.waitForTimeout(300);
    const db = sql(`select string_agg(t.name||' '||s.price_from||'/'||s.price_unit||(case when s.active then '' else ' (aus)' end), ', ' order by t.name) from service_partner_services s join service_types t on t.id=s.service_type_id join service_partners sp on sp.id=s.service_partner_id where sp.company_name='${FIRM}' and sp.partner_organization_id=sp.organization_id`);
    if (names !== 'Hauskontrolle, Servicearbeiten, Sanierungen') throw new Error(names); return `${names} · DB: ${db}`;
  });
  await step('Leistungen: Zurück führt zu „Mehr“', async () => {
    await P.click('.pp-main .pp-back'); await P.waitForTimeout(200); const v = await P.evaluate(() => pp.view); if (v !== 'more') throw new Error(v); return v;
  });
  await step('Firma: volle Handybreite, Zurück führt zu „Mehr“', async () => {
    await view('company'); await P.screenshot({ path: OUT + '/5-firma.png' });
    const w = await P.evaluate(() => document.querySelector('[data-pp-form=company-edit]').offsetWidth);
    await P.click('.pp-main .pp-back'); await P.waitForTimeout(200); const v = await P.evaluate(() => pp.view);
    if (w < 340 || v !== 'more') throw new Error(`Breite ${w}, Ansicht ${v}`); return `Formularbreite ${w}px von 390 · zurück: ${v}`;
  });
  await step('Rechnung erstellen → PDF erzeugt und an Hausbesitzer gesendet', async () => {
    await P.evaluate(() => { pp.detail = { type: 'order', id: ppD('orders').find((o) => o.title === 'Dachrinne reinigen').id }; ppRender(); });
    await P.click('[data-pp-action=accept]'); await P.waitForFunction(() => !pp.busy, null, { timeout: 15000 }); await P.waitForTimeout(300);
    await P.click('[data-pp-action=finance-form][data-kind=invoice]:not([data-mode])'); await P.waitForTimeout(150);
    await P.fill('[data-pp-form=finance] [name=net]', '1000');
    await P.$eval('[data-pp-form=finance] button[type=submit]', (e) => e.click()); await P.waitForFunction(() => !pp.busy, null, { timeout: 20000 }); await P.waitForTimeout(300);
    const r = sql(`select i.invoice_number||' '||i.amount_gross||' '||i.status||' · '||d.file_name||' '||d.file_size||'B' from invoices i join documents d on d.id=i.document_id join service_orders o on o.id=i.service_order_id where o.title='Dachrinne reinigen' and o.service_partner_id in (select id from service_partners where company_name='${FIRM}')`);
    const msg = sql(`select message from messages m join service_orders o on o.id=m.service_order_id where o.title='Dachrinne reinigen' and m.message like 'Rechnung%' and o.service_partner_id in (select id from service_partners where company_name='${FIRM}')`);
    const err = await P.evaluate(() => pp.error);
    if (!r) throw new Error(err || 'keine Rechnung'); return `${r} · Nachricht: ${msg.slice(0, 80)}`;
  });
  await step('Eigene Rechnung als PDF hochladen → gesendet', async () => {
    await P.click('[data-pp-action=finance-form][data-mode=upload]'); await P.waitForTimeout(150);
    await P.screenshot({ path: OUT + '/6-pdf-upload.png' });
    await P.setInputFiles('[data-pp-form=finance] [name=pdf]', { name: 'Faktura-2026-117.pdf', mimeType: 'application/pdf', buffer: PDF });
    await P.fill('[data-pp-form=finance] [name=number]', 'F-2026-117'); await P.fill('[data-pp-form=finance] [name=net]', '360');
    await P.$eval('[data-pp-form=finance] button[type=submit]', (e) => e.click()); await P.waitForFunction(() => !pp.busy, null, { timeout: 20000 }); await P.waitForTimeout(300);
    await P.screenshot({ path: OUT + '/7-rechnungen.png' });
    const r = sql(`select d.file_name||' '||i.amount_gross from invoices i join documents d on d.id=i.document_id where i.invoice_number='F-2026-117'`);
    if (!r.startsWith('Faktura-2026-117.pdf')) throw new Error(r || await P.evaluate(() => pp.error)); return r + ` · PDF-Knöpfe: ${await P.$$eval('[data-pp-action=invoice-pdf]', (e) => e.length)}`;
  });
  await step('Hausbesitzer: Rechnungen im Partner-Portal + automatisch unter Dokumente', async () => {
    await H.evaluate(() => { currentPage = 'partnerHub'; hub.tab = 'orders'; render(); }); await H.evaluate(() => hubRefresh()); await H.waitForTimeout(2500);
    await H.evaluate(() => { currentPage = 'partnerHub'; hub.tab = 'orders'; render(); }); await H.waitForTimeout(300);
    const cards = await H.$$eval('.hub-invoice', (e) => e.map((x) => x.innerText.replace(/\s+/g, ' ')).join(' | '));
    const card = await H.$('.hub-invoice'); if (card) await (await card.evaluateHandle((e) => e.closest('.hub-order'))).asElement().screenshot({ path: OUT + '/8-hausbesitzer.png' });
    const local = await H.evaluate(() => documents.filter((d) => d.id.startsWith('cloud-invoice-')).map((d) => `${d.name} (${d.category}, ${d.dataUrl.slice(0, 28)})`).join(', '));
    const dbg = await H.evaluate(async () => { const out = []; const inv = ownerSide.invoices.find((i) => i.invoice_number === 'F-2026-117'); out.push('app_ref=' + inv?.property?.app_ref, 'local=' + properties.map((p) => p.id).join('/'), 'doc=' + !!inv?.document); try { const u = await cloudGetFile(`${CLOUD_FILE_PREFIX}${inv.document.storage_bucket}/${inv.document.storage_path}`); out.push('file ' + String(u).slice(0, 40)); } catch (e) { out.push('getFile ' + e.message); } return out.join(' | '); });
    if (!/F-2026-117/.test(cards) || !/Faktura/.test(local)) throw new Error(`${dbg} // ${local}`); return `${cards.slice(0, 160)} · lokal: ${local}`;
  });
  await step('Hausbesitzer: PDF öffnen', async () => {
    await H.click('[data-hub-invoice]'); await H.waitForTimeout(600);
    return `PDF-Ansicht offen: ${await H.evaluate(() => !!document.querySelector('.pdf-viewer.open, #pdf-modal.open, .modal-backdrop.open'))}`;
  });
  console.log(res.join('\n')); console.log(errs.length ? 'JS-Fehler:\n' + [...new Set(errs)].join('\n') : 'keine JS-Fehler'); await b.close();
})();
