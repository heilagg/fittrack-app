// Срез 6 против настоящих Supabase и Server: чек-ин и оверрайд, тап по дню
// недели, флаг боли и замена, правки Профиля. Календарь цикла — в cycle.spec.

import { expect, test, type Page } from '@playwright/test'
import { completeOnboarding, startLinkedWorkout, trainingDays, todayIsoWeekday } from './helpers'

const toProfile = (page: Page) =>
  page.getByRole('navigation', { name: 'Разделы' }).getByRole('link', { name: 'Профиль' }).click()
const toToday = (page: Page) =>
  page.getByRole('navigation', { name: 'Разделы' }).getByRole('link', { name: 'Сегодня' }).click()

test.describe('«Сегодня»', () => {
  test('оверрайд и чек-ин пишутся и переживают перезагрузку; «Не сегодня» — растяжка', async ({ page }) => {
    await completeOnboarding(page)
    await expect(page.getByTestId('session-kind')).toBeVisible()

    const ease = page.locator('[data-override="ease"]')
    await ease.click()
    await expect(ease).toHaveAttribute('aria-pressed', 'true')

    await page.getByText('Чек-ин', { exact: true }).click()
    await page.getByRole('group', { name: 'Энергия' }).locator('input[value="2"]').check()
    await page.getByRole('button', { name: 'Сохранить чек-ин' }).click()
    await expect(page.getByTestId('checkin-saved')).toBeVisible()

    await page.reload()
    await expect(page.locator('[data-override="ease"]')).toHaveAttribute('aria-pressed', 'true')
    await page.getByText('Чек-ин', { exact: true }).click()
    await expect(page.getByRole('group', { name: 'Энергия' }).locator('input[value="2"]')).toBeChecked()

    // «Не сегодня» заменяет день растяжкой (§10, §11.4) — это считает сервер.
    await page.locator('[data-override="rest"]').click()
    await expect(page.getByTestId('day-stretching')).toBeVisible()
    await expect(page.getByRole('button', { name: 'Начать тренировку' })).toHaveCount(0)
  })

  test('тап по другому дню недели показывает его состав из /preview', async ({ page }) => {
    await completeOnboarding(page)
    await expect(page.getByTestId('session-kind')).toBeVisible()
    // Второй тренировочный день этой недели, если он ещё впереди; иначе — любой другой день.
    const today = todayIsoWeekday()
    const other = trainingDays().find((d) => d > today) ?? (today === 7 ? 6 : today + 1)
    const preview = page.waitForRequest((r) => r.url().includes('/preview?'))
    await page.getByTestId('week-calendar').locator('> li').nth(other - 1).getByRole('button').click()
    await preview
    await expect(page.getByTestId('day-preview')).toBeVisible()
    await expect(page.getByRole('button', { name: 'Начать тренировку' })).toHaveCount(0)
    await page.getByRole('button', { name: 'К сегодняшнему дню' }).click()
    await expect(page.getByRole('button', { name: 'Начать тренировку' })).toBeVisible()
  })
})

test.describe('тренировка', () => {
  test('флаг боли: подход с pain_flag без фидбэка, «Без замены» — следующее упражнение', async ({ page }) => {
    await startLinkedWorkout(page)
    const first = await page.getByTestId('current-exercise').textContent()
    const sent = page.waitForRequest((r) => r.method() === 'POST' && r.url().endsWith('/sets'))
    await page.getByTestId('pain-button').click()
    const body = (await sent).postDataJSON() as { pain_flag: boolean; feedback?: string; actual_reps: number }
    expect(body.pain_flag).toBe(true)
    expect(body.feedback).toBeUndefined()
    expect(body.actual_reps).toBeGreaterThan(0)

    const panel = page.getByTestId('alternatives')
    await expect(panel).toHaveAttribute('data-purpose', 'pain')
    await expect(panel.getByRole('status')).toHaveCount(0)
    await panel.getByRole('button', { name: 'Без замены, дальше' }).click()
    await expect(page.getByTestId('current-exercise')).not.toHaveText(first!)
    // После перезагрузки упражнение с болью так и остаётся закрытым.
    await page.reload()
    await expect(page.getByTestId('current-exercise')).not.toHaveText(first!)
  })

  test('замена в один тап: новое упражнение, подход 1', async ({ page }) => {
    await startLinkedWorkout(page)
    const first = await page.getByTestId('current-exercise').textContent()
    await page.getByTestId('substitute-button').click()
    const panel = page.getByTestId('alternatives')
    await expect(panel).toHaveAttribute('data-purpose', 'user_choice')
    const choose = panel.getByRole('button', { name: 'Выбрать' }).first()
    await expect(choose).toBeVisible()
    const picked = await panel.getByTestId('alternative-name').first().textContent()
    const substitute = page.waitForRequest((r) => r.method() === 'POST' && r.url().endsWith('/substitute'))
    await choose.click()
    expect(((await substitute).postDataJSON() as { reason: string }).reason).toBe('user_choice')
    await expect(page.getByTestId('current-exercise')).toHaveText(picked!)
    expect(picked).not.toBe(first)
    await expect(page.getByTestId('set-counter')).toContainText('Подход 1 из')
  })
})

