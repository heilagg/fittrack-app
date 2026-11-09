import { expect, test, type Page } from '@playwright/test'
import { startLinkedWorkout, tapFeedback } from './helpers'

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
    // Подпись снаряда (§6.6, §13.2) — ровно то, что отдал сервер: строка через
    // запятую, а у упражнения без снаряда строки нет.
    const content = (await (await page.request.get('/v1/content/exercises')).json()) as {
      name: string
      equipment_labels: string[]
    }[]
    const labels = content.find((c) => c.name === name)?.equipment_labels
    expect(labels, 'упражнение есть в /v1/content/exercises').toBeDefined()
    if (labels!.length > 0) await expect(page.getByTestId('equipment-line')).toHaveText(labels!.join(', '))
    else await expect(page.getByTestId('equipment-line')).toHaveCount(0)
    // Весовое упражнение в калибровке без базовой линии спрашивает вес (§9.8).
    // Весовое упражнение в калибровке без базовой линии спрашивает вес (§9.8);
    // без веса — «Собственный вес» или «Резинка» (§13.2).
    await expect(page.getByTestId('weight')).toHaveText(/кг|Собственный вес|Резинка|Введите вес/)
    // Над подходом — цель, счётчика повторов нет (§13.2).
    await expect(page.getByTestId('target')).toHaveText(/^\d+ повтор/)
    expect(await counterText(page)).toMatchObject({ n: 1 })
    await expect(page.getByTestId('wake-lock')).toBeVisible()

    const saved = page.waitForResponse((r) => r.url().includes('/sets') && r.request().method() === 'POST')
    await tapFeedback(page, 'ok')
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

    // Что именно ушло на сервер: повтор обязан нести тот же клиентский id, а не
    // полагаться на то, что сервер как-нибудь свёл две строки в одну.
    const sentIds: string[] = []
    page.on('request', (request) => {
      if (request.method() === 'POST' && request.url().includes('/sets')) {
        sentIds.push((request.postDataJSON() as { id: string }).id)
      }
    })

    // Запрос ДОХОДИТ до сервера и записывается, а ответ теряется — худший случай:
    // клиент не знает, записан ли подход.
    await page.route('**/exercises/*/sets', async (route) => {
      await route.fetch()
      await route.abort('failed')
    })
    await tapFeedback(page, 'ok')
    await expect(page.getByTestId('log-failure')).toContainText('Нет связи')
    // Очереди нет: следующий подход ввести нельзя.
    await expect(feedback(page, 'ok')).toBeDisabled()
    await expect(page.getByTestId('set-done')).toHaveCount(0)

    await page.unroute('**/exercises/*/sets')
    await page.getByRole('button', { name: 'Повторить' }).click()
    await expect(page.getByTestId('log-failure')).toHaveCount(0)
    await expect(counter(page)).toContainText(`Подход ${before.n + 1} из`)

    expect(sentIds).toHaveLength(2)
    expect(sentIds[1]).toBe(sentIds[0])

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
      await tapFeedback(page, 'ok')
      await expect(page.getByTestId('log-failure')).toHaveCount(0)
      if (i < total - 1) await expect(counter(page)).toContainText(`Подход ${i + 2} из`)
    }
    // Подходы кончились, и экран переходит к следующему упражнению.
    await expect(page.getByTestId('current-exercise')).not.toHaveText(first ?? '')

    // Второе: «не смог» дважды подряд — досрочное завершение (§9.3).
    const second = await page.getByTestId('current-exercise').textContent()
    await tapFeedback(page, 'failed')
    await expect(counter(page)).toContainText('Подход 2 из')
    await tapFeedback(page, 'failed')
    await expect(page.getByTestId('current-exercise')).not.toHaveText(second ?? '')
  })

  test('вес числом: вне лестницы сервер пишет ближайшую ступень, и экран показывает записанное', async ({ page }) => {
    await startLinkedWorkout(page)
    const input = page.getByTestId('weight-input')
    test.skip((await input.count()) === 0, 'первое упражнение без веса — проверять нечего')
    // 21 кг нет ни у гантелей посева (20, 24), ни у штанги (20 + пары блинов от 1.25):
    // ближайшая ступень — 20.
    await input.fill('21')
    const saved = page.waitForResponse((r) => r.url().includes('/sets') && r.request().method() === 'POST')
    await page.getByTestId('set-done').click()
    await page.locator('[data-feedback="ok"]').click()
    const response = await saved
    expect(response.status()).toBe(200)
    const body = (await response.json()) as { set: { actual_kg: number } }
    expect(body.set.actual_kg).toBe(20)
    await expect(page.getByTestId('recorded-weight')).toContainText('Записано 20 кг')
  })

  test('подход в два шага: «Подход выполнен», затем оценка; «Не смог» пишет ответ на вопрос (§13.2)', async ({ page }) => {
    await startLinkedWorkout(page)
    const weight = page.getByTestId('weight-input')
    if ((await weight.count()) > 0 && (await weight.inputValue()) === '') await weight.fill('20')
    const target = Number(/^(\d+)/.exec((await page.getByTestId('target').textContent()) ?? '')![1])

    // До «Подход выполнен» оценок нет; после — отдых уже идёт, а запроса ещё нет.
    await expect(page.locator('[data-feedback]')).toHaveCount(0)
    const posts: { feedback: string; actual_reps: number; completed_at: string }[] = []
    page.on('request', (r) => {
      if (r.method() === 'POST' && r.url().includes('/sets')) posts.push(r.postDataJSON())
    })
    await page.getByTestId('set-done').click()
    await expect(page.getByTestId('rest-clock')).toContainText('Отдых')
    await expect(page.locator('[data-feedback]')).toHaveCount(4)
    expect(posts).toEqual([])

    const first = page.waitForResponse((r) => r.url().includes('/sets') && r.request().method() === 'POST')
    await page.locator('[data-feedback="ok"]').click()
    expect((await first).status()).toBe(200)
    expect(posts[0]).toMatchObject({ feedback: 'ok', actual_reps: target })

    await expect(page.getByTestId('set-done')).toBeEnabled()
    await page.getByTestId('set-done').click()
    await page.locator('[data-feedback="failed"]').click()
    await page.getByTestId('failed-reps-input').fill('3')
    const second = page.waitForResponse((r) => r.url().includes('/sets') && r.request().method() === 'POST')
    await page.getByRole('button', { name: 'Записать' }).click()
    expect((await second).status()).toBe(200)
    expect(posts[1]).toMatchObject({ feedback: 'failed', actual_reps: 3 })
    expect(posts).toHaveLength(2)
  })
})

