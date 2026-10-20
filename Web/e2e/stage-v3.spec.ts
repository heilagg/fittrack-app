// Этап В3 против настоящих Supabase и Server: раздел «Растяжка» и
// проигрыватель (§12.2), экран «Прогресс» (§13.7), автозаминка после
// тренировки. Сессия проходится кнопкой «Пропустить»: таймер проверяет
// Vitest на поддельном времени, а здесь проверяется путь до базы и обратно.

import { expect, test, type Page } from '@playwright/test'
import { completeOnboarding, startLinkedWorkout } from './helpers'

const nav = (page: Page, name: string) =>
  page.getByRole('navigation', { name: 'Разделы' }).getByRole('link', { name }).click()

/**
 * Телефон: на двенадцати неделях страница не шире экрана, три кнопки окна — в
 * одном ряду. Объём у нового пользователя нулевой (калибровочные подходы в
 * `неделя[m]` не входят, §3.1), поэтому настоящий ответ `/v1/progress`
 * дополняется в браузере самыми длинными подписями — «13,5» в каждой клетке.
 */
async function checkProgressOnPhone(page: Page) {
  await page.route('**/v1/progress?*', async (route) => {
    const response = await route.fetch()
    const body = (await response.json()) as { weeks: { groups: Record<string, number> }[] }
    for (const week of body.weeks) for (const group of Object.keys(week.groups)) week.groups[group] = 13.5
    await route.fulfill({ response, json: body })
  })
  await page.setViewportSize({ width: 393, height: 852 })
  // Без анимации смены фона: стили сравниваются сразу после клика.
  await page.emulateMedia({ reducedMotion: 'reduce' })
  await page.goto('/progress')
  await expect(page.getByTestId('volume-groups').locator('li[data-group]')).toHaveCount(6)
  await page.getByRole('button', { name: '4 нед.' }).click()
  await expect(page.getByTestId('volume-groups').locator('li[data-group="back"] rect')).toHaveCount(4)
  await page.getByRole('button', { name: '12 нед.' }).click()
  await expect(page.getByTestId('volume-groups').locator('li[data-group="back"] rect')).toHaveCount(12)
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(393)
  // Клетка подписи — ровно под своим столбцом: ширины клеток равны, сколько бы ни занимал текст.
  const widths = await page.getByTestId('volume-groups').locator('li[data-group="back"] [data-testid="week-labels"] li')
    .evaluateAll((cells) => cells.map((c) => c.getBoundingClientRect().width))
  expect(Math.max(...widths) - Math.min(...widths)).toBeLessThan(1)
  const tops = await page.getByRole('group', { name: 'Окно' }).getByRole('button').evaluateAll(
    (buttons) => buttons.map((b) => Math.round(b.getBoundingClientRect().top)))
  expect(new Set(tops).size).toBe(1)
  // Выбранное окно залито: фон кнопки не тот, что у невыбранных.
  const window = page.getByRole('group', { name: 'Окно' })
  const unpressed = await window.getByRole('button', { name: '8 нед.' }).evaluate((b) => getComputedStyle(b).backgroundColor)
  await expect(window.getByRole('button', { name: '4 нед.' })).toHaveCSS('background-color', unpressed)
  await expect(window.getByRole('button', { name: '12 нед.' })).not.toHaveCSS('background-color', unpressed)
  // Сегодня — в рамке, а не только другим цветом.
  const today = page.getByTestId('activity-calendar').locator('td[aria-current="date"]')
  expect(await today.evaluate((td) => getComputedStyle(td).outlineStyle)).toBe('solid')
  expect(await page.getByTestId('activity-calendar').locator('td:not([aria-current])').first()
    .evaluate((td) => getComputedStyle(td).outlineStyle)).toBe('none')
}

async function skipThrough(page: Page) {
  const done = page.getByTestId('stretch-done')
  // После последнего «Пропустить» кнопка исчезает, пока идёт `finish`: клик с
  // коротким ожиданием, а не обычные 60 секунд на кнопку, которой уже нет.
  for (let i = 0; i < 60 && !(await done.isVisible()); i++) {
    await page.getByRole('button', { name: 'Пропустить' }).click({ timeout: 3000 }).catch(() => undefined)
  }
  await expect(done).toBeVisible()
}

