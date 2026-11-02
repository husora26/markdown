// Kontaktdaten an den Servicepartner (Name/E-Mail, Freigabe Telefon/Adresse) und Verbindung trennen
const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON } = require('./env'); const OUT = SP + '/audit/contactshare'; fs.mkdirSync(OUT, { recursive: true });
const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Kontakt Service ${N}`, P_EMAIL = `kontakt${N}@hs.test`, PW = 'Husora!2026', TITLE = `Fensterreinigung ${N}`;
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
  const porg = sql(`select id from organizations where name='${FIRM}'`);
  const cust = () => sql(`select concat_ws('|', first_name, last_name, email, coalesce(phone,'-'), coalesce(street,'-'), coalesce(city,'-'), coalesce(linked_organization_id::text,'-')) from customers where organization_id='${porg}' order by created_at limit 1`);
  const hubLoad = async () => { await H.evaluate(() => { currentPage = 'partnerHub'; hub.tab = 'partners'; render(); }); await H.evaluate(() => ownerLoadPartners().then(() => render())); await H.waitForTimeout(500); };
  await step('Bei der Verbindung: nur Name und E-Mail aus dem Konto', async () => {
    const c = cust(); if (!c.includes('admin@husora.test') || !c.includes('|-|-|-|')) throw new Error(c); return c;
  });
  await step('Partner sieht Hinweis „nicht freigegeben“', async () => {
    const cid = sql(`select id from customers where organization_id='${porg}' limit 1`);
    await P.evaluate(async (id) => { await ppLoad(); pp.view = 'customers'; pp.detail = { type: 'customer', id }; ppRender(); }, cid); await P.waitForTimeout(300);
    const t = await P.textContent('#partner-portal'); if (!t.includes('nicht freigegeben')) throw new Error('kein Hinweis'); return 'Hinweis sichtbar';
  });
  await step('Hausbesitzer: Rückfrage erscheint, Telefon freigeben', async () => {
    await hubLoad();
    await H.waitForSelector(`[data-hub-consent="${spId}"]`, { timeout: 15000 });
    const text = (await H.textContent(`[data-hub-consent="${spId}"]`)).replace(/\s+/g, ' ');
    await H.$eval(`[data-hub-consent="${spId}"]`, (e) => e.scrollIntoView()); await H.screenshot({ path: OUT + '/1-rueckfrage.png' });
    await H.check(`[data-hub-consent="${spId}"] [name=share_phone]`);
    await H.click(`[data-hub-consent="${spId}"] [data-mode=selected]`); await H.waitForFunction(() => !ownerSide.busy, null, { timeout: 20000 }); await H.waitForTimeout(300);
    const c = cust(); if (!c.startsWith('Hanna|Haus|admin@husora.test|+49 170 5551234|-|')) throw new Error(`${c} · ${text}`);
    return `${text.slice(0, 120)} → ${c}`;
  });
  await step('Hausbesitzer: Freigabe ändern, Adresse zusätzlich', async () => {
    await H.click(`[data-owner-action=contact-edit][data-id="${spId}"]`); await H.waitForTimeout(200);
    await H.check(`[data-hub-consent="${spId}"] [name=share_address]`);
    await H.click(`[data-hub-consent="${spId}"] [data-mode=selected]`); await H.waitForFunction(() => !ownerSide.busy, null, { timeout: 20000 }); await H.waitForTimeout(300);
    const c = cust(); const line = await H.textContent('.hub-contact-line');
    if (!c.includes('Lindenweg 4|Hamburg') || sql(`select country from customers where organization_id='${porg}' limit 1`) !== 'DE') throw new Error(c);
    return `${line.trim()} · ${c}`;
  });
  await step('Partner kann die Freigabe nicht selbst setzen', async () => {
    const r = await P.evaluate(async (id) => { try { await ppPatch('service_partners', id, { share_phone: false, contact_decided_at: null }); return 'ok'; } catch (e) { return e.message; } }, spId);
    const v = sql(`select share_phone::text||'/'||(contact_decided_at is not null)::text from service_partners where id='${spId}'`);
    if (v !== 'true/true') throw new Error(`${r} · ${v}`); return `unverändert (${v})`;
  });
  const ORDER = sql(`insert into service_orders (organization_id, property_id, service_partner_id, title, status) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', '${spId}', '${TITLE}', 'offered') returning id`).split('\n')[0];
  await step('Hausbesitzer: Verbindung trennen', async () => {
    await hubLoad();
    await H.click(`[data-owner-action=disconnect][data-id="${spId}"]`); await H.waitForFunction(() => !ownerSide.busy, null, { timeout: 20000 }); await H.waitForTimeout(400);
    const st = sql(`select coalesce(partner_organization_id::text,'-')||'/'||(disconnected_at is not null)::text from service_partners where id='${spId}'`);
    const order = sql(`select status from service_orders where id='${ORDER}'`); const c = cust();
    const note = sql(`select count(*) from notifications where organization_id='${porg}' and title like '%hat die Verbindung getrennt'`);
    await H.screenshot({ path: OUT + '/2-getrennt.png', fullPage: true });
    if (st !== '-/true' || order !== 'cancelled' || !c.includes('|-|-|-|-') || note === '0') throw new Error(`${st} · ${order} · ${c} · ${note}`);
    return `Auftrag ${order} · Kontaktkarte ${c} · Partner benachrichtigt`;
  });
  await step('Partner sieht den Kunden nicht mehr', async () => {
    await P.evaluate(async () => { await ppLoad(); });
    const r = await P.evaluate(() => [ppD('orders').filter((o) => o.organization_id === 'cccccccc-0000-4000-8000-000000000001').length, ppD('properties').filter((p) => p.organization_id === 'cccccccc-0000-4000-8000-000000000001').length, pp.ctx.links.length]);
    if (r.some((n) => n !== 0)) throw new Error(r.join('/')); return 'keine Aufträge, Häuser, Verbindungen';
  });

  console.log(res.join('\n')); if (errs.length) console.log('JS-Fehler:\n' + errs.join('\n'));
  await b.close();
})();
