import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { readFileSync } from 'node:fs';

const plist = readFileSync(new URL('../Resources/Control-Info.plist', import.meta.url), 'utf8');
const version = process.env.CMM_VERSION ?? plist.match(/CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/)?.[1] ?? 'development';

export default defineConfig({
  plugins: [react()],
  define: { __APP_VERSION__: JSON.stringify(version) },
  build: { target: 'safari17', sourcemap: false },
});
