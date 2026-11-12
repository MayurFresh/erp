import { randomUUID } from 'node:crypto';
import { SignJWT, jwtVerify, errors as joseErrors } from 'jose';
import { AppError, unauthorized } from '../lib/errors.ts';

export interface TokenConfig { secret: string; accessTtlSeconds: number; refreshTtlDays: number }

export type Amr = 'pwd' | 'mfa' | 'sso';
export interface AccessClaims { userId: string; tenantId: string; sid?: string; amr?: Amr }
export interface RefreshClaims extends AccessClaims { jti: string }
export interface MfaClaims { userId: string; tenantId: string; challengeId: string }

const amrOf = (v: unknown): Amr | undefined => (v === 'pwd' || v === 'mfa' || v === 'sso' ? v : undefined);

export function createTokenService(cfg: TokenConfig) {
  const key = new TextEncoder().encode(cfg.secret);

  async function sign(claims: Record<string, unknown>, subject: string, ttlSeconds: number, jti?: string) {
    const jwt = new SignJWT(claims).setProtectedHeader({ alg: 'HS256' }).setSubject(subject)
      .setIssuedAt().setExpirationTime(Math.floor(Date.now() / 1000) + ttlSeconds);
    if (jti) jwt.setJti(jti);
    return jwt.sign(key);
  }

  async function verify(token: string, typ: 'access' | 'refresh' | 'mfa') {
    try {
      const { payload } = await jwtVerify(token, key, { algorithms: ['HS256'] });
      if (payload.typ !== typ || typeof payload.sub !== 'string' || typeof payload.tid !== 'string') {
        throw unauthorized('Invalid token.');
      }
      return payload;
    } catch (err) {
      if (err instanceof AppError) throw err;
      if (err instanceof joseErrors.JWTExpired) {
        throw new AppError(401, typ === 'access' ? 'TOKEN_EXPIRED' : 'UNAUTHORIZED', 'Session expired. Please sign in again.');
      }
      throw unauthorized('Invalid token.');
    }
  }

  return {
    accessTtlSeconds: cfg.accessTtlSeconds,
    refreshTtlMs: cfg.refreshTtlDays * 86_400_000,

    signAccess: (c: AccessClaims) => sign({ typ: 'access', tid: c.tenantId, sid: c.sid, amr: c.amr }, c.userId, cfg.accessTtlSeconds),

    async signMfa(c: MfaClaims): Promise<string> {
      return sign({ typ: 'mfa', tid: c.tenantId }, c.userId, 300, c.challengeId);
    },

    async verifyMfa(token: string): Promise<MfaClaims> {
      const p = await verify(token, 'mfa');
      if (typeof p.jti !== 'string') throw unauthorized('Invalid token.');
      return { userId: p.sub!, tenantId: p.tid as string, challengeId: p.jti };
    },

    async signRefresh(c: AccessClaims): Promise<{ token: string; jti: string; expiresAt: Date }> {
      const jti = randomUUID();
      const ttl = cfg.refreshTtlDays * 86_400;
      const token = await sign({ typ: 'refresh', tid: c.tenantId, sid: c.sid, amr: c.amr }, c.userId, ttl, jti);
      return { token, jti, expiresAt: new Date(Date.now() + ttl * 1000) };
    },

    async verifyAccess(token: string): Promise<AccessClaims> {
      const p = await verify(token, 'access');
      return { userId: p.sub!, tenantId: p.tid as string, sid: typeof p.sid === 'string' ? p.sid : undefined, amr: amrOf(p.amr) };
    },

    async verifyRefresh(token: string): Promise<RefreshClaims> {
      const p = await verify(token, 'refresh');
      if (typeof p.jti !== 'string') throw unauthorized('Invalid token.');
      return { userId: p.sub!, tenantId: p.tid as string, jti: p.jti, sid: typeof p.sid === 'string' ? p.sid : undefined, amr: amrOf(p.amr) };
    },
  };
}

export type TokenService = ReturnType<typeof createTokenService>;
