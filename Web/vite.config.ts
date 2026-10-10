/// <reference types="vitest/config" />
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Порт 3000 совпадает с `site_url` в Supabase/config.toml (magic link, срез 2).
// `WEB_PORT` переопределяет его, когда 3000 занят другим процессом; `strictPort`
// при этом остаётся: молча уйти на соседний порт значило бы разойтись с
// `site_url` незаметно.
// `/v1` проксируется на Vapor-сервер: в проде SPA раздаётся с того же origin
// (SPEC §20.13), поэтому CORS не нужен и здесь.
export default defineConfig({
  plugins: [react()],
  server: {
    host: '127.0.0.1',
    port: Number(process.env.WEB_PORT ?? 3000),
    strictPort: true,
    proxy: {
      '/v1': { target: 'http://127.0.0.1:8080', changeOrigin: false },
    },
  },
  test: {
    environment: 'jsdom',
    include: ['src/**/*.test.{ts,tsx}'],
    globals: false,
  },
})
