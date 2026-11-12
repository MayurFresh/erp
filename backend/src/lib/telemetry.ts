import type { FastifyInstance } from 'fastify';
import type { Config } from '../config.ts';

// The OpenTelemetry packages are not in package.json (they clash with vitest's optional peer range for
// @opentelemetry/api). To turn tracing on, install them in the deployment image:
//   npm install --no-save @opentelemetry/api @opentelemetry/sdk-trace-node @opentelemetry/exporter-trace-otlp-http
// and set OTEL_ENABLED=true and OTEL_EXPORTER_OTLP_ENDPOINT. Off by default; missing packages only log a warning.
const load = (name: string): Promise<any> => import(name);

/** One server span per request, named `METHOD /route/pattern`, exported over OTLP/HTTP. */
export async function setupTelemetry(app: FastifyInstance, config: Config): Promise<boolean> {
  if (config.OTEL_ENABLED !== 'true') return false;
  try {
    const api = await load('@opentelemetry/api');
    const { NodeTracerProvider, BatchSpanProcessor } = await load('@opentelemetry/sdk-trace-node');
    const { OTLPTraceExporter } = await load('@opentelemetry/exporter-trace-otlp-http');
    process.env.OTEL_SERVICE_NAME ??= 'progen-api';
    new NodeTracerProvider({ spanProcessors: [new BatchSpanProcessor(new OTLPTraceExporter())] }).register();
    const tracer = api.trace.getTracer('progen-api');
    const spans = new WeakMap<object, any>();
    app.addHook('onRequest', async (req) => {
      const route = req.routeOptions.url ?? req.url.split('?')[0];
      spans.set(req, tracer.startSpan(`${req.method} ${route}`, { kind: api.SpanKind.SERVER, attributes: { 'http.request.method': req.method, 'http.route': route } }));
    });
    app.addHook('onError', async (req, _reply, err) => { spans.get(req)?.recordException(err); });
    app.addHook('onResponse', async (req, reply) => {
      const span = spans.get(req);
      if (!span) return;
      span.setAttribute('http.response.status_code', reply.statusCode);
      if (reply.statusCode >= 500) span.setStatus({ code: api.SpanStatusCode.ERROR });
      span.end();
    });
    app.log.info('OpenTelemetry tracing is on');
    return true;
  } catch (err) {
    app.log.warn(`OTEL_ENABLED is true but tracing could not start: ${(err as Error).message}`);
    return false;
  }
}
