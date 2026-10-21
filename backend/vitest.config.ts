import { loadEnv } from 'vite';
import { defineConfig } from 'vitest/config';

export default defineConfig(({ mode }) => ({
  test: {
    include: ['test/**/*.test.ts'],
    // Loads backend/.env (all keys, not only VITE_*) for the database URLs.
    env: loadEnv(mode, process.cwd(), ''),
    // API tests share one test database, so files run one after another.
    fileParallelism: false,
    testTimeout: 20_000,
    hookTimeout: 30_000,
  },
}));
