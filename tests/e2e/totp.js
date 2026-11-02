// TOTP (RFC 6238, SHA-1, 30 s, 6 Stellen) für E2E-Tests mit Zwei-Faktor-Anmeldung
const crypto = require('crypto');
function base32(secret) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'; let bits = ''; const out = [];
  for (const ch of secret.replace(/=+$/, '').toUpperCase()) { const v = alphabet.indexOf(ch); if (v < 0) continue; bits += v.toString(2).padStart(5, '0'); }
  for (let i = 0; i + 8 <= bits.length; i += 8) out.push(parseInt(bits.slice(i, i + 8), 2));
  return Buffer.from(out);
}
module.exports = function totp(secret, at = Date.now()) {
  const counter = Buffer.alloc(8); counter.writeBigUInt64BE(BigInt(Math.floor(at / 30000)));
  const h = crypto.createHmac('sha1', base32(secret)).update(counter).digest();
  const o = h[h.length - 1] & 15;
  return String(((h.readUInt32BE(o) & 0x7fffffff) % 1000000)).padStart(6, '0');
};
