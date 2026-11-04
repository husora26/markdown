// Partner-Startseite: Mängel-Zahlen überall gleich, Bereiche einklappbar/„Alle anzeigen“, Aufträge nach Kunde und Gebäude filtern
const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON } = require('./env'); const OUT = SP + '/audit/pphome'; fs.mkdirSync(OUT, { recursive: true });
const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Startseite Service ${N}`, P_EMAIL = `pphome${N}@hs.test`, PW = 'Husora!2026';
const ORG = 'cccccccc-0000-4000-8000-000000000001', PROP = 'dddddddd-0000-4000-8000-000000000001';
const sql = (q) => execSync(`psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -At -c "${q.replace(/"/g, '\\"')}"`).toString().trim();
(async () => {
  const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (name, fn) => { try { const r = await fn(); res.push(`OK   ${name}${r ? ' – ' + r : ''}`); } catch (e) { res.push(`FEHL ${name} – ${e.message.split('\n')[0].slice(0, 240)}`); } };
  const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  const P = await ctx.newPage(); P.on('pageerror', (e) => errs.push(e.message)); P.on('dialog', (d) => d.accept());
  await P.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
  await P.goto('http://127.0.0.1:8081/index.html');
  await P.evaluate(({ url, key }) => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); localStorage.setItem('husora-cloud', JSON.stringify({ url, key })); }, { url: URL_, key: ANON });
  await P.reload(); await P.waitForTimeout(400);
  const wait = () => P.waitForFunction(() => !pp.busy, null, { timeout: 25000 }).then(() => P.waitForTimeout(300));
  await step('Partner: Betrieb anlegen', async () => {
    await P.evaluate(() => ppOpen('dashboard')); await P.waitForTimeout(200);
    await P.fill('[data-pp-form=login] [name=email]', P_EMAIL); await P.fill('[data-pp-form=login] [name=password]', PW);
    await P.$eval('[data-pp-action=signup]', (e) => e.click()); await P.waitForFunction(() => !pp.busy && document.querySelector('[data-pp-form=company]'), null, { timeout: 25000 });
    await P.fill('[data-pp-form=company] [name=name]', FIRM); await P.$eval('[data-pp-form=company] button[type=submit]', (e) => e.click()); await P.waitForFunction(() => !pp.busy && ppOrg(), null, { timeout: 25000 });
  });
  const POrg = sql(`select id from organizations where name='${FIRM}'`);
  // Testdaten: 2 eigene Kunden mit je einem Haus, 5 Aufträge, 1 Kontrolle mit 2 Mängeln (einer davon angefragt)
  const SELF = sql(`select id from service_partners where partner_organization_id='${POrg}' and organization_id='${POrg}'`) || sql(`insert into service_partners (organization_id, company_name, partner_organization_id) values ('${POrg}', '${FIRM}', '${POrg}') returning id`).split('\n')[0];
  const C1 = sql(`insert into customers (organization_id, first_name, last_name) values ('${POrg}', 'Anna', 'Berg ${N}') returning id`).split('\n')[0];
  const C2 = sql(`insert into customers (organization_id, company_name) values ('${POrg}', 'Fjäll AB ${N}') returning id`).split('\n')[0];
  const H1 = sql(`insert into properties (organization_id, name, owner_customer_id) values ('${POrg}', 'Haus Berg ${N}', '${C1}') returning id`).split('\n')[0];
  const H2 = sql(`insert into properties (organization_id, name, owner_customer_id) values ('${POrg}', 'Haus Fjäll ${N}', '${C2}') returning id`).split('\n')[0];
  const H3 = sql(`insert into properties (organization_id, name, owner_customer_id) values ('${POrg}', 'Stuga Fjäll ${N}', '${C2}') returning id`).split('\n')[0];
  for (const [h, t] of [[H1, 'A'], [H1, 'B'], [H2, 'C'], [H3, 'D'], [H3, 'E']]) sql(`insert into service_orders (organization_id, property_id, service_partner_id, title, status) values ('${POrg}', '${h}', '${SELF}', 'Auftrag ${t} ${N}', 'accepted')`);
  const INSP = sql(`insert into inspections (organization_id, property_id, service_partner_id, status) values ('${POrg}', '${H1}', '${SELF}', 'in_progress') returning id`).split('\n')[0];
  sql(`insert into inspection_items (inspection_id, category, name, status) values ('${INSP}', 'Dach', 'Rinne ${N}', 'defect'), ('${INSP}', 'Wasser', 'Hahn ${N}', 'defect')`);
  const ITEM = sql(`select id from inspection_items where inspection_id='${INSP}' and name='Hahn ${N}'`);
  sql(`insert into repairs (organization_id, property_id, inspection_id, inspection_item_id, title, status, service_partner_id) values ('${POrg}', '${H1}', '${INSP}', '${ITEM}', 'Hahn ${N}', 'reported', '${SELF}')`);
  // abgesagte Kontrolle: ihr Mangel darf nirgends mitzählen
  const INSP2 = sql(`insert into inspections (organization_id, property_id, service_partner_id, status) values ('${POrg}', '${H2}', '${SELF}', 'cancelled') returning id`).split('\n')[0];
  sql(`insert into inspection_items (inspection_id, category, name, status) values ('${INSP2}', 'Dach', 'Alt ${N}', 'defect')`);
  await P.evaluate(async () => { await ppLoad(); ppOpen('dashboard'); }); await wait();

  await step('Mängel: Kachel, Startseite, Menü und Mängel-Seite zeigen dieselbe Zahl', async () => {
    const r = await P.evaluate(() => {
      const tile = document.querySelector('.pp-home-tile[data-pp-view=defects] .pp-home-tile-value')?.textContent.trim();
      const sec = document.querySelector('[data-pp-fold-section=urgent] .pp-fold-count')?.textContent;
      const rows = document.querySelectorAll('[data-pp-fold-section=urgent] .pp-list > *').length;
      pp.view = 'defects'; ppRender();
      const heads = [...document.querySelectorAll('#partner-portal .pp-section-head h2')].map((h) => h.textContent).join(' | ');
      const sum = [...heads.matchAll(/\((\d+)\)/g)].reduce((s, m) => s + Number(m[1]), 0);
      pp.view = 'dashboard'; ppRender();
      return { tile, sec, rows, heads, sum };
    });
    if (r.tile !== '2 Mängel' || r.sec !== '2' || r.rows !== 2 || r.sum !== 2) throw new Error(JSON.stringify(r));
    return `Kachel ${r.tile}, Startseite ${r.sec}, Mängel-Seite: ${r.heads}`;
  });
  await step('Startseite: „Letzte Aktivität“ zeigt 3 von 5, „Alle anzeigen“ zeigt alle', async () => {
    const n = () => P.$$eval('[data-pp-fold-section=activity] .pp-list > *', (e) => e.length);
    const a = await n(); await P.click('[data-pp-fold-all=activity]'); await P.waitForTimeout(200); const all = await n();
    const label = await P.$eval('[data-pp-fold-all=activity]', (e) => e.textContent);
    if (a !== 3 || all !== 5 || label !== 'Weniger anzeigen') throw new Error(`${a}/${all}/${label}`); return '3 → 5';
  });
  await step('Startseite: Bereich einklappen bleibt nach Neuladen eingeklappt', async () => {
    await P.click('[data-pp-fold=activity]'); await P.waitForTimeout(200);
    await P.reload(); await P.waitForFunction(() => !pp.busy && pp.data, null, { timeout: 25000 }); await P.evaluate(() => ppOpen('dashboard')); await P.waitForTimeout(400);
    const closed = await P.$eval('[data-pp-fold-section=activity]', (e) => e.classList.contains('closed') && !e.querySelector('.pp-list'));
    await P.click('[data-pp-fold=activity]'); await P.waitForTimeout(200);
    if (!closed) throw new Error('nicht eingeklappt'); return 'eingeklappt, wieder aufgeklappt';
  });
  await step('Einstellungen: Bereich „Heute“ abschalten', async () => {
    await P.evaluate(() => { pp.view = 'settings'; pp.detail = null; ppRender(); }); await P.waitForTimeout(200);
    await P.$eval('[data-pp-home-pref=showToday]', (el) => { el.checked = false; el.dispatchEvent(new Event('change', { bubbles: true })); }); await P.waitForTimeout(200);
    await P.evaluate(() => ppOpen('dashboard')); await P.waitForTimeout(300);
    const has = await P.$('[data-pp-fold-section=today]');
    await P.evaluate(() => { pp.view = 'settings'; ppRender(); }); await P.$eval('[data-pp-home-pref=showToday]', (el) => { el.checked = true; el.dispatchEvent(new Event('change', { bubbles: true })); });
    if (has) throw new Error('noch sichtbar'); return 'ausgeblendet';
  });
  await step('Aufträge: nach Kunde filtern', async () => {
    await P.evaluate(() => { pp.view = 'orders'; pp.filter = 'all'; pp.detail = null; ppRender(); }); await P.waitForTimeout(200);
    const key = await P.$eval('[data-pp-order-opt=orderCustomer]', (s, name) => [...s.options].find((o) => o.textContent.includes(name))?.value, `Fjäll AB ${N}`);
    await P.selectOption('[data-pp-order-opt=orderCustomer]', key); await P.waitForTimeout(300);
    const titles = await P.$$eval('#partner-portal .pp-list .pp-order strong, #partner-portal .pp-list strong', (e) => [...new Set(e.map((x) => x.textContent))].filter((t) => t.startsWith('Auftrag')));
    const houses = await P.$$eval('[data-pp-order-opt=orderProperty] option', (e) => e.map((o) => o.textContent));
    if (titles.length !== 3 || houses.length !== 3) throw new Error(`${titles.join(',')} | ${houses.join(',')}`); return `${titles.length} Aufträge, Gebäude: ${houses.slice(1).join(', ')}`;
  });
  await step('Aufträge: zusätzlich nach Gebäude filtern', async () => {
    await P.selectOption('[data-pp-order-opt=orderProperty]', H3); await P.waitForTimeout(300);
    const titles = await P.$$eval('#partner-portal .pp-list strong', (e) => [...new Set(e.map((x) => x.textContent))].filter((t) => t.startsWith('Auftrag')));
    await P.screenshot({ path: OUT + '/1-filter.png' });
    if (titles.length !== 2 || !titles.every((t) => /Auftrag [DE]/.test(t))) throw new Error(titles.join(',')); return titles.join(', ');
  });
  await step('Auftragskarte zeigt den Namen des eigenen Kunden', async () => {
    const t = await P.$$eval('#partner-portal .pp-list .pp-item-main small', (e) => e.map((x) => x.textContent).join(' | '));
    if (!t.includes(`Fjäll AB ${N}`)) throw new Error(t.slice(0, 160)); return 'Fjäll AB statt „Eigener Kunde“';
  });
  await step('Aufträge: Kundenwechsel setzt ein fremdes Gebäude zurück', async () => {
    const key = await P.$eval('[data-pp-order-opt=orderCustomer]', (s, name) => [...s.options].find((o) => o.textContent.includes(name))?.value, `Berg ${N}`);
    await P.selectOption('[data-pp-order-opt=orderCustomer]', key); await P.waitForTimeout(300);
    const st = await P.evaluate(() => ({ prop: pp.orderProperty, n: [...document.querySelectorAll('#partner-portal .pp-list strong')].filter((e) => e.textContent.startsWith('Auftrag')).length }));
    await P.selectOption('[data-pp-order-opt=orderCustomer]', ''); await P.waitForTimeout(200);
    if (st.prop || st.n !== 2) throw new Error(JSON.stringify(st)); return '2 Aufträge von Anna Berg, Gebäudefilter zurückgesetzt';
  });
  await step('Einstellungen: Karten „Darstellung & Sprache“ und „Daten & App“ auf-/zuklappbar', async () => {
    await P.evaluate(() => { pp.view = 'settings'; pp.detail = null; ppRender(); }); await P.waitForTimeout(200);
    const n = await P.$$eval('#partner-portal .pp-sfold', (e) => e.length);
    for (const t of ['Darstellung & Sprache', 'Daten & App']) { await P.click(`#partner-portal [data-pp-sfold="${t}"]`); await P.waitForTimeout(150); }
    const st = await P.evaluate(() => ({ look: document.querySelector('[data-pp-sfold="Darstellung & Sprache"]').closest('.pp-sfold').classList.contains('closed'), lang: !!document.querySelector('#partner-portal .pp-sfold [data-app-lang]'), data: document.querySelector('[data-pp-sfold="Daten & App"]').closest('.pp-sfold').classList.contains('closed') }));
    await P.screenshot({ path: OUT + '/2-einstellungen-zu.png' });
    await P.reload(); await P.waitForFunction(() => !pp.busy && pp.data, null, { timeout: 25000 }); await P.evaluate(() => { ppOpen('settings'); }); await P.waitForTimeout(400);
    const after = await P.$eval('[data-pp-sfold="Daten & App"]', (e) => e.closest('.pp-sfold').classList.contains('closed'));
    for (const t of ['Darstellung & Sprache', 'Daten & App']) { await P.click(`#partner-portal [data-pp-sfold="${t}"]`); await P.waitForTimeout(150); }
    if (n < 6 || !st.look || st.lang || !st.data || !after) throw new Error(JSON.stringify({ n, ...st, after })); return `${n} Karten, Zustand bleibt nach Neuladen`;
  });
  await step('Einstellungen: Alle zuklappen / Alle aufklappen', async () => {
    await P.click('#partner-portal [data-pp-sfold-all]'); await P.waitForTimeout(200);
    const zu = await P.$$eval('#partner-portal .pp-sfold', (e) => e.every((c) => c.classList.contains('closed')));
    const label = await P.$eval('#partner-portal [data-pp-sfold-all]', (e) => e.textContent);
    await P.click('#partner-portal [data-pp-sfold-all]'); await P.waitForTimeout(200);
    const auf = await P.$$eval('#partner-portal .pp-sfold', (e) => e.every((c) => !c.classList.contains('closed')));
    if (!zu || !auf || label !== 'Alle aufklappen') throw new Error(`${zu}/${auf}/${label}`); return 'ok';
  });
  await step('Einstellungen: untere Leiste – Platz 2 auf „Mängel“, doppelte Wahl tauscht, Standard', async () => {
    await P.evaluate(() => { pp.view = 'settings'; pp.detail = null; ppRender(); }); await P.waitForTimeout(200);
    await P.selectOption('[data-pp-nav-slot="1"]', 'defects'); await P.waitForTimeout(200);
    const nav1 = await P.$$eval('.pp-nav button', (e) => e.map((b) => b.dataset.ppView).join(','));
    await P.selectOption('[data-pp-nav-slot="0"]', 'defects'); await P.waitForTimeout(200);
    const nav2 = await P.$$eval('.pp-nav button', (e) => e.map((b) => b.dataset.ppView).join(','));
    await P.click('.pp-nav [data-pp-view=defects]'); await P.waitForTimeout(200);
    const active = await P.$eval('.pp-nav button.active', (e) => e.dataset.ppView);
    await P.click('.pp-top [data-pp-action=top-back]'); await P.waitForTimeout(200); const back = await P.evaluate(() => pp.view);
    await P.evaluate(() => { pp.view = 'settings'; ppRender(); }); await P.click('[data-pp-nav-reset]'); await P.waitForTimeout(200);
    const nav3 = await P.$$eval('.pp-nav button', (e) => e.map((b) => b.dataset.ppView).join(','));
    if (nav1 !== 'dashboard,defects,calendar,messages,more' || nav2 !== 'defects,dashboard,calendar,messages,more' || active !== 'defects' || back !== 'dashboard' || nav3 !== 'dashboard,orders,calendar,messages,more') throw new Error([nav1, nav2, active, back, nav3].join(' | '));
    return 'Mängel unten, Tausch, aktiv, Zurück → Start, Standard';
  });
  await step('Unterseiten: kein Beta-Hinweis, nur auf der Startseite', async () => {
    await P.evaluate(() => { pp.view = 'orders'; pp.detail = null; ppRender(); }); await P.waitForTimeout(150);
    const onSub = await P.$('#partner-portal .beta-banner');
    await P.evaluate(() => { pp.view = 'dashboard'; ppRender(); }); await P.waitForTimeout(150);
    const onHome = await P.$('#partner-portal .beta-banner');
    const expected = await P.evaluate(() => Boolean(betaBannerHtml('partner')));
    if (onSub || Boolean(onHome) !== expected) throw new Error(`Unterseite ${Boolean(onSub)}, Start ${Boolean(onHome)}, erwartet ${expected}`); return expected ? 'nur Startseite' : 'Hinweis für dieses Konto aus, Unterseiten ohne';
  });
  await step('Nachrichten: eigene löschen (für beide), empfangene für sich ausblenden', async () => {
    const ORDER = sql(`select id from service_orders where organization_id='${POrg}' and title='Auftrag A ${N}'`);
    const ME = sql(`select pu.id from public.users pu join auth.users u on u.id=pu.auth_user_id where u.email='${P_EMAIL}'`);
    const OTHER = sql(`select pu.id from public.users pu join auth.users u on u.id=pu.auth_user_id where u.email='admin@husora.test'`);
    const M1 = sql(`insert into messages (organization_id, sender_user_id, service_order_id, message) values ('${POrg}', '${ME}', '${ORDER}', 'Meine Nachricht ${N}') returning id`).split('\n')[0];
    const M2 = sql(`insert into messages (organization_id, sender_user_id, service_order_id, message) values ('${POrg}', '${OTHER}', '${ORDER}', 'Fremde Nachricht ${N}') returning id`).split('\n')[0];
    await P.evaluate(async (id) => { await ppLoad(); pp.view = 'orders'; pp.detail = { type: 'order', id }; ppRender(); }, ORDER); await wait();
    const before = await P.$$eval('#partner-portal .pp-bubble', (e) => e.length);
    await P.click(`[data-pp-msg-del="${M1}"]`); await wait();
    const m1 = sql(`select count(*) from messages where id='${M1}'`);
    await P.click(`[data-pp-msg-del="${M2}"]`); await P.waitForTimeout(300);
    const m2 = sql(`select count(*) from messages where id='${M2}'`);
    await P.evaluate(async () => { await ppLoad(); ppRender(); }); await wait();
    const after = await P.$$eval('#partner-portal .pp-bubble', (e) => e.map((x) => x.textContent).join('|'));
    if (before !== 2 || m1 !== '0' || m2 !== '1' || after.includes('Nachricht ' + N)) throw new Error(JSON.stringify({ before, m1, m2, after: after.slice(0, 120) }));
    return 'eigene gelöscht, fremde nur ausgeblendet (bleibt nach Neuladen weg)';
  });
  console.log(res.join('\n')); if (errs.length) console.log('JS-Fehler:\n' + errs.join('\n'));
  await b.close();
})();
