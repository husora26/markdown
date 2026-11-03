#!/usr/bin/env node
// Husora · App-Build für eine Umgebung (beta | production | development)
// Erzeugt www/ (Inhalt der nativen Android-/iOS-App bzw. eines eigenen Web-Deploys):
//   - index.html mit eingebetteter Laufzeit-Konfiguration (window.HUSORA_RUNTIME)
//   - assets/, (nur Web) sw.js
// Prüft vorher: Pflichtvariablen, keine Geheimnisse, Supabase-Projekt passt zur Umgebung,
// Beta-Build nie mit der Production-URL (und umgekehrt), Version aus version.json.
//   node tools/build-app.mjs --env beta [--target native|web] [--out www]
import { readFileSync, writeFileSync, mkdirSync, rmSync, cpSync, existsSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = Object.fromEntries(process.argv.slice(2).reduce((acc, cur, i, all) => (cur.startsWith('--') ? [...acc, [cur.slice(2), all[i + 1] && !all[i + 1].startsWith('--') ? all[i + 1] : 'true']] : acc), []));
const envName = args.env;
const target = args.target || 'native';
const outDir = resolve(root, args.out || 'www');
const fail = (msg) => { console.error(`\n✖ Build abgebrochen: ${msg}\n`); process.exit(1); };

const cfg = JSON.parse(readFileSync(join(root, 'config/environments.json'), 'utf8'));
if (!cfg.environments[envName]) fail(`--env muss eine von ${Object.keys(cfg.environments).join(', ')} sein`);
if (!['native', 'web'].includes(target)) fail('--target muss native oder web sein');
const envCfg = cfg.environments[envName];

// .env.<umgebung> laden (einfacher Parser); Prozess-Variablen (CI-Secrets) haben Vorrang
function loadDotenv(file) {
  if (!existsSync(file)) return {};
  return Object.fromEntries(readFileSync(file, 'utf8').split(/\r?\n/)
    .map((line) => line.trim()).filter((line) => line && !line.startsWith('#') && line.includes('='))
    .map((line) => { const i = line.indexOf('='); return [line.slice(0, i).trim(), line.slice(i + 1).trim().replace(/^["']|["']$/g, '')]; }));
}
const fileVars = loadDotenv(join(root, `.env.${envName}`));
const v = (name, ...aliases) => [name, ...aliases].map((n) => process.env[n] || fileVars[n]).find((x) => x && String(x).trim()) || '';

const appEnv = v('APP_ENV') || envName;
if (appEnv !== envName) fail(`APP_ENV=${appEnv} passt nicht zu --env ${envName}`);
const url = v('HUSORA_PUBLIC_SUPABASE_URL', 'EXPO_PUBLIC_SUPABASE_URL').replace(/\/+$/, '');
const key = v('HUSORA_PUBLIC_SUPABASE_ANON_KEY', 'EXPO_PUBLIC_SUPABASE_ANON_KEY');
const apiBase = (v('API_BASE_URL') || url).replace(/\/+$/, '');
if (!url) fail(`HUSORA_PUBLIC_SUPABASE_URL fehlt (in .env.${envName} oder als Umgebungsvariable)`);
if (!key) fail(`HUSORA_PUBLIC_SUPABASE_ANON_KEY fehlt (in .env.${envName} oder als Umgebungsvariable)`);

// URL-Prüfung
let parsed;
try { parsed = new URL(url); } catch { fail(`Ungültige Supabase-URL: ${url}`); }
const localHost = /^(localhost|127\.0\.0\.1|10\.0\.2\.2)$/.test(parsed.hostname);
if (parsed.protocol !== 'https:' && !(envCfg.allowHttp && localHost)) fail(`Supabase-URL muss https verwenden (${url})`);

// Kein Geheimnis im Client
const jwtRole = (token) => { try { return JSON.parse(Buffer.from(String(token).split('.')[1], 'base64url').toString()).role || ''; } catch { return ''; } };
if (/^sb_secret_/.test(key) || jwtRole(key) === 'service_role') fail('Der Schlüssel ist der geheime service_role/secret-Schlüssel – in die App gehört nur der publishable/anon-Schlüssel.');
if (!/^sb_publishable_/.test(key) && jwtRole(key) !== 'anon') fail('Der Schlüssel ist weder sb_publishable_… noch ein anon-JWT.');
for (const [name, value] of Object.entries({ ...fileVars, ...Object.fromEntries(Object.entries(process.env).filter(([n]) => /^(HUSORA_|EXPO_PUBLIC_|API_BASE_URL|APP_)/.test(n))) })) {
  if (/^(EXPO_PUBLIC_|HUSORA_PUBLIC_)/.test(name) && (/^sb_secret_/.test(value) || jwtRole(value) === 'service_role' || /^sk_(live|test)_|^whsec_|^sk-ant-|^re_[A-Za-z0-9]{20,}/.test(value))) {
    fail(`${name} enthält ein Geheimnis – öffentliche Variablen dürfen keine Secrets enthalten.`);
  }
}

// Umgebungs-Trennung: Projekt-Referenzen und Gegen-URL
const ref = /^([a-z0-9]{20})\.supabase\.co$/.exec(parsed.hostname)?.[1] || '';
for (const [other, oc] of Object.entries(cfg.environments)) {
  if (other !== envName && ref && (oc.projectRefs || []).includes(ref)) fail(`Supabase-Projekt ${ref} gehört zur Umgebung „${other}“ – nicht für ${envName} verwenden.`);
}
if (envName !== 'production' && v('HUSORA_PRODUCTION_SUPABASE_URL') && v('HUSORA_PRODUCTION_SUPABASE_URL').replace(/\/+$/, '') === url) fail('Beta-/Dev-Build zeigt auf die Production-Datenbank.');
if (envName === 'production' && v('HUSORA_BETA_SUPABASE_URL') && v('HUSORA_BETA_SUPABASE_URL').replace(/\/+$/, '') === url) fail('Production-Build zeigt auf die Beta-Datenbank.');

// Version (zentral aus version.json)
const ver = JSON.parse(readFileSync(join(root, 'version.json'), 'utf8'));
if (v('APP_VERSION') && v('APP_VERSION') !== ver.version) fail(`APP_VERSION=${v('APP_VERSION')} weicht von version.json (${ver.version}) ab – Version nur über „npm run version:bump“ ändern.`);
if (envName === 'production' && /-/.test(ver.version)) fail(`Production-Builds brauchen eine Release-Version ohne Vorabkennung (aktuell ${ver.version}).`);
let commit = '';
try { commit = execSync('git rev-parse --short HEAD', { cwd: root, stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim(); } catch { /* ohne git */ }

const runtime = {
  env: envName,
  serverEnvironment: envCfg.serverEnvironment,
  supabaseUrl: url,
  supabaseKey: key,
  apiBaseUrl: apiBase,
  version: ver.version,
  marketingVersion: ver.marketingVersion,
  buildNumber: ver.build,
  buildDate: ver.date,
  native: target === 'native',
  appId: cfg.appId,
  urlScheme: cfg.urlScheme,
  appName: envCfg.appName,
  supportEmail: v('HUSORA_SUPPORT_EMAIL') || null,
  publicWebUrl: v('HUSORA_PUBLIC_WEB_URL') || envCfg.publicWebUrl || null,
  commit,
  builtAt: new Date().toISOString()
};

// www/ erzeugen
rmSync(outDir, { recursive: true, force: true });
mkdirSync(outDir, { recursive: true });
let html = readFileSync(join(root, 'index.html'), 'utf8');
const marker = '<meta charset="utf-8">';
const inject = `${marker}\n  <script>window.HUSORA_RUNTIME = Object.freeze(${JSON.stringify(runtime).replace(/</g, '\\u003c')});</script>`;
if (html.includes(marker)) html = html.replace(marker, inject);
else if (/<head>/i.test(html)) html = html.replace(/<head>/i, `<head>\n  <script>window.HUSORA_RUNTIME = Object.freeze(${JSON.stringify(runtime).replace(/</g, '\\u003c')});</script>`);
else fail('index.html: <head> nicht gefunden');
writeFileSync(join(outDir, 'index.html'), html);
cpSync(join(root, 'assets'), join(outDir, 'assets'), { recursive: true });
if (existsSync(join(root, 'manifest.webmanifest'))) cpSync(join(root, 'manifest.webmanifest'), join(outDir, 'manifest.webmanifest'));
if (target === 'web') cpSync(join(root, 'sw.js'), join(outDir, 'sw.js'));
const { supabaseKey, ...publicInfo } = runtime;
writeFileSync(join(outDir, 'husora-build.json'), JSON.stringify(publicInfo, null, 2));

// Native Projekte: App-Name und Version nachziehen (Android liest version.json selbst)
if (target === 'native') {
  const strings = join(root, 'android/app/src/main/res/values/strings.xml');
  if (existsSync(strings)) {
    let s = readFileSync(strings, 'utf8');
    s = s.replace(/(<string name="app_name">)[^<]*(<\/string>)/, `$1${envCfg.appName}$2`).replace(/(<string name="title_activity_main">)[^<]*(<\/string>)/, `$1${envCfg.appName}$2`);
    writeFileSync(strings, s);
  }
  const plist = join(root, 'ios/App/App/Info.plist');
  if (existsSync(plist)) {
    let p = readFileSync(plist, 'utf8');
    p = p.replace(/(<key>CFBundleDisplayName<\/key>\s*<string>)[^<]*(<\/string>)/, `$1${envCfg.appName}$2`);
    writeFileSync(plist, p);
  }
  const pbx = join(root, 'ios/App/App.xcodeproj/project.pbxproj');
  if (existsSync(pbx)) {
    let p = readFileSync(pbx, 'utf8');
    p = p.replace(/MARKETING_VERSION = [^;]+;/g, `MARKETING_VERSION = ${ver.marketingVersion};`).replace(/CURRENT_PROJECT_VERSION = [^;]+;/g, `CURRENT_PROJECT_VERSION = ${ver.build};`);
    writeFileSync(pbx, p);
  }
}

console.log(`✔ Husora ${ver.version} (Build ${ver.build}) für ${envName}/${target} → ${outDir}`);
console.log(`  Supabase: ${parsed.hostname}  · App-Name: ${envCfg.appName}  · erwartete Server-Umgebung: ${envCfg.serverEnvironment.join('/')}`);
