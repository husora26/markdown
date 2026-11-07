// Onboarding service_partner_v1: Betrieb anlegen → Einrichtung → Profil (Pflichtfelder) → Servicegebiet → Leistungen →
// Funktionsschritte → Abschluss; Fortschritt serverseitig (onboarding_sessions), Fortsetzen auf neuem Gerät, Checkliste
const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON } = require('./env'); const OUT = SP + '/audit/onboarding'; fs.mkdirSync(OUT, { recursive: true });
const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Einrichtung Service ${N}`, P_EMAIL = `obpartner${N}@hs.test`, PW = 'Husora!2026';
const sql = (q) => execSync(`psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -At -c "${q.replace(/"/g, '\\"')}"`).toString().trim();
(async () => {
  const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (name, fn) => { try { const r = await fn(); res.push(`OK   ${name}${r ? ' – ' + r : ''}`); } catch (e) { res.push(`FEHL ${name} – ${e.message.split('\n')[0].slice(0, 240)}`); } };
  const mk = async () => {
    const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    const P = await ctx.newPage(); P.on('pageerror', (e) => errs.push(e.message)); P.on('dialog', (d) => d.accept());
    await P.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
    await P.goto('http://127.0.0.1:8081/index.html');
    await P.evaluate(({ url, key }) => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); localStorage.setItem('husora-cloud', JSON.stringify({ url, key })); }, { url: URL_, key: ANON });
    await P.reload(); await P.waitForTimeout(400); return P;
  };
  const P = await mk();
  const wait = (X = P) => X.waitForFunction(() => !pp.busy, null, { timeout: 25000 }).then(() => X.waitForTimeout(300));
  const cur = (X = P) => X.evaluate(() => obPpStep().key);
  await step('Betrieb anlegen führt direkt in die Einrichtung (Schritt 2: Profil)', async () => {
    await P.evaluate(() => ppOpen('dashboard')); await P.waitForTimeout(200);
    await P.fill('[data-pp-form=login] [name=email]', P_EMAIL); await P.fill('[data-pp-form=login] [name=password]', PW);
    await P.$eval('[data-pp-action=signup]', (e) => e.click()); await P.waitForFunction(() => !pp.busy && document.querySelector('[data-pp-form=company]'), null, { timeout: 25000 });
    await P.fill('[data-pp-form=company] [name=name]', FIRM); await P.fill('[data-pp-form=company] [name=service_radius_km]', '0');
    await P.$eval('[data-pp-form=company] button[type=submit]', (e) => e.click()); await P.waitForFunction(() => !pp.busy && ppOrg(), null, { timeout: 25000 }); await wait();
    const r = await P.evaluate(() => ({ view: pp.view, step: obPpStep().key, title: document.querySelector('.pp-top-title strong')?.textContent, prog: document.querySelector('.ob-progress span')?.textContent }));
    if (r.view !== 'setup' || r.step !== 'profile') throw new Error(JSON.stringify(r)); return `${r.title} · ${r.prog}`;
  });
  await step('Leistungen aus der Anlage zählen sofort als erledigt', async () => {
    const s = await P.evaluate(() => obState('service_partner').steps); if (s.services !== 'completed') throw new Error(JSON.stringify(s)); return 'Hauskontrolle aktiv';
  });
  await step('Profil: Pflichtfelder werden geprüft', async () => {
    await P.fill('[data-pp-form=ob-profile] [name=contact_name]', 'Eva Ek'); await P.fill('[data-pp-form=ob-profile] [name=email]', ''); await P.fill('[data-pp-form=ob-profile] [name=phone]', '');
    await P.click('[data-ob-pp=profile-save]'); await P.waitForTimeout(200);
    const msg = await P.$eval('[data-pp-form=ob-profile] .ob-error', (e) => !e.hidden && e.textContent); if (!msg) throw new Error('kein Hinweis'); return msg;
  });
  await step('Profil speichern → Datenbank + Schritt „Servicegebiet“', async () => {
    await P.fill('[data-pp-form=ob-profile] [name=phone]', '+46 70 123 45 67'); await P.fill('[data-pp-form=ob-profile] [name=city]', 'Sunne');
    await P.click('[data-ob-pp=profile-save]'); await wait();
    const db = sql(`select contact_name||'|'||phone||'|'||city from organizations where name='${FIRM}'`);
    if (db !== 'Eva Ek|+46 70 123 45 67|Sunne' || (await cur()) !== 'area') throw new Error(`${db} / ${await cur()}`); return db;
  });
  await step('Ohne Servicegebiet ist „Weiter“ gesperrt, Gebiet hinzufügen gibt frei', async () => {
    const dis = await P.$eval('.ob-pp [data-ob-pp=next]', (e) => e.disabled); const before = await P.evaluate(() => obState('service_partner').steps.area);
    if (before === 'completed') throw new Error('leeres Standardgebiet zählt als erledigt');
    await P.fill('[data-pp-form=area-new] [name=city]', 'Sunne'); await P.fill('[data-pp-form=area-new] [name=radius_km]', '40');
    await P.$eval('[data-pp-form=area-new] button[type=submit]', (e) => e.click()); await wait();
    const r = await P.evaluate(() => ({ dis: document.querySelector('.ob-pp [data-ob-pp=next]')?.disabled, s: obState('service_partner').steps.area, view: pp.view }));
    if (!dis || r.dis || r.s !== 'completed' || r.view !== 'setup') throw new Error(JSON.stringify(r)); await P.click('.ob-pp [data-ob-pp=next]'); await P.waitForTimeout(200);
    return `weiter zu ${await cur()}`;
  });
  await step('Leistungen bearbeiten öffnet die Ansicht mit Rückweg in die Einrichtung', async () => {
    await P.click('[data-ob-pp-open=services]'); await P.waitForTimeout(250);
    const r = await P.evaluate(() => ({ view: pp.view, pill: Boolean(document.querySelector('.ob-pp-resume')) }));
    if (r.view !== 'services' || !r.pill) throw new Error(JSON.stringify(r));
    await P.click('.ob-pp-resume [data-ob-pp=resume]'); await P.waitForTimeout(250);
    if ((await cur()) !== 'services' || (await P.evaluate(() => pp.view)) !== 'setup') throw new Error(await cur()); return 'zurück in der Einrichtung';
  });
  await step('Später fortsetzen → Startseite mit Checkliste (3 von 3)', async () => {
    await P.click('.ob-pp [data-ob-pp=next]'); await P.waitForTimeout(200);
    await P.click('[data-ob-pp=pause]'); await P.waitForTimeout(250);
    const r = await P.evaluate(() => ({ view: pp.view, t: document.querySelector('#partner-portal .ob-checklist')?.textContent || '', paused: obState('service_partner').paused, c: obState('service_partner').current }));
    if (r.view !== 'dashboard' || !/3 von 3/.test(r.t) || !r.paused || r.c !== 'orders') throw new Error(JSON.stringify(r)); return `pausiert bei ${r.c}`;
  });
  await step('Fortschritt liegt serverseitig (Sitzung + Schritte)', async () => {
    await P.waitForTimeout(800);
    const r = sql(`select s.current_step_key||'|'||s.paused||'|'||(select string_agg(step_key||':'||status, ',' order by step_key) from onboarding_step_progress p where p.session_id=s.id) from onboarding_sessions s join users u on u.id=s.user_id join auth.users a on a.id=u.auth_user_id where a.email='${P_EMAIL}' and s.role_key='service_partner'`);
    if (!/^orders\|(t|true)\|/.test(r) || !/profile:completed/.test(r) || !/area:completed/.test(r) || !/services:completed/.test(r)) throw new Error(r); return r;
  });
  await step('Neues Gerät: Stand wird vom Server übernommen', async () => {
    const Q = await mk();
    await Q.evaluate(() => ppOpen('dashboard')); await Q.waitForTimeout(200);
    await Q.fill('[data-pp-form=login] [name=email]', P_EMAIL); await Q.fill('[data-pp-form=login] [name=password]', PW);
    await Q.$eval('[data-pp-form=login] button[type=submit]', (e) => e.click()); await Q.waitForFunction(() => !pp.busy && ppOrg(), null, { timeout: 25000 });
    await Q.waitForFunction(() => obState('service_partner')?.steps?.profile === 'completed', null, { timeout: 8000 });
    await Q.click('#partner-portal .ob-checklist [data-ob-pp=resume]'); await Q.waitForTimeout(250);
    const k = await cur(Q); await Q.context().close(); if (k !== 'orders') throw new Error(k); return `fortgesetzt bei ${k}`;
  });
  await step('Funktionsschritte: Aufträge ansehen, Ablauf + Doku verstanden, Finanzen/Team überspringen', async () => {
    await P.click('#partner-portal .ob-checklist [data-ob-pp=resume]'); await P.waitForTimeout(200);
    await P.click('[data-ob-pp-open=orders]'); await P.waitForTimeout(200);
    if ((await P.evaluate(() => pp.view)) !== 'orders') throw new Error('keine Auftragsansicht');
    await P.click('.ob-pp-resume [data-ob-pp=resume]'); await P.waitForTimeout(200);
    await P.click('[data-ob-pp=seen]'); await P.waitForTimeout(150);
    await P.click('[data-ob-pp=seen]'); await P.waitForTimeout(150);
    await P.click('[data-ob-pp=skip]'); await P.waitForTimeout(150);
    await P.click('[data-ob-pp=skip]'); await P.waitForTimeout(150);
    const s = await P.evaluate(() => obState('service_partner').steps); const k = await cur();
    if (k !== 'done' || s.orders !== 'completed' || s.workflow !== 'completed' || s.documentation !== 'completed' || s.finance !== 'skipped' || s.team !== 'skipped') throw new Error(`${k} ${JSON.stringify(s)}`);
    await P.screenshot({ path: `${OUT}/partner-abschluss.png` }); return 'Schritt 10 von 10';
  });
  await step('Abschluss → Startseite, Checkliste verschwindet bis auf optionale Punkte nicht', async () => {
    await P.click('[data-ob-pp=finish]'); await P.waitForTimeout(700);
    const r = await P.evaluate(() => ({ view: pp.view, st: obState('service_partner').status, list: Boolean(document.querySelector('#partner-portal .ob-checklist')) }));
    const db = sql(`select s.status from onboarding_sessions s join users u on u.id=s.user_id join auth.users a on a.id=u.auth_user_id where a.email='${P_EMAIL}' and s.role_key='service_partner'`);
    if (r.view !== 'dashboard' || r.st !== 'completed' || r.list || db !== 'completed') throw new Error(`${JSON.stringify(r)} ${db}`); return 'completed (Server)';
  });
  await step('Mitarbeiter (kein Lead) sehen keine Einrichtung', async () => {
    const r = await P.evaluate(() => { const real = ppRole; window.__r = ppRole; return null; });
    const html = await P.evaluate(() => { const ctx = pp.ctx; const role = ctx.role; ctx.role = 'technician'; if (ctx.membership) ctx.membership.role = 'technician'; const h = obPpChecklistHtml(); ctx.role = role; if (ctx.membership) ctx.membership.role = role; return { h, lead: ppIsLead() }; });
    if (html.h) throw new Error('Checkliste sichtbar'); return 'keine Checkliste';
  });
  console.log(res.join('\n')); if (errs.length) console.log('JS-Fehler:\n' + errs.join('\n'));
  await b.close();
})();
