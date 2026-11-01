const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON: ENV_ANON } = require('./env'); const OUT = SP + '/audit/plan'; fs.mkdirSync(OUT, { recursive: true });
const ANON = ENV_ANON; const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Hagfors Kontroll ${N}`, P_EMAIL = `plan${N}@hs.test`, PW = 'Husora!2026';
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
    const card = await H.$$('.hub-partner'); for (const c of card) { if ((await c.textContent().catch(() => '')).includes(FIRM)) { await c.screenshot({ path: OUT + '/2-code.png' }).catch(() => {}); } }
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



  const spId = () => sql(`select id from service_partners where company_name='${FIRM}' and organization_id=(select id from organizations where name='Husora Testorganisation')`);
  const planDocs = () => sql(`select count(*) from documents d join service_orders o on o.id=d.service_order_id where o.service_partner_id='${spId()}' and d.file_name like 'Kontrollplan%' and d.file_type='application/pdf'`);
  await step('Hausbesitzer: Hauskontrolle per „SP beauftragen“ → Kontrollplan-PDF hängt am Auftrag', async () => {
    await H.evaluate(({ firm, email }) => {
      const id = 'custom-k' + Date.now(); providers.push({ id, name: firm, email, category: 'inspection', custom: true, initials: 'HK', distances: {} }); persistCustomProviders();
      const p = properties[0];
      tasks.push({ id: Date.now(), partnerId: id, title: 'Abwesenheitskontrolle Dezember', property: p.name, propertyId: p.id, date: localDateKey(new Date(Date.now() + 5 * 86400000)), priority: 'normal', area: 'Kontrolle', status: 'Offen', done: false, repeat: 'Einmalig' });
      try { localStorage.setItem('stugliv-tasks', JSON.stringify(tasks)); } catch (e) {}
    }, { firm: FIRM, email: P_EMAIL });
    await H.evaluate((firm) => commissionPartner(providers.find((p) => p.name === firm).id), FIRM); await H.waitForTimeout(2500);
    const n = planDocs(); if (n !== '1') throw new Error(`PDFs: ${n}`);
    return `${n} Kontrollplan-PDF · ${sql(`select d.file_name||' ('||d.file_size||' Bytes) · '||d.description from documents d join service_orders o on o.id=d.service_order_id where o.service_partner_id='${spId()}' limit 1`)}`;
  });
  await step('Partner: sieht und öffnet den Kontrollplan im Auftrag', async () => {
    await P.evaluate(async () => { await ppLoad(); const o = ppD('orders').find((x) => /Abwesenheitskontrolle Dezember/.test(x.title)); pp.view = 'orders'; pp.detail = { type: 'order', id: o.id }; ppRender(); }); await P.waitForTimeout(400);
    const label = await P.textContent('.pp-doc[data-pp-doc=view]');
    await P.click('.pp-doc[data-pp-doc=view]'); await P.waitForSelector('#pdf-viewer-modal.open', { timeout: 15000 });
    await P.screenshot({ path: OUT + '/1-partner-plan.png' }); await P.evaluate(() => closePdfViewer());
    if (!/Kontrollplan/.test(label)) throw new Error(label); return label.replace(/\s+/g, ' ').trim();
  });
  await step('Hausbesitzer: Kontrollplan-Fenster → „Über Partner-Portal beauftragen“ mit PDF', async () => {
    const r = await H.evaluate(async (firm) => {
      const p = properties[0]; const prov = providers.find((x) => x.name === firm);
      tasks.forEach((t) => { if (/Abwesenheitskontrolle Dezember/.test(t.title)) { t.done = true; t.status = 'Erledigt'; } });
      const control = { id: 'ctrl-e2e-' + Date.now(), name: 'Winterkontrolle', providerId: prov.id, items: Object.fromEntries(absenceChecklist.slice(0, 5).map((i) => [i.id, 'monthly'])), createdAt: new Date().toISOString() };
      inspectionControls[p.id] = [...controlsFor(p.id), control];
      inspectionProperty = p.id; openSendPlan(control.id);
      await new Promise((res) => setTimeout(res, 2500));
      return { visible: !document.getElementById('send-plan-portal').hidden, note: document.getElementById('send-plan-portal-note').textContent };
    }, FIRM);
    if (!r.visible) throw new Error('Knopf nicht sichtbar: ' + r.note);
    await H.screenshot({ path: OUT + '/2-fenster.png' });
    await H.click('#send-plan-portal'); await H.waitForTimeout(3000);
    const n = planDocs(); const order = sql(`select o.title||' · '||o.status from service_orders o where o.service_partner_id='${spId()}' and o.title not like 'Abwesenheitskontrolle Dezember%' and exists (select 1 from documents d where d.service_order_id=o.id and d.file_name like 'Kontrollplan%') order by o.created_at desc limit 1`);
    if (n !== '2' || !order.includes('offered')) throw new Error(`PDFs ${n} · ${order}`);
    return `${r.note.slice(0, 70)}… · Auftrag „${order}“ · ${n} Kontrollplan-PDFs`;
  });
  console.log(res.join('\n')); console.log(errs.length ? 'JS-Fehler:\n' + [...new Set(errs)].join('\n') : 'keine JS-Fehler'); await b.close();
})();
