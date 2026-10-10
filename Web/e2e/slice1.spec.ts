import { expect, test } from '@playwright/test'

// Срез 1: вход → подготовка данных dev-кнопкой → показ тренировки дня.
test('анонимный вход, подготовка данных и состав тренировки с названиями', async ({ page }) => {
  const consoleErrors: string[] = []
  page.on('pageerror', (e) => consoleErrors.push(e.message))

  await page.goto('/')

  // Вход анонимный, без экрана логина; недели ещё нет — карточка дня пуста.
  await expect(page.getByRole('heading', { name: 'Сегодня' })).toBeVisible()
  await expect(page.getByTestId('day-not-built')).toHaveText('Неделя ещё не сгенерирована')

  await page.getByRole('button', { name: 'Подготовить тестовые данные' }).click()
  await expect(page.getByRole('status').filter({ hasText: 'Готово' })).toBeVisible()

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
