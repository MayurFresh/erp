import { createCipheriv, createDecipheriv, createHash, hkdfSync, randomBytes } from 'node:crypto';

let dataKey: Buffer | null = null;

/**
 * Sets the key that seals secrets at rest (TOTP secrets, SSO client secrets, GSP credentials).
 * `DATA_KEY` is 32 bytes in base64; without it a key is derived from `JWT_SECRET`.
 * Returns true when the key was derived, so the caller can warn.
 */
export function configureDataKey(cfg: { DATA_KEY?: string; JWT_SECRET: string }): boolean {
  if (cfg.DATA_KEY) {
    const key = Buffer.from(cfg.DATA_KEY, 'base64');
    if (key.length !== 32) throw new Error('DATA_KEY must be 32 bytes, base64-encoded');
    dataKey = key;
    return false;
  }
  dataKey = Buffer.from(hkdfSync('sha256', cfg.JWT_SECRET, 'progen', 'data-key-v1', 32));
  return true;
}

function key(): Buffer {
  if (!dataKey) throw new Error('configureDataKey() has not been called');
  return dataKey;
}

/** AES-256-GCM: `v1.<iv>.<tag>.<ciphertext>`, each base64url. */
export function seal(plain: string): string {
  const iv = randomBytes(12);
  const c = createCipheriv('aes-256-gcm', key(), iv);
  const ct = Buffer.concat([c.update(plain, 'utf8'), c.final()]);
  return ['v1', iv.toString('base64url'), c.getAuthTag().toString('base64url'), ct.toString('base64url')].join('.');
}

/** Opens a value from `seal`. Throws if it was tampered with or sealed under another key. */
export function unseal(sealed: string): string {
  const [v, iv, tag, ct] = sealed.split('.');
  if (v !== 'v1' || !iv || !tag || ct === undefined) throw new Error('Not a sealed value');
  const d = createDecipheriv('aes-256-gcm', key(), Buffer.from(iv, 'base64url'));
  d.setAuthTag(Buffer.from(tag, 'base64url'));
  return Buffer.concat([d.update(Buffer.from(ct, 'base64url')), d.final()]).toString('utf8');
}

export const sha256Hex = (s: string) => createHash('sha256').update(s).digest('hex');

/** A URL-safe random token of `bytes` random bytes. */
export const randomToken = (bytes = 32) => randomBytes(bytes).toString('base64url');
