const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON: ENV_ANON } = require('./env'); const OUT = SP + '/audit/custom'; fs.mkdirSync(OUT, { recursive: true });
const ANON = ENV_ANON; const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const sql = (q) => execSync(`psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -At -c "${q.replace(/"/g, '\\"')}"`).toString().trim();
(async () => {
  const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (name, fn) => { try { const r = await fn(); res.push(`OK   ${name}${r ? ' – ' + r : ''}`); } catch (e) { res.push(`FEHL ${name} – ${e.message.split('\n')[0].slice(0, 220)}`); } };
  const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  const p = await ctx.newPage(); p.on('pageerror', (e) => errs.push(e.message)); p.on('dialog', (d) => d.accept());
  await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
  await p.goto('http://127.0.0.1:8081/index.html');
  await p.evaluate(({ url, key }) => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); localStorage.setItem('husora-cloud', JSON.stringify({ url, key })); }, { url: URL_, key: ANON });
  await p.reload(); await p.waitForTimeout(400);
  const NAME = `Anderssons Bygg ${N}`;
  await step('Zugeordnete Servicepartner: kein Anlegen-Knopf mehr', async () => {
    await p.evaluate(() => { currentPage = 'assignedProviders'; render(); }); await p.waitForTimeout(200);
    await p.screenshot({ path: OUT + '/1-leer.png' });
    if (await p.$('main [data-custom-provider-new]')) throw new Error('Knopf noch da');
    return 'nur noch „Servicepartner finden“';
  });
  await step('Servicepartner finden: Knopf „Eigenen Servicepartner anlegen“', async () => {
    await p.evaluate(() => { currentPage = 'providers'; render(); }); await p.waitForTimeout(200);
    await p.$eval('[data-custom-provider-new]', (e) => e.click()); await p.waitForTimeout(150);
    await p.screenshot({ path: OUT + '/2-formular.png' });
    return `Dialog offen: ${await p.evaluate(() => document.getElementById('custom-provider-modal').classList.contains('open'))}`;
  });
  await step('Pflichtfeld wird geprüft', async () => {
    await p.$eval('#custom-provider-form button[type=submit]', (e) => e.click()); await p.waitForTimeout(100);
    return await p.evaluate(() => document.querySelector('.custom-provider-error').textContent);
  });
  await step('Partner anlegen und dem Haus zuordnen', async () => {
    const f = (n, v) => p.fill(`#custom-provider-form [name=${n}]`, v);
    await f('name', NAME); await p.selectOption('#custom-provider-form [name=category]', 'renovation'); await f('town', 'Sunne'); await f('services', 'Dach · Fassade · Kleinreparaturen');
    await f('contact', 'Lars Andersson'); await f('phone', '+46 70 555 12 34'); await f('email', 'lars@andersson.test'); await f('website', 'andersson.test'); await f('notes', 'Schlüssel liegt beim Nachbarn.');
    await p.$eval('#custom-provider-form button[type=submit]', (e) => e.click()); await p.waitForTimeout(300);
    await p.evaluate(() => { currentPage = 'assignedProviders'; render(); }); await p.waitForTimeout(200);
    await p.screenshot({ path: OUT + '/3-karte.png', fullPage: false });
    const card = await p.evaluate((n) => [...document.querySelectorAll('.ap-card')].find((c) => c.textContent.includes(n))?.textContent.replace(/\s+/g, ' ').slice(0, 140), NAME);
    if (!card) throw new Error('Karte fehlt'); return card;
  });
  await step('Bleibt nach Neuladen erhalten (inkl. Zuordnung)', async () => {
    await p.reload(); await p.waitForTimeout(400); await p.evaluate(() => { currentPage = 'assignedProviders'; render(); });
    return `${await p.evaluate((n) => providers.filter((x) => x.custom && x.name === n).length, NAME)} eigener Partner · zugeordnet: ${await p.evaluate((n) => (servicePartnerAssignments[properties[0].id] || []).includes(providers.find((x) => x.name === n)?.id), NAME)} · Website: ${await p.evaluate((n) => providers.find((x) => x.name === n)?.website, NAME)}`;
  });
  await step('Im Verzeichnis „Servicepartner finden“ oben, gekennzeichnet', async () => {
    await p.evaluate(() => { currentPage = 'providers'; render(); }); await p.waitForTimeout(200);
    await p.screenshot({ path: OUT + '/4-verzeichnis.png' });
    return await p.evaluate(() => document.querySelector('.provider-result h3')?.textContent + ' · ' + (document.querySelector('.provider-result .custom-provider-tag')?.textContent || 'kein Tag'));
  });
  await step('Bearbeiten', async () => {
    await p.$eval('[data-custom-provider-edit]', (e) => e.click()); await p.waitForTimeout(100);
    await p.fill('#custom-provider-form [name=phone]', '+46 70 999 00 11'); await p.$eval('#custom-provider-form button[type=submit]', (e) => e.click()); await p.waitForTimeout(200);
    return await p.evaluate((n) => providers.find((x) => x.name === n).phone, NAME);
  });
  await step('Als Partner für Aufgaben wählbar', async () => {
    const id = await p.evaluate((n) => providers.find((x) => x.name === n).id, NAME);
    await p.evaluate(() => { currentPage = 'tasks'; render(); }); await p.waitForTimeout(150);
    await p.$eval('[data-action="new-task"]', (e) => e.click()); await p.waitForTimeout(200);
    const options = await p.evaluate(() => [...document.querySelectorAll('#task-form select option')].map((o) => o.textContent));
    const ok = options.some((o) => o.includes('Anderssons'));
    await p.evaluate(() => document.querySelector('.modal-backdrop.open [data-close], .modal-backdrop.open .close-btn')?.click());
    return ok ? 'im Aufgaben-Formular auswählbar' : `nicht gefunden (${options.length} Optionen)`;
  });
  await step('Mit Cloud: anlegen + direkt ins Partner-Portal einladen', async () => {
    await p.evaluate(() => { currentPage = 'settings'; settingsView = 'settings-data'; render(); });
    await p.fill('[data-cloud-form=signin] [name=email]', 'admin@husora.test'); await p.fill('[data-cloud-form=signin] [name=password]', 'Husora!2026');
    await p.$eval('[data-cloud-form=signin] button[type=submit]', (e) => e.click()); await p.waitForFunction(() => cloudReady() && !cloudState.busy, null, { timeout: 20000 });
    await p.evaluate(() => { currentPage = 'providers'; render(); });
    await p.$eval('[data-custom-provider-new]', (e) => e.click()); await p.waitForTimeout(100);
    await p.fill('#custom-provider-form [name=name]', `Nilssons Städ ${N}`); await p.fill('#custom-provider-form [name=email]', 'info@nilsson.test');
    const hasInvite = !!(await p.$('#custom-provider-form [name=invite]'));
    await p.$eval('#custom-provider-form [name=invite]', (e) => { e.checked = true; });
    await p.$eval('#custom-provider-form button[type=submit]', (e) => e.click());
    await p.waitForFunction(() => currentPage === 'partnerHub' && !ownerSide.busy && ownerSide.code, null, { timeout: 20000 }); await p.waitForTimeout(300);
    await p.screenshot({ path: OUT + '/5-einladung.png' });
    return `Option sichtbar: ${hasInvite} · Code ${await p.evaluate(() => ownerSide.code.code)} · DB: ${sql(`select company_name||' '||coalesce(email,'') from service_partners where company_name='Nilssons Städ ${N}'`)}`;
  });
  await step('Eigene Partner werden mit der Cloud abgeglichen', async () => {
    await p.evaluate(() => { currentPage = 'settings'; settingsView = 'settings-data'; render(); });
    await p.$eval('[data-cloud-action=upload]', (e) => e.click()); await p.waitForFunction(() => /hochgeladen/.test(cloudState.notice) || cloudState.error, null, { timeout: 30000 });
    return sql(`select size_bytes||' Bytes' from app_data where key='stugliv-custom-providers' order by updated_at desc limit 1`);
  });
  await step('Löschen entfernt Partner und Zuordnung', async () => {
    await p.evaluate(() => { currentPage = 'assignedProviders'; render(); });
    await p.evaluate((n) => [...document.querySelectorAll('.ap-card')].find((c) => c.textContent.includes(n)).querySelector('[data-custom-provider-edit]').click(), NAME); await p.waitForTimeout(100);
    await p.$eval('[data-custom-provider-delete]', (e) => e.click()); await p.waitForTimeout(200);
    return `noch vorhanden: ${await p.evaluate((n) => providers.some((x) => x.name === n), NAME)} · Zuordnungen: ${await p.evaluate((n) => Object.values(servicePartnerAssignments).flat().filter((id) => id.startsWith('custom-')).length, NAME)}`;
  });
  console.log(res.join('\n')); console.log(errs.length ? 'JS-Fehler:\n' + [...new Set(errs)].join('\n') : 'keine JS-Fehler'); await b.close();
})();
