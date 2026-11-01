const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON: ENV_ANON } = require('./env'); const OUT = SP + '/audit/kontakte'; fs.mkdirSync(OUT, { recursive: true });
const ANON = ENV_ANON; const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Sunne Service ${N}`, P_EMAIL = `kontakt${N}@hs.test`, PW = 'Husora!2026';
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



  const editCustomer = async (id, data) => {
    await P.evaluate((id) => { pp.view = 'customers'; pp.detail = { type: 'customer', id }; pp.form = null; ppRender(); }, id);
    await P.click('[data-pp-action=edit-customer]'); await P.waitForSelector('[data-pp-form=customer-edit]');
    for (const [k, v] of Object.entries(data)) { if (k === 'country') await P.selectOption(`[data-pp-form=customer-edit] [name=${k}]`, v); else await P.fill(`[data-pp-form=customer-edit] [name=${k}]`, v); }
    await P.screenshot({ path: OUT + `/edit-${id.slice(0, 6)}.png` });
    await P.$eval('[data-pp-form=customer-edit] button[type=submit]', (e) => e.click()); await P.waitForFunction(() => !pp.busy, null, { timeout: 20000 }); await P.waitForTimeout(200);
    const err = await P.evaluate(() => pp.error); if (err) throw new Error(err);
  };
  await step('Partner: Kontakt des Husora-Kunden bearbeiten', async () => {
    const id = await P.evaluate(() => ppD('customers').find((c) => c.linked_organization_id)?.id);
    if (!id) throw new Error('kein verbundener Kunde');
    const orgBefore = sql(`select name from organizations where id=(select linked_organization_id from customers where id='${id}')`);
    await editCustomer(id, { first_name: 'Alexander', last_name: 'Schäle', phone: '+49 170 5550101', street: 'Mansfelder Weg 6', postal_code: '31311', city: 'Uetze', country: 'DE', notes: 'Schlüssel beim Nachbarn', customer_number: `K-${N}` });
    const r = sql(`select concat_ws(' | ', first_name, last_name, phone, street, postal_code, city, country, customer_number) from customers where id='${id}'`);
    const orgAfter = sql(`select name from organizations where id=(select linked_organization_id from customers where id='${id}')`);
    const shown = await P.textContent('.pp-facts');
    if (!r.includes('Uetze') || orgBefore !== orgAfter || !shown.includes('5550101')) throw new Error(`${r} · ${orgBefore}/${orgAfter}`);
    return `${r} · Hausbesitzer-Organisation unverändert („${orgAfter}“)`;
  });
  await step('Partner: eigenen Kunden anlegen und bearbeiten', async () => {
    await P.evaluate(() => { pp.view = 'customers'; pp.detail = null; pp.form = 'new-customer'; ppRender(); });
    await P.fill('[data-pp-form=customer] [name=last_name]', `Berg ${N}`); await P.$eval('[data-pp-form=customer] button[type=submit]', (e) => e.click()); await P.waitForFunction(() => !pp.busy, null, { timeout: 20000 });
    const id = await P.evaluate((n) => ppD('customers').find((c) => c.last_name === `Berg ${n}`)?.id, N);
    await editCustomer(id, { email: 'falsch' }).catch(() => {});
    if (sql(`select coalesce(email, '') from customers where id='${id}'`) === 'falsch') throw new Error('ungültige E-Mail gespeichert');
    await P.evaluate(() => { pp.error = ''; pp.form = null; });
    await editCustomer(id, { first_name: 'Anna', email: 'anna@berg.test', city: 'Mora' });
    return sql(`select concat_ws(' | ', first_name, last_name, email, city) from customers where id='${id}'`);
  });
  await step('Fremder Betrieb kann den Kontakt nicht ändern (RLS)', async () => {
    const id = sql(`select id from customers where last_name='Berg ${N}'`);
    const upd = sql(`begin; set local role authenticated; set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}'; update customers set city='X' where id='${id}'; commit;`);
    const n = sql(`select city from customers where id='${id}'`);
    if (n !== 'Mora') throw new Error(n); return `${upd.split('\n').find((l) => /UPDATE/.test(l)) || ''} · Ort bleibt „${n}“`;
  });
  console.log(res.join('\n')); console.log(errs.length ? 'JS-Fehler:\n' + [...new Set(errs)].join('\n') : 'keine JS-Fehler'); await b.close();
})();
