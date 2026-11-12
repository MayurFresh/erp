import './telemetry.ts';
import { buildApp } from './app.ts';
import { loadConfig } from './config.ts';
import { createDb } from './db/database.ts';
import { startJobWorker } from './lib/jobs.ts';

const config = loadConfig();
const db = createDb(config.DATABASE_URL);
const app = await buildApp({ config, db });
const worker = config.JOBS_WORKER ? startJobWorker({ db, config, log: app.log }) : null;

// A hung job or request must not keep the process alive forever.
const SHUTDOWN_DEADLINE_MS = 15_000;
let stopping = false;

const shutdown = async (signal: string) => {
  if (stopping) return;
  stopping = true;
  app.log.info(`${signal} received, shutting down`);
  setTimeout(() => {
    app.log.error(`shutdown took longer than ${SHUTDOWN_DEADLINE_MS / 1000}s, exiting`);
    process.exit(1);
  }, SHUTDOWN_DEADLINE_MS).unref();
  await worker?.stop();
  await app.close();
  await db.destroy();
  process.exit(0);
};
process.on('SIGINT', () => void shutdown('SIGINT'));
process.on('SIGTERM', () => void shutdown('SIGTERM'));

await app.listen({ port: config.PORT, host: config.HOST });
