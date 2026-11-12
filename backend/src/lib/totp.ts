import { createHmac, randomBytes } from 'node:crypto';

// RFC 6238 TOTP (SHA-1, 6 digits, 30 s) with RFC 4648 base32, no dependencies.
const ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
const STEP_SECONDS = 30;

export function base32Encode(buf: Buffer): string {
  let bits = 0; let value = 0; let out = '';
  for (const b of buf) {
    value = (value << 8) | b; bits += 8;
    while (bits >= 5) { out += ALPHABET[(value >>> (bits - 5)) & 31]; bits -= 5; }
  }
  if (bits > 0) out += ALPHABET[(value << (5 - bits)) & 31];
  return out;
}

export function base32Decode(s: string): Buffer {
  let bits = 0; let value = 0; const out: number[] = [];
  for (const ch of s.toUpperCase().replace(/=+$/, '')) {
    const i = ALPHABET.indexOf(ch);
    if (i < 0) throw new Error('Invalid base32');
    value = (value << 5) | i; bits += 5;
    if (bits >= 8) { out.push((value >>> (bits - 8)) & 255); bits -= 8; }
  }
  return Buffer.from(out);
}

export const newTotpSecret = () => base32Encode(randomBytes(20));

export const stepOf = (ms = Date.now()) => Math.floor(ms / 1000 / STEP_SECONDS);

export function hotp(secret: string, counter: number): string {
  const msg = Buffer.alloc(8);
  msg.writeBigUInt64BE(BigInt(counter));
  const h = createHmac('sha1', base32Decode(secret)).update(msg).digest();
  const off = h[h.length - 1]! & 15;
  const code = (h.readUInt32BE(off) & 0x7fffffff) % 1_000_000;
  return String(code).padStart(6, '0');
}

export const totpAt = (secret: string, ms = Date.now()) => hotp(secret, stepOf(ms));

/** The matching step within ±1 of now that is newer than `lastStep`, or null. */
export function verifyTotp(secret: string, code: string, lastStep: number | null, ms = Date.now()): number | null {
  if (!/^\d{6}$/.test(code)) return null;
  const now = stepOf(ms);
  for (const step of [now - 1, now, now + 1]) {
    if (lastStep !== null && step <= lastStep) continue;
    if (hotp(secret, step) === code) return step;
  }
  return null;
}

export function newRecoveryCodes(n = 10): string[] {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return Array.from({ length: n }, () => {
    const b = randomBytes(8);
    const s = Array.from(b, (x) => chars[x % chars.length]).join('');
    return `${s.slice(0, 4)}-${s.slice(4)}`;
  });
}
