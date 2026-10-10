import { defineConfig } from '@playwright/test'

// Сквозной тест идёт против настоящих Supabase и Server (web-domain §7): мок
// сервера не используется, потому что тест, проверяющий клиент на ответе,
// которого сервер отдать не умеет, ничего не доказывает.
//
// Supabase поднимается снаружи (`supabase start`, пароль роли `fitserver` —
// см. Server/Tests/FitServerTests/LiveHarness.swift). Vite и Vapor-сервер
// поднимает сам Playwright, а уже запущенные переиспользует.
//
// Браузер: если задан PLAYWRIGHT_CHROME_PATH — берётся этот Chrome/Chromium,
// иначе системный Chrome (`channel: 'chrome'`). Скачивать браузер не нужно.
const chromePath = process.env.PLAYWRIGHT_CHROME_PATH
const port = Number(process.env.WEB_PORT ?? 5173)

export default defineConfig({
  testDir: 'e2e',
  fullyParallel: false,
  workers: 1,
  timeout: 60_000,
  expect: { timeout: 15_000 },
  reporter: [['list']],
  use: {
    baseURL: `http://127.0.0.1:${port}`,
    // Зона и локаль фиксируются: «сегодня» клиента считается в ней.
    timezoneId: 'Europe/Moscow',
    locale: 'ru-RU',
    ...(chromePath
      ? { launchOptions: { executablePath: chromePath } }
      : { channel: 'chrome' as const }),
  },
  globalSetup: './e2e/preflight.ts',
  webServer: [
    {
      command: 'swift run --package-path ../Server fitserver',
      url: 'http://127.0.0.1:8080/v1/content/exercises',
      reuseExistingServer: true,
      timeout: 600_000,
      env: {
        FITTRACK_ISSUER: 'http://127.0.0.1:54321/auth/v1',
        FITTRACK_DB_PASSWORD: 'fitserver',
        // Умолчание сервера — 5432, а локальный Supabase слушает 54322.
        FITTRACK_DB_PORT: '54322',
        FITTRACK_DB_TLS: 'disable',
      },
    },
    {
      command: 'npm run dev',
      url: `http://127.0.0.1:${port}`,
      env: { WEB_PORT: String(port) },
      reuseExistingServer: true,
      timeout: 60_000,
    },
  ],
})
