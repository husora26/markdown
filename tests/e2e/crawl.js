const { chromium } = require('playwright'); const fs = require('fs');
const OUT = require('./env').SP + '/audit/crawl'; fs.mkdirSync(OUT, { recursive: true });
const PAGES = ['dashboard', 'properties', 'propertyDetail', 'tasks:list', 'tasks:partners', 'calendar', 'bookings:list', 'bookings:calendar', 'inspections', 'seasons', 'repairs', 'renovations', 'automation', 'costs', 'documents', 'assignedProviders', 'providers', 'partnerHub', 'house3d', 'emergency', 'contracts', 'meters', 'plans', 'profile', 'settings:settings-home', 'settings:settings-look', 'settings:settings-data', 'help', 'legal'];
(async () => {
  const b = await chromium.launch(); const report = [];
  for (const [vw, vh, label] of [[390, 844, 'handy'], [1366, 900, 'desktop']]) for (const theme of ['light', 'dark']) {
    const ctx = await b.newContext({ viewport: { width: vw, height: vh }, isMobile: vw < 500, hasTouch: vw < 500 }); const p = await ctx.newPage();
    const errs = []; p.on('pageerror', (e) => errs.push('pageerror: ' + e.message)); p.on('console', (m) => { if (m.type() === 'error' && !/ERR_|Failed to load resource|net::/.test(m.text())) errs.push('console: ' + m.text().slice(0, 160)); });
    await p.route(/unpkg|cdnjs|openstreetmap|nominatim|paypal|open-meteo|frankfurter|er-api|allorigins|cors\.lol|google|jsdelivr|tile/, (r) => r.abort());
    await p.goto('http://127.0.0.1:8081/index.html'); await p.evaluate((theme) => { localStorage.clear(); localStorage.setItem('stugliv-onboarding', '{"status":"done"}'); localStorage.setItem('stugliv-display', JSON.stringify({ theme })); }, theme); await p.reload(); await p.waitForTimeout(500);
    for (const entry of PAGES) {
      const [page, sub] = entry.split(':'); errs.length = 0;
      try {
        await p.evaluate(({ page, sub }) => { if (page === 'tasks') taskView = sub; if (page === 'bookings') bookingView = sub; if (page === 'settings') settingsView = sub; if (page === 'propertyDetail') sectionPropertyId = properties[0]?.id; currentPage = page; render(); window.scrollTo(0, 0); }, { page, sub });
        await p.waitForTimeout(350);
        const r = await p.evaluate(() => {
          const out = []; const W = innerWidth;
          if (document.documentElement.scrollWidth > W + 1) {
            const wide = [...document.querySelectorAll('body *')].filter((e) => { const r = e.getBoundingClientRect(); return r.width && r.right > W + 2 && getComputedStyle(e).position !== 'fixed'; }).slice(0, 3).map((e) => `${e.tagName.toLowerCase()}.${String(e.className).split(' ')[0]}(${Math.round(e.getBoundingClientRect().right)})`);
            out.push(`Überlauf ${document.documentElement.scrollWidth}>${W}: ${wide.join(', ')}`);
          }
          const big = [...document.querySelectorAll('#page-content svg, .topbar svg')].filter((s) => { const r = s.getBoundingClientRect(); return r.width > 90 && !s.closest('.house3d, .scene, .chart, .donut, [class*=chart], [class*=donut], .cost-ring, .stat-art, .map, [class*=map], .house-svg, .ring, .model, [class*=gauge], [class*=spark], [class*=house-model], .breadcrumb-home'); }).slice(0, 3).map((s) => `${s.parentElement.tagName.toLowerCase()}.${String(s.parentElement.className).split(' ')[0]}(${Math.round(s.getBoundingClientRect().width)}px)`);
          if (big.length) out.push('Riesen-Symbol: ' + big.join(', '));
          const broken = [...document.querySelectorAll('#page-content img')].filter((i) => i.complete && i.naturalWidth === 0 && i.src && !i.src.startsWith('data:,')).slice(0, 3).map((i) => i.src.slice(0, 60));
          if (broken.length) out.push('Bild fehlt: ' + broken.join(', '));
          const unlabeled = [...document.querySelectorAll('#page-content button, #page-content a')].filter((e) => { const r = e.getBoundingClientRect(); return r.width && !e.textContent.trim() && !e.getAttribute('aria-label') && !e.getAttribute('title'); }).slice(0, 3).map((e) => `${e.tagName.toLowerCase()}.${String(e.className).split(' ')[0]}`);
          if (unlabeled.length) out.push('ohne Beschriftung: ' + unlabeled.join(', '));
          const ids = {}; document.querySelectorAll('[id]').forEach((e) => { ids[e.id] = (ids[e.id] || 0) + 1; }); const dup = Object.entries(ids).filter(([, n]) => n > 1).map(([id]) => id);
          if (dup.length) out.push('doppelte IDs: ' + dup.slice(0, 5).join(', '));
          const tiny = [...document.querySelectorAll('#page-content button, #page-content a, #page-content input[type=checkbox]')].filter((e) => { const r = e.getBoundingClientRect(); return r.width && r.height && r.height < 24 && W < 500 && getComputedStyle(e).display !== 'inline'; }).length;
          if (tiny > 3) out.push(`${tiny} sehr kleine Tippziele (<24px)`);
          if (!document.querySelector('#page-content').textContent.trim()) out.push('LEERE SEITE');
          return out;
        });
        if (errs.length || r.length) report.push(`[${label}/${theme}] ${entry}: ${[...new Set(errs)].concat(r).join(' | ')}`);
        if (theme === 'dark' && label === 'handy' && ['dashboard', 'tasks:partners', 'costs', 'partnerHub', 'bookings:list'].includes(entry)) await p.screenshot({ path: `${OUT}/dark-${entry.replace(':', '-')}.png` });
      } catch (e) { report.push(`[${label}/${theme}] ${entry}: CRASH ${e.message.split('\n')[0]}`); }
    }
    await ctx.close();
  }
  console.log(report.join('\n') || 'keine Auffälligkeiten'); await b.close();
})();
