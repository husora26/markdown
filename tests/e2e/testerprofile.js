// Beta-Tester-Steckbrief: erscheint einmalig nach dem Login, Felder je Rolle, „Später“, Absenden speichert, danach nicht mehr
const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON } = require('./env'); const OUT = SP + '/audit/testerprofile'; fs.mkdirSync(OUT, { recursive: true });
const URL_ = 'http://127.0.0.1:54321'; const PW = 'Husora!2026'; const EMAIL = 'eigentuemer@husora.test';
const sql = (q) => execSync(`psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -At -c "${q.replace(/"/g, '\\"')}"`).toString().trim();
(async () => {
  sql(`update users set is_beta_user = true where email = '${EMAIL}'`);
  sql(`delete from tester_profiles where user_id = (select id from users where email = '${EMAIL}')`);
  const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (name, fn) => { try { const r = await fn(); res.push(`OK   ${name}${r ? ' – ' + r : ''}`); } catch (e) { res.push(`FEHL ${name} – ${e.message.split('\n')[0].slice(0, 220)}`); } };
  const login = async () => {
    const p = await (await b.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true })).newPage();
    p.on('pageerror', (e) => errs.push(e.message)); p.on('dialog', (d) => d.accept());
    await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
    await p.goto('http://127.0.0.1:8081/index.html');
    await p.evaluate(({ url, key }) => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); localStorage.setItem('husora-profile-ui', '1'); localStorage.setItem('husora-cloud', JSON.stringify({ url, key })); }, { url: URL_, key: ANON });
    await p.reload(); await p.waitForTimeout(900);
    await p.evaluate(() => { document.getElementById('consent-sheet')?.remove(); document.querySelector('.nav [data-page="partnerHub"]').click(); }); await p.waitForTimeout(300);
    await p.fill('[data-cloud-form=signin] [name=email]', EMAIL); await p.fill('[data-cloud-form=signin] [name=password]', PW);
    await p.$eval('[data-cloud-form=signin] button[type=submit]', (e) => e.click());
    await p.waitForFunction(() => cloudSignedIn() && !cloudState.busy, null, { timeout: 20000 });
    return p;
  };
  const P = await login();
  await step('Steckbrief erscheint nach dem Login eines Beta-Testers (Rolle vorbelegt)', async () => {
    await P.waitForSelector('#tp-modal.open', { timeout: 15000 });
    await P.evaluate(() => document.getElementById('legal-accept')?.remove());
    const v = await P.evaluate(() => ({ role: document.querySelector('#tp-form input[name=role]:checked')?.value, team: !document.querySelector('[data-tp-for="partner"]').hidden, houses: !document.querySelector('[data-tp-for="owner"]').hidden }));
    await P.screenshot({ path: OUT + '/1-steckbrief.png', fullPage: false });
    if (v.role !== 'owner' || v.team || !v.houses) throw new Error(JSON.stringify(v)); return 'Hausbesitzer: Frage nach Häusern, nicht nach Betriebsgröße';
  });
  await step('„Später“ schließt den Dialog ohne zu speichern', async () => {
    await P.click('[data-tp-later]'); await P.waitForTimeout(300);
    const v = await P.evaluate(() => ({ open: document.getElementById('tp-modal').classList.contains('open'), later: Number(localStorage.getItem('husora-profile-later')) > Date.now() }));
    const n = sql(`select count(*) from tester_profiles where user_id = (select id from users where email = '${EMAIL}')`);
    if (v.open || !v.later || n !== '0') throw new Error(JSON.stringify({ v, n })); return 'erneut in 3 Tagen';
  });
  await step('Absenden speichert die Auswahl (ohne Freitext außer Region)', async () => {
    await P.evaluate(() => tpOpen()); await P.waitForTimeout(200);
    await P.check('#tp-form input[name=house_count][value="2-3"]'); await P.fill('#tp-form [name=region]', 'Värmland');
    await P.check('#tp-form input[name=current_tool][value="excel"]'); await P.check('#tp-form input[name=source][value="friend"]'); await P.check('#tp-form [name=interview_ok]');
    await P.click('#tp-form button[type=submit]'); await P.waitForTimeout(1200);
    const row = sql(`select role || '|' || house_count || '|' || region || '|' || current_tool || '|' || source || '|' || interview_ok || '|' || skipped from tester_profiles where user_id = (select id from users where email = '${EMAIL}')`);
    if (row !== 'owner|2-3|Värmland|excel|friend|true|false') throw new Error(row); return row;
  });
  await step('Nach erneutem Login erscheint der Steckbrief nicht mehr', async () => {
    const Q = await login(); await Q.waitForTimeout(3000);
    const open = await Q.evaluate(() => Boolean(document.getElementById('tp-modal')?.classList.contains('open')));
    await Q.context().close();
    if (open) throw new Error('Dialog erneut offen'); return 'profile_done';
  });
  sql(`delete from tester_profiles where user_id = (select id from users where email = '${EMAIL}')`);
  console.log(res.join('\n'));
  if (errs.length) console.log('JS-Fehler:\n' + errs.join('\n'));
  await b.close();
})();
