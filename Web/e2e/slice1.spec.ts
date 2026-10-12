import { expect, test } from '@playwright/test'
import { completeOnboarding } from './helpers'

// Срез 1 на настоящем онбординге (срез 5): вход → онбординг → показ тренировки дня.
test('анонимный вход, онбординг и состав тренировки с названиями', async ({ page }) => {
  const consoleErrors: string[] = []
  page.on('pageerror', (e) => consoleErrors.push(e.message))

  await completeOnboarding(page)

  // Сегодняшний день входит в набор дней, поэтому состав собран.
  const names = page.getByTestId('exercise-name')
  await expect(names.first()).toBeVisible()
  const texts = await names.allTextContents()
  expect(texts.length).toBeGreaterThanOrEqual(3)
  // Названия пришли из /v1/content/exercises, а не показаны слагами.
  for (const text of texts) expect(text).not.toMatch(/^[a-z0-9_]+$/)

  await expect(page.getByRole('alert')).toHaveCount(0)
  expect(consoleErrors).toEqual([])
})
