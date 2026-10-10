/// <reference types="vitest/config" />
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Порт 5173 — умолчание Vite; 3000 на машинах разработки часто занят. `site_url`
// и `additional_redirect_urls` в Supabase/config.toml пока указывают на 3000 и
// приводятся к 5173 первым коммитом среза 2 (magic link). `WEB_PORT`
// переопределяет порт; `strictPort` остаётся: молча уйти на соседний порт
// значило бы разойтись с `site_url` незаметно.
// `/v1` проксируется на Vapor-сервер: в проде SPA раздаётся с того же origin
// (SPEC §20.13), поэтому CORS не нужен и здесь.
export default defineConfig({
  plugins: [react()],
  server: {
    host: '127.0.0.1',
    port: Number(process.env.WEB_PORT ?? 5173),
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
