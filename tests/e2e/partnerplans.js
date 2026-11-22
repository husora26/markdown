// Servicepartner-Tarife: parallele Anlagen können das Limit nicht überschreiten (Akzeptanztest 6),
// „Mein Tarif“ mit Nutzung und Tarifvergleich, Limitmeldung mit Upgrade-Weg, gekennzeichnete Sperren,
// Zusatzmodul nur mit bestätigtem Preis, Startschalter aus = keine Sperren.
const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const { SP, ANON } = require('./env'); const OUT = SP + '/audit/partnerplans'; fs.mkdirSync(OUT, { recursive: true });
const URL_ = 'http://127.0.0.1:54321'; const N = Date.now() % 100000;
const FIRM = `Tarif Service ${N}`, P_EMAIL = `pplan${N}@hs.test`, PW = 'Husora!2026';
const sql = (q) => execSync(`psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -At -c "${q.replace(/"/g, '\\"')}"`).toString().trim();
const enforce = (on) => sql(`update app_config set value = '{"enforce": ${on}}' where key = 'partner_plans'`);
(async () => {
  const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (name, fn) => { try { const r = await fn(); res.push(`OK   ${name}${r ? ' – ' + r : ''}`); } catch (e) { res.push(`FEHL ${name} – ${e.message.split('\n')[0].slice(0, 240)}`); } };
  const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, deviceScaleFactor: 2 });
  const P = await ctx.newPage(); P.on('pageerror', (e) => errs.push(e.message)); P.on('dialog', (d) => d.accept());
  await P.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
  await P.goto('http://127.0.0.1:8081/index.html');
  await P.evaluate(({ url, key }) => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); localStorage.setItem('husora-cloud', JSON.stringify({ url, key })); }, { url: URL_, key: ANON });
  await P.reload(); await P.waitForTimeout(400);
  const wait = () => P.waitForFunction(() => !pp.busy, null, { timeout: 25000 }).then(() => P.waitForTimeout(300));
  const view = async (v) => { await P.evaluate((x) => { pp.view = x; pp.detail = null; pp.form = null; ppRender(); }, v); await P.waitForTimeout(200); };
  const reload = async () => { await P.evaluate(() => ppLoad()); await wait(); };
  // ganze Seite fotografieren: der Inhalt scrollt im Portal selbst, daher kurz ein hohes Fenster
  const shot = async (file) => { await P.setViewportSize({ width: 390, height: 2600 }); await P.waitForTimeout(250); await P.screenshot({ path: `${OUT}/${file}` }); await P.setViewportSize({ width: 390, height: 844 }); };
  try {
    await step('Partner: Betrieb anlegen', async () => {
      await P.evaluate(() => ppOpen('dashboard')); await P.waitForTimeout(200);
      await P.fill('[data-pp-form=login] [name=email]', P_EMAIL); await P.fill('[data-pp-form=login] [name=password]', PW);
      await P.$eval('[data-pp-action=signup]', (e) => e.click()); await P.waitForFunction(() => !pp.busy && document.querySelector('[data-pp-form=company]'), null, { timeout: 25000 });
      await P.fill('[data-pp-form=company] [name=name]', FIRM); await P.$eval('[data-pp-form=company] button[type=submit]', (e) => e.click()); await P.waitForFunction(() => !pp.busy && ppOrg(), null, { timeout: 25000 });
    });
    const ORG = sql(`select id from organizations where name='${FIRM}'`);
    enforce(true);

    await step('Akzeptanztest 6: 8 parallele Kunden-Anlagen über die API – genau 3 kommen durch (Free)', async () => {
      const token = await P.evaluate(() => cloud.session.access_token);
      const one = (i) => fetch(`${URL_}/rest/v1/customers`, { method: 'POST', headers: { apikey: ANON, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', Prefer: 'return=minimal' }, body: JSON.stringify({ organization_id: ORG, company_name: `Parallel ${i}` }) }).then((r) => r.status);
      const codes = await Promise.all(Array.from({ length: 8 }, (_, i) => one(i)));
      const ok = codes.filter((c) => c === 201).length; const rows = Number(sql(`select count(*) from customers where organization_id='${ORG}'`));
      if (ok !== 3 || rows !== 3) throw new Error(`angenommen ${ok}, in der Datenbank ${rows}, Status ${codes.join(',')}`);
      return `Status ${codes.join(',')}`;
    });

    await step('Mehr: „Mein Tarif“ mit Kunden-Zähler, Sperren gekennzeichnet', async () => {
      await reload(); await view('more');
      const r = await P.evaluate(() => ({
        plan: document.querySelector('#partner-portal [data-pp-view=plan] small')?.textContent,
        team: document.querySelector('#partner-portal [data-pp-view=team] .pp-lock')?.textContent,
        finance: document.querySelector('#partner-portal [data-pp-view=finance] .pp-lock')?.textContent,
        customers: document.querySelector('#partner-portal [data-pp-view=customers] .pp-lock')
      }));
      if (r.plan !== 'Free · 3/3 Kunden' || r.team !== 'ab Pro' || r.finance !== 'ab Plus' || r.customers) throw new Error(JSON.stringify(r));
      await shot('mehr-gesperrt.png');
      return `${r.plan}, Mitarbeiter ${r.team}, Finanzen ${r.finance}`;
    });

    await step('Gesperrter Bereich zeigt Erklärung und den passenden Tarif', async () => {
      await view('team');
      const t = await P.$eval('#partner-portal .pp-locked', (e) => e.textContent);
      if (!/Mitarbeiterverwaltung/.test(t) || !/ab Pro \(29,90 € netto\/Monat\)/.test(t)) throw new Error(t.slice(0, 200));
      await P.$eval('#partner-portal .pp-locked [data-pp-view=plan]', (e) => e.click()); await P.waitForTimeout(200);
      if (await P.evaluate(() => pp.view) !== 'plan') throw new Error('nicht zur Tarifseite');
      return 'Erklärung + „Tarife vergleichen“';
    });

    await step('Mein Tarif: Free, 3/3 Kunden rot, vier Tarife, keine Provision', async () => {
      const r = await P.evaluate(() => ({
        name: document.querySelector('#partner-portal .pp-plan-now h2')?.textContent,
        cust: document.querySelector('#partner-portal [data-pp-usage=customers]')?.className,
        custText: document.querySelector('#partner-portal [data-pp-usage=customers] b')?.textContent,
        plans: [...document.querySelectorAll('#partner-portal .pp-plan h3')].map((h) => h.textContent).join(','),
        prices: [...document.querySelectorAll('#partner-portal .pp-plan-price')].map((h) => h.textContent).join(' | '),
        noFee: /Keine Vermittlungsprovision/.test(document.querySelector('#partner-portal .pp-main').textContent),
        beta: /noch nicht aktiv/.test(document.querySelector('#partner-portal .pp-main').textContent)
      }));
      if (r.name !== 'Free' || !/red/.test(r.cust) || r.custText !== '3 / 3' || r.plans !== 'Free,Plus,Pro,Ultra' || !r.noFee || r.beta) throw new Error(JSON.stringify(r));
      await shot('mein-tarif-free.png');
      return r.prices;
    });

    await step('4. Kunde im Formular: verständliche Meldung mit „Tarife ansehen“', async () => {
      await view('customers');
      const hint = await P.$eval('#partner-portal .pp-usage-hint', (e) => e.textContent);
      await P.evaluate(() => { pp.form = 'new-customer'; ppRender(); }); await P.waitForTimeout(150);
      await P.fill('[data-pp-form=customer] [name=last_name]', 'Vierte'); await P.$eval('[data-pp-form=customer] button[type=submit]', (e) => e.click()); await wait();
      const msg = await P.$eval('#partner-portal .pp-msg.error[role=alert]', (e) => e.textContent);
      const btn = await P.$('#partner-portal .pp-msg.error [data-pp-view=plan]');
      if (!/Kundenlimit von 3 Kunden im Free-Tarif erreicht\. Wechsle zu Plus, um bis zu 20 Kunden zu verwalten\./.test(msg) || !btn || !/3 von 3 Kunden/.test(hint)) throw new Error(`${msg} | ${hint}`);
      await P.screenshot({ path: `${OUT}/kundenlimit-meldung.png` });
      if (Number(sql(`select count(*) from customers where organization_id='${ORG}'`)) !== 3) throw new Error('trotzdem angelegt');
      return msg.trim().slice(0, 110);
    });

    await step('Upgrade-Auswahl: Vorschau und (Beta) Wechsel per E-Mail', async () => {
      await view('plan');
      await P.$eval('#partner-portal [data-pp-action=plan-pick][data-plan=partner_plus]', (e) => e.click());
      await P.waitForFunction(() => pp.planPreview, null, { timeout: 10000 }); await P.waitForTimeout(200);
      const t = await P.$eval('#partner-portal [data-pp-plan-confirm]', (e) => e.textContent);
      const mail = await P.$eval('#partner-portal [data-pp-plan-confirm] a.primary-btn', (e) => e.getAttribute('href'));
      if (!/Upgrade auf Plus/.test(t) || !/Alle deine Daten passen/.test(t) || !/^mailto:/.test(mail) || !/Plus/.test(decodeURIComponent(mail))) throw new Error(t.slice(0, 200));
      return 'Vorschau ohne Überschreitung, E-Mail-Anfrage';
    });

    await step('Zusatzmodul: erst mit bestätigtem Preis, dann „Angefragt“, Limit unverändert', async () => {
      await P.$eval('#partner-portal [data-pp-action=addon-pick][data-code=extra_user]', (e) => e.click()); await P.waitForTimeout(150);
      await P.$eval('#partner-portal [data-pp-action=addon-request]', (e) => e.click()); await P.waitForTimeout(200);
      if (sql(`select count(*) from partner_addons where organization_id='${ORG}'`) !== '0') throw new Error('ohne Bestätigung angelegt');
      await P.check('#partner-portal [data-pp-addon-ok]');
      await P.$eval('#partner-portal [data-pp-action=addon-request]', (e) => e.click()); await wait();
      const row = sql(`select status || ':' || price_monthly_cents_confirmed from partner_addons where organization_id='${ORG}'`);
      const badge = await P.evaluate(() => [...document.querySelectorAll('#partner-portal .pp-addon')].find((e) => /Weiterer Benutzer/.test(e.textContent))?.querySelector('.pp-badge')?.textContent);
      const users = await P.evaluate(() => pp.data.ent.limits.users);
      if (row !== 'requested:390' || badge !== 'Angefragt' || users !== 1) throw new Error(`${row} ${badge} ${users}`);
      return '3,90 € bestätigt, wartet auf Freigabe';
    });

    await step('Tarif Pro (vom Husora-Team gesetzt): Sperren weg, 3/100 Kunden', async () => {
      sql(`insert into partner_subscriptions (organization_id, plan_id, status, billing_provider, current_period_end) values ('${ORG}', 'partner_pro', 'active', 'manual', now() + interval '30 days')`);
      await reload(); await view('more');
      const r = await P.evaluate(() => ({ locks: document.querySelectorAll('#partner-portal .pp-lock').length, plan: document.querySelector('#partner-portal [data-pp-view=plan] small')?.textContent }));
      await view('team'); const locked = await P.$('#partner-portal .pp-locked');
      if (r.locks !== 0 || r.plan !== 'Pro · 3/100 Kunden' || locked) throw new Error(JSON.stringify(r));
      await view('plan'); await shot('mein-tarif-pro.png');
      return r.plan;
    });

    await step('Startschalter aus: keine Sperren, Hinweis „noch nicht aktiv“', async () => {
      sql(`delete from partner_subscriptions where organization_id='${ORG}'`); enforce(false);
      await reload(); await view('team');
      const locked = await P.$('#partner-portal .pp-locked');
      await view('plan'); const beta = await P.evaluate(() => /noch nicht aktiv/.test(document.querySelector('#partner-portal .pp-main').textContent));
      if (locked || !beta) throw new Error(`gesperrt ${Boolean(locked)}, Hinweis ${beta}`);
      return 'Free ohne Sperren';
    });
  } finally {
    enforce(false);
  }
  if (errs.length) res.push(...errs.map((e) => `JS-Fehler: ${e}`));
  console.log(res.join('\n')); await b.close();
})();
