// Tracing, off unless OTEL_EXPORTER_OTLP_ENDPOINT is set. Imported first in server.ts so the
// http and pg instrumentation is in place before those modules load. Needs no config object:
// the standard OTEL_* environment variables (service name, headers, sampler) apply.
if (process.env.OTEL_EXPORTER_OTLP_ENDPOINT && process.env.OTEL_ENABLED !== 'false') {
  // ESM imports of node:http and pg only reach the instrumentation through this loader hook.
  const { register } = await import('node:module');
  register('import-in-the-middle/hook.mjs', import.meta.url);
  const [{ NodeSDK }, { OTLPTraceExporter }, { HttpInstrumentation }, { PgInstrumentation }] = await Promise.all([
    import('@opentelemetry/sdk-node'),
    import('@opentelemetry/exporter-trace-otlp-http'),
    import('@opentelemetry/instrumentation-http'),
    import('@opentelemetry/instrumentation-pg'),
  ]);
  const sdk = new NodeSDK({
    serviceName: process.env.OTEL_SERVICE_NAME ?? 'progen-erp-api',
    traceExporter: new OTLPTraceExporter(),
    instrumentations: [new HttpInstrumentation(), new PgInstrumentation()],
  });
  sdk.start();
  const flush = () => { void sdk.shutdown().catch(() => undefined); };
  process.once('SIGTERM', flush);
  process.once('SIGINT', flush);
}
export {};
