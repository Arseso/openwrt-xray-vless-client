import { defineConfig } from 'vitest/config';

// Tauri expects a fixed port in dev and the build in dist/ (src-tauri/tauri.conf.json)
export default defineConfig({
  clearScreen: false,
  server: { port: 1420, strictPort: true, watch: { ignored: ['**/src-tauri/**'] } },
  build: { target: 'es2022', outDir: 'dist', emptyOutDir: true },
  test: {
    include: ['tests/unit/**/*.test.ts'],
    environment: 'node',
  },
});