test.describe('растяжка и прогресс', () => {
  test('восемь шаблонов, один предложен; сессия пишется и попадает в историю и стрик', async ({ page }) => {
    await completeOnboarding(page)
    await nav(page, 'Растяжка')
    const templates = page.getByTestId('stretch-templates')
    await expect(templates.locator('li')).toHaveCount(8)
    await expect(page.getByTestId('suggested')).toHaveCount(1)
    await expect(page.getByTestId('stretch-history-empty')).toBeVisible()
    // Нажимается вся строка шаблона, а не только текст.
    for (const row of await templates.locator('li').all()) {
      const [li, link] = [await row.boundingBox(), await row.getByRole('link').boundingBox()]
      expect(link!.width).toBeGreaterThanOrEqual(li!.width - 1)
    }

    const started = page.waitForResponse((r) => r.url().endsWith('/v1/stretch-sessions') && r.request().method() === 'POST')
    await templates.getByText('Утренняя мобильность').click()
    expect((await started).status()).toBe(201)
    await expect(page.getByTestId('stretch-pose')).toHaveText('Кошка-корова')
    await expect(page.getByTestId('stretch-clock')).toHaveText(/^[01]:\d\d$/)
    // Крупные цифры одной ширины: токен --type-reps-size и tabular-nums.
    await expect(page.getByTestId('stretch-clock')).toHaveCSS('font-size', '46px')
    await expect(page.getByTestId('stretch-clock')).toHaveCSS('font-variant-numeric', 'tabular-nums')
    const finished = page.waitForResponse((r) => r.url().endsWith('/finish') && r.request().method() === 'POST')
    await skipThrough(page)
    expect((await finished).status()).toBe(200)

    await page.getByRole('link', { name: 'К растяжке' }).click()
    await expect(page.getByTestId('stretch-history').locator('li')).toHaveCount(1)
    await expect(page.getByTestId('stretch-history')).toContainText('Утренняя мобильность')

    await nav(page, 'Прогресс')
    await expect(page.getByTestId('streak')).toContainText('1')
    // Силовых нет — вместо шести нулевых графиков пояснение.
    await expect(page.getByTestId('volume-empty')).toBeVisible()
    await expect(page.getByTestId('volume-groups')).toHaveCount(0)
    await expect(page.getByTestId('activity-calendar').locator('td[data-stretch="true"]')).toHaveCount(1)
    await checkProgressOnPhone(page)
  })

  test('плеер по ссылке до онбординга — ссылка на настройку, а не повтор', async ({ page }) => {
    await page.goto('/stretch/play/morning_mobility')
    const link = page.getByTestId('stretch-onboarding')
    await expect(link).toBeVisible()
    await expect(page.getByRole('button', { name: 'Повторить' })).toHaveCount(0)
    expect((await link.boundingBox())!.height).toBeGreaterThanOrEqual(44)
    // Ссылка выглядит кнопкой: без подчёркивания, текст по центру.
    await expect(link).toHaveCSS('text-decoration-line', 'none')
    const offset = await link.evaluate((a) => {
      const range = document.createRange()
      range.selectNodeContents(a)
      const [text, box] = [range.getBoundingClientRect(), a.getBoundingClientRect()]
      return Math.abs(text.left + text.width / 2 - (box.left + box.width / 2))
    })
    expect(offset).toBeLessThan(2)
    await link.click()
    await expect(page).toHaveURL(/\/onboarding$/)
  })

  test('после тренировки — заминка из ответа /finish, сессия без шаблона', async ({ page }) => {
    await startLinkedWorkout(page)
    await page.locator('[data-feedback="ok"]').click()
    const finished = page.waitForResponse((r) => r.url().includes('/v1/workouts/') && r.url().endsWith('/finish'))
    await page.getByRole('button', { name: 'Завершить тренировку' }).click()
    const body = (await (await finished).json()) as { cooldown: { pose: string; seconds: number }[] }
    test.info().annotations.push({ type: 'cooldown', description: String(body.cooldown.length) })
    if (body.cooldown.length === 0) {
      await expect(page.getByTestId('cooldown-offer')).toHaveCount(0)
      return
    }
    const offer = page.getByRole('link', { name: 'Начать заминку' })
    expect((await offer.boundingBox())!.height).toBeGreaterThanOrEqual(44)
    const started = page.waitForRequest((r) => r.url().endsWith('/v1/stretch-sessions') && r.method() === 'POST')
    await page.getByRole('link', { name: 'Начать заминку' }).click()
    const sent = (await started).postDataJSON() as { kind: string; template_slug?: string }
    expect(sent.kind).toBe('static_cooldown')
    expect(sent.template_slug).toBeUndefined()
    await expect(page.getByTestId('stretch-player')).toBeVisible()
    await skipThrough(page)
  })
})
