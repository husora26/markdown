const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON: ENV_ANON } = require('./env'); const OUT = SP + '/audit/hub2'; fs.mkdirSync(OUT, { recursive: true });
const ANON = ENV_ANON; const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Fjällstugan Service ${N}`, P_EMAIL = `hub2${N}@hs.test`, PW = 'Husora!2026';
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


  await step('Serviceaufgaben nach Partner: Knopf „SP beauftragen“ neben „Liste kopieren“', async () => {
    await H.evaluate((firm) => {
      const id = 'custom-h2' + Date.now(); providers.push({ id, name: firm, category: 'house', custom: true, initials: 'FS', distances: {} }); persistCustomProviders();
      const prop = properties[0]; const d = (n) => localDateKey(new Date(Date.now() + n * 86400000));
      tasks.push({ id: Date.now(), partnerId: id, title: 'Fenster putzen', property: prop.name, date: d(3), priority: 'normal', area: 'Reinigung', status: 'Offen', done: false, repeat: 'Einmalig' });
      tasks.push({ id: Date.now() + 1, partnerId: id, title: 'Laub entfernen', property: prop.name, date: d(4), priority: 'normal', area: 'Außen', status: 'Offen', done: false, repeat: 'Einmalig' });
      tasks.push({ id: Date.now() + 2, title: 'Schornstein fegen lassen', property: prop.name, date: d(9), priority: 'soon', area: 'Technik', status: 'Offen', done: false, repeat: 'Einmalig' });
      tasks.push({ id: Date.now() + 3, title: 'Wasserfilter tauschen', property: prop.name, date: d(12), priority: 'urgent', area: 'Technik', status: 'Offen', done: false, repeat: 'Einmalig' });
      try { localStorage.setItem('stugliv-tasks', JSON.stringify(tasks)); } catch (e) {}
      currentPage = 'tasks'; taskView = 'partners'; render();
    }, FIRM);
    await H.waitForTimeout(300);
    const card = await H.evaluateHandle((firm) => [...document.querySelectorAll('.partner-task-card')].find((c) => c.textContent.includes(firm)), FIRM);
    const buttons = await card.evaluate((c) => [...c.querySelectorAll('.partner-task-actions > *')].map((b) => b.textContent.trim()).join(' | '));
    await card.asElement().screenshot({ path: OUT + '/1-sp-beauftragen.png' });
    await card.evaluate((c) => c.querySelector('[data-commission-partner]').click());
    await H.waitForFunction(() => !ownerSide.dispatching, null, { timeout: 20000 }); await H.waitForTimeout(2500);
    const r = sql(`select string_agg(o.title, ', ' order by o.title) from service_orders o join service_partners sp on sp.id=o.service_partner_id where sp.company_name='${FIRM}'`);
    const st = await H.evaluate(() => tasks.filter((t) => ['Fenster putzen', 'Laub entfernen'].includes(t.title)).map((t) => `${t.title}: ${taskStatus(t)}`).join(', '));
    await H.screenshot({ path: OUT + '/1b-status.png' });
    const after = await H.evaluate((firm) => { const c = [...document.querySelectorAll('.partner-task-card')].find((x) => x.textContent.includes(firm)); const b = c.querySelector('[data-commission-partner]'); return `Knopf „${b.textContent.trim()}“ ${getComputedStyle(b).backgroundColor} · Chips: ${c.querySelectorAll('.ptask-status').length} · Kopf: ${c.querySelector('.partner-task-head small').textContent}`; }, FIRM);
    const card2 = await H.evaluateHandle((firm) => [...document.querySelectorAll('.partner-task-card')].find((c) => c.textContent.includes(firm)), FIRM); await card2.asElement().screenshot({ path: OUT + '/1c-beauftragt.png' });
    // früher gesendete Aufgabe, die noch auf „Offen“ steht → wird nachgezogen
    await H.evaluate(() => { const t = tasks.find((x) => x.title === 'Fenster putzen'); t.status = 'Offen'; t.done = false; persistTasks(); render(); });
    const mid = await H.evaluate((firm) => [...document.querySelectorAll('.partner-task-card')].find((x) => x.textContent.includes(firm)).querySelector('[data-commission-partner]').textContent.trim(), FIRM);
    await H.evaluate((firm) => [...document.querySelectorAll('.partner-task-card')].find((x) => x.textContent.includes(firm)).querySelector('[data-commission-partner]').click(), FIRM); await H.waitForTimeout(2500);
    const restated = await H.evaluate((firm) => `${taskStatus(tasks.find((x) => x.title === 'Fenster putzen'))} · Knopf „${[...document.querySelectorAll('.partner-task-card')].find((x) => x.textContent.includes(firm)).querySelector('[data-commission-partner]').textContent.trim()}“`, FIRM);
    if (!/Fenster putzen/.test(r) || !/Laub/.test(r) || /Offen/.test(st) || !/SP beauftragt/.test(after) || !/rgb\(47, 111, 176\)/.test(after) || !/In Bearbeitung · Knopf „SP beauftragt“/.test(restated)) throw new Error(`${after} // ${st} // ${mid} → ${restated}`);
    return `${buttons} · Status: ${st} · danach: ${after} · Nachziehen: „${mid}“ → ${restated}`;
  });
  await step('Partner-Portal → Aufträge: Partner-Auswahl, mehrere Aufgaben je Ferienhaus ankreuzen', async () => {
    await H.evaluate(() => { currentPage = 'partnerHub'; hub.tab = 'orders'; render(); }); await H.evaluate(() => hubRefresh()); await H.waitForTimeout(500);
    await H.evaluate((firm) => { const p = ownerSide.partners.find((x) => x.company_name === firm); hub.partner = p.id; hubRerender(); }, FIRM);
    const picks = await H.$$eval('[data-hub-pick]', (e) => e.length);
    const doneBadges = await H.$$eval('.hub-pick.done', (e) => e.length);
    for (const t of ['Schornstein fegen lassen', 'Wasserfilter tauschen']) await H.evaluate((t) => [...document.querySelectorAll('.hub-pick')].find((l) => l.textContent.includes(t) && !l.classList.contains('done')).querySelector('input').click(), t);
    await H.waitForTimeout(200);
    await H.evaluate(() => { document.querySelector('.hub-dispatch').scrollIntoView(); window.scrollBy(0, -70); }); await H.screenshot({ path: OUT + '/2-senden.png' });
    const bar = await H.evaluate(() => document.querySelector('.hub-send-bar').innerText.replace(/\s+/g, ' '));
    await H.click('[data-hub-send-picked]'); await H.waitForFunction(() => !ownerSide.busy, null, { timeout: 20000 }); await H.waitForTimeout(400);
    const r = sql(`select count(*) from service_orders o join service_partners sp on sp.id=o.service_partner_id where sp.company_name='${FIRM}'`);
    if (r !== '4') throw new Error(`${bar} → ${r}`); return `${picks} Aufgaben zur Wahl, ${doneBadges} schon gesendet · Leiste: „${bar}“ → ${r} Aufträge`;
  });
  await step('Aufträge gruppiert nach Servicepartner und Ferienhaus', async () => {
    await H.evaluate(() => document.querySelector('.hub-list-title').scrollIntoView()); await H.screenshot({ path: OUT + '/3-auftraege.png' });
    return await H.evaluate((firm) => { const g = [...document.querySelectorAll('.hub-group')].find((x) => x.textContent.includes(firm)); return `${document.querySelectorAll('.hub-group').length} Partnergruppen · ${g.querySelector('.hub-section-title').innerText.replace(/\s+/g, ' ')} · Häuser: ${[...g.querySelectorAll('.hub-house-label')].map((x) => x.textContent.trim()).join(', ')} · Karte: ${g.querySelector('.hub-order small').innerText.slice(0, 60)}`; }, FIRM);
  });
  await step('Messenger gruppiert nach Servicepartner, Auftragsgespräche mit Ferienhaus', async () => {
    const link = await P.evaluate(() => pp.ctx.links[0]);
    await P.evaluate(() => ppLoad()); await P.waitForFunction(() => !pp.busy, null, { timeout: 15000 });
    const oid = await P.evaluate(() => { const o = ppD('orders').find((o) => o.title === 'Fenster putzen'); if (!o) throw new Error('P: ' + pp.error + ' / ' + ppD('orders').map((x) => x.title).join(',') + ' / ctx ' + JSON.stringify(pp.ctx?.links)); return o.id; });
    await P.evaluate(async ({ l, oid }) => { await cloudFetch('/rest/v1/messages', { method: 'POST', body: { organization_id: l.organization_id, service_order_id: oid, message: 'Fenster mache ich am Donnerstag.' }, headers: { Prefer: 'return=minimal' } }); await cloudFetch('/rest/v1/messages', { method: 'POST', body: { organization_id: l.organization_id, service_partner_id: l.service_partner_id, message: 'Hallo, danke für die Aufträge!' }, headers: { Prefer: 'return=minimal' } }); }, { l: link, oid });
    await H.evaluate(() => { hub.tab = 'chat'; hub.thread = null; }); await H.evaluate(() => hubRefresh()); await H.waitForTimeout(400);
    await H.screenshot({ path: OUT + '/4-messenger.png', fullPage: false });
    return await H.evaluate((firm) => { const g = [...document.querySelectorAll('.hub-group')].find((x) => x.textContent.includes(firm)); return `${g.querySelector('.hub-section-title').innerText.replace(/\s+/g, ' ')} → ${[...g.querySelectorAll('.hub-conv')].map((c) => c.innerText.replace(/\s+/g, ' ').slice(0, 70)).join(' | ')}`; }, FIRM);
  });
  await step('Partner meldet „Erledigt“ → Aufgabe beim Hausbesitzer automatisch abgehakt', async () => {
    await P.evaluate(() => { pp.detail = { type: 'order', id: ppD('orders').find((o) => o.title === 'Laub entfernen').id }; pp.view = 'orders'; ppRender(); });
    for (const a of ['accept', 'start']) { await P.click(`[data-pp-action=${a}]`); await P.waitForFunction(() => !pp.busy, null, { timeout: 15000 }); await P.waitForTimeout(300); }
    await P.fill('[data-pp-field=actual]', '300'); await P.click('[data-pp-action=complete]'); await P.waitForFunction(() => !pp.busy, null, { timeout: 15000 });
    await H.evaluate(() => { currentPage = 'tasks'; taskView = 'list'; render(); msgTop.fullAt = 0; }); await H.evaluate(() => msgPoll()); await H.waitForTimeout(800);
    const st = await H.evaluate(() => { const t = tasks.find((x) => x.title === 'Laub entfernen'); return `${taskStatus(t)} · done=${t.done}`; });
    const toast = await H.evaluate(() => document.querySelector('.toast, #toast')?.textContent || '');
    if (!/Erledigt/.test(st)) throw new Error(st); return `${st} · Hinweis: ${toast.trim().slice(0, 90)}`;
  });
  console.log(res.join('\n')); console.log(errs.length ? 'JS-Fehler:\n' + [...new Set(errs)].join('\n') : 'keine JS-Fehler'); await b.close();
})();
