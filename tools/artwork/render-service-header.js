// Rendert die Titelleiste der Servicepartner-App (service-header.html) nach assets/pp/header-illustration.jpg (Alternative; aktiv ist das Foto header-service.jpg)
// Aufruf: node tools/artwork/render-service-header.js   (benötigt Playwright)
const path = require('path');
const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1600, height: 360 }, deviceScaleFactor: 1 });
  await p.goto('file://' + path.join(__dirname, 'service-header.html'));
  await p.waitForTimeout(300);
  await p.locator('#owner-header').screenshot({ path: path.join(__dirname, '..', '..', 'assets', 'pp', 'header-illustration.jpg'), type: 'jpeg', quality: 86 });
  await b.close();
})();
