// Onboarding – Unit-Tests der Logik im Browser (ohne Server): Flow-Auswahl, Reihenfolge, Übergänge, Fortschritt,
// Wiederaufnahme, Versionierung, Checkliste aus echten Daten, Server-Sync Hausbesitzer (Konto, neues Gerät)
const { chromium } = require('playwright'); const { execSync } = require('child_process');
const { ANON } = require('./env');
const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000; const EMAIL = `obowner${N}@hs.test`, PW = 'Husora!2026';
const sql = (q) => execSync(`psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -At -c "${q.replace(/"/g, '\\"')}"`).toString().trim();
(async () => {
  const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (name, fn) => { try { const r = await fn(); res.push(`OK   ${name}${r ? ' – ' + r : ''}`); } catch (e) { res.push(`FEHL ${name} – ${e.message.split('\n')[0].slice(0, 240)}`); } };
  const mk = async (cloud) => {
    const p = await (await b.newContext()).newPage(); p.on('pageerror', (e) => errs.push(e.message));
    await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
    await p.goto('http://127.0.0.1:8081/index.html');
    await p.evaluate(({ url, key, cloud }) => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); if (cloud) localStorage.setItem('husora-cloud', JSON.stringify({ url, key })); }, { url: URL_, key: ANON, cloud });
    await p.reload(); await p.waitForTimeout(500); return p;
  };
  const p = await mk(false);
  const ev = (fn, arg) => p.evaluate(fn, arg);

  await step('Flow-Auswahl je Rolle und Version', async () => {
    const r = await ev(() => ({ h: OB_FLOWS.homeowner.version, s: OB_FLOWS.service_partner.version, roles: Object.keys(OB_FLOWS) }));
    if (r.h !== 'homeowner_v1' || r.s !== 'service_partner_v1' || r.roles.length !== 2) throw new Error(JSON.stringify(r)); return `${r.h}, ${r.s}`;
  });
  await step('Schritt-Reihenfolge entspricht der Spezifikation und dem Server', async () => {
    const r = await ev(() => [OB_FLOWS.homeowner.steps.map((x) => x.key).join(','), OB_FLOWS.service_partner.steps.map((x) => x.key).join(',')]);
    const srv = sql("select private.onboarding_flow_steps('homeowner_v1')::text || '|' || private.onboarding_flow_steps('service_partner_v1')::text");
    if (r[0] !== 'welcome,property,profile,task,inspection,automation,partners,organize,done' || r[1] !== 'welcome,profile,area,services,orders,workflow,documentation,finance,team,done') throw new Error(r.join(' | '));
    if (srv.replace(/[{}]/g, '').replace('|', ' | ') !== r.join(' | ')) throw new Error(`Server: ${srv}`); return 'Client = Server';
  });
  await step('Nicht überspringbar: nur Willkommen und Abschluss', async () => {
    const r = await ev(() => Object.values(OB_FLOWS).flatMap((f) => f.steps.filter((x) => !x.skippable).map((x) => x.key)));
    if (r.join() !== 'welcome,done,welcome,done') throw new Error(r.join()); return 'ok';
  });
  await step('Übergänge: übersprungen → erledigt erlaubt, erledigt bleibt erledigt', async () => {
    const r = await ev(() => {
      localStorage.removeItem(obKey('homeowner')); obStart('homeowner');
      obMark('homeowner', 'property', 'skipped'); const a = obState('homeowner').steps.property;
      obMark('homeowner', 'property', 'completed'); const b2 = obState('homeowner').steps.property;
      obMark('homeowner', 'property', 'skipped'); const c = obState('homeowner').steps.property;
      obMark('homeowner', 'property', 'in_progress'); const d = obState('homeowner').steps.property;
      return [a, b2, c, d];
    });
    if (r.join() !== 'skipped,completed,completed,completed') throw new Error(r.join()); return r.join(' → ');
  });
  await step('Fortschritt zählt nur erledigte Schritte ohne Willkommen/Abschluss', async () => {
    const r = await ev(() => { obMark('homeowner', 'welcome', 'completed'); obMark('homeowner', 'task', 'skipped'); return obProgress('homeowner'); });
    if (r.done !== 1 || r.total !== 7) throw new Error(JSON.stringify(r)); return '1 von 7';
  });
  await step('Wiederaufnahme: aktueller Schritt und Pause bleiben erhalten', async () => {
    const r = await ev(() => { obMark('homeowner', null, null, { current: 'inspection', refs: { paused: true } }); const s1 = obStart('homeowner'); return { c: s1.current, paused: s1.paused, status: s1.status }; });
    if (r.c !== 'inspection' || !r.paused || r.status !== 'in_progress') throw new Error(JSON.stringify(r)); return 'inspection, pausiert';
  });
  await step('Versionierung: Stand einer anderen Flow-Version wird ignoriert', async () => {
    const r = await ev(() => { localStorage.setItem(obKey('homeowner'), JSON.stringify({ version: 'homeowner_v0', status: 'in_progress', current: 'task', steps: { property: 'completed' } })); return obState('homeowner'); });
    if (r !== null) throw new Error(JSON.stringify(r)); return 'alter Stand → neu beginnen';
  });
  await step('Abschluss bleibt abgeschlossen, nur ein ausdrücklicher Neustart setzt Schritte zurück', async () => {
    const r = await ev(() => { localStorage.removeItem(obKey('homeowner')); obStart('homeowner'); obMark('homeowner', 'task', 'completed'); obFinish('homeowner'); const fin = obState('homeowner').status; const again = obStart('homeowner').status; const done = obState('homeowner').status; obStart('homeowner', { restart: true }); return [fin, again, done, Object.keys(obState('homeowner').steps).length]; });
    if (r.join() !== 'completed,completed,completed,0') throw new Error(r.join()); return r.join(' / ');
  });
  await step('Checkliste aus echten Daten: Demo-Haus zählt nicht, echtes Haus und Aufgabe schon', async () => {
    const r = await ev(() => {
      const before = obOwnerChecklist().map((x) => x[2]);
      properties = [...properties.filter((x) => !obIsDemoHouse(x)), propertyWithDefaults({ id: 'h-unit', name: 'Unit-Haus', address: '', region: '', yearBuilt: '1990', livingArea: '80', rooms: '3' })];
      tasks = [...tasks, { id: 991, title: 'Unit-Aufgabe', property: 'Unit-Haus', date: '2026-12-01', priority: 'normal', repeat: 'Einmalig', status: 'Offen', done: false }];
      const after = obOwnerChecklist().map((x) => x[2]);
      return { before, after, demoOnly: properties.length };
    });
    if (r.before.slice(0, 3).some(Boolean) || r.after.slice(0, 3).join() !== 'true,true,true') throw new Error(JSON.stringify(r)); return `${r.before.slice(0, 3)} → ${r.after.slice(0, 3)}`;
  });
  await step('Unbekannter Schritt fällt auf Schritt 1 zurück', async () => {
    const i = await ev(() => obStepIndex('homeowner', 'gibt-es-nicht')); if (i !== 0) throw new Error(String(i)); return 'Index 0';
  });

  // ---- Integration: Hausbesitzer mit Konto ----
  const A = await mk(true);
  await step('Hausbesitzer mit Konto: Fortschritt landet am Server', async () => {
    await A.evaluate(async ({ e, pw }) => { await cloudRegister(e, pw); await cloudSignIn(e, pw); }, { e: EMAIL, pw: PW });
    await A.evaluate(() => { localStorage.removeItem(obKey('homeowner')); obStart('homeowner'); obMark('homeowner', 'welcome', 'completed'); obMark('homeowner', 'property', 'completed', { current: 'profile', refs: { primary_property_ref: 'h-unit' } }); obMark('homeowner', 'profile', 'skipped', { current: 'task', refs: { paused: true } }); });
    await A.waitForTimeout(1500);
    const r = sql(`select s.current_step_key||'|'||s.paused||'|'||coalesce(s.primary_property_ref,'')||'|'||(select string_agg(step_key||':'||status, ',' order by step_key) from onboarding_step_progress p where p.session_id=s.id) from onboarding_sessions s join users u on u.id=s.user_id join auth.users a on a.id=u.auth_user_id where a.email='${EMAIL}' and s.role_key='homeowner'`);
    if (!/^task\|(t|true)\|h-unit\|/.test(r) || !/profile:skipped/.test(r) || !/property:completed/.test(r)) throw new Error(r); return r;
  });
  await step('Neues Gerät: nach Anmeldung wird an der richtigen Stelle fortgesetzt', async () => {
    const B = await mk(true);
    await B.evaluate(async ({ e, pw }) => { await cloudSignIn(e, pw); }, { e: EMAIL, pw: PW });
    await B.waitForFunction(() => obState('homeowner')?.current === 'task', null, { timeout: 8000 });
    const r = await B.evaluate(() => ({ c: obState('homeowner').current, p: obState('homeowner').steps.property, ref: obState('homeowner').propertyRef, paused: obState('homeowner').paused }));
    await B.context().close(); if (r.p !== 'completed' || r.ref !== 'h-unit' || !r.paused) throw new Error(JSON.stringify(r)); return 'task, Haus-Referenz übernommen';
  });
  await step('Offline gespeicherter Schritt wird nach Wiederverbindung nachgereicht', async () => {
    await A.context().setOffline(true);
    await A.evaluate(() => obMark('homeowner', 'task', 'completed', { current: 'inspection' })); await A.waitForTimeout(500);
    const pending = await A.evaluate(() => obState('homeowner').pendingSync);
    await A.context().setOffline(false); await A.evaluate(() => window.dispatchEvent(new Event('online'))); await A.waitForTimeout(2000);
    const r = sql(`select s.current_step_key||'|'||(select status from onboarding_step_progress p where p.session_id=s.id and step_key='task') from onboarding_sessions s join users u on u.id=s.user_id join auth.users a on a.id=u.auth_user_id where a.email='${EMAIL}' and s.role_key='homeowner'`);
    if (!pending || r !== 'inspection|completed') throw new Error(`${pending} ${r}`); return r;
  });
  await step('Abmelden: kein Partner-Einrichtungsstand eines anderen Nutzers bleibt', async () => {
    const r = await A.evaluate(() => { localStorage.setItem(obKey('service_partner'), JSON.stringify({ version: 'service_partner_v1', status: 'in_progress', current: 'area', steps: {} })); cloudSignOut(); return localStorage.getItem(obKey('service_partner')); });
    if (r !== null) throw new Error(r); return 'entfernt';
  });
  console.log(res.join('\n')); if (errs.filter((e) => !/Failed to fetch|NetworkError/.test(e)).length) console.log('JS-Fehler:\n' + errs.join('\n'));
  await b.close();
})();
