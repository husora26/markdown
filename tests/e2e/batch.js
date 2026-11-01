const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON: ENV_ANON } = require('./env'); const OUT = SP + '/audit/batch'; fs.mkdirSync(OUT, { recursive: true });
const ANON = ENV_ANON; const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Mora Trädgård ${N}`, P_EMAIL = `batch${N}@hs.test`, PW = 'Husora!2026';
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



  const spId = () => sql(`select id from service_partners where company_name='${FIRM}' and organization_id=(select id from organizations where name='Husora Testorganisation')`);
  const RASEN = `Rasen mähen ${N}`;
  await step('Hausbesitzer: Jahresvertrag vorschlagen (Reiter „Jahresverträge“)', async () => {
    await H.evaluate(() => { hub.tab = 'agreements'; ownerLoadPartners().then(() => render()); }); await H.waitForFunction(() => ownerSide.cloudProperties?.length && document.querySelector('[data-owner-form=agreement]'), null, { timeout: 20000 });
    await H.selectOption('[data-owner-form=agreement] [name=partner]', spId());
    await H.fill('[data-owner-form=agreement] [name=task]', RASEN); await H.fill('[data-owner-form=agreement] [name=price]', '6000');
    await H.$eval('[data-owner-form=agreement] button[type=submit]', (e) => e.click()); await H.waitForFunction(() => !ownerSide.busy, null, { timeout: 20000 }); await H.waitForTimeout(400);
    await H.screenshot({ path: OUT + '/1-vorschlag.png', fullPage: true });
    return sql(`select status||' · '||proposed_by||' · '||annual_price from service_agreements where task_title='${RASEN}'`);
  });
  await step('Partner: Vorschlag unter Mehr → Jahresverträge annehmen', async () => {
    await P.evaluate(() => { pp.view = 'agreements'; ppLoad(); }); await P.waitForFunction(() => !pp.busy && document.querySelector('[data-pp-ag=accept]'), null, { timeout: 20000 });
    await P.screenshot({ path: OUT + '/2-partner-vertraege.png' });
    await P.$eval('[data-pp-ag=accept]', (e) => e.click()); await P.waitForFunction(() => !pp.busy, null, { timeout: 20000 }); await P.waitForTimeout(300);
    const st = sql(`select status from service_agreements where task_title='${RASEN}'`); if (st !== 'active') throw new Error(st); return st;
  });
  await step('Hausbesitzer beauftragt 3 Aufgaben – „Rasen mähen“ geht automatisch in den Vertrag', async () => {
    await H.evaluate(({ firm, rasen }) => {
      const id = 'custom-b' + Date.now(); providers.push({ id, name: firm, category: 'house', custom: true, initials: 'MT', distances: {} }); persistCustomProviders();
      const d = localDateKey(new Date(Date.now() + 3 * 86400000));
      [rasen, 'Hecke schneiden B', 'Fenster putzen B'].forEach((title, i) => tasks.push({ id: Date.now() + i, partnerId: id, title, property: properties[0].name, date: d, priority: 'normal', area: 'Außen', status: 'Offen', done: false, repeat: i ? 'Einmalig' : 'Monatlich' }));
      try { localStorage.setItem('stugliv-tasks', JSON.stringify(tasks)); } catch (e) {}
    }, { firm: FIRM, rasen: RASEN });
    await H.evaluate((firm) => commissionPartner(providers.find((p) => p.name === firm).id), FIRM); await H.waitForTimeout(1200);
    const r = sql(`select string_agg(title||':'||(agreement_id is not null), ', ' order by title) from service_orders where service_partner_id='${spId()}'`);
    if (!r.includes(`${RASEN}:true`) || !r.includes('Hecke schneiden B:false')) throw new Error(r); return r;
  });
  await step('Partner: drei Aufträge annehmen, zwei anhaken → Sammelrechnung mit Abschluss', async () => {
    await P.evaluate(async () => { await ppLoad(); for (const o of ppD('orders').filter((x) => x.status === 'offered')) await ppPatch('service_orders', o.id, { status: 'accepted' }); await ppLoad(); pp.view = 'orders'; pp.filter = 'active'; pp.detail = null; ppRender(); });
    await P.waitForFunction(() => !pp.busy && document.querySelectorAll('[data-pp-select]').length >= 3, null, { timeout: 20000 });
    for (const t of ['Hecke schneiden B', 'Fenster putzen B']) { const id = await P.evaluate((t) => ppD('orders').find((o) => o.title === t).id, t); await P.check(`[data-pp-select="${id}"]`); }
    const bar = await P.textContent('.pp-batch-bar'); await P.screenshot({ path: OUT + '/3-auswahl.png' });
    await P.$eval('[data-pp-batch=invoice]', (e) => e.click()); await P.waitForSelector('[data-pp-form=batch-invoice]');
    const inputs = await P.$$('[data-pp-form=batch-invoice] .pp-batch-line input'); await inputs[0].fill('400'); await inputs[1].fill('600');
    await P.screenshot({ path: OUT + '/4-sammelrechnung.png' });
    await P.$eval('[data-pp-form=batch-invoice] button[type=submit]', (e) => e.click()); await P.waitForFunction(() => !pp.busy, null, { timeout: 30000 }); await P.waitForTimeout(300);
    const err = await P.evaluate(() => pp.error); if (err) throw new Error(err);
    const r = sql(`select i.invoice_number||' '||i.amount_gross||' · Positionen '||(select count(*) from invoice_orders x where x.invoice_id=i.id)||' · erledigt '||(select count(*) from service_orders o join invoice_orders x on x.service_order_id=o.id where x.invoice_id=i.id and o.status='completed') from invoices i where i.service_partner_id='${spId()}' and i.service_order_id is null and i.agreement_id is null`);
    if (!/1000\.00 · Positionen 2 · erledigt 2/.test(r)) throw new Error(r); return `Leiste: ${bar.replace(/\s+/g, ' ').slice(0, 90)} · DB: ${r}`;
  });
  await step('Partner: Vertragsauftrag beenden – keine Einzelrechnung möglich', async () => {
    const id = await P.evaluate((t) => ppD('orders').find((o) => o.title === t).id, RASEN);
    await P.evaluate(() => { pp.sel.clear(); ppRender(); }); await P.check(`[data-pp-select="${id}"]`);
    const invoiceBtn = await P.$('[data-pp-batch=invoice]'); const tag = await P.evaluate(() => document.querySelector('.pp-ag-tag')?.textContent || '');
    await P.$eval('[data-pp-batch=complete]', (e) => e.click()); await P.waitForFunction(() => !pp.busy, null, { timeout: 20000 });
    const guard = (() => { try { sql(`insert into invoices (organization_id, property_id, service_order_id, service_partner_id, invoice_number, amount_net, tax_amount, amount_gross, currency) select organization_id, property_id, id, service_partner_id, 'X-${N}', 1, 0, 1, currency from service_orders where id='${id}'`); return 'Einzelrechnung angelegt (falsch)'; } catch (e) { return 'Einzelrechnung vom Server abgelehnt'; } })();
    const st = sql(`select status from service_orders where id='${id}'`);
    if (st !== 'completed' || invoiceBtn || /falsch/.test(guard)) throw new Error(`${st} · Rechnungsknopf: ${!!invoiceBtn} · ${guard}`);
    return `${st} · Hinweis „${tag}“ · Rechnungsknopf ausgeblendet · ${guard}`;
  });
  await step('Partner: Jahresrechnung zum Vertrag', async () => {
    await P.evaluate(() => { pp.view = 'agreements'; pp.form = null; ppRender(); }); await P.$eval('[data-pp-ag=bill]', (e) => e.click()); await P.waitForSelector('[data-pp-form=agreement-bill]');
    await P.screenshot({ path: OUT + '/5-jahresrechnung.png' });
    await P.$eval('[data-pp-form=agreement-bill] button[type=submit]', (e) => e.click()); await P.waitForFunction(() => !pp.busy, null, { timeout: 30000 });
    const err = await P.evaluate(() => pp.error); if (err) throw new Error(err);
    const r = sql(`select i.invoice_number||' '||i.amount_gross||' '||d.file_name from invoices i join documents d on d.id=i.document_id where i.agreement_id=(select id from service_agreements where task_title='${RASEN}')`);
    if (!/6000\.00/.test(r)) throw new Error(r || 'keine Jahresrechnung'); return r;
  });
  await step('Hausbesitzer: Aufgaben erledigt, Kosten je Position + Jahresvertrag gebucht', async () => {
    await H.evaluate(() => ownerLoadPartners()); await H.waitForTimeout(2500);
    const ids = sql(`select string_agg(id::text, ',') from invoices where service_partner_id='${spId()}'`).split(',');
    const r = await H.evaluate(({ rasen, ids }) => {
      const done = ['Hecke schneiden B', 'Fenster putzen B', rasen].map((t) => taskStatus(tasks.find((x) => x.title === t)));
      const ex = expenses.filter((e) => ids.some((id) => e.id.startsWith(`expense-cloud-invoice-${id}`)));
      return { done, ex: ex.map((e) => `${e.note.split('·').pop().trim()} ${e.originalAmount}`) };
    }, { rasen: RASEN, ids });
    if (r.done.some((d) => d !== 'Erledigt') || r.ex.length !== 3) throw new Error(JSON.stringify(r));
    await H.evaluate(() => { hub.tab = 'agreements'; render(); }); await H.waitForTimeout(300); await H.screenshot({ path: OUT + '/6-besitzer-vertraege.png', fullPage: true });
    return `Aufgaben: ${r.done.join('/')} · Buchungen: ${r.ex.join(' | ')}`;
  });
  await step('Fremde Firma sieht den Vertrag nicht', async () => {
    const n = sql(`set local role authenticated; set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}'; select count(*) from service_agreements where task_title='${RASEN}'`).split('\n').pop();
    if (n !== '0') throw new Error(n); return `sichtbar: ${n}`;
  });
  console.log(res.join('\n')); console.log(errs.length ? 'JS-Fehler:\n' + [...new Set(errs)].join('\n') : 'keine JS-Fehler'); await b.close();
})();
