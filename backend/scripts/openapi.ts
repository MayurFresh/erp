// Writes ../docs/openapi.json from the routes of the running code. Needs no database.
import { writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { buildApp } from '../src/app.ts';
import { loadConfig } from '../src/config.ts';
import type { Db } from '../src/db/database.ts';

const app = await buildApp({ config: loadConfig({ ...process.env, LOG_LEVEL: 'silent' }), db: {} as Db, logger: false, authRateLimit: false });
const res = await app.inject({ method: 'GET', url: '/api/v1/openapi.json' });
const out = fileURLToPath(new URL('../../docs/openapi.json', import.meta.url));
await writeFile(out, `${JSON.stringify(res.json(), null, 2)}\n`);
console.log(`wrote ${out} (${Object.keys(res.json().paths).length} paths)`);
await app.close();
