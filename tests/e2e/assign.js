// Phase 3: Häuser für einen Servicepartner freigeben (Basis/Service/Voll), Rolle Subunternehmer
const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON } = require('./env'); const OUT = SP + '/audit/assign'; fs.mkdirSync(OUT, { recursive: true });
const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Freigabe Service ${N}`, P_EMAIL = `freigabe${N}@hs.test`, PW = 'Husora!2026', TITLE = `Fensterreinigung ${N}`;
const sql = (q) => execSync(`psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -At -c "${q.replace(/"/g, '\\"')}"`).toString().trim();
(async () => {
  const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (name, fn) => { try { const r = await fn(); res.push(`OK   ${name}${r ? ' – ' + r : ''}`); } catch (e) { res.push(`FEHL ${name} – ${e.message.split('\n')[0].slice(0, 220)}`); } };
  const device = async (label) => {
    const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    const p = await ctx.newPage(); p.on('pageerror', (e) => errs.push(`${label}: ${e.message}`)); p.on('dialog', (d) => d.accept());
    await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
    await p.goto('http://127.0.0.1:8081/index.html');
    await p.evaluate(({ url, key, owner }) => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); localStorage.setItem('husora-cloud', JSON.stringify({ url, key })); if (owner) localStorage.setItem('stugliv-profile', JSON.stringify({ name: 'Hanna Haus', username: 'hanna', phone: '+49 170 5551234', street: 'Lindenweg 4', zip: '20095', city: 'Hamburg', country: 'Deutschland' })); }, { url: URL_, key: ANON, owner: label === 'H' });
    await p.reload(); await p.waitForTimeout(400); return p;
  };

  const H = await device('H');
  await step('Hausbesitzer: anmelden im Partner-Portal', async () => {
    await H.evaluate(() => document.querySelector('.nav [data-page="partnerHub"]').click()); await H.waitForTimeout(300);
    await H.fill('[data-cloud-form=signin] [name=email]', 'admin@husora.test'); await H.fill('[data-cloud-form=signin] [name=password]', PW);
    await H.$eval('[data-cloud-form=signin] button[type=submit]', (e) => e.click());
    await H.waitForFunction(() => cloudReady() && !cloudState.busy && ownerSide.partners !== null && !ownerSide.busy, null, { timeout: 20000 });
    return `${await H.evaluate(() => ownerSide.partners.length)} Partner`;
  });
  let CODE = '';
  await step('Hausbesitzer: Partner einladen', async () => {
    await H.fill('[data-owner-form=partner] [name=company_name]', FIRM); await H.fill('[data-owner-form=partner] [name=email]', P_EMAIL);
    await H.$eval('[data-owner-form=partner] button[type=submit]', (e) => e.click()); await H.waitForFunction(() => !ownerSide.busy, null, { timeout: 20000 }); await H.waitForTimeout(300);
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
  const HOUSE = 'dddddddd-0000-4000-8000-000000000001';
  const grant = () => sql(`select coalesce(string_agg(property_id::text||':'||access_level||':'||coalesce(end_date::text,'-'), ','), '-') from property_service_assignments where service_partner_id='${spId}'`);
  const hubLoad = async () => { await H.evaluate(() => { currentPage = 'partnerHub'; hub.tab = 'partners'; render(); }); await H.evaluate(() => ownerLoadPartners().then(() => render())); await H.waitForTimeout(500); };
  const partnerHouses = async () => { await P.evaluate(async () => { await ppLoad(); }); return P.evaluate(() => ppD('properties').filter((p) => p.organization_id === 'cccccccc-0000-4000-8000-000000000001').map((p) => p.id)); };
  await step('Ohne Freigabe: Partner sieht keine Häuser des Kunden', async () => { const h = await partnerHouses(); if (h.length) throw new Error(h.join(',')); return '0 Häuser'; });
  await step('Hausbesitzer: Hinweis „Noch keine Häuser freigegeben“', async () => {
    await hubLoad(); const t = await H.textContent(`[data-owner-action=assign-edit][data-id="${spId}"]`); return t.trim();
  });
  await step('Hausbesitzer: Haus mit Stufe „Service“ freigeben', async () => {
    await H.click(`[data-owner-action=assign-edit][data-id="${spId}"]`); await H.waitForTimeout(200);
    await H.selectOption(`[data-hub-assign="${spId}"] [name="level:${HOUSE}"]`, 'service');
    await H.$eval(`[data-hub-assign="${spId}"]`, (e) => e.scrollIntoView()); await H.screenshot({ path: OUT + '/1-freigabe.png' });
    await H.click(`[data-hub-assign="${spId}"] button[type=submit]`); await H.waitForFunction(() => !ownerSide.busy, null, { timeout: 20000 }); await H.waitForTimeout(300);
    const g = grant(); if (g !== `${HOUSE}:service:-`) throw new Error(g);
    return `${g} · ${(await H.textContent('.hub-partner .hub-contact-line:last-of-type')).trim().slice(0, 80)}`;
  });
  await step('Partner sieht genau das freigegebene Haus mit Stufe', async () => {
    const h = await partnerHouses(); if (h.length !== 1 || h[0] !== HOUSE) throw new Error(h.join(','));
    const cid = sql(`select id from customers where organization_id=(select id from organizations where name='${FIRM}') limit 1`);
    await P.evaluate((id) => { pp.view = 'customers'; pp.detail = { type: 'customer', id }; ppRender(); }, cid); await P.waitForTimeout(300);
    const badge = await P.textContent('.pp-grant'); await P.screenshot({ path: OUT + '/2-partner.png', fullPage: true });
    if (!/Freigegeben: Service/.test(badge)) throw new Error(badge); return badge.trim();
  });
  await step('Partner ergänzt das Objekt mit eigenen Infos (nur für den Betrieb)', async () => {
    await P.click(`[data-pp-action=prop-notes][data-property="${HOUSE}"]`); await P.waitForTimeout(200);
    await P.fill('[data-pp-form=prop-notes] [name=key_info]', 'Schlüsselkasten links, Code 4711');
    await P.fill('[data-pp-form=prop-notes] [name=technical_info]', 'Hauptwasserhahn im Keller');
    await P.click('[data-pp-form=prop-notes] button[type=submit]'); await wait(); await noErr();
    const n = sql(`select key_info||' | '||technical_info from partner_property_notes where property_id='${HOUSE}' and organization_id=(select id from organizations where name='${FIRM}')`);
    const ownerSees = sql(`select count(*) from partner_property_notes where organization_id='cccccccc-0000-4000-8000-000000000001'`);
    if (!n.includes('4711') || ownerSees !== '0') throw new Error(`${n} · ${ownerSees}`);
    return n;
  });
  await step('Aufträge unter dem Haus aufklappen', async () => {
    sql(`insert into service_orders (organization_id, property_id, service_partner_id, title, status) values ('cccccccc-0000-4000-8000-000000000001', '${HOUSE}', '${spId}', 'Fenster putzen ${N}', 'offered')`);
    const cid = sql(`select id from customers where organization_id=(select id from organizations where name='${FIRM}') limit 1`);
    await P.evaluate(async (id) => { await ppLoad(); pp.view = 'customers'; pp.detail = { type: 'customer', id }; ppRender(); }, cid); await P.waitForTimeout(300);
    const closed = await P.$eval(`[data-pp-prop-orders="${HOUSE}"]`, (e) => e.open);
    await P.click(`[data-pp-prop-orders="${HOUSE}"] summary`); await P.waitForTimeout(200);
    const items = await P.$$eval(`[data-pp-prop-orders="${HOUSE}"] .pp-item`, (e) => e.length);
    await P.screenshot({ path: OUT + '/3-objekt.png', fullPage: true });
    if (closed || items < 1) throw new Error(`${closed} / ${items}`);
    return `${items} Auftrag/Aufträge aufgeklappt · Infos: ${(await P.textContent('.pp-prop-notes')).replace(/\s+/g, ' ').slice(0, 80)}`;
  });
  await step('Hausbesitzer: Stufe „Voll“ mit Enddatum', async () => {
    await hubLoad(); await H.click(`[data-owner-action=assign-edit][data-id="${spId}"]`); await H.waitForTimeout(200);
    const end = new Date(Date.now() + 30 * 86400000).toISOString().slice(0, 10);
    await H.selectOption(`[data-hub-assign="${spId}"] [name="level:${HOUSE}"]`, 'full'); await H.fill(`[data-hub-assign="${spId}"] [name="end:${HOUSE}"]`, end);
    await H.click(`[data-hub-assign="${spId}"] button[type=submit]`); await H.waitForFunction(() => !ownerSide.busy, null, { timeout: 20000 }); await H.waitForTimeout(300);
    const g = grant(); if (g !== `${HOUSE}:full:${end}`) throw new Error(g); return g;
  });
  await step('Hausbesitzer: Freigabe entfernen → Partner sieht das Haus nicht mehr', async () => {
    sql(`update service_orders set status = 'cancelled' where title = 'Fenster putzen ${N}'`); // Auftrag würde das Haus sonst weiter freigeben
    await hubLoad(); await H.click(`[data-owner-action=assign-edit][data-id="${spId}"]`); await H.waitForTimeout(200);
    await H.selectOption(`[data-hub-assign="${spId}"] [name="level:${HOUSE}"]`, '');
    await H.click(`[data-hub-assign="${spId}"] button[type=submit]`); await H.waitForFunction(() => !ownerSide.busy, null, { timeout: 20000 }); await H.waitForTimeout(300);
    const g = grant(); const h = await partnerHouses(); if (g !== '-' || h.length) throw new Error(`${g} · ${h}`); return 'entfernt';
  });
  await step('Partner: Rolle „Subunternehmer“ beim Einladen wählbar', async () => {
    await P.evaluate(() => { pp.view = 'team'; pp.detail = null; ppRender(); }); await P.waitForTimeout(200);
    const opts = await P.$$eval('[data-pp-form=member-invite] [name=role] option', (o) => o.map((x) => x.value));
    if (!opts.includes('contractor')) throw new Error(opts.join(',')); return opts.join(', ');
  });

  console.log(res.join('\n')); if (errs.length) console.log('JS-Fehler:\n' + errs.join('\n'));
  await b.close();
})();
