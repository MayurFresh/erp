import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { MODULE_ROUTES, moduleForRoute } from './entitlements.ts';

export interface RouteInfo { method: string; url: string }

/** Records every route the app registers. Call before registering routes. */
export function collectRoutes(app: FastifyInstance): RouteInfo[] {
  const routes: RouteInfo[] = [];
  app.addHook('onRoute', (r) => {
    for (const m of Array.isArray(r.method) ? r.method : [r.method]) if (m !== 'HEAD' && m !== 'OPTIONS') routes.push({ method: m, url: r.url });
  });
  return routes;
}

/** Zod schemas for routes whose body or query is described. Keyed `METHOD /path` with `:param` segments, no /api/v1. */
export interface RouteDoc { summary?: string; body?: z.ZodType; query?: z.ZodType }
const docs = new Map<string, RouteDoc>();
export function documentRoute(method: string, path: string, doc: RouteDoc): void {
  docs.set(`${method.toUpperCase()} ${path}`, doc);
}

const schemaOf = (s: z.ZodType, io: 'input' | 'output' = 'input') => {
  const { $schema: _drop, ...rest } = z.toJSONSchema(s, { target: 'draft-2020-12', io, unrepresentable: 'any' }) as Record<string, unknown>;
  return rest;
};

const ERROR_REF = { $ref: '#/components/schemas/Error' };
const errorResponse = (description: string) => ({ description, content: { 'application/json': { schema: ERROR_REF } } });

const camel = (s: string) => s.replace(/[^a-zA-Z0-9]+(.)?/g, (_m, c: string | undefined) => (c ? c.toUpperCase() : ''));

/** Builds an OpenAPI 3.1 document from the registered routes and the zod schemas described with documentRoute. */
export function buildOpenApi(routes: RouteInfo[], opts: { version?: string; serverUrl?: string } = {}): Record<string, unknown> {
  const paths: Record<string, Record<string, unknown>> = {};
  const prefix = '/api/v1';
  for (const r of [...routes].sort((a, b) => (a.url === b.url ? a.method.localeCompare(b.method) : a.url.localeCompare(b.url)))) {
    if (!r.url.startsWith(prefix)) continue;
    const short = r.url.slice(prefix.length) || '/';
    const oaPath = short.replace(/:([A-Za-z0-9_]+)/g, '{$1}');
    const method = r.method.toLowerCase();
    const doc = docs.get(`${r.method} ${short}`);
    const tag = short.split('/')[1] || 'root';
    const module = moduleForRoute(r.url);
    const open = /^\/(auth|business-types)(\/|$)/.test(short) || short === '/openapi.json';
    const params = [...short.matchAll(/:([A-Za-z0-9_]+)/g)].map((m) => ({
      name: m[1], in: 'path', required: true, schema: m[1] === 'id' || m[1]!.endsWith('Id') ? { type: 'string', format: 'uuid' } : { type: 'string' },
    }));
    const op: Record<string, unknown> = {
      operationId: camel(`${method} ${short}`),
      summary: doc?.summary ?? `${r.method} ${short}`,
      tags: [tag],
      ...(params.length ? { parameters: params } : {}),
      ...(doc?.query ? { 'x-query-schema': schemaOf(doc.query) } : {}),
      responses: {
        '200': { description: 'Success' },
        '400': errorResponse('VALIDATION_ERROR'),
        ...(open ? {} : { '401': errorResponse('UNAUTHORIZED'), '403': errorResponse('FORBIDDEN or MODULE_DISABLED') }),
        '404': errorResponse('NOT_FOUND'),
      },
      ...(open ? { security: [] } : {}),
      ...(module ? { 'x-module': module } : {}),
    };
    if (doc?.body) op.requestBody = { required: true, content: { 'application/json': { schema: schemaOf(doc.body) } } };
    else if (['post', 'put', 'patch'].includes(method)) op.requestBody = { content: { 'application/json': { schema: { type: 'object' } } } };
    (paths[oaPath] ??= {})[method] = op;
  }
  return {
    openapi: '3.1.0',
    info: {
      title: 'OneMatrix API', version: opts.version ?? '1.11.0',
      description: 'Routes are listed from the running server. Request bodies are described where a zod schema is registered with documentRoute; see docs/API.md for the rest. Money is in rupees, dates are YYYY-MM-DD.',
    },
    servers: [{ url: opts.serverUrl ?? '/api/v1' }],
    security: [{ bearerAuth: [] }],
    paths,
    components: {
      securitySchemes: {
        bearerAuth: { type: 'http', scheme: 'bearer', bearerFormat: 'JWT or pk_ API key', description: 'Access token from /auth/login, or a company API key starting with pk_.' },
      },
      schemas: {
        Error: {
          type: 'object', required: ['error'],
          properties: { error: { type: 'object', required: ['code', 'message'], properties: { code: { type: 'string' }, message: { type: 'string' }, details: { type: 'object', additionalProperties: true } } } },
        },
      },
    },
    'x-modules': Object.fromEntries(Object.entries(MODULE_ROUTES)),
  };
}

export function registerOpenApi(app: FastifyInstance, routes: RouteInfo[]): void {
  app.get('/openapi.json', { config: { rateLimit: false } }, async () => buildOpenApi(routes));
}
