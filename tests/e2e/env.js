// Gemeinsame Einstellungen der Browser-Tests (lokaler Supabase-Stack + App auf Port 8081)
const path = require('path');
const fs = require('fs');
const { execSync } = require('child_process');

// Ausgabeordner für Screenshots (nicht im Git)
const SP = process.env.HUSORA_E2E_OUT || path.join(__dirname, 'output');
fs.mkdirSync(path.join(SP, 'audit'), { recursive: true });

// Öffentlicher anon-Schlüssel des lokalen Stacks: aus der Umgebung oder über `supabase status`
let ANON = process.env.SUPABASE_ANON_KEY || '';
// service_role nur für Tests, die Daten direkt prüfen (lokaler Stack, nie Produktion)
let SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY || '';
// `supabase status` scheitert direkt nach dem Start gelegentlich – bis zu dreimal versuchen
for (let attempt = 0; attempt < 3 && (!ANON || !SERVICE); attempt += 1) {
  try {
    const env = execSync('npx -y supabase@2 status -o env', { cwd: path.join(__dirname, '..', '..'), stdio: ['ignore', 'pipe', 'ignore'], timeout: 60000 }).toString();
    ANON = ANON || (env.match(/^ANON_KEY="?([^"\n]+)"?/m) || [])[1] || '';
    SERVICE = SERVICE || (env.match(/^SERVICE_ROLE_KEY="?([^"\n]+)"?/m) || [])[1] || '';
  } catch (error) { execSync('sleep 3'); }
}
if (!ANON) throw new Error('Kein anon-Schlüssel – lokalen Supabase-Stack starten oder SUPABASE_ANON_KEY setzen.');

module.exports = { SP, ANON, SERVICE };
