import { expect, test } from '@playwright/test'

// Срез 2: «Начать» на анонимном аккаунте → экран привязки → письмо в Mailpit →
// ссылка → привязанный аккаунт → старт тренировки → состав. Мок письма не
// используется: письмо отправляет настоящий Supabase Auth.
import { verifyLink } from './helpers'

test('привязка аккаунта по ссылке из письма и старт тренировки', async ({ page }) => {
  const email = `web-${Date.now()}-${Math.floor(Math.random() * 1e6)}@example.com`
  const consoleErrors: string[] = []
  page.on('pageerror', (e) => consoleErrors.push(e.message))

  await page.goto('/')
  await page.getByRole('button', { name: 'Подготовить тестовые данные' }).click()
  await expect(page.getByRole('status').filter({ hasText: 'Готово' })).toBeVisible()
  await expect(page.getByTestId('exercise-name').first()).toBeVisible()

  // Анонимный аккаунт: сервер отвечает unlinked_account, клиент открывает привязку.
  await page.getByRole('button', { name: 'Начать тренировку' }).click()
  await expect(page).toHaveURL(/\/link$/)
  await expect(page.getByRole('heading', { name: 'Сохранить прогресс' })).toBeVisible()
  await expect(page.getByRole('alert')).toHaveCount(0)

  await page.getByLabel('Почта').fill(email)
  await page.getByRole('button', { name: 'Отправить ссылку' }).click()
  await expect(page.getByTestId('link-sent')).toContainText(email)

  // Ссылка из письма подтверждает адрес и возвращает на сайт с сессией.
  await page.goto(await verifyLink(email))
  await expect(page.getByRole('heading', { name: 'Сегодня' })).toBeVisible()

  await page.getByRole('button', { name: 'Начать тренировку' }).click()
  await expect(page).toHaveURL(/\/workout\/[0-9a-f-]{36}$/)
  const workoutUrl = page.url()
  await expect(page.getByTestId('workout-state')).toHaveText('Идёт')

  const names = page.getByTestId('workout-exercise-name')
  await expect(names.first()).toBeVisible()
  const texts = await names.allTextContents()
  expect(texts.length).toBeGreaterThanOrEqual(3)
  for (const text of texts) expect(text).not.toMatch(/^[a-z0-9_]+$/)

  // День начат: «Начать» исчезает, «Продолжить» ведёт в ту же тренировку
  // (старт идемпотентен по дню, второй строки не появляется).
  await page.goto('/')
  await expect(page.getByRole('button', { name: 'Начать тренировку' })).toHaveCount(0)
  await page.getByRole('button', { name: 'Продолжить тренировку' }).click()
  await expect(page).toHaveURL(workoutUrl)

  await expect(page.getByRole('alert')).toHaveCount(0)
  expect(consoleErrors).toEqual([])
})
