// Hybrid Service & Smart Maintenance (Migration 4700): Szenarien A–D im Browser – Hausbesitzer-App und Partner-Portal
const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON } = require('./env'); const OUT = SP + '/audit/hybrid'; fs.mkdirSync(OUT, { recursive: true });
const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Hybrid Service ${N}`, P_EMAIL = `hybrid${N}@hs.test`, PW = 'Husora!2026';
const ORG = 'cccccccc-0000-4000-8000-000000000001', PROP = 'dddddddd-0000-4000-8000-000000000001';
const sql = (q) => execSync(`psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -At -c "${q.replace(/"/g, '\\"')}"`).toString().trim();
(async () => {
  const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (name, fn) => { try { const r = await fn(); res.push(`OK   ${name}${r ? ' – ' + r : ''}`); } catch (e) { res.push(`FEHL ${name} – ${e.message.split('\n')[0].slice(0, 240)}`); } };
  const device = async (label, width = 390) => {
    const ctx = await b.newContext({ viewport: { width, height: 844 }, isMobile: width < 600, hasTouch: true, deviceScaleFactor: 2 });
    const p = await ctx.newPage(); p.on('pageerror', (e) => errs.push(`${label}: ${e.message}`)); p.on('dialog', (d) => d.accept(d.type() === 'prompt' ? (globalThis.NEXT_PROMPT || 'ok') : undefined));
    await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
    await p.goto('http://127.0.0.1:8081/index.html');
    await p.evaluate(({ url, key }) => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); localStorage.setItem('husora-cloud', JSON.stringify({ url, key })); }, { url: URL_, key: ANON });
    await p.reload(); await p.waitForTimeout(400); return p;
  };
  const H = await device('H');
  const hWait = () => H.waitForFunction(() => !ownerSide.busy, null, { timeout: 25000 }).then(() => H.waitForTimeout(300));
  const hErr = async () => { const e = await H.evaluate(() => ownerSide.error); if (e) throw new Error(e); };
  const hub = async (tab) => { await H.evaluate(async (t) => { await ownerLoadPartners(); currentPage = 'partnerHub'; hub.tab = t; render(); }, tab); await H.waitForTimeout(300); };
  await step('Hausbesitzer: anmelden', async () => {
    await H.evaluate(() => document.querySelector('.nav [data-page="partnerHub"]').click()); await H.waitForTimeout(300);
    await H.fill('[data-cloud-form=signin] [name=email]', 'admin@husora.test'); await H.fill('[data-cloud-form=signin] [name=password]', PW);
    await H.$eval('[data-cloud-form=signin] button[type=submit]', (e) => e.click());
    await H.waitForFunction(() => cloudReady() && !cloudState.busy && ownerSide.partners !== null && !ownerSide.busy, null, { timeout: 25000 });
  });
  let CODE = '';
  await step('Hausbesitzer: Partner einladen', async () => {
    await H.fill('[data-owner-form=partner] [name=company_name]', FIRM); await H.fill('[data-owner-form=partner] [name=email]', P_EMAIL);
    await H.$eval('[data-owner-form=partner] button[type=submit]', (e) => e.click()); await hWait();
    CODE = await H.evaluate(() => ownerSide.code?.code || ownerSide.error); if (!/^HUS-/.test(CODE)) throw new Error(CODE); return CODE;
  });
  const P = await device('P');
  const wait = () => P.waitForFunction(() => !pp.busy, null, { timeout: 25000 }).then(() => P.waitForTimeout(300));
  const pRpc = (name, body) => P.evaluate(async ({ name, body }) => { try { await cloudFetch(`/rest/v1/rpc/${name}`, { method: 'POST', body }); return ''; } catch (e) { return e.message; } }, { name, body });
  await step('Partner: Betrieb anlegen und verbinden', async () => {
    await P.evaluate(() => ppOpen('dashboard')); await P.waitForTimeout(200);
    await P.fill('[data-pp-form=login] [name=email]', P_EMAIL); await P.fill('[data-pp-form=login] [name=password]', PW);
    await P.$eval('[data-pp-action=signup]', (e) => e.click()); await P.waitForFunction(() => !pp.busy && document.querySelector('[data-pp-form=company]'), null, { timeout: 25000 });
    await P.fill('[data-pp-form=company] [name=name]', FIRM); await P.$eval('[data-pp-form=company] button[type=submit]', (e) => e.click()); await P.waitForFunction(() => !pp.busy && ppOrg(), null, { timeout: 25000 });
    await P.evaluate(() => { pp.view = 'customers'; ppRender(); });
    await P.fill('[data-pp-form=invite-code] [name=code]', CODE); await P.$eval('[data-pp-form=invite-code] button[type=submit]', (e) => e.click()); await wait();
    return await P.evaluate(() => pp.ctx.links.map((l) => l.organization_name).join(', '));
  });
  const SPID = sql(`select id from service_partners where company_name='${FIRM}' and organization_id='${ORG}'`);
  sql(`insert into property_service_assignments (organization_id, property_id, service_partner_id, start_date) values ('${ORG}', '${PROP}', '${SPID}', current_date - 1)`);

  // ---------- Szenario B: vierteljährliche Heizungsprüfung ohne Dauerauftrag (Freigabe je Einsatz) + Bündelung ----------
  const newPlan = async (fill, arg = {}) => {
    await H.$eval('[data-mt-action="new"]', (e) => e.click()); await H.waitForTimeout(300);
    await H.evaluate(fill, { N, SPID, ...arg }); await H.waitForTimeout(900);
    const preview = await H.$eval('#mt-preview', (e) => e.textContent);
    await H.$eval('[data-mt-form] button[type=submit]', (e) => e.click()); await hWait(); await hErr();
    return preview;
  };
  await step('B: Wartungsplan „vierteljährlich, Freigabe je Einsatz“ mit Terminvorschau', async () => {
    await hub('maintenance');
    const preview = await newPlan(({ N, SPID }) => {
      const f = document.querySelector('[data-mt-form]');
      f.elements.property_id.value = 'dddddddd-0000-4000-8000-000000000001';
      f.elements.title.value = `Heizung prüfen ${N}`;
      f.elements.interval_type.value = 'quarterly';
      const d = new Date(Date.now() + 3 * 86400000); f.elements.start_date.value = d.toISOString().slice(0, 10);
      f.querySelector('[name=automation_mode][value=owner_approval]').checked = true;
      f.elements.interval_type.dispatchEvent(new Event('change', { bubbles: true }));
      f.elements.assigned_partner_id.value = SPID;
    });
    const dates = (preview.match(/\d{2}\.\d{2}\.\d{4}/g) || []).length;
    if (dates < 4) throw new Error(`Vorschau: ${preview}`);
    const r = sql(`select count(*) from service_tasks t join maintenance m on m.id=t.maintenance_id where m.title = 'Heizung prüfen ${N}' and m.organization_id='${ORG}' and t.owner_action='approval_required'`);
    if (Number(r) < 1) throw new Error(`Fälligkeiten mit Freigabe: ${r}`);
    return `${dates} Termine in der Vorschau, Fälligkeit wartet auf Freigabe`;
  });
  await step('B: zweiter Plan (Dachrinne mit Checkliste), Fälligkeiten unter „Handlungsbedarf“', async () => {
    await newPlan(({ N }) => {
      const f = document.querySelector('[data-mt-form]');
      f.elements.title.value = `Dachrinne prüfen ${N}`; f.elements.category.value = 'Dach'; f.elements.interval_type.value = 'yearly';
      f.elements.start_date.value = new Date(Date.now() + 5 * 86400000).toISOString().slice(0, 10);
      f.elements.checklist.value = 'Laub entfernen\nFallrohr prüfen';
      f.querySelector('[name=automation_mode][value=owner_approval]').checked = true;
      f.elements.interval_type.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await hub('maintenance');
    const rows = await H.$$eval('.mt-occ', (els) => els.map((e) => e.textContent));
    await H.screenshot({ path: OUT + '/1-wartung-handlungsbedarf.png', fullPage: true });
    if (!rows.some((t) => t.includes(`Heizung prüfen ${N}`) && /Entscheidung nötig/.test(t)) || !rows.some((t) => t.includes(`Dachrinne prüfen ${N}`))) throw new Error(rows.join(' | ').slice(0, 200));
    return `${rows.length} Fälligkeiten`;
  });
  let BUNDLE = '';
  await step('B: zwei Fälligkeiten gebündelt beauftragen → ein Auftrag mit zwei Positionen', async () => {
    const ids = await H.$$eval('.mt-occ', (els, N) => els.filter((e) => e.textContent.includes(`Heizung prüfen ${N}`) || e.textContent.includes(`Dachrinne prüfen ${N}`)).map((e) => e.querySelector('[data-mt-pick]')?.dataset.mtPick).filter(Boolean), N);
    if (ids.length < 2) throw new Error(`nur ${ids.length} wählbar`);
    for (const id of ids.slice(0, 2)) { await H.$eval(`[data-mt-pick="${id}"]`, (el) => { el.checked = true; el.dispatchEvent(new Event('change', { bubbles: true })); }); await H.waitForTimeout(150); }
    await H.evaluate((sp) => { document.querySelector('[data-mt-bundle-partner]').value = sp; }, SPID);
    await H.screenshot({ path: OUT + '/2-buendeln.png' });
    await H.$eval('[data-mt-action="bundle"]', (e) => e.click()); await hWait(); await hErr();
    BUNDLE = sql(`select i.service_order_id from service_order_items i where i.occurrence_id = '${ids[0]}'`);
    const n = sql(`select count(*)||'/'||(select source_type from service_orders where id='${BUNDLE}') from service_order_items where service_order_id='${BUNDLE}'`);
    if (n !== '2/maintenance') throw new Error(n); return 'Auftrag mit 2 Positionen (Quelle Wartungsplan)';
  });
  await step('B: Partner sieht Positionen und Checkliste, dokumentiert je Position', async () => {
    await P.evaluate(async () => { await ppLoad(); }); await wait();
    if (await pRpc('transition_service_order', { p_service_order_id: BUNDLE, p_status: 'accepted' })) throw new Error('annehmen');
    if (await pRpc('transition_service_order', { p_service_order_id: BUNDLE, p_status: 'in_progress' })) throw new Error('starten');
    await P.evaluate(async (id) => { await ppLoad(); pp.view = 'orders'; pp.detail = { type: 'order', id }; ppRender(); }, BUNDLE); await wait();
    const txt = await P.$eval('#partner-portal', (e) => e.textContent);
    if (!/Positionen \(2\)/.test(txt) || !/Fallrohr prüfen/.test(txt)) throw new Error('Positionen fehlen');
    for (const key of ['Laub entfernen', 'Fallrohr prüfen']) { await P.$eval(`[data-pp-item-check][data-key="${key}"]`, (el) => { el.checked = true; el.dispatchEvent(new Event('change', { bubbles: true })); }); await wait(); }
    const items = await P.$$eval('[data-pp-item][data-status="done"]', (els) => els.map((e) => e.dataset.ppItem));
    for (const id of items) { await P.$eval(`[data-pp-item="${id}"][data-status="done"]`, (e) => e.click()); await wait(); }
    await P.evaluate(() => document.querySelector('.mt-item-card')?.scrollIntoView()); await P.screenshot({ path: OUT + '/3-partner-positionen.png' });
    const r = sql(`select string_agg(status, ',' order by sort_order) || '/' || bool_or(checklist_results ? 'Fallrohr prüfen') from service_order_items where service_order_id='${BUNDLE}'`);
    if (r !== 'done,done/true') throw new Error(r); return 'Checkliste abgehakt, beide Positionen erledigt';
  });
  await step('B: Partner meldet erledigt → Fälligkeiten erledigt, Hausbesitzer bestätigt Abschluss', async () => {
    if (await pRpc('transition_service_order', { p_service_order_id: BUNDLE, p_status: 'completed' })) throw new Error('abschließen');
    await hub('orders');
    const btn = await H.$(`[data-hub-confirm="ok"][data-id="${BUNDLE}"]`); if (!btn) throw new Error('Bestätigen-Knopf fehlt');
    await H.evaluate((id) => document.querySelector(`[data-hub-confirm="ok"][data-id="${id}"]`).closest('.hub-order').scrollIntoView(), BUNDLE); await H.screenshot({ path: OUT + '/4-besitzer-bestaetigen.png' });
    await btn.click(); await hWait(); await hErr();
    const r = sql(`select (owner_confirmed_at is not null) || '/' || (select count(*) from service_tasks t join service_order_items i on i.occurrence_id=t.id where i.service_order_id='${BUNDLE}' and t.status='completed') from service_orders where id='${BUNDLE}'`);
    if (r !== 'true/2') throw new Error(r); return 'bestätigt, 2 Fälligkeiten erledigt';
  });

  // ---------- Szenario A: wöchentliche Gartenpflege mit Dauerauftrag ----------
  const AG = sql(`insert into service_agreements (organization_id, property_id, service_partner_id, title, task_title, task_titles, visits_per_year, annual_price, currency, starts_on, ends_on, status, proposed_by, pricing_type, unit_price, max_price_per_visit, approval_mode, categories)
    values ('${ORG}', '${PROP}', '${SPID}', 'Gartenpflege ${N}', 'Rasen mähen ${N}', array['Rasen mähen ${N}'], 30, 1200, 'EUR', current_date - 1, current_date + 200, 'active', 'owner', 'per_visit', 40, 50, 'auto_within_limits', array['Garten']) returning id`).split('\n')[0];
  await step('A: Konditionen des Dauerauftrags beim Hausbesitzer sichtbar', async () => {
    await hub('agreements');
    const t = await H.evaluate((id) => document.querySelector(`[data-ag-terms="edit"][data-id="${id}"]`)?.closest('article')?.textContent || '', AG);
    if (!/Preis je Einsatz/.test(t) || !/automatisch im vereinbarten Rahmen/.test(t)) throw new Error(t.slice(0, 160)); return 'Preis je Einsatz, Max., Freigabeart, Fassung';
  });
  await step('A: Plan „wöchentlich, automatisch über Dauerauftrag“ → Aufträge nach Vertragsprüfung', async () => {
    await hub('maintenance');
    await newPlan(({ N, AG }) => {
      const f = document.querySelector('[data-mt-form]');
      f.elements.title.value = `Rasen mähen ${N}`; f.elements.category.value = 'Garten'; f.elements.interval_type.value = 'weekly';
      f.elements.start_date.value = new Date().toISOString().slice(0, 10);
      f.querySelector('[name=automation_mode][value=agreement_auto]').checked = true;
      f.elements.interval_type.dispatchEvent(new Event('change', { bubbles: true }));
      f.elements.service_agreement_id.value = AG;
    }, { AG });
    const n = sql(`select count(*) from service_orders where agreement_id='${AG}' and source_type='agreement_auto'`);
    const price = sql(`select coalesce(min(estimated_cost)::text,'-') from service_orders where agreement_id='${AG}' and source_type='agreement_auto'`);
    if (Number(n) < 2 || price !== '40.00') throw new Error(`${n} Aufträge, Preis ${price}`);
    return `${n} Aufträge à ${price} € automatisch erstellt`;
  });
  await step('A: zweiter Scheduler-Lauf erzeugt nichts doppelt', async () => {
    const before = sql(`select count(*) from service_orders where agreement_id='${AG}'`);
    sql('select public.run_maintenance_scheduler()');
    const after = sql(`select count(*) from service_orders where agreement_id='${AG}'`);
    if (before !== after) throw new Error(`${before} → ${after}`); return `${after} Aufträge, unverändert`;
  });
  const AUTO = sql(`select o.id from service_orders o join service_tasks t on t.id=o.service_task_id where o.agreement_id='${AG}' order by t.local_scheduled_date limit 1`);
  await step('A: Partner sieht den Auftrag mit Vertragsbezug', async () => {
    await P.evaluate(async (id) => { await ppLoad(); pp.view = 'orders'; pp.detail = { type: 'order', id }; ppRender(); }, AUTO); await wait();
    const txt = await P.$eval('#partner-portal', (e) => e.textContent);
    await P.screenshot({ path: OUT + '/5-partner-dauerauftrag.png' });
    if (!/Automatisch aus Dauerauftrag/.test(txt) || !/Vertragsfassung 1/.test(txt)) throw new Error('Hinweis fehlt'); return 'Fassung 1, Rahmen 40 €';
  });

  // ---------- Szenario D: Budgetüberschreitung ----------
  await step('D: Mehrkosten über Vertragsmaximum → keine automatische Freigabe, Abschluss gesperrt', async () => {
    sql(`update organizations set auto_approval_limit = 100 where id='${ORG}'`);
    if (await pRpc('transition_service_order', { p_service_order_id: AUTO, p_status: 'accepted' })) throw new Error('annehmen');
    if (await pRpc('transition_service_order', { p_service_order_id: AUTO, p_status: 'in_progress' })) throw new Error('starten');
    if (await pRpc('request_approval', { p_service_order_id: AUTO, p_title: 'Hecke zusätzlich', p_amount: 25 })) throw new Error('Mehrkosten');
    const st = sql(`select status from approval_requests where service_order_id='${AUTO}'`);
    const msg = await pRpc('transition_service_order', { p_service_order_id: AUTO, p_status: 'completed' });
    sql(`update organizations set auto_approval_limit = null where id='${ORG}'`);
    if (st !== 'pending' || !/Freigabe/.test(msg)) throw new Error(`${st} / ${msg}`); return `Anfrage „pending“ trotz Auto-Limit; Abschluss: ${msg.slice(0, 70)}`;
  });
  await step('D: Hausbesitzer gibt den Mehrbetrag explizit frei → Abschluss möglich', async () => {
    await hub('orders');
    const id = sql(`select id from approval_requests where service_order_id='${AUTO}'`);
    await H.click(`.hub-approvals-card [data-hub-approval="${id}"][data-approve="1"]`); await H.waitForSelector('[data-cost-confirm="ok"]'); await H.click('[data-cost-confirm="ok"]'); await hWait();
    const st = sql(`select status from approval_requests where id='${id}'`);
    if (st !== 'approved') throw new Error(`Freigabe: ${st}`);
    const msg = await pRpc('transition_service_order', { p_service_order_id: AUTO, p_status: 'completed' });
    if (msg) throw new Error(msg);
    return sql(`select status||' / Rahmen '||estimated_cost from service_orders where id='${AUTO}'`);
  });

  // ---------- Szenario C: Mangel → Auftrag als Finding ----------
  await step('C: Mangel aus Kontrolle wird als „Aus Mangel“ geführt', async () => {
    const o = sql(`insert into service_orders (organization_id, property_id, service_partner_id, title, status) values ('${ORG}', '${PROP}', '${SPID}', 'Mangel: Dachrinne ${N}', 'offered') returning id`).split('\n')[0];
    sql(`insert into repairs (organization_id, property_id, title, service_order_id, service_partner_id) values ('${ORG}', '${PROP}', 'Dachrinne ${N}', '${o}', '${SPID}')`);
    const r = sql(`select source_type || '/' || (select count(*) from service_order_items where service_order_id='${o}' and source_repair_id is not null) from service_orders where id='${o}'`);
    await hub('orders');
    const badge = await H.evaluate((t) => [...document.querySelectorAll('.hub-order')].find((e) => e.textContent.includes(t))?.querySelector('.mt-source')?.textContent, `Mangel: Dachrinne ${N}`);
    if (r !== 'finding/1' || !/Mangel/.test(badge || '')) throw new Error(`${r} / ${badge}`); return 'Quelle Finding, Position mit Mangelbezug';
  });

  await step('Mandantentrennung: Partner liest keine Wartungspläne', async () => {
    const n = await P.evaluate(async () => (await cloudFetch('/rest/v1/maintenance?select=id')).length);
    if (n !== 0) throw new Error(String(n)); return '0 Pläne sichtbar';
  });
  await step('Aufgaben-Seite: Hinweis auf Wartungsfälligkeiten führt in die Wartung', async () => {
    sql(`select public.run_maintenance_scheduler()`);
    await H.evaluate(async () => { await ownerLoadPartners(); currentPage = 'tasks'; render(); }); await H.waitForTimeout(300);
    const t = await H.$eval('.mt-tasks-hint', (e) => e.textContent).catch(() => '');
    if (!/Wartungspläne/.test(t)) throw new Error('Hinweis fehlt');
    await H.$eval('[data-mt-open]', (e) => e.click()); await H.waitForTimeout(500);
    const ok = await H.evaluate(() => currentPage === 'partnerHub' && hub.tab === 'maintenance' && !!document.querySelector('.mt-kpis'));
    if (!ok) throw new Error('nicht in der Wartung'); return t.replace(/\s+/g, ' ').trim().slice(0, 90);
  });
  await step('Dunkelmodus: Wartungsansicht lesbar', async () => {
    await hub('maintenance'); await H.evaluate(() => document.documentElement.classList.add('dark')); await H.waitForTimeout(200);
    const c = await H.evaluate(() => { const e = document.querySelector('.mt-kpi b'); return e ? getComputedStyle(e).color : ''; });
    await H.screenshot({ path: OUT + '/6-dunkel.png' }); await H.evaluate(() => document.documentElement.classList.remove('dark'));
    if (!c) throw new Error('keine Kennzahl'); return c;
  });
  console.log(res.join('\n')); if (errs.length) console.log('JS-Fehler:\n' + errs.join('\n'));
  await b.close();
})();
