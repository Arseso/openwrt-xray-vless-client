import { defineConfig } from 'vitest/config';

// The client against a live router or the stand of scripts/luci.sh: scripts/desktop-itest.sh
export default defineConfig({
  test: {
    include: ['tests/stand/**/*.test.ts'],
    environment: 'node',
    testTimeout: 60_000,
    fileParallelism: false,
  },
});
