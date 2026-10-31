const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON: ENV_ANON } = require('./env'); const OUT = SP + '/audit/hub'; fs.mkdirSync(OUT, { recursive: true });
const ANON = ENV_ANON; const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Värmland Service ${N} AB`, P_EMAIL = `chef${N}@vs.test`, PW = 'Husora!2026';
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
  await step('Hausbesitzer: Menüpunkt „Partner-Portal“ öffnet Anmeldung', async () => {
    await H.evaluate(() => document.querySelector('.nav [data-page="partnerHub"]').click()); await H.waitForTimeout(300);
    const t = await H.evaluate(() => [currentPage, document.querySelector('#page-content h1')?.textContent, !!document.querySelector('[data-cloud-form=signin]')].join(' · '));
    await H.screenshot({ path: OUT + '/1-anmelden.png' }); return t;
  });
  await step('Hausbesitzer: anmelden direkt im Partner-Portal', async () => {
    await H.fill('[data-cloud-form=signin] [name=email]', 'admin@husora.test'); await H.fill('[data-cloud-form=signin] [name=password]', PW);
    await H.$eval('[data-cloud-form=signin] button[type=submit]', (e) => e.click());
    await H.waitForFunction(() => cloudReady() && !cloudState.busy && ownerSide.partners !== null && !ownerSide.busy, null, { timeout: 20000 });
    return `${await H.evaluate(() => document.querySelectorAll('.hub-tabs button').length)} Reiter · ${await H.evaluate(() => ownerSide.partners.length)} Partner`;
  });
  let CODE = '';
  await step('Hausbesitzer: Einladungscode erzeugen (Kopieren/Teilen/E-Mail/SMS)', async () => {
    await H.fill('[data-owner-form=partner] [name=company_name]', FIRM); await H.fill('[data-owner-form=partner] [name=email]', P_EMAIL);
    await H.$eval('[data-owner-form=partner] button[type=submit]', (e) => e.click()); await H.waitForFunction(() => !ownerSide.busy, null, { timeout: 20000 }); await H.waitForTimeout(300);
    CODE = await H.evaluate(() => ownerSide.code?.code || ownerSide.error);
    const box = await H.evaluate(() => [...document.querySelectorAll('.hub-code-actions > *')].map((e) => e.textContent.trim()).join('/'));
    if (!/^HUS-/.test(CODE)) throw new Error(CODE);
    const card = await H.$$('.hub-partner'); for (const c of card) { if ((await c.textContent()).includes(FIRM)) { await c.screenshot({ path: OUT + '/2-code.png' }); } }
    await H.screenshot({ path: OUT + '/2-partner-tab.png' });
    return `${CODE} · ${box} · Status: ${await H.evaluate((f) => [...document.querySelectorAll('.hub-partner')].find((c) => c.textContent.includes(f))?.querySelector('.pp-badge')?.textContent, FIRM)}`;
  });
  // Partner richtet Betrieb ein und verbindet sich
  const P = await device('P');
  await step('Partner: Betrieb anlegen und Code eingeben', async () => {
    await P.evaluate(() => ppOpen('dashboard')); await P.waitForTimeout(200);
    await P.fill('[data-pp-form=login] [name=email]', P_EMAIL); await P.fill('[data-pp-form=login] [name=password]', PW);
    await P.$eval('[data-pp-action=signup]', (e) => e.click()); await P.waitForFunction(() => !pp.busy && document.querySelector('[data-pp-form=company]'), null, { timeout: 20000 });
    await P.fill('[data-pp-form=company] [name=name]', FIRM); await P.$eval('[data-pp-form=company] button[type=submit]', (e) => e.click()); await P.waitForFunction(() => !pp.busy && ppOrg(), null, { timeout: 20000 });
    await P.evaluate(() => { pp.view = 'customers'; ppRender(); });
    await P.fill('[data-pp-form=invite-code] [name=code]', CODE); await P.$eval('[data-pp-form=invite-code] button[type=submit]', (e) => e.click()); await P.waitForFunction(() => !pp.busy, null, { timeout: 20000 });
    return await P.evaluate(() => pp.ctx.links.map((l) => l.organization_name).join(', '));
  });
  await step('Hausbesitzer: Partner erscheint als „verbunden“, Nachricht-Knopf', async () => {
    await H.evaluate(() => hubRefresh()); await H.waitForFunction(() => !ownerSide.busy, null, { timeout: 20000 }); await H.waitForTimeout(200);
    const st = await H.evaluate((f) => { const c = [...document.querySelectorAll('.hub-partner')].find((x) => x.textContent.includes(f)); return [c?.querySelector('.pp-badge')?.textContent, !!c?.querySelector('[data-hub-chat]')].join(' · '); }, FIRM);
    if (!st.startsWith('verbunden')) throw new Error(st); return st;
  });
  await step('Hausbesitzer: Messenger öffnen und schreiben (Enter sendet)', async () => {
    await H.evaluate((f) => [...document.querySelectorAll('.hub-partner')].find((x) => x.textContent.includes(f)).querySelector('[data-hub-chat]').click(), FIRM); await H.waitForTimeout(200);
    await H.fill('[data-hub-send] textarea', 'Hallo! Können Sie ab Dezember jeden Montag nach dem Haus sehen?'); await H.press('[data-hub-send] textarea', 'Enter');
    await H.waitForFunction(() => !hub.sending, null, { timeout: 15000 }); await H.waitForTimeout(300);
    await H.screenshot({ path: OUT + '/3-messenger.png' });
    return sql(`select count(*) from messages m join service_partners sp on sp.id=m.service_partner_id where sp.company_name='${FIRM}'`) + ' Nachricht(en) in der DB';
  });
  await step('Partner: sieht Gespräch mit ungelesener Nachricht und antwortet', async () => {
    await P.evaluate(() => { pp.view = 'messages'; pp.detail = null; }); await P.evaluate(() => ppLoad()); await P.waitForFunction(() => !pp.busy, null, { timeout: 15000 });
    const badge = await P.evaluate(() => document.querySelector('[data-pp-open^="chat:"] .pp-badge')?.textContent || '');
    await P.screenshot({ path: OUT + '/4-partner-liste.png' });
    await P.$eval('[data-pp-open^="chat:"]', (e) => e.click()); await P.waitForTimeout(500);
    await P.fill('[data-pp-form=chat] textarea', 'Gerne, jeden Montag gegen 10 Uhr. Kosten: 450 SEK pro Kontrolle.'); await P.press('[data-pp-form=chat] textarea', 'Enter'); await P.waitForTimeout(1200);
    await P.screenshot({ path: OUT + '/5-partner-chat.png' });
    const read = sql(`select count(*) from messages m join service_partners sp on sp.id=m.service_partner_id where sp.company_name='${FIRM}' and m.read_at is not null`);
    return `Liste: „${badge}“ · nach Öffnen gelesen: ${read} · Nachrichten: ${sql(`select count(*) from messages m join service_partners sp on sp.id=m.service_partner_id where sp.company_name='${FIRM}'`)}`;
  });
  await step('Hausbesitzer: Antwort kommt an (automatisch), Lesebestätigung sichtbar', async () => {
    await H.waitForFunction(() => document.querySelectorAll('#hub-messages .pp-bubble').length >= 2, null, { timeout: 20000 });
    const texts = await H.evaluate(() => [...document.querySelectorAll('#hub-messages .pp-bubble')].map((b) => b.querySelector('small').textContent).join(' | '));
    await H.screenshot({ path: OUT + '/6-antwort.png' }); return texts;
  });
  await step('Hausbesitzer: ungelesen-Zähler im Menü, wenn nicht im Gespräch', async () => {
    await H.evaluate(() => { hub.thread = null; hub.tab = 'partners'; currentPage = 'dashboard'; render(); });
    await P.fill('[data-pp-form=chat] textarea', 'Kurze Rückfrage: Gibt es einen Schlüsseltresor?'); await P.press('[data-pp-form=chat] textarea', 'Enter'); await P.waitForTimeout(800);
    await H.evaluate(() => hubRefresh({ quiet: true })); await H.waitForTimeout(800);
    const nav = await H.evaluate(() => document.querySelector('.nav [data-page="partnerHub"] .hub-nav-count')?.textContent || '–');
    const notif = sql(`select count(*) from notifications where type='message' and message like 'Kurze Rückfrage%'`);
    return `Menü-Zähler: ${nav} · Benachrichtigungen: ${notif}`;
  });
  await step('Hausbesitzer: Aufträge-Reiter mit Auftrag senden', async () => {
    await H.evaluate(() => { currentPage = 'partnerHub'; hub.tab = 'orders'; render(); }); await H.waitForTimeout(200);
    await H.screenshot({ path: OUT + '/7-auftraege.png' });
    return `Formular: ${!!(await H.$('[data-owner-form=send]'))}`;
  });
  await step('Einstellungen: Karte verweist auf das Partner-Portal', async () => {
    await H.evaluate(() => { currentPage = 'settings'; settingsView = 'settings-data'; render(); }); await H.waitForTimeout(200);
    await H.$eval('#settings-partners [data-page="partnerHub"]', (e) => e.click()); await H.waitForTimeout(200);
    return await H.evaluate(() => currentPage);
  });
  console.log(res.join('\n')); console.log(errs.length ? 'JS-Fehler:\n' + [...new Set(errs)].join('\n') : 'keine JS-Fehler'); await b.close();
})();
