// Rendert die Illustrationen des Partner-Portals (partner-illustrations.html) nach assets/pp/*.jpg
// Aufruf: node tools/artwork/render.js   (benötigt Playwright)
const path = require('path');
const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1700, height: 900 }, deviceScaleFactor: 1 });
  await p.goto('file://' + path.join(__dirname, 'partner-illustrations.html'));
  await p.waitForTimeout(300);
  for (const id of ['orders', 'inspections', 'defects', 'finance', 'calendar', 'customers', 'messages', 'agreements', 'documents', 'header']) {
    await p.locator('#' + id).screenshot({ path: path.join(__dirname, '..', '..', 'assets', 'pp', `${id}.jpg`), type: 'jpeg', quality: 84 });
  }
  await b.close();
})();
