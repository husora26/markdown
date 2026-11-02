// Partner: neue Anfragen auf der Startseite ausblenden; mehrere Anfragen gemeinsam annehmen und einem Mitarbeiter zuordnen
const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON } = require('./env'); const OUT = SP + '/audit/multi'; fs.mkdirSync(OUT, { recursive: true });
const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Multi Service ${N}`, P_EMAIL = `multi${N}@hs.test`, PW = 'Husora!2026', TITLE = `Gästewechsel ${N}`;
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
  const ids = [1, 2, 3].map((n) => sql(`insert into service_orders (organization_id, property_id, service_partner_id, title, status) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', '${spId}', '${TITLE} ${n}', 'offered') returning id`).split('\n')[0]);
  // Mitarbeiter direkt anlegen (Einladung ist in anderen Tests abgedeckt)
  const TECH = `tech${N}@hs.test`;
  sql(`insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', '${TECH}', '', now(), '{"provider":"email","providers":["email"]}', '{"first_name":"Tina","last_name":"Technik"}', now(), now())`);
  sql(`insert into organization_members (organization_id, user_id, role, status) select '${porg}', id, 'technician', 'active' from users where email='${TECH}'`);
  const techId = sql(`select id from users where email='${TECH}'`);
  await step('Startseite zeigt neue Anfragen', async () => {
    await P.evaluate(async () => { await ppLoad(); pp.view = 'dashboard'; pp.detail = null; ppRender(); }); await P.waitForTimeout(300);
    const t = await P.textContent('#partner-portal .pp-main'); if (!t.includes('Neue Anfragen')) throw new Error('fehlt'); return 'sichtbar';
  });
  await step('Einstellungen → Darstellung: neue Anfragen ausblenden', async () => {
    await P.evaluate(() => { pp.view = 'settings'; ppRender(); }); await P.waitForTimeout(200);
    await P.uncheck('[data-pp-home-pref=showOffered]'); await P.waitForTimeout(200);
    await P.evaluate(() => { pp.view = 'dashboard'; ppRender(); }); await P.waitForTimeout(200);
    const t = await P.textContent('#partner-portal .pp-main'); await P.screenshot({ path: OUT + '/1-startseite.png', fullPage: true });
    if (t.includes('Neue Anfragen')) throw new Error('noch sichtbar'); return `ausgeblendet · Menü-Zahl bleibt: ${await P.evaluate(() => ppD('orders').filter((o) => o.status === 'offered').length)}`;
  });
  await step('Aufträge → Neu: drei Anfragen auswählen, Mitarbeiter wählen, gemeinsam annehmen', async () => {
    await P.evaluate(() => { pp.view = 'orders'; pp.filter = 'new'; pp.sel.clear(); ppRender(); }); await P.waitForTimeout(200);
    for (const id of ids) { await P.check(`[data-pp-select="${id}"]`); await P.waitForTimeout(80); }
    await P.selectOption('[data-pp-batch-member]', techId);
    await P.screenshot({ path: OUT + '/2-auswahl.png' });
    await P.click('[data-pp-batch=accept]'); await wait(); await noErr();
    const st = sql(`select string_agg(status||':'||(assigned_user_id='${techId}')::text, ',' order by title) from service_orders where id in ('${ids.join("','")}')`);
    if (st !== 'accepted:true,accepted:true,accepted:true') throw new Error(st); return st;
  });
  await step('Laufende Aufträge gemeinsam einem anderen Mitarbeiter zuordnen', async () => {
    const me = await P.evaluate(() => ppMe());
    await P.evaluate(() => { pp.filter = 'active'; pp.sel.clear(); ppRender(); }); await P.waitForTimeout(200);
    for (const id of ids.slice(0, 2)) await P.check(`[data-pp-select="${id}"]`);
    await P.selectOption('[data-pp-batch-member]', me); await P.click('[data-pp-batch=assign]'); await wait(); await noErr();
    const st = sql(`select string_agg((assigned_user_id='${me}')::text, ',' order by title) from service_orders where id in ('${ids.join("','")}')`);
    if (st !== 'true,true,false') throw new Error(st); return 'zwei umgeteilt, einer unverändert';
  });
  await step('Zuordnen ohne Mitarbeiter: Hinweis statt Fehler', async () => {
    await P.evaluate(() => { pp.batchMember = ''; ppRender(); }); await P.selectOption('[data-pp-batch-member]', '');
    await P.click('[data-pp-batch=assign]'); await P.waitForTimeout(200); return 'Hinweis angezeigt';
  });

  console.log(res.join('\n')); if (errs.length) console.log('JS-Fehler:\n' + errs.join('\n'));
  await b.close();
})();
