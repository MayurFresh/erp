import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { z } from 'zod';

/** Uploaded files go to backend/uploads unless UPLOAD_DIR says otherwise. */
const DEFAULT_UPLOAD_DIR = fileURLToPath(new URL('../uploads/', import.meta.url));

const schema = z.object({
  PORT: z.coerce.number().int().default(8080),
  HOST: z.string().default('0.0.0.0'),
  DATABASE_URL: z.string().min(1, 'DATABASE_URL is required'),
  DATABASE_ADMIN_URL: z.string().optional(),
  TEST_DATABASE_URL: z.string().optional(),
  JWT_SECRET: z.string().min(32, 'JWT_SECRET must be at least 32 characters'),
  ACCESS_TOKEN_TTL_SECONDS: z.coerce.number().int().positive().default(900),
  REFRESH_TOKEN_TTL_DAYS: z.coerce.number().int().positive().default(30),
  CORS_ORIGINS: z.string().default('*'),
  LOG_LEVEL: z.string().default('info'),
  UPLOAD_DIR: z.preprocess((v) => (typeof v === 'string' && v.trim() === '' ? undefined : v),
    z.string().default(DEFAULT_UPLOAD_DIR)).transform((p) => resolve(p)),
});

export type Config = z.infer<typeof schema>;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const parsed = schema.safeParse(env);
  if (!parsed.success) {
    const problems = parsed.error.issues.map((i) => `  ${i.path.join('.')}: ${i.message}`).join('\n');
    throw new Error(`Invalid configuration (check backend/.env):\n${problems}`);
  }
  return parsed.data;
}
