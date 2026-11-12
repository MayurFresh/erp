// Run by otel.test.ts in a child process: telemetry first, then one http request, then flush on SIGTERM.
import '../../src/telemetry.ts';
import http from 'node:http';

const server = http.createServer((_req, res) => { res.end('ok'); });
await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
const port = (server.address() as { port: number }).port;
await new Promise<void>((resolve, reject) => {
  http.get(`http://127.0.0.1:${port}/ping-otel`, (res) => { res.resume(); res.on('end', resolve); }).on('error', reject);
});
server.close();
process.kill(process.pid, 'SIGTERM'); // telemetry.ts flushes the exporter, then the process ends