test.describe('картинки упражнений (§6.5)', () => {
  test('кадры с /illustrations грузятся; без картинки — заглушка', async ({ page }) => {
    // Файлы раздаёт Vite из public/: картинка с сопоставлением отдаётся, ненайденная — нет.
    const ok = await page.request.get('/illustrations/plank_bw/start.jpg')
    expect(ok.status()).toBe(200)
    expect(ok.headers()['content-type']).toContain('image/jpeg')

    await startLinkedWorkout(page)
    const figure = page.getByTestId('illustration')
    const placeholder = page.getByTestId('illustration-placeholder')
    await expect(figure.or(placeholder)).toBeVisible()
    if (await figure.count()) {
      const loaded = await figure.locator('img').first().evaluate((img: HTMLImageElement) =>
        img.complete ? img.naturalWidth : new Promise<number>((r) => (img.onload = () => r(img.naturalWidth))))
      expect(loaded).toBeGreaterThan(0)
    }
  })
})

test.describe('Профиль', () => {
  test('инвентарь: правка строки по умолчанию, /rebuild с equipment_changed', async ({ page }) => {
    await completeOnboarding(page)
    await toProfile(page)
    await page.getByTestId('equipment-link').click()
    await page.getByLabel(/Гантели/).fill('4 6 8 10')
    const rebuild = page.waitForRequest(
      (r) => r.method() === 'POST' && r.url().includes('/rebuild') && r.postDataJSON()?.cause === 'equipment_changed',
    )
    await page.getByRole('button', { name: 'Сохранить инвентарь' }).click()
    await rebuild
    await expect(page.getByTestId('equipment-saved')).toBeVisible()
    await page.reload()
    await expect(page.getByLabel(/Гантели/)).toHaveValue('4, 6, 8, 10')
  })

  test('ограничения и личные данные сохраняются', async ({ page }) => {
    await completeOnboarding(page)
    await toProfile(page)
    await page.getByTestId('restrictions-link').click()
    await page.locator('[data-joint="knee"]').selectOption('avoid')
    await page.getByRole('button', { name: 'Сохранить' }).click()
    await expect(page.getByTestId('restrictions-saved')).toBeVisible()
    await page.reload()
    await expect(page.locator('[data-joint="knee"]')).toHaveValue('avoid')
    // Снятие: строка не удаляется, а снимается — на экране её больше нет.
    await page.locator('[data-joint="knee"]').selectOption('')
    await page.getByRole('button', { name: 'Сохранить' }).click()
    await expect(page.getByTestId('restrictions-saved')).toBeVisible()
    await page.reload()
    await expect(page.locator('[data-joint="knee"]')).toHaveValue('')

    await toProfile(page)
    await page.getByTestId('personal-link').click()
    // По умолчанию 45 (§3.1): неизменённое поле не уходит, поэтому — 60.
    await expect(page.getByLabel('Длительность тренировки, мин')).toHaveValue('45')
    await page.getByLabel('Длительность тренировки, мин').fill('60')
    const patch = page.waitForRequest((r) => r.method() === 'PATCH' && r.url().endsWith('/v1/profile'))
    await page.getByRole('button', { name: 'Сохранить' }).click()
    expect((await patch).postDataJSON()).toEqual({ session_minutes: 60 })
    await expect(page.getByTestId('personal-saved')).toBeVisible()
    await page.reload()
    await expect(page.getByLabel('Длительность тренировки, мин')).toHaveValue('60')
    await toToday(page)
    await expect(page.getByRole('heading', { name: 'Сегодня' })).toBeVisible()
  })
})
