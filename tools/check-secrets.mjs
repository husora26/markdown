#!/usr/bin/env node
// Husora · Secret-Scan über alle versionierten Dateien (Spec §16, §26)
// Bricht ab, wenn geheime Schlüssel, private Schlüssel oder .env-/Keystore-Dateien im Repository liegen.
// Öffentliche Werte (sb_publishable_…, anon-JWT, Projekt-URL) sind erlaubt.
import { execSync } from 'node:child_process';
import { readFileSync, statSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const files = execSync('git ls-files -z', { cwd: root }).toString().split('\0').filter(Boolean);
const forbiddenFiles = [/(^|\/)\.env(\.[^/]*)?$/, /\.(jks|keystore|p8|p12|mobileprovision|pem)$/i, /(^|\/)keystore\.properties$/, /google-play-service-account.*\.json$/i, /(^|\/)AuthKey_.*\.p8$/];
const allowedFiles = [/(^|\/)\.env(\.[a-z]+)?\.example$/];
const jwtRole = (token) => { try { return JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString()).role || ''; } catch { return ''; } };
const patterns = [
  ['Supabase secret key', /\bsb_secret_[A-Za-z0-9_-]{10,}/g],
  ['Stripe secret key', /\b(sk|rk)_(live|test)_[A-Za-z0-9]{16,}/g],
  ['Stripe webhook secret', /\bwhsec_[A-Za-z0-9]{16,}/g],
  ['Anthropic API key', /\bsk-ant-[A-Za-z0-9_-]{20,}/g],
  ['Resend API key', /\bre_[A-Za-z0-9]{8,}_[A-Za-z0-9]{16,}/g],
  ['Private key', /-----BEGIN (RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----/g],
  ['Google service account', /"type":\s*"service_account"/g],
  ['GitHub token', /\bgh[pousr]_[A-Za-z0-9]{30,}/g],
  ['AWS access key', /\bAKIA[0-9A-Z]{16}\b/g]
];
const problems = [];
for (const f of files) {
  if (forbiddenFiles.some((r) => r.test(f)) && !allowedFiles.some((r) => r.test(f))) { problems.push(`${f}: Datei darf nicht im Repository liegen`); continue; }
  let text;
  try { if (statSync(resolve(root, f)).size > 8 * 1024 * 1024) continue; text = readFileSync(resolve(root, f), 'utf8'); } catch { continue; }
  if (text.includes('\u0000')) continue;
  for (const [label, re] of patterns) {
    for (const m of text.matchAll(re)) {
      if (f.startsWith('tools/check-secrets.mjs')) continue;
      problems.push(`${f}: ${label} (${m[0].slice(0, 12)}…)`);
    }
  }
  for (const m of text.matchAll(/\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g)) {
    if (jwtRole(m[0]) === 'service_role') problems.push(`${f}: service_role-JWT`);
  }
}
if (problems.length) { console.error(`✖ Secret-Scan: ${problems.length} Fund(e)\n  - ${problems.join('\n  - ')}`); process.exit(1); }
console.log(`✔ Secret-Scan: ${files.length} Dateien geprüft, keine Geheimnisse gefunden`);
