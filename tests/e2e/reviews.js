// Phase 11: Bewertung + Antwort, Angebote vergleichen und annehmen, Notdienst anfordern, Partnerangaben
const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON } = require('./env'); const OUT = SP + '/audit/reviews'; fs.mkdirSync(OUT, { recursive: true });
const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Review Service ${N}`, P_EMAIL = `review${N}@hs.test`, PW = 'Husora!2026', TITLE = `Dach ${N}`;
const sql = (q) => execSync(`psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -At -c "${q.replace(/"/g, '\\"')}"`).toString().trim();
(async () => {
  const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (name, fn) => { try { const r = await fn(); res.push(`OK   ${name}${r ? ' – ' + r : ''}`); } catch (e) { res.push(`FEHL ${name} – ${e.message.split('\n')[0].slice(0, 220)}`); } };
  const device = async (label, width = 390) => {
    const ctx = await b.newContext({ viewport: { width, height: 844 }, isMobile: width < 600, hasTouch: true });
    const p = await ctx.newPage(); p.on('pageerror', (e) => errs.push(`${label}: ${e.message}`)); p.on('dialog', (d) => d.accept());
    await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
    await p.goto('http://127.0.0.1:8081/index.html');
    await p.evaluate(({ url, key }) => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); localStorage.setItem('husora-cloud', JSON.stringify({ url, key })); }, { url: URL_, key: ANON });
    await p.reload(); await p.waitForTimeout(400); return p;
  };
  sql(`update organizations set emergency_service = false where emergency_service`);

  const H = await device('H');
  const hWait = () => H.waitForFunction(() => !ownerSide.busy, null, { timeout: 20000 }).then(() => H.waitForTimeout(300));
  await step('Hausbesitzer: anmelden', async () => {
    await H.evaluate(() => document.querySelector('.nav [data-page="partnerHub"]').click()); await H.waitForTimeout(300);
    await H.fill('[data-cloud-form=signin] [name=email]', 'admin@husora.test'); await H.fill('[data-cloud-form=signin] [name=password]', PW);
    await H.$eval('[data-cloud-form=signin] button[type=submit]', (e) => e.click());
    await H.waitForFunction(() => cloudReady() && !cloudState.busy && ownerSide.partners !== null && !ownerSide.busy, null, { timeout: 20000 });
  });
  let CODE = '';
  await step('Hausbesitzer: Partner einladen', async () => {
    await H.fill('[data-owner-form=partner] [name=company_name]', FIRM); await H.fill('[data-owner-form=partner] [name=email]', P_EMAIL);
    await H.$eval('[data-owner-form=partner] button[type=submit]', (e) => e.click()); await hWait();
    CODE = await H.evaluate(() => ownerSide.code?.code || ownerSide.error); if (!/^HUS-/.test(CODE)) throw new Error(CODE); return CODE;
  });
  const P = await device('P');
  const wait = () => P.waitForFunction(() => !pp.busy, null, { timeout: 20000 }).then(() => P.waitForTimeout(300));
  const noErr = async () => { const e = await P.evaluate(() => pp.error); if (e) throw new Error(e); };
  await step('Partner: Betrieb anlegen und verbinden', async () => {
    await P.evaluate(() => ppOpen('dashboard')); await P.waitForTimeout(200);
    await P.fill('[data-pp-form=login] [name=email]', P_EMAIL); await P.fill('[data-pp-form=login] [name=password]', PW);
    await P.$eval('[data-pp-action=signup]', (e) => e.click()); await P.waitForFunction(() => !pp.busy && document.querySelector('[data-pp-form=company]'), null, { timeout: 20000 });
    await P.fill('[data-pp-form=company] [name=name]', FIRM); await P.$eval('[data-pp-form=company] button[type=submit]', (e) => e.click()); await P.waitForFunction(() => !pp.busy && ppOrg(), null, { timeout: 20000 });
    await P.evaluate(() => { pp.view = 'customers'; ppRender(); });
    await P.fill('[data-pp-form=invite-code] [name=code]', CODE); await P.$eval('[data-pp-form=invite-code] button[type=submit]', (e) => e.click()); await wait();
    return await P.evaluate(() => pp.ctx.links.map((l) => l.organization_name).join(', '));
  });
  const spId = sql(`select id from service_partners where company_name='${FIRM}' and organization_id='cccccccc-0000-4000-8000-000000000001'`);
  const porg = sql(`select id from organizations where name='${FIRM}'`);
  sql(`update organizations set emergency_service = true where id='${porg}'`);
  // zweiter verbundener Partner (ohne eigenes Login) für den Angebotsvergleich
  const org2 = sql(`insert into organizations (name, org_type, country, currency) values ('Zweitbetrieb ${N}', 'service_partner', 'SE', 'SEK') returning id`).split('\n')[0];
  const sp2 = sql(`insert into service_partners (organization_id, company_name, partner_organization_id) values ('cccccccc-0000-4000-8000-000000000001', 'Zweitbetrieb ${N}', '${org2}') returning id`).split('\n')[0];
  const DONE = sql(`insert into service_orders (organization_id, property_id, service_partner_id, title, status, currency) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', '${spId}', 'Erledigt ${N}', 'offered', 'SEK') returning id`).split('\n')[0];
  sql(`update service_orders set status='accepted' where id='${DONE}'`); sql(`update service_orders set status='completed' where id='${DONE}'`);
  const TASK = sql(`insert into service_tasks (organization_id, property_id, title) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', '${TITLE}') returning id`).split('\n')[0];
  const O1 = sql(`insert into service_orders (organization_id, property_id, service_partner_id, service_task_id, title, status, currency) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', '${spId}', '${TASK}', '${TITLE}', 'offered', 'SEK') returning id`).split('\n')[0];
  const O2 = sql(`insert into service_orders (organization_id, property_id, service_partner_id, service_task_id, title, status, currency) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', '${sp2}', '${TASK}', '${TITLE}', 'offered', 'SEK') returning id`).split('\n')[0];
  sql(`insert into quotes (organization_id, property_id, service_order_id, service_partner_id, quote_number, amount_net, tax_amount, amount_gross, currency, status) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', '${O1}', '${spId}', 'A-${N}', 960, 240, 1200, 'SEK', 'received'), ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', '${O2}', '${sp2}', 'B-${N}', 720, 180, 900, 'SEK', 'received')`);
  const hubOrders = () => H.evaluate(async () => { await ownerLoadPartners(); currentPage = 'partnerHub'; hub.tab = 'orders'; hub.orderFilter = 'all'; hub.partnerFilter = ''; render(); }).then(() => H.waitForTimeout(400));
  await step('Hausbesitzer: Angebote vergleichen (günstigstes markiert)', async () => {
    await hubOrders();
    const v = await H.evaluate(() => ({ n: document.querySelectorAll('.hub-compare .hub-quote').length, best: document.querySelector('.hub-compare .hub-best + .hub-quote b')?.textContent }));
    await H.evaluate(() => document.querySelector('.hub-compare')?.scrollIntoView()); await H.screenshot({ path: OUT + '/1-vergleich.png' });
    if (v.n < 2 || !/900/.test(v.best || '')) throw new Error(JSON.stringify(v)); return `${v.n} Angebote · günstigstes ${v.best}`;
  });
  await step('Hausbesitzer nimmt das günstigere Angebot an → anderes abgelehnt, Anfrage zurückgezogen', async () => {
    const qid = sql(`select id from quotes where quote_number='B-${N}'`);
    await H.click(`.hub-compare [data-hub-quote="${qid}"][data-approve="1"]`); await hWait();
    const r = sql(`select string_agg(q.quote_number||':'||q.status||':'||o.status, ' ' order by q.quote_number) from quotes q join service_orders o on o.id=q.service_order_id where q.quote_number in ('A-${N}','B-${N}')`);
    if (r !== `A-${N}:rejected:cancelled B-${N}:approved:offered`) throw new Error(r); return r;
  });
  await step('Hausbesitzer bewertet den abgeschlossenen Auftrag (5 Sterne)', async () => {
    await hubOrders();
    await H.click(`[data-hub-review-open="${DONE}"]`); await H.waitForTimeout(200);
    await H.click(`[data-hub-review="${DONE}"] .beta-stars label[title="5 von 5"]`); await H.fill(`[data-hub-review="${DONE}"] [name=comment]`, `Super Arbeit ${N}`);
    await H.click(`[data-hub-review="${DONE}"] button[type=submit]`); await hWait();
    const r = sql(`select r.rating||'/'||o.rating_avg||'/'||o.rating_count from service_partner_reviews r join organizations o on o.id='${porg}' where r.service_order_id='${DONE}'`);
    const shown = await H.evaluate(() => document.querySelector('.hub-review .hub-review-stars')?.textContent);
    if (!r.startsWith('5/5.00/1') || shown !== '★★★★★') throw new Error(`${r} ${shown}`); return r;
  });
  await step('Partner sieht die Bewertung unter Firma und antwortet', async () => {
    await P.evaluate(async () => { await ppLoad(); pp.view = 'company'; pp.detail = null; ppRender(); }); await P.waitForTimeout(300);
    await P.fill('#partner-portal [data-pp-form="review-reply"] [name=reply]', 'Danke, gerne wieder!'); await P.click('#partner-portal [data-pp-form="review-reply"] button[type=submit]'); await wait(); await noErr();
    await P.evaluate(() => document.querySelector('.pp-reviews')?.scrollIntoView()); await P.screenshot({ path: OUT + '/2-partner-bewertung.png' });
    const r = sql(`select partner_reply from service_partner_reviews where service_order_id='${DONE}'`);
    if (r !== 'Danke, gerne wieder!') throw new Error(r); return r;
  });
  await step('Partnerauswahl zeigt Bewertung und Notdienst', async () => {
    await hubOrders();
    const chip = await H.evaluate((id) => document.querySelector(`[data-hub-send-partner="${id}"]`)?.textContent, spId);
    if (!chip || !chip.includes('★ 5,0') || !chip.includes('Notdienst')) throw new Error(chip); return chip.replace(/\s+/g, ' ').trim();
  });
  await step('Notdienst anfordern → Notfall-Anfrage beim Partner mit Notdienst', async () => {
    await H.evaluate(() => { currentPage = 'emergency'; render(); }); await H.waitForTimeout(800);
    // Haus ggf. mit dem Cloud-Haus verknüpfen (Testkonto ohne Cloud-Abgleich)
    await H.evaluate(() => { const f = document.querySelector('[data-emergency-form]'); if (f && !f.dataset.property) { f.dataset.property = 'dddddddd-0000-4000-8000-000000000001'; f.querySelector('button[type=submit]').disabled = false; } });
    await H.fill('[data-emergency-form] [name=title]', `Wasserrohrbruch ${N}`); await H.click('[data-emergency-form] button[type=submit]'); await hWait();
    await H.screenshot({ path: OUT + '/3-notdienst.png' });
    const r = sql(`select priority||'/'||order_type||'/'||status||'/'||(service_partner_id='${spId}') from service_orders where title='NOTFALL: Wasserrohrbruch ${N}'`);
    const msg = await H.evaluate(() => document.querySelector('.emergency-sent')?.textContent || '');
    if (r !== 'emergency/emergency/offered/true' || !msg.includes(FIRM)) throw new Error(`${r} ${msg}`); return r;
  });
  await step('Partner: Notfall ganz oben als Notfall gekennzeichnet', async () => {
    await P.evaluate(async () => { await ppLoad(); pp.view = 'orders'; pp.filter = 'new'; ppRender(); }); await P.waitForTimeout(300);
    const info = await P.evaluate(() => ({ n: ppD('orders').length, em: ppD('orders').filter((o) => o.priority === 'emergency').map((o) => o.title), view: pp.view, filter: pp.orderFilter || '', err: pp.error }));
    const t = await P.textContent('#partner-portal .pp-main'); if (!t.includes(`NOTFALL: Wasserrohrbruch ${N}`) || !t.includes('Notfall')) throw new Error(JSON.stringify(info) + ' ' + t.slice(0, 200)); return 'sichtbar';
  });
  sql(`update organizations set emergency_service = false where id='${porg}'`);
  console.log(res.join('\n')); if (errs.length) console.log('JS-Fehler:\n' + errs.join('\n'));
  await b.close();
})();
