// Onboarding homeowner_v1 (kurz): Erststart → Rolle/Tarif → Haus mit Adresse → Pflegepaket/erste Aufgabe → Abschluss,
// Überspringen, „Später fortsetzen“, Fortsetzen nach Neuladen, Checkliste aus echten Daten, keine Duplikate, Neustart
const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch(); const res = []; const errs = [];
  const step = async (name, fn) => { try { const r = await fn(); res.push(`OK   ${name}${r ? ' – ' + r : ''}`); } catch (e) { res.push(`FEHL ${name} – ${e.message.split('\n')[0].slice(0, 220)}`); } };
  const p = await b.newPage({ viewport: { width: 390, height: 844 } }); p.on('pageerror', (e) => errs.push(e.message));
  await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
  await p.goto('http://127.0.0.1:8081/index.html');
  await p.evaluate(() => localStorage.clear());
  await p.reload(); await p.waitForTimeout(700);
  const cur = () => p.evaluate(() => OB_FLOWS.homeowner.steps[onboardingStep].key);
  const st = () => p.evaluate(() => obState('homeowner'));

  await step('Erststart öffnet die Einrichtung mit Rollenwahl', async () => {
    await p.waitForSelector('#onboarding-modal.open', { timeout: 4000 });
    const t = await p.textContent('#onboarding-body'); if (!/Willkommen bei Husora/.test(t) || !/Schritt 1 von 4/.test(t)) throw new Error(t.slice(0, 120));
    return 'Schritt 1 von 4';
  });
  await step('Hausbesitzer wählen → Tarifwahl mit FREE, PLUS, PRO, ULTIMATE', async () => {
    await p.click('[data-ob-role=owner]'); await p.waitForTimeout(200);
    const r = await p.evaluate(() => ({ plans: [...document.querySelectorAll('[data-ob-plan]')].map((b) => b.dataset.obPlan).join(','), on: document.querySelector('.ob-plan.on')?.dataset.obPlan, t: document.getElementById('onboarding-title')?.textContent, k: OB_FLOWS.homeowner.steps[onboardingStep].key }));
    if (r.plans !== 'free,plus,pro,ultimate' || r.on !== 'free' || r.k !== 'welcome' || !/Tarif/.test(r.t)) throw new Error(JSON.stringify(r)); return r.plans;
  });
  await step('Tarif wählen (PLUS ansehen, mit FREE weiter) → Schritt „Erstes Haus“', async () => {
    await p.click('[data-ob-plan=plus]'); await p.waitForTimeout(100);
    const btn = await p.textContent('[data-ob-plan-next]'); if (!/PLUS/.test(btn)) throw new Error(btn);
    await p.click('[data-ob-plan=free]'); await p.waitForTimeout(100);
    await p.click('[data-ob-plan-next]'); await p.waitForTimeout(250);
    const k = await cur(); const s = await st(); const plan = await p.evaluate(() => currentPlanId());
    if (k !== 'property' || s.steps.welcome !== 'completed' || plan !== 'free') throw new Error(`${k}/${plan}/${JSON.stringify(s.steps)}`); return `${k}, ${plan}`;
  });
  await step('Pflichtfeld wird geprüft (Fehlermeldung statt Speichern)', async () => {
    await p.click('[data-ob-house-save]'); await p.waitForTimeout(150);
    const msg = await p.$eval('.ob-error', (e) => !e.hidden && e.textContent); if (!msg) throw new Error('kein Hinweis'); return msg;
  });
  await step('Haus speichern ersetzt das Demo-Haus (keine Demo-Daten, kein Duplikat)', async () => {
    await p.fill('[data-ob-form=property] [name=house]', 'Stuga am Fryken');
    await p.fill('[data-ob-form=property] [name=address]', 'Sjövägen 4, Sunne');
    await p.selectOption('[data-ob-form=property] [name=region]', { index: 1 });
    await p.click('[data-ob-house-save]'); await p.waitForTimeout(300);
    const r = await p.evaluate(() => ({ n: properties.length, name: properties[0].name, demoTasks: tasks.filter((t) => initialTasks.some((d) => d.id === t.id && d.title === t.title)).length, ref: obState('homeowner').propertyRef, step: OB_FLOWS.homeowner.steps[onboardingStep].key }));
    if (r.n !== 1 || r.name !== 'Stuga am Fryken' || r.demoTasks || r.step !== 'task' || !r.ref) throw new Error(JSON.stringify(r)); return `${r.name}, weiter zu ${r.step}`;
  });
  await step('Zurück zeigt das Haus als erledigt, kein zweites Haus', async () => {
    await p.click('[data-ob-prev]'); await p.waitForTimeout(150);
    const t = await p.textContent('#onboarding-body'); await p.click('[data-ob-house-use]'); await p.waitForTimeout(150);
    const n = await p.evaluate(() => properties.length); if (!/Bereits erledigt/.test(t) || n !== 1 || (await cur()) !== 'task') throw new Error(`${n}`); return 'ok';
  });
  await step('„Später fortsetzen“ schließt und merkt den Schritt', async () => {
    await p.click('[data-ob-pause]'); await p.waitForTimeout(250);
    const s = await st(); const open = await p.$eval('#onboarding-modal', (e) => e.classList.contains('open'));
    if (open || !s.paused || s.current !== 'task') throw new Error(JSON.stringify(s)); return s.current;
  });
  await step('Dashboard-Checkliste aus echten Daten (2 von 3)', async () => {
    const t = await p.textContent('.ob-checklist'); if (!/2 von 3 wichtigen/.test(t)) throw new Error(t.slice(0, 160)); return '2 von 3';
  });
  await step('Bildkacheln bleiben oben sichtbar, Checkliste kompakt darunter', async () => {
    const r = await p.evaluate(() => { const tile = document.querySelector('#page-content .stat'); const list = document.querySelector('.ob-checklist'); return { tileTop: Math.round(tile.getBoundingClientRect().top), art: tile.querySelector('.stat-art')?.naturalWidth || 0, below: Boolean(tile.compareDocumentPosition(list) & Node.DOCUMENT_POSITION_FOLLOWING), open: list.open, h: Math.round(list.getBoundingClientRect().height) }; });
    if (r.tileTop > 400 || !r.art || !r.below || r.open || r.h > 90) throw new Error(JSON.stringify(r)); return `erste Kachel bei ${r.tileTop}px, Checkliste ${r.h}px hoch`;
  });
  await step('Pausiert: nach Neuladen kein automatisches Öffnen', async () => {
    await p.reload(); await p.waitForTimeout(700);
    if (await p.$eval('#onboarding-modal', (e) => e.classList.contains('open'))) throw new Error('offen'); return 'bleibt zu';
  });
  await step('Fortsetzen über die Checkliste → Aufgabe mit Vorlage erstellen', async () => {
    await p.click('.ob-checklist [data-ob-resume]'); await p.waitForTimeout(200);
    if ((await cur()) !== 'task') throw new Error(await cur());
    const pk = await p.evaluate(() => ({ n: document.querySelectorAll('[data-ob-pkg]').length, mode: document.querySelectorAll('[data-ob-task-mode]').length })); // FREE: keine Aufgabenpakete, direkt einzelne Aufgabe
    if (pk.n || pk.mode) throw new Error(`Pakete in FREE sichtbar ${JSON.stringify(pk)}`);
    await p.click('[data-ob-template="Rauchmelder prüfen"]');
    await p.selectOption('[data-ob-form=task] [name=priority]', 'soon');
    await p.click('[data-ob-task-save]'); await p.waitForTimeout(250);
    const r = await p.evaluate(() => ({ n: obUserTasks().length, t: obUserTasks()[0]?.title, s: obState('homeowner').steps.task, prop: obUserTasks()[0]?.property, prio: obUserTasks()[0]?.priority }));
    if (r.n !== 1 || r.t !== 'Rauchmelder prüfen' || r.s !== 'completed' || r.prop !== 'Stuga am Fryken' || r.prio !== 'soon' || (await cur()) !== 'done') throw new Error(JSON.stringify(r)); return `${r.t} (Wichtig)`;
  });
  await step('Nicht pausiert: Neuladen setzt am aktuellen Schritt fort', async () => {
    await p.reload(); await p.waitForTimeout(800);
    const open = await p.$eval('#onboarding-modal', (e) => e.classList.contains('open')); if (!open || (await cur()) !== 'done') throw new Error(`${open}/${await cur()}`); return 'done';
  });
  await step('Abschluss: Schritt 4 von 4, 3 von 3 wichtigen, Hausprofil & Co. nur noch optional', async () => {
    const t = await p.textContent('#onboarding-body');
    if (!/Schritt 4 von 4/.test(t) || !/3 von 3/.test(t) || !/Hausprofil ergänzt \(optional\)/.test(t) || !(await p.$('#onboarding-body [data-ob-check-page=propertyDetail]'))) throw new Error(t.slice(0, 300)); return 'Schritt 4 von 4';
  });
  await step('Abschluss → Übersicht, Status abgeschlossen, Checkliste bleibt für offene Punkte', async () => {
    await p.click('[data-ob-close]'); await p.waitForTimeout(300);
    const r = await p.evaluate(() => ({ s: obState('homeowner').status, page: currentPage, list: Boolean(document.querySelector('.ob-checklist')), old: JSON.parse(localStorage.getItem('stugliv-onboarding')).status }));
    if (r.s !== 'completed' || r.page !== 'dashboard' || !r.list || r.old !== 'done') throw new Error(JSON.stringify(r)); return 'completed';
  });
  await step('Abgeschlossen: nach Neuladen kein Einrichtungsfenster', async () => {
    await p.reload(); await p.waitForTimeout(700);
    if (await p.$eval('#onboarding-modal', (e) => e.classList.contains('open'))) throw new Error('offen'); return 'ok';
  });
  await step('Checkliste: „Hausprofil ergänzt“ öffnet die Hausseite', async () => {
    await p.click('.ob-checklist > summary .ob-check-sum-text'); await p.waitForTimeout(150);
    await p.click('.ob-checklist [data-ob-check-page=propertyDetail]'); await p.waitForTimeout(250);
    const r = await p.evaluate(() => ({ page: currentPage, house: sectionPropertyId === obPrimaryHouse()?.id }));
    await p.evaluate(() => { obChecklistOpen = false; currentPage = 'dashboard'; render(); }); await p.waitForTimeout(150);
    if (r.page !== 'propertyDetail' || !r.house) throw new Error(JSON.stringify(r)); return 'Hausseite des ersten Hauses';
  });
  await step('Checkliste ausblenden bleibt ausgeblendet', async () => {
    await p.click('.ob-checklist > summary .ob-check-sum-text'); await p.waitForTimeout(150);
    await p.click('.ob-checklist [data-ob-dismiss]'); await p.waitForTimeout(200);
    await p.reload(); await p.waitForTimeout(600);
    if (await p.$('.ob-checklist')) throw new Error('sichtbar'); return 'ok';
  });
  await step('Neustart über Hilfe: Schritte zurückgesetzt, Haus/Aufgabe bleiben', async () => {
    await p.evaluate(() => openOnboarding(0)); await p.waitForTimeout(200);
    const r = await p.evaluate(() => ({ s: obState('homeowner'), n: properties.length, t: obUserTasks().length }));
    if (r.s.status !== 'in_progress' || Object.keys(r.s.steps).length || r.n !== 1 || r.t !== 1) throw new Error(JSON.stringify(r)); return 'neu gestartet';
  });
  await step('Ausführliches Formular: angelegte Aufgabe wird erkannt', async () => {
    await p.evaluate(() => obGo('task')); await p.waitForTimeout(100);
    await p.click('[data-ob-task-form]'); await p.waitForTimeout(250);
    await p.fill('#task-form [name=title]', 'Heizung warten'); await p.click('#task-form [type=submit]'); await p.waitForTimeout(700);
    const r = await p.evaluate(() => ({ s: obState('homeowner').steps.task, open: document.getElementById('onboarding-modal').classList.contains('open'), k: OB_FLOWS.homeowner.steps[onboardingStep].key }));
    if (r.s !== 'completed' || !r.open || r.k !== 'done') throw new Error(JSON.stringify(r)); return 'weiter zum Abschluss';
  });
  await step('Feature-Guide: „Was kann ich hier tun?“ öffnen und dauerhaft ausblenden', async () => {
    await p.evaluate(() => { closeOnboarding(); currentPage = 'tasks'; render(); }); await p.waitForTimeout(200);
    await p.click('[data-ob-guide=open]'); await p.waitForTimeout(150);
    const txt = await p.textContent('.ob-guide');
    await p.click('[data-ob-guide=hide]'); await p.waitForTimeout(150);
    await p.reload(); await p.waitForTimeout(700); await p.evaluate(() => { closeOnboarding(); currentPage = 'tasks'; render(); }); await p.waitForTimeout(200);
    const still = await p.$('.ob-guide-pill'); await p.evaluate(() => { currentPage = 'inspections'; render(); }); await p.waitForTimeout(150);
    const other = await p.$('.ob-guide-pill');
    if (!/Wiederholung/.test(txt) || still || !other) throw new Error(`${Boolean(still)}/${Boolean(other)}`); return 'Aufgaben aus, Kontrolle weiter da';
  });
  await step('Hilfe-Tipps über die Hilfe-Seite abschalten', async () => {
    await p.evaluate(() => { currentPage = 'help'; render(); }); await p.waitForTimeout(150);
    await p.click('[data-ob-tips]'); await p.waitForTimeout(150);
    await p.evaluate(() => { currentPage = 'inspections'; render(); }); await p.waitForTimeout(150);
    const pill = await p.$('.ob-guide-pill'); if (pill) throw new Error('noch sichtbar'); return 'aus';
  });
  await step('Einstellungen: Karte „Einrichtung & Hilfe“ holt Hilfen zurück und startet die Einrichtung', async () => {
    await p.evaluate(() => { currentPage = 'settings'; settingsView = 'settings-data'; render(); }); await p.waitForTimeout(250);
    const cap = await p.textContent('#settings-onboarding .card-caption');
    await p.click('#settings-onboarding [data-ob-tips]'); await p.waitForTimeout(150);
    await p.click('#settings-onboarding [data-ob-guides-reset]'); await p.waitForTimeout(150);
    const prefs = await p.evaluate(() => obPrefs());
    await p.evaluate(() => { currentPage = 'tasks'; render(); }); await p.waitForTimeout(150);
    const pill = await p.$('.ob-guide-pill');
    await p.evaluate(() => { currentPage = 'settings'; settingsView = 'settings-data'; render(); }); await p.waitForTimeout(200);
    await p.click('#settings-onboarding [data-onboarding-start]'); await p.waitForTimeout(250);
    const open = await p.$eval('#onboarding-modal', (e) => e.classList.contains('open'));
    if (!pill || (prefs.dismissed_guides || []).length || prefs.help_tips_enabled === false || !open) throw new Error(`${cap} ${JSON.stringify(prefs)} ${Boolean(pill)} ${open}`);
    await p.evaluate(() => closeOnboarding()); return cap.trim();
  });
  await step('Guide „Meine Häuser“ mit Link zur Hilfe', async () => {
    await p.evaluate(() => { currentPage = 'properties'; render(); }); await p.waitForTimeout(150);
    await p.click('[data-ob-guide=open]'); await p.waitForTimeout(150);
    await p.click('.ob-guide [data-page=help]'); await p.waitForTimeout(200);
    const page = await p.evaluate(() => currentPage); if (page !== 'help') throw new Error(page); return 'Hilfe geöffnet';
  });
  await step('Demo-Weg: „Erst umsehen“ öffnet nicht erneut', async () => {
    const q = await b.newPage({ viewport: { width: 1280, height: 900 } }); q.on('pageerror', (e) => errs.push(e.message));
    await q.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
    await q.goto('http://127.0.0.1:8081/index.html'); await q.evaluate(() => localStorage.clear()); await q.reload(); await q.waitForTimeout(700);
    const demo = await q.$('[data-ob-demo]');
    if (!demo) { await q.close(); return 'Beta-Build ohne Demo-Knopf'; }
    await demo.click(); await q.waitForTimeout(200); await q.reload(); await q.waitForTimeout(700);
    const open = await q.$eval('#onboarding-modal', (e) => e.classList.contains('open')); const banner = await q.$('.demo-banner');
    await q.close(); if (open || !banner) throw new Error(`${open}/${Boolean(banner)}`); return 'Demo-Hinweis statt Fenster';
  });
  await step('Bestandsnutzer ohne Einrichtungsstand: kein Fenster', async () => {
    const q = await b.newPage(); q.on('pageerror', (e) => errs.push(e.message));
    await q.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
    await q.goto('http://127.0.0.1:8081/index.html'); await q.evaluate(() => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); }); await q.reload(); await q.waitForTimeout(700);
    const open = await q.$eval('#onboarding-modal', (e) => e.classList.contains('open')); const list = await q.$('.ob-checklist');
    await q.close(); if (open || list) throw new Error(`${open}/${Boolean(list)}`); return 'ok';
  });
  await step('Aufgabenpaket: in FREE ausgeblendet, mit PLUS „Paket übernehmen“ legt Aufgaben an', async () => {
    const q = await b.newPage({ viewport: { width: 390, height: 844 } }); q.on('pageerror', (e) => errs.push(e.message));
    await q.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr/, (r) => r.abort());
    await q.goto('http://127.0.0.1:8081/index.html'); await q.evaluate(() => localStorage.clear()); await q.reload(); await q.waitForSelector('#onboarding-modal.open', { timeout: 4000 });
    await q.click('[data-ob-role=owner]'); await q.waitForTimeout(150); await q.click('[data-ob-plan-next]'); await q.waitForTimeout(200);
    await q.fill('[data-ob-form=property] [name=house]', 'Paket-Stuga'); await q.click('[data-ob-house-save]'); await q.waitForTimeout(250);
    await q.evaluate(() => obGo('task')); await q.waitForTimeout(150);
    const free = await q.evaluate(() => ({ plan: currentPlanId(), pkgs: document.querySelectorAll('[data-ob-pkg]').length, single: Boolean(document.querySelector('[data-ob-form=task]')) }));
    if (free.plan !== 'free' || free.pkgs || !free.single) throw new Error(`FREE ${JSON.stringify(free)}`);
    await q.evaluate(() => { obDraft = { phase: 'plan', back: 'task' }; obGo('welcome'); }); await q.waitForTimeout(150); await q.click('[data-ob-plan=plus]'); await q.click('[data-ob-plan-next]'); await q.waitForTimeout(250);
    const back = await q.evaluate(() => ({ k: OB_FLOWS.homeowner.steps[onboardingStep].key, plan: currentPlanId() }));
    if (back.k !== 'task' || back.plan !== 'plus') throw new Error(`zurück: ${JSON.stringify(back)}`);
    await q.click('[data-ob-pkg=basis]'); await q.waitForTimeout(100);
    await q.click('[data-ob-pkg-apply=basis]'); await q.waitForTimeout(300);
    const r = await q.evaluate(() => ({ pkg: autoTasks.packageId, on: autoTasks.enabled, n: obUserTasks().length, s: obState('homeowner').steps.task, k: OB_FLOWS.homeowner.steps[onboardingStep].key }));
    await q.close();
    if (r.pkg !== 'basis' || !r.on || !r.n || r.s !== 'completed' || r.k !== 'done') throw new Error(JSON.stringify(r)); return `Paket Basis, ${r.n} Aufgaben angelegt`;
  });
  console.log(res.join('\n')); if (errs.length) console.log('JS-Fehler:\n' + errs.join('\n'));
  await b.close();
})();
