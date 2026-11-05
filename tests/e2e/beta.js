// Husora Beta Mode: Banner, Feedback, Fehler melden, Analytics, Bewertung, Umfrage, Premium-Interesse, Admin-Dashboard, Schalter
const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON } = require('./env'); const totp = require('./totp'); const OUT = SP + '/audit/beta'; fs.mkdirSync(OUT, { recursive: true });
const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000; const PW = 'Husora!2026';
const sql = (q) => execSync(`psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -At -c "${q.replace(/"/g, '\\"')}"`).toString().trim();
(async () => {
  const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (name, fn) => { try { const r = await fn(); res.push(`OK   ${name}${r ? ' – ' + r : ''}`); } catch (e) { res.push(`FEHL ${name} – ${e.message.split('\n')[0].slice(0, 220)}`); } };
  sql(`update app_config set value = value || '{"enabled": true, "feedback": true, "analytics": true}' where key = 'beta'`);
  const device = async (label, width = 390) => {
    const ctx = await b.newContext({ viewport: { width, height: 844 }, isMobile: width < 600, hasTouch: true });
    const p = await ctx.newPage(); p.on('pageerror', (e) => errs.push(`${label}: ${e.message}`)); p.on('dialog', (d) => d.accept());
    await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
    await p.goto('http://127.0.0.1:8081/index.html');
    await p.evaluate(({ url, key }) => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); localStorage.setItem('husora-cloud', JSON.stringify({ url, key })); localStorage.setItem('husora-beta-ui', '1'); localStorage.setItem('husora-consent', JSON.stringify({ v: '2026-11-02', analytics: true, external_content: false, decidedAt: new Date().toISOString() })); }, { url: URL_, key: ANON });
    await p.reload(); await p.waitForTimeout(800); return p;
  };
  const signIn = async (p, email) => {
    await p.evaluate(() => document.querySelector('.nav [data-page="partnerHub"]').click()); await p.waitForTimeout(300);
    await p.fill('[data-cloud-form=signin] [name=email]', email); await p.fill('[data-cloud-form=signin] [name=password]', PW);
    await p.$eval('[data-cloud-form=signin] button[type=submit]', (e) => e.click());
    await p.waitForFunction(() => cloudReady() && !cloudState.busy, null, { timeout: 20000 }); await p.waitForTimeout(500);
  };
  const flush = (p) => p.evaluate(async () => { await betaFlush(); return JSON.parse(localStorage.getItem('husora-beta-events') || '[]').length; });

  const H = await device('H');
  await step('Beta-Hinweis nur auf der Hauptseite', async () => {
    await H.evaluate(() => { currentPage = 'tasks'; render(); }); await H.waitForTimeout(200);
    const onSub = await H.evaluate(() => Boolean(document.querySelector('#page-content .beta-banner')));
    if (onSub) throw new Error('auf Unterseite sichtbar'); return 'Unterseite ohne Hinweis';
  });
  await step('Banner und Feedback-Button sichtbar', async () => {
    await H.evaluate(() => { currentPage = 'dashboard'; render(); }); await H.waitForTimeout(200);
    const v = await H.evaluate(() => ({ banner: document.querySelector('.beta-banner')?.textContent.replace(/\s+/g, ' '), fab: Boolean(document.querySelector('#beta-fab .beta-fab-main')) }));
    await H.screenshot({ path: OUT + '/1-banner.png' });
    if (!v.banner?.includes('Husora Beta') || !v.fab) throw new Error(JSON.stringify(v)); return v.banner.slice(0, 70);
  });
  const MSG = `Beta-Feedback ${N}`;
  await step('Feedback ohne Konto: Art „Funktion fehlt“ mit Bereich und Rolle', async () => {
    await H.click('#beta-fab .beta-fab-main'); await H.waitForTimeout(200);
    await H.click('[data-beta-form=feedback] .beta-types label:nth-child(3)');
    await H.fill('[data-beta-form=feedback] [name=message]', MSG);
    await H.screenshot({ path: OUT + '/2-feedback.png' });
    await H.click('[data-beta-form=feedback] button[type=submit]'); await H.waitForTimeout(1200);
    const r = sql(`select kind||'/'||feedback_type||'/'||app_role||'/'||page||'/'||coalesce(environment,'')||'/'||(user_id is null) from app_feedback where message='${MSG}'`);
    if (r !== 'feedback/missing/owner/dashboard/development/true') throw new Error(r); return r;
  });
  await step('Anmelden; Aufgabe + Haus speichern → Ereignisse gesendet', async () => {
    await signIn(H, 'admin@husora.test');
    await H.evaluate((n) => {
      tasks.push({ id: `beta-${n}`, title: `Beta-Aufgabe ${n}`, property: properties[0]?.name || '', propertyId: properties[0]?.id, date: localDateKey(new Date()), done: false });
      persistTasks();
      properties.push({ ...properties[0], id: `bh-${n}`, name: `Beta-Haus ${n}`, rooms: 4 }); saveProperties();
      const t = tasks.find((x) => x.id === `beta-${n}`); t.done = true; persistTasks();
    }, N);
    const left = await flush(H);
    const r = sql(`select string_agg(event_name, ',' order by event_name) from analytics_events e join users u on u.id=e.user_id where u.email='admin@husora.test' and entity_ref in ('beta-${N}','bh-${N}')`);
    if (r !== 'house_created,task_completed,task_created') throw new Error(`${left} ${r}`); return r;
  });
  await step('Doppeltes Speichern zählt nicht erneut', async () => {
    await H.evaluate(() => { persistTasks(); saveProperties(); }); await flush(H);
    const n = sql(`select count(*) from analytics_events e join users u on u.id=e.user_id where u.email='admin@husora.test' and entity_ref in ('beta-${N}','bh-${N}')`);
    if (n !== '3') throw new Error(n); return `${n} Ereignisse`;
  });
  const BUG = `Beta-Fehler ${N}`;
  await step('🐞 Fehler melden mit Erwartet/Passiert und Schwere', async () => {
    await H.click('#beta-fab .beta-fab-bug'); await H.waitForTimeout(200);
    await H.selectOption('[data-beta-form=bug] [name=title]', 'Speichern klappt nicht'); await H.selectOption('[data-beta-form=bug] [name=severity]', 'high');
    await H.fill('[data-beta-form=bug] [name=message]', BUG); await H.fill('[data-beta-form=bug] [name=expected]', 'Aufgabe gespeichert'); await H.fill('[data-beta-form=bug] [name=actual]', 'Nichts passiert');
    await H.screenshot({ path: OUT + '/3-bug.png' });
    await H.click('[data-beta-form=bug] button[type=submit]'); await H.waitForTimeout(1200);
    const r = sql(`select a.title||'/'||a.severity||'/'||a.expected_behavior||'/'||a.status||'/'||(a.user_id = u.id) from app_feedback a join users u on u.email='admin@husora.test' where a.message='${BUG}'`);
    if (r !== 'Speichern klappt nicht/high/Aufgabe gespeichert/open/true') throw new Error(r); return r;
  });
  await step('Bewertung nach Hauskontrolle (4 Sterne)', async () => {
    await H.evaluate(() => betaAskRating('inspection', `test-${Date.now()}`)); await H.waitForTimeout(200);
    await H.click('[data-beta-form=rating] .beta-stars label[title="4 von 5"]'); await H.fill('[data-beta-form=rating] [name=comment]', `Rating ${N}`);
    await H.screenshot({ path: OUT + '/4-rating.png' });
    await H.click('[data-beta-form=rating] button[type=submit]'); await H.waitForTimeout(1000);
    const r = sql(`select rating||'/'||context||'/'||app_role from beta_ratings where comment='Rating ${N}'`);
    if (r !== '4/inspection/owner') throw new Error(r); return r;
  });
  await step('Premium vormerken → subscription_interest', async () => {
    await H.evaluate(() => { currentPage = 'help'; render(); }); await H.waitForTimeout(200);
    await H.click('[data-beta-premium=multi_house]'); await flush(H);
    const r = sql(`select count(*) from analytics_events e join users u on u.id=e.user_id where u.email='admin@husora.test' and event_name='subscription_interest' and metadata->>'feature'='multi_house'`);
    if (r !== '1') throw new Error(r); return `${r} Vormerkung`;
  });
  await step('7-Tage-Umfrage einmalig', async () => {
    sql(`delete from beta_ratings where context='day7' and user_id=(select id from users where email='admin@husora.test')`);
    await H.evaluate(() => { const d = new Date(Date.now() - 10 * 86400000); localStorage.setItem('husora-beta-activity', JSON.stringify({ first: localDateKey(d), days: ['a', 'b', 'c', 'd'] })); localStorage.removeItem('husora-beta-survey'); betaMaybeSurvey(); }); await H.waitForTimeout(200);
    const open = await H.evaluate(() => betaS().modal?.kind);
    await H.click('[data-beta-form=day7] .beta-stars label[title="5 von 5"]'); await H.selectOption('[data-beta-form=day7] [name=most_used]', 'Aufgaben');
    await H.click('[data-beta-form=day7] button[type=submit]'); await H.waitForTimeout(1000);
    await H.evaluate(() => betaMaybeSurvey()); const again = await H.evaluate(() => betaS().modal?.kind || '');
    const r = sql(`select rating||'/'||(answers->>'most_used') from beta_ratings where context='day7' and user_id=(select id from users where email='admin@husora.test')`);
    if (open !== 'day7' || again || r !== '5/Aufgaben') throw new Error(`${open} ${again} ${r}`); return r;
  });
  await step('Normale Nutzer: kein Zugriff aufs Dashboard', async () => {
    await H.evaluate(() => { betaS().dash = null; currentPage = 'betaAdmin'; render(); }); await H.waitForTimeout(1500);
    const t = await H.textContent('#page-content'); if (!t.includes('nur für das Husora-Team')) throw new Error(t.slice(0, 200)); return 'gesperrt';
  });
  await step('Partner-Portal zeigt den Beta-Hinweis', async () => {
    await H.evaluate(() => ppOpen('dashboard')); await H.waitForTimeout(500);
    const ok = await H.evaluate(() => Boolean(document.querySelector('#partner-portal .beta-banner.partner')));
    await H.evaluate(() => ppClose()); if (!ok) throw new Error('kein Banner'); return 'Banner im Portal';
  });

  const A = await device('A', 1280);
  await step('Husora-Team: Beta Dashboard mit Kennzahlen, Funnel, KPI-Zielen', async () => {
    sql(`delete from auth.mfa_factors where user_id = (select id from auth.users where email = 'support@husora.test')`);
    await signIn(A, 'support@husora.test');
    // Zwei-Faktor einrichten (TOTP) – Admin-Bereiche verlangen aal2
    await A.evaluate(() => { betaS().dash = null; admS().status = null; admS().mfa = null; currentPage = 'betaAdmin'; render(); });
    await A.waitForSelector('[data-mfa-enroll]', { timeout: 15000 }); await A.click('[data-mfa-enroll]');
    await A.waitForSelector('.mfa-card code', { timeout: 15000 });
    const secret = (await A.textContent('.mfa-card code')).trim();
    await A.screenshot({ path: OUT + '/0-mfa.png' });
    await A.fill('[data-mfa-verify] [name=code]', totp(secret)); await A.click('[data-mfa-verify] button[type=submit]');
    await A.waitForFunction(() => admS().status?.aal === 'aal2', null, { timeout: 15000 });
    await A.evaluate(() => { betaS().dash = null; currentPage = 'betaAdmin'; render(); }); await A.waitForTimeout(2500);
    const v = await A.evaluate(() => ({ tiles: document.querySelectorAll('.beta-kpi').length, funnel: document.querySelectorAll('.beta-funnel li').length, targets: document.querySelectorAll('.beta-target').length, reports: document.querySelectorAll('.beta-report').length }));
    await A.screenshot({ path: OUT + '/5-dashboard.png', fullPage: true });
    if (v.tiles < 15 || v.funnel !== 14 || v.targets !== 8 || !v.reports) throw new Error(JSON.stringify(v)); return JSON.stringify(v);
  });
  await step('Husora-Team: Fehler als erledigt markieren', async () => {
    const id = sql(`select id from app_feedback where message='${BUG}'`);
    await A.evaluate(() => { betaS().dash.filter = 'all'; render(); }); await A.waitForTimeout(200);
    await A.selectOption(`[data-beta-report="${id}"]`, 'resolved'); await A.waitForTimeout(1000);
    const r = sql(`select status||'/'||(resolved_at is not null) from app_feedback where id='${id}'`); if (r !== 'resolved/true') throw new Error(r); return r;
  });
  await step('Beta Mode abschalten wirkt ohne Codeänderung', async () => {
    const setFlag = (on) => A.$eval('[data-beta-flag=enabled]', (el, v) => { el.checked = v; el.dispatchEvent(new Event('change', { bubbles: true })); }, on);
    await setFlag(false); await A.waitForTimeout(1000);
    const cfg = sql(`select value->>'enabled' from app_config where key='beta'`);
    await H.evaluate(async () => { await betaLoadConfig(); currentPage = 'dashboard'; render(); }); await H.waitForTimeout(300);
    const v = await H.evaluate(() => ({ banner: Boolean(document.querySelector('.beta-banner')), fab: Boolean(document.getElementById('beta-fab')) }));
    await setFlag(true); await A.waitForTimeout(800);
    const back = sql(`select value->>'enabled' from app_config where key='beta'`);
    if (cfg !== 'false' || v.banner || v.fab || back !== 'true') throw new Error(`${cfg} ${JSON.stringify(v)} ${back}`); return 'aus → Banner/Button weg → wieder an';
  });
  sql(`update app_config set value = value || '{"enabled": true}' where key = 'beta'`);
  console.log(res.join('\n')); if (errs.length) console.log('JS-Fehler:\n' + errs.join('\n'));
  await b.close();
})();
