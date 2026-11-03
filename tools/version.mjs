#!/usr/bin/env node
// Husora · zentrale Versionierung (Quelle: version.json)
//   node tools/version.mjs check                 → prüft, dass index.html, package.json und native Projekte passen
//   node tools/version.mjs bump [beta|patch|minor|major|release]
//        beta    1.0.0-beta.1 → 1.0.0-beta.2   (Standard)
//        release 1.0.0-beta.5 → 1.0.0
//        patch/minor/major → nächste Version als -beta.1
//   Jeder Bump erhöht die Build-Nummer (Android versionCode, iOS CFBundleVersion) um 1 – nie zurücksetzen.
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const file = (p) => join(root, p);
const ver = JSON.parse(readFileSync(file('version.json'), 'utf8'));
const SEMVER = /^(\d+)\.(\d+)\.(\d+)(?:-beta\.(\d+))?$/;
const fail = (msg) => { console.error(`✖ ${msg}`); process.exit(1); };

function check() {
  const errors = [];
  const m = SEMVER.exec(ver.version);
  if (!m) errors.push(`version.json: „${ver.version}“ ist kein gültiges Format (x.y.z oder x.y.z-beta.n)`);
  else if (`${m[1]}.${m[2]}.${m[3]}` !== ver.marketingVersion) errors.push(`version.json: marketingVersion ${ver.marketingVersion} passt nicht zu ${ver.version}`);
  if (!Number.isInteger(ver.build) || ver.build < 1) errors.push('version.json: build muss eine ganze Zahl ≥ 1 sein');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(ver.date || '')) errors.push('version.json: date im Format JJJJ-MM-TT');
  const html = readFileSync(file('index.html'), 'utf8');
  if (!html.includes(`const APP_VERSION = '${ver.version}';`)) errors.push(`index.html: APP_VERSION ist nicht '${ver.version}'`);
  if (!html.includes(`const APP_BUILD = '${ver.date}';`)) errors.push(`index.html: APP_BUILD ist nicht '${ver.date}'`);
  if (!html.includes(`const APP_BUILD_NUMBER = ${ver.build};`)) errors.push(`index.html: APP_BUILD_NUMBER ist nicht ${ver.build}`);
  const pkg = JSON.parse(readFileSync(file('package.json'), 'utf8'));
  if (pkg.version !== ver.version) errors.push(`package.json: version ist ${pkg.version}, erwartet ${ver.version}`);
  const gradle = file('android/app/build.gradle');
  if (existsSync(gradle) && !readFileSync(gradle, 'utf8').includes('version.json')) errors.push('android/app/build.gradle liest version.json nicht');
  if (errors.length) fail(`Versionen inkonsistent:\n  - ${errors.join('\n  - ')}\n  → „npm run version:bump“ bzw. Dateien angleichen`);
  console.log(`✔ Version ${ver.version} · Build ${ver.build} · Stand ${ver.date} – konsistent`);
}

function writeAll(next) {
  writeFileSync(file('version.json'), `${JSON.stringify(next, null, 2)}\n`);
  let html = readFileSync(file('index.html'), 'utf8');
  html = html.replace(/const APP_VERSION = '[^']*';/, `const APP_VERSION = '${next.version}';`)
    .replace(/const APP_BUILD = '[^']*';/, `const APP_BUILD = '${next.date}';`)
    .replace(/const APP_BUILD_NUMBER = \d+;/, `const APP_BUILD_NUMBER = ${next.build};`);
  writeFileSync(file('index.html'), html);
  const pkg = JSON.parse(readFileSync(file('package.json'), 'utf8'));
  pkg.version = next.version;
  writeFileSync(file('package.json'), `${JSON.stringify(pkg, null, 2)}\n`);
  const pbx = file('ios/App/App.xcodeproj/project.pbxproj');
  if (existsSync(pbx)) {
    writeFileSync(pbx, readFileSync(pbx, 'utf8').replace(/MARKETING_VERSION = [^;]+;/g, `MARKETING_VERSION = ${next.marketingVersion};`).replace(/CURRENT_PROJECT_VERSION = [^;]+;/g, `CURRENT_PROJECT_VERSION = ${next.build};`));
  }
}

function bump(kind = 'beta') {
  const m = SEMVER.exec(ver.version);
  if (!m) fail(`Unbekanntes Versionsformat ${ver.version}`);
  let [maj, min, pat, beta] = [Number(m[1]), Number(m[2]), Number(m[3]), m[4] ? Number(m[4]) : null];
  if (kind === 'beta') beta = beta === null ? (pat += 1, 1) : beta + 1;
  else if (kind === 'release') { if (beta === null) fail(`${ver.version} ist bereits ein Release`); beta = null; }
  else if (kind === 'patch') { pat += 1; beta = 1; }
  else if (kind === 'minor') { min += 1; pat = 0; beta = 1; }
  else if (kind === 'major') { maj += 1; min = 0; pat = 0; beta = 1; }
  else fail('bump: beta | release | patch | minor | major');
  const marketing = `${maj}.${min}.${pat}`;
  const next = { version: beta === null ? marketing : `${marketing}-beta.${beta}`, marketingVersion: marketing, build: ver.build + 1, date: new Date().toISOString().slice(0, 10) };
  writeAll(next);
  console.log(`✔ ${ver.version} (Build ${ver.build}) → ${next.version} (Build ${next.build})`);
}

const [cmd, arg] = process.argv.slice(2);
if (cmd === 'check') check();
else if (cmd === 'bump') bump(arg);
else fail('Aufruf: node tools/version.mjs check | bump [beta|release|patch|minor|major]');
