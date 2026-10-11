import { expect, type Page } from '@playwright/test'

const MAILPIT = 'http://127.0.0.1:54324'

/** Ссылка подтверждения из письма, отправленного настоящим Supabase Auth. */
export async function verifyLink(email: string): Promise<string> {
  for (let attempt = 0; attempt < 30; attempt++) {
    const found = await fetch(`${MAILPIT}/api/v1/search?query=${encodeURIComponent(`to:${email}`)}`)
    const list = (await found.json()) as { messages: { ID: string }[] }
    const first = list.messages[0]
    if (first) {
      const message = (await (await fetch(`${MAILPIT}/api/v1/message/${first.ID}`)).json()) as { HTML: string }
      const href = /href="([^"]*\/auth\/v1\/verify[^"]*)"/.exec(message.HTML)?.[1]
      if (href) return href.replaceAll('&amp;', '&')
    }
    await new Promise((resolve) => setTimeout(resolve, 500))
  }
  throw new Error(`Письмо для ${email} не пришло в Mailpit`)
}

/**
 * Весь путь до начатой тренировки: данные dev-кнопкой, привязка по письму,
 * «Начать». Возвращает адрес экрана тренировки.
 */
export async function startLinkedWorkout(page: Page): Promise<string> {
  const email = `web-${Date.now()}-${Math.floor(Math.random() * 1e6)}@example.com`
  await page.goto('/')
  await page.getByRole('button', { name: 'Подготовить тестовые данные' }).click()
  await expect(page.getByRole('status').filter({ hasText: 'Готово' })).toBeVisible()
  await page.getByRole('button', { name: 'Начать тренировку' }).click()
  await expect(page).toHaveURL(/\/link$/)
  await page.getByLabel('Почта').fill(email)
  await page.getByRole('button', { name: 'Отправить ссылку' }).click()
  await expect(page.getByTestId('link-sent')).toContainText(email)
  await page.goto(await verifyLink(email))
  await expect(page.getByRole('heading', { name: 'Сегодня' })).toBeVisible()
  await page.getByRole('button', { name: 'Начать тренировку' }).click()
  await expect(page).toHaveURL(/\/workout\/[0-9a-f-]{36}$/)
  return page.url()
}
