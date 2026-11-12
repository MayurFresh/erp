import { spawn } from 'node:child_process';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

// Proves src/telemetry.ts exports a span for one request, against a local OTLP receiver (no collector needed).
describe('telemetry', () => {
  it('exports a span for one http request', async () => {
    const bodies: string[] = [];
    const receiver = http.createServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on('data', (c) => chunks.push(c));
      req.on('end', () => { if (req.url === '/v1/traces') bodies.push(Buffer.concat(chunks).toString('utf8')); res.writeHead(200, { 'content-type': 'application/json' }); res.end('{}'); });
    });
    await new Promise<void>((r) => receiver.listen(0, '127.0.0.1', r));
    const endpoint = `http://127.0.0.1:${(receiver.address() as AddressInfo).port}`;
    const child = fileURLToPath(new URL('./fixtures/otel-child.ts', import.meta.url));
    const out: string[] = [];
    const code = await new Promise<number | null>((resolve) => {
      const p = spawn(process.execPath, [child], {
        env: { ...process.env, OTEL_EXPORTER_OTLP_ENDPOINT: endpoint, OTEL_ENABLED: 'true', OTEL_SERVICE_NAME: 'otel-test', OTEL_TRACES_EXPORTER: 'otlp' },
      });
      p.stderr.on('data', (d) => out.push(String(d)));
      p.on('close', resolve);
    });
    await new Promise((r) => receiver.close(r));
    expect(code, out.join('')).toBe(0);
    const all = bodies.join('\n');
    expect(all, 'no spans received').toContain('otel-test');
    expect(all).toContain('/ping-otel');
  }, 30_000);
});
