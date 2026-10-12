import { defineConfig } from '@playwright/test'
import base from './playwright.config'

// Скриншоты основных экранов для просмотра дизайна (не тест): `npm run screens`.
// Тот же стек, что у e2e, — настоящие Supabase и Server; кадры — в
// design-screens/ (в .gitignore), ширина 390 px.
export default defineConfig({
  ...base,
  testMatch: '*.screens.ts',
  use: {
    ...base.use,
    viewport: { width: 390, height: 844 },
    deviceScaleFactor: 2,
  },
})
