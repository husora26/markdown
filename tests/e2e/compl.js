const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON: ENV_ANON } = require('./env'); const OUT = SP + '/audit/compl'; fs.mkdirSync(OUT, { recursive: true });
const ANON = ENV_ANON; const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Älvdalens Hausservice ${N}`, P_EMAIL = `compl${N}@hs.test`, PW = 'Husora!2026';
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
    const card = await H.$$('.hub-partner'); for (const c of card) { if ((await c.textContent()).includes(FIRM)) { await c.screenshot({ path: OUT + '/2-code.png' }); } }
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



  await step('Hausbesitzer beauftragt Hausservice', async () => {
    await H.evaluate((firm) => {
      const id = 'custom-c' + Date.now(); providers.push({ id, name: firm, category: 'house', custom: true, initials: 'ÄH', distances: {} }); persistCustomProviders();
      tasks.push({ id: Date.now(), partnerId: id, title: 'Hecke schneiden', property: properties[0].name, date: localDateKey(new Date(Date.now() + 2 * 86400000)), priority: 'normal', area: 'Außen', status: 'Offen', done: false, repeat: 'Einmalig' });
      try { localStorage.setItem('stugliv-tasks', JSON.stringify(tasks)); } catch (e) {}
    }, FIRM);
    await H.evaluate((firm) => commissionPartner(providers.find((p) => p.name === firm).id), FIRM); await H.waitForTimeout(800);
    return await H.evaluate(() => taskStatus(tasks.find((t) => t.title === 'Hecke schneiden')));
  });
  await step('Servicepartner: annehmen, starten, „Auftrag erledigt und Rechnung an Kunden schicken“', async () => {
    await P.evaluate(() => ppLoad()); await P.waitForFunction(() => !pp.busy, null, { timeout: 20000 });
    await P.evaluate(() => { pp.detail = { type: 'order', id: ppD('orders').find((o) => o.title === 'Hecke schneiden').id }; ppRender(); });
    for (const a of ['accept', 'start']) { await P.click(`[data-pp-action=${a}]`); await P.waitForFunction(() => !pp.busy, null, { timeout: 15000 }); await P.waitForTimeout(300); }
    await P.fill('[data-pp-form=complete-invoice] [name=gross]', '1500'); await P.fill('[data-pp-form=complete-invoice] [name=note]', 'Hecke geschnitten, Schnittgut entsorgt.');
    await P.evaluate(() => document.querySelector('[data-pp-form=complete-invoice]').scrollIntoView()); await P.screenshot({ path: OUT + '/1-abschluss.png' });
    // Regression: vorgeschlagene Nummer ist beim Kunden schon vergeben (früher HTTP 409 + Auftrag ohne Rechnung)
    const proposed = await P.$eval('[data-pp-form=complete-invoice] [name=number]', (e) => e.value);
    sql(`insert into invoices (organization_id, property_id, service_partner_id, invoice_number, amount_net, tax_amount, amount_gross, currency, status) select organization_id, property_id, service_partner_id, '${proposed}', 1, 0, 1, currency, 'received' from service_orders where title='Hecke schneiden' and service_partner_id in (select id from service_partners where company_name='${FIRM}')`);
    await P.$eval('[data-pp-form=complete-invoice] button[type=submit]', (e) => e.click()); await P.waitForFunction(() => !pp.busy, null, { timeout: 20000 }); await P.waitForTimeout(300);
    const orphans = sql(`select count(*) from documents d where d.document_type='invoice' and d.service_order_id in (select id from service_orders where title='Hecke schneiden' and service_partner_id in (select id from service_partners where company_name='${FIRM}')) and not exists (select 1 from invoices i where i.document_id=d.id)`);
    if (orphans !== '0') throw new Error(`verwaiste Rechnungs-PDFs: ${orphans}`);
    const r = sql(`select o.status||' '||o.actual_cost||' · '||i.invoice_number||' '||i.amount_net||'+'||i.tax_amount||'='||i.amount_gross||' · '||d.file_name from service_orders o join invoices i on i.service_order_id=o.id join documents d on d.id=i.document_id where o.title='Hecke schneiden' and o.service_partner_id in (select id from service_partners where company_name='${FIRM}')`);
    if (!r.startsWith('completed')) throw new Error(r || await P.evaluate(() => pp.error)); if (r.includes(` ${proposed} `)) throw new Error('doppelte Nummer: ' + r); return `${r} · vergebene Nummer ${proposed} übersprungen`;
  });
  await step('Hausbesitzer: Aufgabe erledigt, Rechnung unter Dokumente und als Ist-Kosten gebucht', async () => {
    await H.evaluate(() => { currentPage = 'dashboard'; render(); msgTop.fullAt = 0; }); await H.evaluate(() => msgPoll()); await H.waitForTimeout(2500);
    const r = await H.evaluate(() => { const t = tasks.find((x) => x.title === 'Hecke schneiden'); const e = expenses.find((x) => x.id.startsWith('expense-cloud-invoice-') && x.note.includes('Hecke')); const d = documents.find((x) => x.id === e?.documentId); return `Aufgabe: ${taskStatus(t)} · Kosten: ${e ? `${e.vendor} ${e.amount} ${e.originalCurrency} (${e.category}) am ${e.date}` : '–'} · Dokument: ${d ? d.name : '–'}`; });
    if (!/Erledigt/.test(r) || /Kosten: –/.test(r)) throw new Error(r);
    await H.evaluate(() => { currentPage = 'costs'; render(); }); await H.waitForTimeout(400);
    const shown = await H.evaluate(() => [...document.querySelectorAll('#page-content *')].some((e) => e.children.length === 0 && /Älvdalens Hausservice/.test(e.textContent)));
    await H.evaluate(() => [...document.querySelectorAll('#page-content *')].find((e) => e.children.length === 0 && /Älvdalens Hausservice/.test(e.textContent))?.scrollIntoView({ block: 'center' })); await H.screenshot({ path: OUT + '/2-kosten.png' });
    return `${r} · in Ferienhaus-Kosten sichtbar: ${shown}`;
  });
  await step('Kein doppeltes Buchen beim nächsten Abgleich', async () => {
    await H.evaluate(() => { msgTop.fullAt = 0; }); await H.evaluate(() => msgPoll()); await H.waitForTimeout(1200);
    const r = await H.evaluate(() => { const ids = expenses.filter((x) => x.id.startsWith('expense-cloud-invoice-')).map((x) => x.id); return [ids.length, new Set(ids).size]; }); if (r[0] !== r[1]) throw new Error(r); return `${r[0]} Rechnungsbuchungen, alle eindeutig`;
  });
  console.log(res.join('\n')); console.log(errs.length ? 'JS-Fehler:\n' + [...new Set(errs)].join('\n') : 'keine JS-Fehler'); await b.close();
})();
