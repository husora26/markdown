const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON: ENV_ANON } = require('./env'); const OUT = SP + '/audit/launch'; fs.mkdirSync(OUT, { recursive: true });
const ANON = ENV_ANON; const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const sql = (q) => execSync(`psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -At -c "${q.replace(/"/g, '\\"')}"`).toString().trim();
(async () => { const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (n, f) => { try { res.push(`OK   ${n} – ${await f()}`); } catch (e) { res.push(`FEHL ${n} – ${e.message.split('\n')[0].slice(0, 240)}`); } };
  const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true }); const p = await ctx.newPage();
  p.on('pageerror', (e) => errs.push(e.message)); p.on('dialog', (d) => d.accept());
  await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr|tile/, (r) => r.abort());
  await p.goto('http://127.0.0.1:8081/index.html');
  await p.evaluate(({ url, key }) => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); localStorage.setItem('husora-cloud', JSON.stringify({ url, key })); }, { url: URL_, key: ANON });
  await p.reload(); await p.waitForTimeout(600);
  await step('Feedback ohne Konto senden (Hilfe & Support)', async () => {
    await p.evaluate(() => { currentPage = 'help'; render(); }); await p.waitForTimeout(200);
    await p.click('[data-feedback-form] input[value=bug] + span'); await p.fill('[data-feedback-form] [name=message]', `Testfeedback ${N}: Knopf reagiert nicht`); await p.fill('[data-feedback-form] [name=email]', 'tester@husora.test');
    await p.evaluate(() => document.getElementById('feedback').scrollIntoView()); await p.screenshot({ path: OUT + '/1-feedback.png' });
    await p.$eval('[data-feedback-form] button[type=submit]', (e) => e.click()); await p.waitForTimeout(800);
    const row = sql(`select kind||' · '||coalesce(contact_email,'')||' · user='||coalesce(auth_user_id::text,'–')||' · '||page from app_feedback where message like 'Testfeedback ${N}%'`);
    if (!row) throw new Error(await p.evaluate(() => document.getElementById('toast').textContent)); return row; });
  await step('Automatischer Fehlerbericht bei JS-Fehler', async () => {
    await p.evaluate((n) => setTimeout(() => { throw new Error(`Testfehler ${n}`); }, 0), N); await p.waitForTimeout(1000);
    const row = sql(`select kind||' · '||left(context->>'stack', 40) from app_feedback where message like '%Testfehler ${N}%'`); if (!row) throw new Error('kein Bericht'); return row; });
  await step('Fehlerberichte abschaltbar', async () => {
    await p.evaluate(() => document.querySelector('[data-error-reports]').click()); await p.waitForTimeout(100);
    await p.evaluate((n) => setTimeout(() => { throw new Error(`Aus-Fehler ${n}`); }, 0), N); await p.waitForTimeout(800);
    await p.evaluate(() => document.querySelector('[data-error-reports]').click());
    return `gesendet trotz Aus: ${sql(`select count(*) from app_feedback where message like '%Aus-Fehler ${N}%'`)}`; });
  await step('Niemand kann Feedback lesen (nur Dashboard/service_role)', async () => {
    const r = await p.evaluate(async ({ url, key }) => { const res = await fetch(`${url}/rest/v1/app_feedback?select=id&limit=1`, { headers: { apikey: key, Authorization: `Bearer ${key}` } }); return `${res.status} ${JSON.stringify(await res.json()).slice(0, 60)}`; }, { url: URL_, key: ANON });
    return r; });
  await step('Offline-Hinweis', async () => {
    await ctx.setOffline(true); await p.evaluate(() => window.dispatchEvent(new Event('offline'))); await p.waitForTimeout(200);
    const t = await p.evaluate(() => document.getElementById('offline-banner')?.textContent || ''); await p.screenshot({ path: OUT + '/2-offline.png' });
    await ctx.setOffline(false); await p.evaluate(() => window.dispatchEvent(new Event('online'))); await p.waitForTimeout(200);
    if (!t) throw new Error('kein Hinweis'); return `${t.slice(0, 50)}… · danach weg: ${await p.evaluate(() => !document.getElementById('offline-banner'))}`; });
  await step('Benachrichtigung in der Glocke, wenn ein Partner einen Auftrag annimmt', async () => {
    await p.evaluate(() => { currentPage = 'settings'; settingsView = 'settings-data'; render(); });
    await p.fill('[data-cloud-form=signin] [name=email]', 'admin@husora.test'); await p.fill('[data-cloud-form=signin] [name=password]', 'Husora!2026');
    await p.$eval('[data-cloud-form=signin] button[type=submit]', (e) => e.click()); await p.waitForFunction(() => cloudReady() && !cloudState.busy, null, { timeout: 20000 });
    await p.evaluate(() => loadCloudNotices()); await p.waitForTimeout(300);
    const oid = sql(`select o.id from service_orders o join service_partners sp on sp.id=o.service_partner_id where o.organization_id='cccccccc-0000-4000-8000-000000000001' and o.status='offered' and sp.partner_organization_id is not null and sp.partner_organization_id<>o.organization_id order by o.created_at desc limit 1`);
    sql(`update service_orders set status='accepted', response_note='Komme am Montag' where id='${oid}'`);
    await p.evaluate(() => loadCloudNotices()); await p.waitForTimeout(400);
    const toast = await p.evaluate(() => document.getElementById('toast').textContent);
    await p.click('#notify-toggle'); await p.waitForTimeout(200); await p.screenshot({ path: OUT + '/3-glocke.png' });
    const item = await p.evaluate(() => [...document.querySelectorAll('[data-notify-open^="cloud-"]')].map((e) => e.innerText.replace(/\s+/g, ' ')).slice(0, 2).join(' | '));
    await p.click('[data-notify-open^="cloud-"]'); await p.waitForTimeout(600);
    const read = sql(`select count(*) from notifications where entity_id='${oid}' and title like '%angenommen%' and read_at is not null`);
    if (!item) throw new Error('kein Eintrag · ' + toast); return `Hinweis: ${toast.slice(0, 60)} · Glocke: ${item.slice(0, 110)} · gelesen: ${read} · Seite: ${await p.evaluate(() => currentPage)}`; });
  await step('Stripe: ohne Preis-ID E-Mail-Anfrage, mit Preis-ID Checkout-Knopf', async () => {
    await p.evaluate(() => { currentPage = 'plans'; render(); }); await p.waitForTimeout(200);
    const before = await p.$$eval('.plan-card .plan-action > *', (e) => e.map((x) => x.tagName.toLowerCase()).join(','));
    sql(`update plans set stripe_price_id='price_test_plus' where id='plus'`);
    await p.evaluate(() => loadPlanCatalog()); await p.waitForTimeout(500); await p.evaluate(() => render());
    const btn = await p.$('[data-plan-checkout="plus"]'); if (btn) { await btn.click(); await p.waitForTimeout(800); }
    const toast = await p.evaluate(() => document.getElementById('toast').textContent);
    sql(`update plans set stripe_price_id=null where id='plus'`); await p.evaluate(() => loadPlanCatalog());
    return `vorher: ${before} · Checkout-Knopf: ${!!btn} · ohne Edge Function: ${toast.slice(0, 80)}`; });
  await step('Konto löschen: Konto, Organisation und Dateien weg', async () => {
    await p.evaluate(() => cloudSignOut?.()); 
    const email = `del${N}@husora.test`;
    const p2 = await ctx.newPage(); await p2.route(/unpkg|cdnjs|openstreetmap|google|jsdelivr|paypal|open-meteo|tile/, (r) => r.abort()); p2.on('dialog', (d) => d.accept()); p2.on('pageerror', (e) => errs.push(e.message));
    await p2.goto('http://127.0.0.1:8081/index.html'); await p2.evaluate(({ url, key }) => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); localStorage.setItem('husora-cloud', JSON.stringify({ url, key })); }, { url: URL_, key: ANON }); await p2.reload(); await p2.waitForTimeout(500);
    await p2.evaluate(() => { currentPage = 'settings'; settingsView = 'settings-data'; render(); });
    await p2.fill('[data-cloud-form=signin] [name=email]', email); await p2.fill('[data-cloud-form=signin] [name=password]', 'Husora!2026');
    await p2.$eval('[data-cloud-action=signup]', (e) => e.click()); await p2.waitForFunction(() => cloudReady() && !cloudState.busy, null, { timeout: 20000 });
    await p2.evaluate(() => { const c = document.createElement('canvas'); c.width = 60; c.height = 40; properties[0].photo = c.toDataURL('image/jpeg'); saveProperties(); });
    await p2.$eval('[data-cloud-action=upload]', (e) => e.click()); await p2.waitForFunction(() => !cloudState.busy, null, { timeout: 30000 }); await p2.waitForTimeout(500);
    const org = await p2.evaluate(() => cloud.org.id);
    const before = `${sql(`select count(*) from storage.objects where name like 'organization/${org}/%'`)} Dateien, ${sql(`select count(*) from app_data where organization_id='${org}'`)} Bereiche`;
    await p2.evaluate(() => { document.querySelector('.cloud-danger').open = true; document.querySelector('.cloud-danger').scrollIntoView(); }); await p2.screenshot({ path: OUT + '/4-loeschen.png' });
    await p2.fill('[data-account-delete] [name=confirm]', 'LÖSCHEN'); await p2.$eval('[data-account-delete] button[type=submit]', (e) => e.click());
    await p2.waitForFunction(() => !cloud.session, null, { timeout: 30000 }); await p2.waitForTimeout(500);
    const after = `${sql(`select count(*) from storage.objects where name like 'organization/${org}/%'`)} Dateien · Org: ${sql(`select count(*) from organizations where id='${org}'`)} · Konto: ${sql(`select count(*) from auth.users where email='${email}'`)} · lokal behalten: ${await p2.evaluate(() => properties.length)} Häuser`;
    if (!/^0 Dateien · Org: 0 · Konto: 0/.test(after)) throw new Error(`${before} → ${after}`); return `${before} → ${after}`; });
  console.log(res.join('\n')); const real = errs.filter((e) => !/Testfehler|Aus-Fehler/.test(e)); console.log(real.length ? 'JS-Fehler:\n' + [...new Set(real)].join('\n') : 'keine JS-Fehler'); await b.close(); })();
