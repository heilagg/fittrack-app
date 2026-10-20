// Этап В3 против настоящих Supabase и Server: раздел «Растяжка» и
// проигрыватель (§12.2), экран «Прогресс» (§13.7), автозаминка после
// тренировки. Сессия проходится кнопкой «Пропустить»: таймер проверяет
// Vitest на поддельном времени, а здесь проверяется путь до базы и обратно.

import { expect, test, type Page } from '@playwright/test'
import { completeOnboarding, startLinkedWorkout } from './helpers'

const nav = (page: Page, name: string) =>
  page.getByRole('navigation', { name: 'Разделы' }).getByRole('link', { name }).click()

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

    const started = page.waitForResponse((r) => r.url().endsWith('/v1/stretch-sessions') && r.request().method() === 'POST')
    await templates.getByText('Утренняя мобильность').click()
    expect((await started).status()).toBe(201)
    await expect(page.getByTestId('stretch-pose')).toHaveText('Кошка-корова')
    await expect(page.getByTestId('stretch-clock')).toHaveText(/^[01]:\d\d$/)
    const finished = page.waitForResponse((r) => r.url().endsWith('/finish') && r.request().method() === 'POST')
    await skipThrough(page)
    expect((await finished).status()).toBe(200)

    await page.getByRole('link', { name: 'К растяжке' }).click()
    await expect(page.getByTestId('stretch-history').locator('li')).toHaveCount(1)
    await expect(page.getByTestId('stretch-history')).toContainText('Утренняя мобильность')

    await nav(page, 'Прогресс')
    await expect(page.getByTestId('streak')).toContainText('1')
    await expect(page.getByTestId('volume-groups').locator('li[data-group]')).toHaveCount(6)
    await expect(page.getByTestId('activity-calendar').locator('td[data-stretch="true"]')).toHaveCount(1)
    await page.getByRole('button', { name: '4 нед.' }).click()
    await expect(page.getByTestId('volume-groups').locator('li[data-group="back"] rect')).toHaveCount(4)
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
