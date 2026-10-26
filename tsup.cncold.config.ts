// CN Cold: build leve para VPS pequena (1 vCPU / pouca memória): só CommonJS (é o que `node dist/main` usa),
// sem minificar e sem source map. O padrão (tsup.config.ts) gera cjs+esm minificado e estoura a memória da VPS.
import { cpSync } from 'node:fs';

import { defineConfig } from 'tsup';

export default defineConfig({
  entry: ['src'],
  outDir: 'dist',
  splitting: false,
  sourcemap: false,
  clean: true,
  minify: false,
  format: ['cjs'],
  onSuccess: async () => {
    cpSync('src/utils/translations', 'dist/translations', { recursive: true });
  },
  loader: {
    '.json': 'file',
    '.yml': 'file',
  },
});
