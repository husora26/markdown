// Phase 9: Benachrichtigungen je Kategorie, Push-Einrichtung, Chat-Anhänge im Auftragsgespräch
const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON } = require('./env'); const OUT = SP + '/audit/notify'; fs.mkdirSync(OUT, { recursive: true });
const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Notify Service ${N}`, P_EMAIL = `notify${N}@hs.test`, PW = 'Husora!2026', TITLE = `Notify-Einsatz ${N}`;
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
  sql(`update app_config set value = '{"vapid_public_key": null}' where key = 'push'`);

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
  const ORDER = sql(`insert into service_orders (organization_id, property_id, service_partner_id, title, status, currency) values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', '${spId}', '${TITLE}', 'offered', 'SEK') returning id`).split('\n')[0];
  sql(`update service_orders set status='accepted' where id='${ORDER}'`);
  const PDF = Buffer.from('%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj 2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj 3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF');
  await step('Partner: Datei im Auftragsgespräch anhängen', async () => {
    await P.evaluate(async (id) => { await ppLoad(); pp.view = 'orders'; pp.detail = { type: 'order', id }; pp.form = null; ppRender(); }, ORDER); await P.waitForTimeout(300);
    await P.setInputFiles(`[data-pp-chat-attach="${ORDER}"]`, { name: `Befund-${N}.pdf`, mimeType: 'application/pdf', buffer: PDF }); await wait(); await noErr();
    const r = sql(`select (document_id is not null)||'/'||message from messages where service_order_id='${ORDER}' and message like '📎%'`);
    await P.evaluate((id) => { pp.detail = { type: 'order', id }; ppRender(); document.querySelector('.pp-thread')?.scrollIntoView(); }, ORDER); await P.waitForTimeout(300);
    const btn = await P.evaluate(() => Boolean(document.querySelector('.pp-thread .chat-attach')));
    await P.screenshot({ path: OUT + '/1-partner-anhang.png' });
    if (r !== `true/📎 Befund-${N}.pdf` || !btn) throw new Error(`${r} ${btn}`); return r;
  });
  await step('Hausbesitzer: Benachrichtigung (Nachricht) und Anhang im Gespräch', async () => {
    const n = sql(`select count(*) from notifications where category='message' and entity_id='${ORDER}' and organization_id='cccccccc-0000-4000-8000-000000000001'`);
    await H.evaluate(async (id) => { await ownerLoadPartners(); currentPage = 'partnerHub'; hub.tab = 'chat'; hub.thread = { kind: 'order', id }; render(); }, ORDER); await H.waitForTimeout(400);
    const btn = await H.evaluate(() => document.querySelector('.hub-messages .chat-attach')?.textContent.trim());
    await H.screenshot({ path: OUT + '/2-besitzer-anhang.png' });
    if (Number(n) < 1 || !btn?.includes(`Befund-${N}.pdf`)) throw new Error(`${n} ${btn}`);
    await H.click('.hub-messages .chat-attach'); await H.waitForTimeout(1500);
    const opened = await H.evaluate(() => Boolean(document.querySelector('#pdf-viewer-modal.open, #pdf-viewer-modal[open], .pdf-viewer.open')) || !document.querySelector('#toast.show'));
    if (!opened) throw new Error(await H.evaluate(() => document.querySelector('#toast')?.textContent)); return `${n} Benachrichtigung · ${btn}`;
  });
  await step('Hausbesitzer: Nachricht an den Partner → Partner wird benachrichtigt', async () => {
    await H.keyboard.press('Escape'); await H.evaluate(() => { document.querySelectorAll('.modal.open, #pdf-viewer-modal.open').forEach((m) => m.classList.remove('open')); hub.thread = { kind: 'order', id: hub.thread.id }; render(); }); await H.waitForTimeout(300);
    await H.evaluate(() => { const t = document.querySelector('[data-hub-send] textarea'); t.value = 'Danke für den Befund'; }); await H.$eval('[data-hub-send] button[type=submit]', (e) => e.click()); await H.waitForTimeout(1500);
    const porg = sql(`select id from organizations where name='${FIRM}'`);
    const n = sql(`select count(*) from notifications where organization_id='${porg}' and category='message' and message='Danke für den Befund'`);
    if (n !== '1') throw new Error(n); return `${n} Benachrichtigung beim Partner`;
  });
  await step('Hausbesitzer: Einstellungen je Kategorie (E-Mail für Nachrichten an)', async () => {
    await H.evaluate(() => { currentPage = 'settings'; settingsView = 'settings-look'; render(); }); await H.waitForTimeout(1200);
    const rows = await H.evaluate(() => document.querySelectorAll('#settings-cloud-notify .notify-row:not(.head)').length);
    await H.$eval('[data-notify-pref="message|email"]', (el) => { el.checked = true; el.dispatchEvent(new Event('change', { bubbles: true })); }); await H.waitForTimeout(1000);
    await H.evaluate(() => document.getElementById('settings-cloud-notify')?.scrollIntoView()); await H.screenshot({ path: OUT + '/3-besitzer-einstellungen.png' });
    const r = sql(`select p.in_app||'/'||p.push||'/'||p.email from notification_preferences p join users u on u.id=p.user_id where u.email='admin@husora.test' and category='message'`);
    if (rows !== 8 || r !== 'true/true/true') throw new Error(`${rows} ${r}`); return `${rows} Kategorien · ${r}`;
  });
  await step('Partner: Einstellungen im Portal (Aufträge ohne Push), Push-Hinweis ohne Schlüssel', async () => {
    await P.evaluate(() => { notifyS().prefs = null; pp.detail = null; pp.view = 'settings'; ppRender(); }); await P.waitForTimeout(1200);
    const hint = await P.evaluate(() => document.querySelector('#partner-portal .notify-table')?.parentElement.textContent.includes('gerade eingerichtet'));
    await P.$eval('#partner-portal [data-notify-pref="order|push"]', (el) => { el.checked = false; el.dispatchEvent(new Event('change', { bubbles: true })); }); await P.waitForTimeout(1000);
    const r = sql(`select p.in_app||'/'||p.push||'/'||p.email from notification_preferences p join users u on u.id=p.user_id where u.email='${P_EMAIL}' and category='order'`);
    if (!hint || r !== 'true/false/false') throw new Error(`${hint} ${r}`); return r;
  });
  await step('Mit öffentlichem VAPID-Schlüssel: „Push aktivieren“ angeboten', async () => {
    sql(`update app_config set value = '{"vapid_public_key": "BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFgDzkrxZJjSgSnfckjBJuBkr3qBUYIHBQFLXYp5Nksh8U"}' where key = 'push'`);
    await P.evaluate(() => { notifyS().prefs = null; ppRender(); }); await P.waitForTimeout(1200);
    const btn = await P.evaluate(() => document.querySelector('#partner-portal [data-notify-device]')?.textContent.trim());
    await P.screenshot({ path: OUT + '/4-partner-einstellungen.png' });
    sql(`update app_config set value = '{"vapid_public_key": null}' where key = 'push'`);
    if (btn !== 'Aktivieren') throw new Error(btn); return btn;
  });
  console.log(res.join('\n')); if (errs.length) console.log('JS-Fehler:\n' + errs.join('\n'));
  await b.close();
})();
