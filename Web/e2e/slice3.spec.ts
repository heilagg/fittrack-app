import { expect, test, type Page } from '@playwright/test'
import { startLinkedWorkout } from './helpers'

// Срез 3: экран упражнения. Всё — против настоящего сервера и базы.

const counter = (page: Page) => page.getByTestId('set-counter')
const feedback = (page: Page, value: 'easy' | 'ok' | 'hard' | 'failed') => page.locator(`[data-feedback="${value}"]`)

async function counterText(page: Page): Promise<{ n: number; total: number }> {
  const text = (await counter(page).textContent()) ?? ''
  const match = /Подход (\d+) из (\d+)/.exec(text)
  if (!match) throw new Error(`не разобрать счётчик: ${text}`)
  return { n: Number(match[1]), total: Number(match[2]) }
}

test.describe('экран упражнения', () => {
  test('подход пишется на сервер, переживает перезагрузку, таймер и Wake Lock на месте', async ({ page }) => {
    const consoleErrors: string[] = []
    page.on('pageerror', (e) => consoleErrors.push(e.message))
    await startLinkedWorkout(page)

    const name = await page.getByTestId('current-exercise').textContent()
    expect(name).not.toMatch(/^[a-z0-9_]+$/)
    await expect(page.getByTestId('weight')).toHaveText(/кг|Без веса/)
    expect(await counterText(page)).toMatchObject({ n: 1 })
    await expect(page.getByTestId('wake-lock')).toBeVisible()

    const saved = page.waitForResponse((r) => r.url().includes('/sets') && r.request().method() === 'POST')
    await feedback(page, 'ok').click()
    // Мгновенно: счётчик и таймер видны сразу, без ожидания ответа.
    await expect(counter(page)).toContainText('Подход 2 из')
    await expect(page.getByTestId('rest-clock')).toContainText('Отдых')

    // Ответ сервера подтвердил подход, и перезагрузка читает его с сервера.
    expect((await saved).status()).toBe(200)
    await expect(page.getByTestId('log-failure')).toHaveCount(0)
    await page.reload()
    await expect(counter(page)).toContainText('Подход 2 из')
    expect(consoleErrors).toEqual([])
  })

  test('обрыв ответа: подход не теряется и не удваивается при повторе с тем же id', async ({ page }) => {
    await startLinkedWorkout(page)
    const before = await counterText(page)

    // Запрос ДОХОДИТ до сервера и записывается, а ответ теряется — худший случай:
    // клиент не знает, записан ли подход.
    await page.route('**/exercises/*/sets', async (route) => {
      await route.fetch()
      await route.abort('failed')
    })
    await feedback(page, 'ok').click()
    await expect(page.getByTestId('log-failure')).toContainText('Нет связи')
    // Очереди нет: следующий подход ввести нельзя.
    await expect(feedback(page, 'ok')).toBeDisabled()

    await page.unroute('**/exercises/*/sets')
    await page.getByRole('button', { name: 'Повторить' }).click()
    await expect(page.getByTestId('log-failure')).toHaveCount(0)
    await expect(counter(page)).toContainText(`Подход ${before.n + 1} из`)

    // На сервере ровно один подход, а не два.
    await page.reload()
    await expect(counter(page)).toContainText(`Подход ${before.n + 1} из`)
    const li = page.getByTestId('workout-exercises').locator('li').first()
    await expect(li).toContainText('выполнено подходов: 1')
  })

  test('упражнение проходится до конца, два «не смог» подряд завершают его досрочно', async ({ page }) => {
    await startLinkedWorkout(page)
    const first = await page.getByTestId('current-exercise').textContent()

    // Первое упражнение — все подходы «нормально».
    const { total } = await counterText(page)
    for (let i = 0; i < total; i++) {
      await feedback(page, 'ok').click()
      await expect(page.getByTestId('log-failure')).toHaveCount(0)
      if (i < total - 1) await expect(counter(page)).toContainText(`Подход ${i + 2} из`)
    }
    // Подходы кончились, и экран переходит к следующему упражнению.
    await expect(page.getByTestId('current-exercise')).not.toHaveText(first ?? '')

    // Второе: «не смог» дважды подряд — досрочное завершение (§9.3).
    const second = await page.getByTestId('current-exercise').textContent()
    await feedback(page, 'failed').click()
    await expect(counter(page)).toContainText('Подход 2 из')
    await feedback(page, 'failed').click()
    await expect(page.getByTestId('current-exercise')).not.toHaveText(second ?? '')
  })
})
