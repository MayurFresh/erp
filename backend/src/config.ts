import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { z } from 'zod';

/** Uploaded files go to backend/uploads unless UPLOAD_DIR says otherwise. */
const DEFAULT_UPLOAD_DIR = fileURLToPath(new URL('../uploads/', import.meta.url));

/** `true`, `false`, a hop count, or a comma-separated list of proxy addresses (Fastify's trustProxy). */
function trustProxy(v: string): boolean | number | string[] {
  const t = v.trim();
  if (t === 'true' || t === 'false') return t === 'true';
  if (/^\d+$/.test(t)) return Number(t);
  return t.split(',').map((a) => a.trim()).filter(Boolean);
}

const schema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().int().default(8080),
  HOST: z.string().default('0.0.0.0'),
  DATABASE_URL: z.string().min(1, 'DATABASE_URL is required'),
  DATABASE_ADMIN_URL: z.string().optional(),
  TEST_DATABASE_URL: z.string().optional(),
  JWT_SECRET: z.string().min(32, 'JWT_SECRET must be at least 32 characters'),
  ACCESS_TOKEN_TTL_SECONDS: z.coerce.number().int().positive().default(900),
  REFRESH_TOKEN_TTL_DAYS: z.coerce.number().int().positive().default(30),
  CORS_ORIGINS: z.string().default('*'),
  // Off unless the API sits behind a proxy; otherwise clients could forge X-Forwarded-For.
  TRUST_PROXY: z.string().default('false').transform(trustProxy),
  RATE_LIMIT_PER_MINUTE: z.coerce.number().int().positive().default(600),
  // Lets SSO issuers resolve to private or loopback addresses. Defaults to on outside production.
  SSO_ALLOW_PRIVATE_ISSUERS: z.enum(['true', 'false']).optional(),
  /** Webhook targets on private or loopback addresses. Default: allowed outside production. */
  WEBHOOK_ALLOW_PRIVATE: z.enum(['true', 'false']).optional(),
  /** Turns on OpenTelemetry tracing (needs @opentelemetry packages and OTEL_EXPORTER_OTLP_ENDPOINT). */
  OTEL_ENABLED: z.enum(['true', 'false']).optional(),
  LOG_LEVEL: z.string().default('info'),
  UPLOAD_DIR: z.preprocess((v) => (typeof v === 'string' && v.trim() === '' ? undefined : v),
    z.string().default(DEFAULT_UPLOAD_DIR)).transform((p) => resolve(p)),
  // v1.7
  APP_URL: z.string().url().default('http://localhost:5000').transform((u) => u.replace(/\/+$/, '')),
  PUBLIC_API_URL: z.string().url().default('http://localhost:8080').transform((u) => u.replace(/\/+$/, '')),
  DATA_KEY: z.string().optional(),
  EMAIL_DRIVER: z.enum(['log', 'smtp']).default('log'),
  SMTP_URL: z.string().optional(),
  EMAIL_FROM: z.string().default('Progen <no-reply@localhost>'),
  WHATSAPP_DRIVER: z.enum(['log', 'cloud_api']).default('log'),
  WHATSAPP_TOKEN: z.string().optional(),
  WHATSAPP_PHONE_ID: z.string().optional(),
  WHATSAPP_API_VERSION: z.string().default('v21.0'),
  JOBS_WORKER: z.enum(['true', 'false']).default('true').transform((v) => v === 'true'),
});

export type Config = z.infer<typeof schema>;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const parsed = schema.safeParse(env);
  if (!parsed.success) {
    const problems = parsed.error.issues.map((i) => `  ${i.path.join('.')}: ${i.message}`).join('\n');
    throw new Error(`Invalid configuration (check backend/.env):\n${problems}`);
  }
  const c = parsed.data;
  if (c.NODE_ENV === 'production') {
    const problems: string[] = [];
    if (c.CORS_ORIGINS.trim() === '*') problems.push('  CORS_ORIGINS: list the allowed web origins; * is not allowed in production');
    if (!c.DATA_KEY) problems.push('  DATA_KEY: required in production, so rotating JWT_SECRET cannot break sealed secrets');
    if (problems.length) throw new Error(`Invalid configuration (check backend/.env):\n${problems.join('\n')}`);
  }
  return c;
}

/** Whether SSO discovery may reach private, loopback or link-local addresses. */
export const ssoAllowPrivate = (c: Config) =>
  c.SSO_ALLOW_PRIVATE_ISSUERS ? c.SSO_ALLOW_PRIVATE_ISSUERS === 'true' : c.NODE_ENV !== 'production';

/** Whether webhook URLs may point at private, loopback or link-local addresses. */
export const webhookAllowPrivate = (c: Config) =>
  c.WEBHOOK_ALLOW_PRIVATE ? c.WEBHOOK_ALLOW_PRIVATE === 'true' : c.NODE_ENV !== 'production';
