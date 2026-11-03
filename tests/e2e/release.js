// Beta Release & App-Verteilung: Version/Beta-Kennzeichnung, App-Build mit Umgebung, Umgebungswächter, Wartung,
// Mindest-Build, App-Version melden, Rollen-Routing, Einladungscode, Fehlergrenze, Netzwerkfehler, Deep Links,
// simulierte native App (Capacitor: Plattform, Auth-Rücksprung, Dateien, Zurück-Taste, keine Käufe), Admin-Übersicht.
const { chromium } = require('playwright'); const fs = require('fs'); const path = require('path'); const { execSync } = require('child_process');
const { SP, ANON, SERVICE } = require('./env'); const totp = require('./totp'); const OUT = SP + '/audit/release'; fs.mkdirSync(OUT, { recursive: true });
const ROOT = path.join(__dirname, '..', '..');
const URL_ = 'http://127.0.0.1:54321'; const PW = 'Husora!2026'; const N = Date.now() % 100000;
const sql = (q) => execSync(`psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -At -c "${q.replace(/"/g, '\\"')}"`).toString().trim();
const setEnv = (name) => sql(`update app_config set value = '{"name": "${name}"}' where key = 'environment'`);
const resetRelease = () => {
  setEnv('beta');
  sql(`update app_config set value = '{"enabled": false, "blocking": false, "message": null}' where key = 'maintenance'`);
  sql(`update app_config set value = value || '{"invite_required": false, "min_build": {"android": 0, "ios": 0}}' where key = 'release'`);
};
(async () => {
  // App-Build für die Entwicklungsumgebung gegen den lokalen Stack (www/ unter http://127.0.0.1:8081/www/)
  execSync('node tools/build-app.mjs --env development --target web', { cwd: ROOT, env: { ...process.env, APP_ENV: 'development', HUSORA_PUBLIC_SUPABASE_URL: URL_, HUSORA_PUBLIC_SUPABASE_ANON_KEY: ANON }, stdio: 'ignore' });
  resetRelease();
  const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (name, fn) => { try { const r = await fn(); res.push(`OK   ${name}${r ? ' – ' + r : ''}`); } catch (e) { res.push(`FEHL ${name} – ${e.message.split('\n')[0].slice(0, 220)}`); } };
  const device = async (label, { app = false, native = null, stored = null, width = 390 } = {}) => {
    const ctx = await b.newContext({ viewport: { width, height: 844 }, isMobile: width < 600, hasTouch: true, acceptDownloads: true });
    const p = await ctx.newPage(); p.on('pageerror', (e) => errs.push(`${label}: ${e.message}`)); p.on('dialog', (d) => d.accept());
    await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
    if (native) await p.addInitScript((platform) => {
      const calls = { writeFile: [], share: [], browser: [], minimize: 0, listeners: {} };
      window.__nativeCalls = calls;
      window.Capacitor = {
        isNativePlatform: () => true, getPlatform: () => platform,
        Plugins: {
          App: { addListener: (ev, fn) => { calls.listeners[ev] = fn; return Promise.resolve({ remove() {} }); }, getLaunchUrl: () => Promise.resolve({}), minimizeApp: () => { calls.minimize += 1; return Promise.resolve(); } },
          Filesystem: { writeFile: (o) => { calls.writeFile.push(o.path); return Promise.resolve({ uri: `file:///cache/${o.path}` }); } },
          Share: { share: (o) => { calls.share.push(o.url); return Promise.resolve({}); } },
          Browser: { open: (o) => { calls.browser.push(o.url); return Promise.resolve(); } }
        }
      };
    }, native);
    const base = app ? 'http://127.0.0.1:8081/www/index.html' : 'http://127.0.0.1:8081/index.html';
    await p.goto(base);
    await p.evaluate(({ url, key, stored }) => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); localStorage.setItem('husora-cloud', JSON.stringify(stored || { url, key })); }, { url: URL_, key: ANON, stored });
    await p.reload(); await p.waitForTimeout(1200); return p;
  };
  const signIn = async (p, email) => {
    await p.evaluate(() => { document.getElementById('consent-sheet')?.remove(); document.querySelector('.nav [data-page="partnerHub"]').click(); }); await p.waitForTimeout(300);
    await p.fill('[data-cloud-form=signin] [name=email]', email); await p.fill('[data-cloud-form=signin] [name=password]', PW);
    await p.$eval('[data-cloud-form=signin] button[type=submit]', (e) => e.click());
    await p.waitForFunction(() => cloudSignedIn() && !cloudState.busy, null, { timeout: 20000 }); await p.waitForTimeout(1200);
  };
  const createUser = async (email) => {
    const r = await fetch(`${URL_}/auth/v1/admin/users`, { method: 'POST', headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: PW, email_confirm: true }) });
    if (!r.ok) throw new Error(`Testkonto: ${r.status} ${await r.text()}`);
  };

  const W = await device('Web');
  await step('Web-App: Version und Beta-Kennzeichnung in Menü, Fußzeile und Hilfe', async () => {
    const v = await W.evaluate(() => { currentPage = 'help'; render(); return { nav: document.querySelector('.nav-version')?.textContent, footer: document.querySelector('.app-footer')?.textContent, help: document.querySelector('#rel-help')?.textContent || '', env: betaEnvironment(), runtime: Boolean(hzRuntime()), ver: betaVersion() }; });
    await W.screenshot({ path: OUT + '/1-hilfe-beta.png', fullPage: false });
    if (!/Beta-Version · Husora Beta 1\.0\.0-beta\.\d+ \(Build \d+\)/.test(v.nav) || !/Beta-Version/.test(v.footer) || !/Android Beta/.test(v.help) || v.runtime || v.env !== 'development') throw new Error(JSON.stringify(v));
    return `${v.nav} · Analytics-Version „${v.ver}“`;
  });
  await step('Web-Link ?invite=… speichert den Einladungscode und entfernt ihn aus der Adresse', async () => {
    await W.goto('http://127.0.0.1:8081/index.html?invite=HUSORA-WEB-0001'); await W.waitForTimeout(900);
    const v = await W.evaluate(() => ({ code: relPendingCode(), search: location.search })); if (v.code !== 'HUSORA-WEB-0001' || /invite/.test(v.search)) throw new Error(JSON.stringify(v));
    await W.evaluate(() => relSetPendingCode('')); return 'gespeichert, Adresse bereinigt';
  });

  const A = await device('App', { app: true, stored: { url: 'https://evil-project.supabase.co', key: 'sb_publishable_fremd', session: { access_token: 'x', refresh_token: 'y', expires_at: 1 } } });
  await step('App-Build: Laufzeit-Konfiguration erzwingt die eigene Datenbank (fremdes gespeichertes Projekt + Sitzung verworfen)', async () => {
    const v = await A.evaluate(() => ({ rt: hzRuntime()?.env, url: cloud.url, session: Boolean(cloud.session), envState: relS().envState, label: relVersionLabel() }));
    if (v.rt !== 'development' || v.url !== 'http://127.0.0.1:54321' || v.session || v.envState !== 'ok') throw new Error(JSON.stringify(v));
    const err = await A.evaluate(async () => { try { await cloudConnect('https://evil-project.supabase.co', 'sb_publishable_xxxxxxxxxxxxxxxxxxxx'); return 'verbunden'; } catch (e) { return e.message; } });
    if (!/fest eingestellt/.test(err)) throw new Error(err); return `${v.label} · Server-Umgebung bestätigt`;
  });
  await step('Umgebungswächter: Server meldet „production“ → Sperrbildschirm, keine Datenübertragung', async () => {
    setEnv('production');
    await A.evaluate(async () => { relS().configFresh = false; await relLoadConfig(); }); await A.waitForTimeout(300);
    const v = await A.evaluate(async () => { let err = ''; try { await cloudFetch('/rest/v1/plans?select=id', { auth: false }); } catch (e) { err = e.message; } return { block: document.querySelector('#rel-block')?.textContent || '', err }; });
    await A.screenshot({ path: OUT + '/2-falsche-umgebung.png' });
    setEnv('beta');
    if (!/Falsche Umgebung/.test(v.block) || !/Sicherheitsstopp/.test(v.err)) throw new Error(JSON.stringify(v));
    await A.click('[data-rel-retry]'); await A.waitForTimeout(800);
    const gone = await A.evaluate(() => !document.querySelector('#rel-block') && relS().envState === 'ok'); if (!gone) throw new Error('Sperre bleibt nach Korrektur');
    return 'gesperrt, nach Korrektur über „Erneut prüfen“ wieder frei';
  });
  await step('Wartungshinweis (nicht sperrend) und Wartungssperre', async () => {
    sql(`update app_config set value = '{"enabled": true, "blocking": false, "message": "Heute 18–19 Uhr Wartung"}' where key = 'maintenance'`);
    await A.evaluate(() => relLoadConfig()); await A.waitForTimeout(400);
    const banner = await A.evaluate(() => document.querySelector('#rel-maintenance')?.textContent || '');
    sql(`update app_config set value = '{"enabled": true, "blocking": true, "message": "Wartung bis 19 Uhr"}' where key = 'maintenance'`);
    await A.evaluate(() => relLoadConfig()); await A.waitForTimeout(400);
    const block = await A.evaluate(() => document.querySelector('#rel-block')?.textContent || '');
    await A.screenshot({ path: OUT + '/3-wartung.png' });
    resetRelease(); await A.evaluate(() => relLoadConfig()); await A.waitForTimeout(400);
    const clear = await A.evaluate(() => !document.querySelector('#rel-block') && !document.querySelector('#rel-maintenance'));
    if (!/18–19 Uhr/.test(banner) || !/Wartung bis 19 Uhr/.test(block) || !clear) throw new Error(JSON.stringify({ banner, block, clear })); return 'Hinweis · Sperre · wieder frei';
  });
  await step('Fehlergrenze: Fehler in einer Seite zeigt Hinweis statt leerer App', async () => {
    const v = await A.evaluate(() => { const orig = helpPage; helpPage = () => { throw new Error('Testfehler Seite'); }; currentPage = 'help'; render(); const text = document.querySelector('.rel-error')?.textContent || ''; const nav = Boolean(document.querySelector('.nav [data-page="dashboard"]')); helpPage = orig; render(); return { text, nav, after: Boolean(document.querySelector('#rel-help')) }; });
    if (!/nicht angezeigt werden/.test(v.text) || !v.nav || !v.after) throw new Error(JSON.stringify(v)); return 'Fehlerkarte, Navigation bleibt, „Erneut versuchen“ funktioniert';
  });
  await step('Netzwerkfehler und Zeitüberschreitung: verständliche Meldung, bleibt „offline“ (TypeError)', async () => {
    await A.route(/127\.0\.0\.1:54321\/rest\/v1\/plans/, (r) => r.abort());
    const v = await A.evaluate(async () => { try { await cloudFetch('/rest/v1/plans?select=id', { auth: false }); return 'ok'; } catch (e) { return `${e instanceof TypeError}|${e.message}`; } });
    await A.unroute(/127\.0\.0\.1:54321\/rest\/v1\/plans/);
    const t = await A.evaluate(async () => { const orig = window.fetch; window.fetch = (u, o) => new Promise((_, rej) => o.signal.addEventListener('abort', () => rej(Object.assign(new Error('aborted'), { name: 'AbortError' })))); try { await relTimedFetch('http://x', {}, 50); return 'ok'; } catch (e) { return `${e instanceof TypeError}|${e.message}`; } finally { window.fetch = orig; } });
    if (!/^true\|Keine Verbindung zum Husora-Server/.test(v) || !/^true\|Zeitüberschreitung/.test(t)) throw new Error(`${v} / ${t}`); return 'Verbindung · Zeitlimit';
  });
  await step('Login meldet App-Version, Build, Plattform und Umgebung (report_app_session)', async () => {
    await signIn(A, 'eigentuemer@husora.test');
    await A.waitForFunction(() => Boolean(relS().status), null, { timeout: 15000 });
    const row = sql(`select last_app_version || '|' || last_app_build || '|' || app_platform || '|' || last_environment || '|' || (last_seen_at > now() - interval '1 minute') from users where email = 'eigentuemer@husora.test'`);
    const roles = await A.evaluate(() => JSON.stringify(relS().status.roles));
    if (!/^1\.0\.0-beta\.\d+\|\d+\|web\|development\|true$/.test(row) || !/"owner":true/.test(roles)) throw new Error(`${row} ${roles}`); return `${row} · Rollen ${roles}`;
  });

  // Geschlossene Beta: neues Konto ohne Code, Code einlösen, danach Organisation
  const newOwner = `rel_owner_${N}@husora.test`; const newPartner = `rel_partner_${N}@husora.test`;
  await createUser(newOwner); await createUser(newPartner);
  sql(`insert into organizations (id, name, org_type) values ('${'5e1ea5e0-0000-4000-8000-0000000' + String(N).padStart(5, '0')}', 'REL Service ${N}', 'service_partner')`);
  sql(`insert into organization_members (organization_id, user_id, role, status) select '${'5e1ea5e0-0000-4000-8000-0000000' + String(N).padStart(5, '0')}', id, 'admin', 'active' from users where email = '${newPartner}'`);
  await step('Rollen-Routing: reines Servicepartner-Konto landet nach dem Login im Partner-Portal', async () => {
    const P = await device('Partner', { app: true });
    await signIn(P, newPartner);
    await P.waitForFunction(() => pp.open === true, null, { timeout: 15000 });
    const v = await P.evaluate(() => ({ open: pp.open, mode: ppMode(), roles: relS().status?.roles }));
    await P.screenshot({ path: OUT + '/4-partner-routing.png' });
    if (!v.open || v.mode !== 'partner' || !v.roles?.partner || v.roles?.owner) throw new Error(JSON.stringify(v)); await P.context().close(); return 'Partner-Portal geöffnet';
  });
  await step('Einladungspflicht: Code-Dialog, falscher Code abgelehnt, richtiger Code eingelöst, Organisation angelegt', async () => {
    sql(`update app_config set value = value || '{"invite_required": true}' where key = 'release'`);
    sql(`delete from beta_invites where label = 'E2E Release'`);
    sql(`insert into beta_invites (code_hash, code_hint, label, tester_group, max_uses) values (encode(sha256(convert_to('HUSORA-E2E-${N}', 'UTF8')), 'hex'), '…${String(N).slice(-4)}', 'E2E Release', 'homeowner', 5)`);
    const I = await device('Invite', { app: true });
    await signIn(I, newOwner).catch(() => {});
    await I.waitForSelector('#rel-invite-modal.open', { timeout: 15000 });
    await I.screenshot({ path: OUT + '/5-einladungscode.png' });
    await I.fill('#rel-invite-form [name=code]', 'HUSORA-FALSCH-0000'); await I.click('#rel-invite-form button[type=submit]'); await I.waitForTimeout(900);
    const wrong = await I.evaluate(() => document.querySelector('#rel-invite-modal .pp-msg')?.textContent || '');
    await I.fill('#rel-invite-form [name=code]', `husora-e2e-${N}`); await I.click('#rel-invite-form button[type=submit]');
    await I.waitForFunction(() => !document.querySelector('#rel-invite-modal.open'), null, { timeout: 15000 });
    await I.waitForFunction(() => Boolean(cloud.org?.id), null, { timeout: 15000 }).catch(() => {});
    const db = sql(`select is_beta_user || '|' || coalesce(tester_group, '') || '|' || (beta_invite_id is not null) || '|' || (select count(*) from organization_members m where m.user_id = users.id) from users where email = '${newOwner}'`);
    resetRelease(); await I.context().close();
    if (!/ungültig/.test(wrong) || !/^true\|homeowner\|true\|[1-9]/.test(db)) throw new Error(`${wrong} / ${db}`); return `falsch abgelehnt · eingelöst (${db})`;
  });

  const NA = await device('Native', { app: true, native: 'android' });
  await step('Native App (Android simuliert): Plattform, Auth-Rücksprung über App-Schema, keine Käufe, kein Web-Push', async () => {
    const v = await NA.evaluate(async () => { let checkout = ''; try { await startCheckout({ plan_id: 'pro' }); } catch (e) { checkout = e.message; } return { cls: document.documentElement.className, plat: betaPlatform(), redirect: decodeURIComponent(cloudRedirect()), checkout, push: notifyPushSupported(), listeners: Object.keys(window.__nativeCalls.listeners) }; });
    if (!/native-app/.test(v.cls) || v.plat !== 'android' || v.redirect !== 'com.husora.app://auth' || !/App-Version/.test(v.checkout) || v.push || !['appUrlOpen', 'backButton', 'resume'].every((l) => v.listeners.includes(l))) throw new Error(JSON.stringify(v));
    return `${v.plat} · ${v.redirect}`;
  });
  await step('Native App: Deep Link com.husora.app://beta?invite=… und Auth-Fehler-Rücksprung', async () => {
    const v = await NA.evaluate(async () => { window.__nativeCalls.listeners.appUrlOpen({ url: 'com.husora.app://beta?invite=HUSORA-LINK-4711' }); window.__nativeCalls.listeners.appUrlOpen({ url: 'com.husora.app://auth#error_description=Link+abgelaufen' }); await new Promise((r) => setTimeout(r, 500)); return { code: relPendingCode(), toast: document.getElementById('toast')?.textContent || '' }; });
    if (v.code !== 'HUSORA-LINK-4711' || !/abgelaufen/.test(v.toast)) throw new Error(JSON.stringify(v)); await NA.evaluate(() => relSetPendingCode('')); return 'Code übernommen · Fehlermeldung des Links angezeigt';
  });
  await step('Native App: Downloads/PDFs werden gespeichert und geteilt, externe Links im System-Browser', async () => {
    const v = await NA.evaluate(async () => {
      const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob(['{"x":1}'], { type: 'application/json' })); a.download = 'husora-datenexport.json'; a.click();
      window.open(URL.createObjectURL(new Blob(['%PDF-1.4'], { type: 'application/pdf' })), '_blank');
      window.open('https://example.org/info', '_blank');
      await new Promise((r) => setTimeout(r, 600)); return window.__nativeCalls;
    });
    if (!v.writeFile.some((p) => /husora-datenexport\.json$/.test(p)) || !v.writeFile.some((p) => /\.pdf$/.test(p)) || v.share.length < 2 || !v.browser.includes('https://example.org/info')) throw new Error(JSON.stringify(v));
    return `${v.writeFile.length} Dateien geteilt · Browser: ${v.browser.length}`;
  });
  await step('Native App: Android-Zurück-Taste schließt Dialog, navigiert zurück, minimiert auf der Startseite', async () => {
    const v = await NA.evaluate(async () => {
      const back = window.__nativeCalls.listeners.backButton;
      document.getElementById('legal-modal').classList.add('open'); back(); const modalClosed = !document.getElementById('legal-modal').classList.contains('open');
      currentPage = 'help'; render(); back(); await new Promise((r) => setTimeout(r, 300)); const page = currentPage;
      currentPage = 'dashboard'; render(); back(); return { modalClosed, page, minimize: window.__nativeCalls.minimize };
    });
    if (!v.modalClosed || v.page === 'help' || v.minimize < 1) throw new Error(JSON.stringify(v)); return `Dialog zu · zurück zu „${v.page}“ · minimiert`;
  });
  await step('Mindest-Build: zu alte App fordert ein Update an', async () => {
    sql(`update app_config set value = value || '{"min_build": {"android": 999, "ios": 0}, "android_beta_url": "https://play.google.com/apps/testing/com.husora.app"}' where key = 'release'`);
    await NA.evaluate(() => relLoadConfig()); await NA.waitForTimeout(400);
    const v = await NA.evaluate(() => ({ text: document.querySelector('#rel-block')?.textContent || '', link: document.querySelector('#rel-block a')?.getAttribute('href') }));
    await NA.screenshot({ path: OUT + '/6-update.png' });
    resetRelease(); await NA.evaluate(() => relLoadConfig());
    if (!/Update erforderlich/.test(v.text) || !/play\.google\.com/.test(v.link || '')) throw new Error(JSON.stringify(v)); return 'Sperre mit Store-Link';
  });

  await step('Husora Admin (MFA): Tester-Übersicht pseudonymisiert, Code erzeugen, Release-Links speichern', async () => {
    const S = await device('Admin', { app: true });
    sql(`delete from auth.mfa_factors where user_id = (select id from auth.users where email = 'support@husora.test')`);
    await signIn(S, 'support@husora.test');
    await S.evaluate(() => { betaS().dash = null; admS().status = null; admS().mfa = null; relS().admin = null; currentPage = 'betaAdmin'; render(); });
    await S.waitForSelector('[data-mfa-enroll]', { timeout: 15000 }); await S.click('[data-mfa-enroll]');
    await S.waitForSelector('.mfa-card code', { timeout: 15000 });
    const secret = (await S.textContent('.mfa-card code')).trim();
    await S.fill('[data-mfa-verify] [name=code]', totp(secret)); await S.click('[data-mfa-verify] button[type=submit]');
    await S.waitForSelector('#rel-admin .rel-table', { timeout: 25000 });
    const table = await S.evaluate(() => document.querySelector('#rel-admin').textContent);
    await S.fill('#rel-admin-invite-form [name=label]', `E2E Welle ${N}`); await S.selectOption('#rel-admin-invite-form [name=group]', 'service_partner');
    await S.click('#rel-admin-invite-form button[type=submit]');
    await S.waitForSelector('.rel-newcode code', { timeout: 15000 });
    const code = (await S.textContent('.rel-newcode code')).trim();
    await S.fill('#rel-admin-config-form [name=android]', 'https://play.google.com/apps/testing/com.husora.app');
    await S.fill('#rel-admin-config-form [name=ios]', 'https://testflight.apple.com/join/HUSORA01');
    await S.click('#rel-admin-config-form button[type=submit]'); await S.waitForTimeout(1500);
    await S.screenshot({ path: OUT + '/7-admin.png', fullPage: true });
    const cfg = sql(`select value ->> 'ios_beta_url' from app_config where key = 'release'`);
    const stored = sql(`select count(*) from beta_invites where label = 'E2E Welle ${N}' and code_hash = encode(sha256(convert_to('${code}', 'UTF8')), 'hex')`);
    sql(`update app_config set value = value || '{"android_beta_url": null, "ios_beta_url": null}' where key = 'release'`);
    sql(`delete from auth.mfa_factors where user_id = (select id from auth.users where email = 'support@husora.test')`);
    await S.context().close();
    if (/@husora\.test/.test(table) || !/HUSORA-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}/.test(code) || stored !== '1' || cfg !== 'https://testflight.apple.com/join/HUSORA01') throw new Error(JSON.stringify({ code, stored, cfg, mail: /@husora\.test/.test(table) }));
    return `Code ${code.slice(0, 7)}… (nur Hash gespeichert) · TestFlight-Link gespeichert · keine E-Mails sichtbar`;
  });

  resetRelease();
  try {
    sql(`delete from organizations where id in (select organization_id from organization_members where user_id in (select id from users where email in ('${newOwner}', '${newPartner}')))`);
    sql(`delete from beta_invites where label in ('E2E Release', 'E2E Welle ${N}')`);
  } catch (error) { console.log('Hinweis: Aufräumen unvollständig – ' + error.message.split('\n')[0]); }
  console.log(res.join('\n'));
  if (errs.length) console.log('JS-Fehler:\n' + errs.join('\n'));
  await b.close();
})();
