// Legal & Beta Compliance: Einwilligung, Rechtliches, Rechtstexte, Export, Datenschutz-Anfrage, neue Fassung, Beta ohne Zahlung, Admin mit MFA
const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON } = require('./env'); const totp = require('./totp'); const OUT = SP + '/audit/legal'; fs.mkdirSync(OUT, { recursive: true });
const URL_ = 'http://127.0.0.1:54321'; const PW = 'Husora!2026'; const N = Date.now() % 100000;
const sql = (q) => execSync(`psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -At -c "${q.replace(/"/g, '\\"')}"`).toString().trim();
(async () => {
  const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (name, fn) => { try { const r = await fn(); res.push(`OK   ${name}${r ? ' – ' + r : ''}`); } catch (e) { res.push(`FEHL ${name} – ${e.message.split('\n')[0].slice(0, 220)}`); } };
  sql(`delete from legal_acceptances where user_id = (select id from users where email = 'admin@husora.test')`);
  sql(`delete from auth.mfa_factors where user_id = (select id from auth.users where email = 'support@husora.test')`);
  const device = async (label, width = 390) => {
    const ctx = await b.newContext({ viewport: { width, height: 844 }, isMobile: width < 600, hasTouch: true, acceptDownloads: true });
    const p = await ctx.newPage(); p.on('pageerror', (e) => errs.push(`${label}: ${e.message}`)); p.on('dialog', (d) => d.accept());
    await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
    await p.goto('http://127.0.0.1:8081/index.html');
    await p.evaluate(({ url, key }) => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); localStorage.setItem('husora-cloud', JSON.stringify({ url, key })); localStorage.setItem('husora-consent-ui', '1'); }, { url: URL_, key: ANON });
    await p.reload(); await p.waitForTimeout(900); return p;
  };
  const signIn = async (p, email) => {
    await p.evaluate(() => { document.getElementById('consent-sheet')?.remove(); document.querySelector('.nav [data-page="partnerHub"]').click(); }); await p.waitForTimeout(300);
    await p.fill('[data-cloud-form=signin] [name=email]', email); await p.fill('[data-cloud-form=signin] [name=password]', PW);
    await p.$eval('[data-cloud-form=signin] button[type=submit]', (e) => e.click());
    await p.waitForFunction(() => cloudReady() && !cloudState.busy, null, { timeout: 20000 }); await p.waitForTimeout(600);
  };
  const H = await device('H');
  await step('Erster Start: Einwilligungsdialog, nichts vorausgewählt', async () => {
    const v = await H.evaluate(() => ({ sheet: Boolean(document.querySelector('#consent-sheet [data-consent-choice="necessary"]')), state: localStorage.getItem('husora-consent'), ext: externalAllowed('open_meteo'), ana: consentGet('analytics') }));
    await H.screenshot({ path: OUT + '/1-einwilligung.png' });
    if (!v.sheet || v.state || v.ext || v.ana) throw new Error(JSON.stringify(v)); return 'Dialog sichtbar, Statistik und externe Inhalte aus';
  });
  await step('„Nur notwendige“ → externe Inhalte bleiben gesperrt (Karte als Platzhalter)', async () => {
    await H.click('#consent-sheet [data-consent-choice="necessary"]'); await H.waitForTimeout(200);
    await H.evaluate(() => { currentPage = 'propertyDetail'; selectedPropertyId = properties[0]?.id; render(); }).catch(() => {}); await H.waitForTimeout(800);
    const v = await H.evaluate(() => ({ state: JSON.parse(localStorage.getItem('husora-consent')), ph: Boolean(document.querySelector('.consent-placeholder')) }));
    if (v.state.analytics || v.state.external_content) throw new Error(JSON.stringify(v)); return `gespeichert · Platzhalter: ${v.ph}`;
  });
  await step('Einstellungen → Rechtliches: alle Unterpunkte', async () => {
    await H.evaluate(() => { currentPage = 'settings'; settingsView = 'settings-legal'; render(); }); await H.waitForTimeout(300);
    const labels = await H.evaluate(() => [...document.querySelectorAll('#settings-legal .legal-hub-item strong')].map((e) => e.textContent));
    const need = ['Impressum', 'Datenschutzerklärung', 'Nutzungsbedingungen', 'Beta-Bedingungen', 'Datenschutz-Einstellungen', 'Datenexport', 'Konto löschen', 'Versionen'];
    await H.screenshot({ path: OUT + '/2-rechtliches.png' });
    const missing = need.filter((l) => !labels.includes(l)); if (missing.length) throw new Error(missing.join(', ')); return `${labels.length} Punkte`;
  });
  await step('Rechtstexte: Beta-Bedingungen, Plattform-Klausel, Hauskontroll-Hinweis, Datenschutz-Übersicht', async () => {
    const txt = async (tab) => H.evaluate((t) => { legalTab = t; currentPage = 'legal'; render(); return document.querySelector('.legal-text')?.textContent || ''; }, tab);
    const beta = await txt('beta_terms'); const terms = await txt('terms'); const liab = await txt('liability'); const priv = await txt('privacy'); const imp = await txt('imprint');
    const checks = { beta: beta.includes('zwingende gesetzliche Rechte'), platform: terms.includes('nicht ausführender Handwerks'), inspection: liab.includes('ersetzt keine gesetzlich vorgeschriebene'), privacy: priv.includes('Dienste und Empfänger') && priv.includes('Anthropic'), imprint: imp.includes('[Registergericht]') };
    if (Object.values(checks).includes(false)) throw new Error(JSON.stringify(checks)); return 'alle vorhanden · Impressum mit Platzhaltern statt erfundener Angaben';
  });
  await step('Beta: Tarif-Kauf löst keine Zahlung aus', async () => {
    const r = await H.evaluate(async () => { try { await startCheckout({ plan_id: 'pro' }); return 'gestartet'; } catch (e) { return e.message; } });
    if (!/Beta deaktiviert/.test(r)) throw new Error(r); return r;
  });
  await step('Anmelden: neue Fassung bestätigen (Nutzungs- und Beta-Bedingungen)', async () => {
    await signIn(H, 'admin@husora.test');
    await H.waitForSelector('#legal-accept [data-legal-accept-check]', { timeout: 15000 });
    await H.screenshot({ path: OUT + '/3-neue-fassung.png' });
    await H.check('#legal-accept [data-legal-accept-check]'); await H.click('#legal-accept [data-legal-accept="ok"]'); await H.waitForTimeout(800);
    const n = sql(`select string_agg(document_type, ',' order by document_type) from legal_acceptances where user_id = (select id from users where email = 'admin@husora.test')`);
    if (n !== 'beta_terms,terms') throw new Error(n); return n;
  });
  await step('Datenschutz-Einstellungen: Statistik einwilligen und widerrufen → Consent-Log', async () => {
    await H.evaluate(() => { legalTab = 'consent'; currentPage = 'legal'; render(); }); await H.waitForTimeout(200);
    await H.$eval('.consent-settings [data-consent-cat="analytics"]', (el) => { el.checked = true; }); await H.click('.consent-settings [data-consent-choice="save"]'); await H.waitForTimeout(800);
    await H.evaluate(() => { legalTab = 'consent'; currentPage = 'legal'; render(); }); await H.waitForTimeout(200);
    await H.$eval('.consent-settings [data-consent-cat="analytics"]', (el) => { el.checked = false; }); await H.click('.consent-settings [data-consent-choice="save"]'); await H.waitForTimeout(800);
    const r = sql(`select string_agg(accepted::text, ',' order by created_at) from consent_log where purpose = 'analytics' and user_id = (select id from users where email = 'admin@husora.test') and created_at > now() - interval '2 minutes'`);
    if (!/true,false$/.test(r)) throw new Error(r); return `Einwilligung → Widerruf (${r})`;
  });
  await step('Datenexport: Datei mit Gerät + Cloud, nur eigene Organisation', async () => {
    await H.evaluate(() => { legalTab = 'export'; currentPage = 'legal'; render(); }); await H.waitForTimeout(200);
    const [dl] = await Promise.all([H.waitForEvent('download', { timeout: 20000 }), H.click('[data-legal-export]')]);
    const file = OUT + '/export.json'; await dl.saveAs(file);
    const data = JSON.parse(fs.readFileSync(file, 'utf8'));
    const orgs = new Set((data.cloud?.properties || []).map((p) => p.organization_id));
    const own = sql(`select string_agg(organization_id::text, ',') from organization_members where status='active' and user_id = (select id from users where email = 'admin@husora.test')`).split(',');
    if (!data.device || !data.cloud?.profile || [...orgs].some((o) => !own.includes(o))) throw new Error(JSON.stringify([...orgs]));
    return `${(data.cloud.properties || []).length} Häuser · ${Object.keys(data.device).length} Gerätebereiche · Export protokolliert: ${sql(`select count(*) > 0 from security_audit_log where event_type = 'data_export' and created_at > now() - interval '2 minutes'`)}`;
  });
  await step('Datenschutz-Anfrage stellen', async () => {
    await H.evaluate(() => { legalTab = 'request'; currentPage = 'legal'; render(); }); await H.waitForTimeout(500);
    await H.selectOption('[data-privacy-request] [name=type]', 'access'); await H.fill('[data-privacy-request] [name=message]', `Auskunft ${N}`);
    await H.click('[data-privacy-request] button[type=submit]'); await H.waitForTimeout(1000);
    const r = sql(`select request_type || '/' || status from privacy_requests where message = 'Auskunft ${N}'`); if (r !== 'access/new') throw new Error(r); return r;
  });
  const A = await device('A', 1280);
  await step('Husora Admin: nur mit zweitem Faktor (TOTP)', async () => {
    await signIn(A, 'support@husora.test');
    await A.evaluate(() => { document.getElementById('legal-accept')?.remove(); admS().status = null; admS().mfa = null; currentPage = 'adminCompliance'; render(); });
    await A.waitForSelector('[data-mfa-enroll]', { timeout: 15000 });
    const blocked = await A.evaluate(() => !document.querySelector('.gate-list'));
    await A.click('[data-mfa-enroll]'); await A.waitForSelector('.mfa-card code', { timeout: 15000 });
    const secret = (await A.textContent('.mfa-card code')).trim();
    await A.fill('[data-mfa-verify] [name=code]', totp(secret)); await A.click('[data-mfa-verify] button[type=submit]');
    await A.waitForFunction(() => admS().status?.aal === 'aal2', null, { timeout: 15000 });
    if (!blocked) throw new Error('ohne MFA sichtbar'); return 'gesperrt → TOTP eingerichtet → aal2';
  });
  await step('Release-Gate: automatische und manuelle Prüfungen, nicht bestanden ohne Prüfung', async () => {
    await A.evaluate(() => { admS().tab = 'gate'; delete admS().data.gate; render(); }); await A.waitForSelector('.gate-list', { timeout: 15000 });
    const v = await A.evaluate(() => ({ items: document.querySelectorAll('.gate-list li').length, open: document.querySelectorAll('.gate-list li.open').length, passed: admS().data.gate?.passed }));
    await A.screenshot({ path: OUT + '/4-release-gate.png', fullPage: true });
    if (v.items < 18 || v.passed !== false) throw new Error(JSON.stringify(v)); return `${v.items} Punkte, ${v.open} offen → NO-GO`;
  });
  await step('Impressum im Admin pflegen → in der App sichtbar', async () => {
    await A.evaluate(() => { admS().tab = 'imprint'; delete admS().data.imprint; render(); }); await A.waitForSelector('[data-adm-imprint]', { timeout: 15000 });
    await A.fill('[data-adm-imprint] [name=register_court]', `Amtsgericht Test ${N}`); await A.click('[data-adm-imprint] button[type=submit]'); await A.waitForTimeout(800);
    const r = sql(`select value->>'register_court' from app_config where key='imprint'`);
    const shown = await A.evaluate(() => { legalTab = 'imprint'; currentPage = 'legal'; render(); return document.querySelector('.legal-text')?.textContent || ''; });
    sql(`update app_config set value = value || '{"register_court": null}' where key = 'imprint'`);
    if (r !== `Amtsgericht Test ${N}` || !shown.includes(r)) throw new Error(r); return r;
  });
  await step('Drittanbieter-Register und Audit-Log einsehbar', async () => {
    await A.evaluate(() => { currentPage = 'adminCompliance'; admS().tab = 'providers'; delete admS().data.providers; render(); }); await A.waitForTimeout(1200);
    const n = await A.evaluate(() => document.querySelectorAll('[data-provider-status]').length);
    await A.evaluate(() => { admS().tab = 'audit'; delete admS().data.audit; render(); }); await A.waitForTimeout(1200);
    const rows = await A.evaluate(() => document.querySelectorAll('.legal-table tr').length);
    if (n < 10 || rows < 2) throw new Error(`${n} ${rows}`); return `${n} Anbieter · ${rows - 1} Audit-Einträge`;
  });
  console.log(res.join('\n')); if (errs.length) console.log('JS-Fehler:\n' + errs.join('\n'));
  await b.close();
})();
