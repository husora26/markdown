const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON: ENV_ANON } = require('./env'); const OUT = SP + '/audit/auth'; fs.mkdirSync(OUT, { recursive: true });
const ANON = ENV_ANON; const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000; const PW = 'Husora!2026';
const sql = (q) => execSync(`psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -At -c "${q.replace(/"/g, '\\"')}"`).toString().trim();
(async () => {
  const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (name, fn) => { try { const r = await fn(); res.push(`OK   ${name}${r ? ' – ' + r : ''}`); } catch (e) { res.push(`FEHL ${name} – ${e.message.split('\n')[0].slice(0, 220)}`); } };
  const device = async (label, stored) => {
    const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    const p = await ctx.newPage(); p.on('pageerror', (e) => errs.push(`${label}: ${e.message}`)); p.on('dialog', (d) => d.type() === 'prompt' ? d.accept('NeuesPasswort!1') : d.accept());
    await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
    await p.goto('http://127.0.0.1:8081/index.html');
    await p.evaluate((s) => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); if (s) localStorage.setItem('husora-cloud', JSON.stringify(s)); }, stored === undefined ? { url: URL_, key: ANON } : stored);
    await p.reload(); await p.waitForTimeout(400); return p;
  };
  await step('Alte leere Verbindung wird durch das Husora-Projekt ersetzt', async () => {
    const p = await device('alt', { url: '', key: '', autoSync: true, deviceId: 'x' });
    const r = await p.evaluate(() => [cloudConnected(), cloud.url].join(' · ')); await p.context().close(); return r;
  });
  await step('Bewusst getrennte Verbindung bleibt getrennt', async () => {
    const p = await device('getrennt', { url: '', key: '', disconnected: true });
    const r = await p.evaluate(() => cloudConnected()); await p.context().close(); if (r) throw new Error('wieder verbunden'); return 'getrennt';
  });
  // Ihre Situation: Konto nur als Servicepartner
  const EMAIL = `fiona${N}@service.test`;
  const P = await device('P');
  await step('Servicepartner: Konto + Betrieb im Partner-Portal', async () => {
    await P.evaluate(() => ppOpen('dashboard')); await P.waitForTimeout(200);
    await P.fill('[data-pp-form=login] [name=email]', EMAIL); await P.fill('[data-pp-form=login] [name=password]', PW);
    await P.$eval('[data-pp-action=signup]', (e) => e.click()); await P.waitForFunction(() => !pp.busy && document.querySelector('[data-pp-form=company]'), null, { timeout: 20000 });
    await P.fill('[data-pp-form=company] [name=name]', `Husora Service ${N}`); await P.$eval('[data-pp-form=company] button[type=submit]', (e) => e.click());
    await P.waitForFunction(() => !pp.busy && ppOrg(), null, { timeout: 20000 });
    return sql(`select string_agg(o.org_type||'/'||m.role, ', ') from organization_members m join users u on u.id=m.user_id join organizations o on o.id=m.organization_id where u.email='${EMAIL}'`);
  });
  await step('Gleiches Gerät → Hausbesitzer-Partner-Portal: Anmeldung wird anerkannt (kein erneutes Login)', async () => {
    await P.evaluate(() => ppClose()); await P.evaluate(() => document.querySelector('.nav [data-page="partnerHub"]').click());
    await P.waitForFunction(() => cloudReady() && !cloudState.busy, null, { timeout: 20000 }); await P.waitForTimeout(500);
    await P.screenshot({ path: OUT + '/1-anerkannt.png' });
    const login = !!(await P.$('[data-cloud-form=signin]'));
    if (login) throw new Error('Anmeldeformular wird erneut verlangt');
    return `Reiter: ${await P.evaluate(() => document.querySelectorAll('.hub-tabs button').length)} · Organisationen: ${sql(`select string_agg(o.org_type||'/'||m.role, ', ' order by o.org_type) from organization_members m join users u on u.id=m.user_id join organizations o on o.id=m.organization_id where u.email='${EMAIL}'`)}`;
  });
  await step('Zurück ins Servicepartner-Portal: weiterhin der eigene Betrieb', async () => {
    await P.evaluate(() => ppOpen('dashboard')); await P.waitForFunction(() => !pp.busy && pp.ctx, null, { timeout: 15000 });
    return await P.evaluate(() => `${ppOrg()?.name} (${ppRole()})`);
  });
  // Registrierung mit bestehender E-Mail (Supabase antwortet ohne Fehler, aber ohne Identitäten)
  const H = await device('H');
  await H.route('**/auth/v1/signup**', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: '00000000-0000-4000-8000-000000000999', aud: 'authenticated', role: '', email: EMAIL, identities: [], confirmation_sent_at: new Date().toISOString() }) }));
  await step('Registrierung mit bereits vergebener E-Mail → klare Meldung', async () => {
    await H.evaluate(() => { currentPage = 'partnerHub'; render(); }); await H.waitForTimeout(200);
    await H.fill('[data-cloud-form=signin] [name=email]', EMAIL); await H.fill('[data-cloud-form=signin] [name=password]', PW);
    await H.$eval('[data-cloud-action=signup]', (e) => e.click()); await H.waitForFunction(() => !cloudState.busy, null, { timeout: 10000 });
    await H.screenshot({ path: OUT + '/2-vorhanden.png' });
    return await H.evaluate(() => cloudState.error);
  });
  await H.unroute('**/auth/v1/signup**');
  await H.route('**/auth/v1/signup**', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: '00000000-0000-4000-8000-000000000998', email: 'neu@x.test', identities: [{ id: 'x', provider: 'email' }], confirmation_sent_at: new Date().toISOString() }) }));
  let resent = 0, recovered = 0;
  await H.route('**/auth/v1/resend**', (r) => { resent += 1; r.fulfill({ status: 200, contentType: 'application/json', body: '{}' }); });
  await H.route('**/auth/v1/recover**', (r) => { recovered += 1; r.fulfill({ status: 200, contentType: 'application/json', body: '{}' }); });
  await step('Registrierung mit Bestätigungs-Mail → Hinweis + „erneut senden“', async () => {
    await H.fill('[data-cloud-form=signin] [name=email]', 'neu@x.test'); await H.fill('[data-cloud-form=signin] [name=password]', PW);
    await H.$eval('[data-cloud-action=signup]', (e) => e.click()); await H.waitForFunction(() => !cloudState.busy, null, { timeout: 10000 });
    const notice = await H.evaluate(() => cloudState.notice);
    await H.$eval('[data-cloud-action=resend]', (e) => e.click()); await H.waitForFunction(() => !cloudState.busy, null, { timeout: 10000 });
    await H.screenshot({ path: OUT + '/3-bestaetigung.png' });
    return `${notice.slice(0, 60)}… · erneut gesendet: ${resent}`;
  });
  await step('Passwort vergessen', async () => {
    await H.fill('[data-cloud-form=signin] [name=email]', EMAIL); await H.$eval('[data-cloud-action=recover]', (e) => e.click()); await H.waitForFunction(() => !cloudState.busy, null, { timeout: 10000 });
    return `${await H.evaluate(() => cloudState.notice)} · Anfragen: ${recovered}`;
  });
  await step('Partner-Portal: Registrierung mit vergebener E-Mail → klare Meldung', async () => {
    await H.unroute('**/auth/v1/signup**');
    await H.route('**/auth/v1/signup**', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'y', email: EMAIL, identities: [] }) }));
    await H.evaluate(() => ppOpen('dashboard')); await H.waitForTimeout(200);
    await H.fill('[data-pp-form=login] [name=email]', EMAIL); await H.fill('[data-pp-form=login] [name=password]', PW);
    await H.$eval('[data-pp-action=signup]', (e) => e.click()); await H.waitForFunction(() => !pp.busy, null, { timeout: 10000 });
    await H.screenshot({ path: OUT + '/4-portal-vorhanden.png' });
    return await H.evaluate(() => pp.error);
  });
  await step('Link aus der Bestätigungs-Mail meldet automatisch an', async () => {
    const tok = await fetch(`${URL_}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email: EMAIL, password: PW }) }).then((x) => x.json());
    const L = await device('L');
    await L.goto('about:blank'); await L.goto(`http://127.0.0.1:8081/index.html#access_token=${tok.access_token}&refresh_token=${tok.refresh_token}&expires_in=3600&token_type=bearer&type=signup`);
    await L.waitForFunction(() => cloud.session?.email, null, { timeout: 10000 }); await L.waitForTimeout(300);
    return `${await L.evaluate(() => cloud.session.email)} · Adresse bereinigt: ${await L.evaluate(() => !location.hash)} · Toast: ${await L.evaluate(() => document.getElementById('toast')?.textContent)}`;
  });
  console.log(res.join('\n')); console.log(errs.length ? 'JS-Fehler:\n' + [...new Set(errs)].join('\n') : 'keine JS-Fehler'); await b.close();
})();
