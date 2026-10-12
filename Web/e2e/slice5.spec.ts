import { expect, test, type Page, type Request } from '@playwright/test'
import {
  basics,
  completeOnboarding,
  disclaimer,
  equipment,
  experience,
  finishOnboarding,
  goal,
  parq,
  restrictions,
  weekdays,
} from './helpers'

// Срез 5: онбординг. Всё — против настоящего Supabase и сервера: прямые записи
// идут в настоящие таблицы под RLS, PATCH — на настоящий /v1.

const step = (page: Page, n: number) => page.getByTestId(`step-${n}`)

/** Тела запросов, ушедших в таблицу Supabase (прямые записи §20.6). */
function directWrites(page: Page, table: string): unknown[] {
  const bodies: unknown[] = []
  page.on('request', (r: Request) => {
    if (r.method() === 'POST' && r.url().includes(`/rest/v1/${table}`)) bodies.push(r.postDataJSON())
  })
  return bodies
}

function profilePatches(page: Page): Record<string, unknown>[] {
  const bodies: Record<string, unknown>[] = []
  page.on('request', (r: Request) => {
    if (r.method() === 'PATCH' && r.url().endsWith('/v1/profile')) bodies.push(r.postDataJSON() as Record<string, unknown>)
  })
  return bodies
}

test.describe('онбординг', () => {
  test('весь путь: профиль, PAR-Q, инвентарь, неделя; dev-кнопки нет', async ({ page }) => {
    const errors: string[] = []
    page.on('pageerror', (e) => errors.push(e.message))
    const patches = profilePatches(page)
    const parqRows = directWrites(page, 'parq_responses')
    const equipmentRows = directWrites(page, 'equipment_profiles')
    const weights = directWrites(page, 'body_weight_entries')

    await completeOnboarding(page)

    await expect(page.getByTestId('exercise-name').first()).toBeVisible()
    await expect(page.getByRole('button', { name: 'Подготовить тестовые данные' })).toHaveCount(0)

    // Пустой PATCH создал строку до PAR-Q, затем поля пришли своими шагами.
    expect(patches[0]).toEqual({})
    expect(patches.slice(1).map((p) => Object.keys(p).sort())).toEqual([
      ['birth_year', 'height_cm', 'sex_at_birth'],
      ['experience_level'],
      ['goal'],
      ['training_weekdays'],
      ['cycle', 'cycle_tracking'],
    ])
    expect(parqRows).toHaveLength(1)
    expect(parqRows[0]).toMatchObject({ has_red_flag: false, acknowledged: false })
    expect(equipmentRows).toHaveLength(1)
    expect(equipmentRows[0]).toMatchObject({ name: 'Зал', is_default: true, barbell_kg: 20, bench: 'adjustable' })
    expect(weights[0]).toMatchObject({ weight_kg: 64.5, source: 'manual' })
    expect(errors).toEqual([])
  })

  test('прерывание: перезагрузка на шаге 6 продолжает с шага 6, а не с начала', async ({ page }) => {
    await page.goto('/')
    await disclaimer(page)
    await parq(page)
    await basics(page)
    await experience(page)
    await goal(page)
    await expect(step(page, 6)).toBeVisible()

    await page.reload()
    // Экран вычислен из null в GET /v1/profile: поля 3–5 заполнены, дней нет.
    await expect(step(page, 6)).toBeVisible()
    await weekdays(page)
    await expect(step(page, 7)).toBeVisible()
  })

  test('is_complete равен наличию инвентаря: без него — шаг 7, с ним — «Сегодня»', async ({ page }) => {
    await page.goto('/')
    await disclaimer(page)
    await parq(page)
    await basics(page)
    await experience(page)
    await goal(page)
    await weekdays(page)
    await expect(step(page, 7)).toBeVisible()

    // Четыре поля заполнены, инвентаря нет: сервер говорит is_complete=false.
    const incomplete = page.waitForResponse((r) => r.url().endsWith('/v1/profile') && r.request().method() === 'GET')
    await page.reload()
    expect(((await (await incomplete).json()) as { is_complete: boolean }).is_complete).toBe(false)
    await expect(step(page, 7)).toBeVisible()

    await equipment(page, 'Дома с гантелями')
    await expect(step(page, 8)).toBeVisible()
    const complete = page.waitForResponse((r) => r.url().endsWith('/v1/profile') && r.request().method() === 'GET')
    await page.goto('/')
    expect(((await (await complete).json()) as { is_complete: boolean }).is_complete).toBe(true)
  })

  test('прерывание после шага 7: человек попадает на «Сегодня» и собирает неделю кнопкой', async ({ page }) => {
    await page.goto('/')
    await disclaimer(page)
    await parq(page)
    await basics(page)
    await experience(page)
    await goal(page)
    await weekdays(page)
    await equipment(page)
    await expect(step(page, 8)).toBeVisible()

    await page.goto('/')
    await expect(page.getByRole('heading', { name: 'Сегодня' })).toBeVisible()
    await expect(page.getByTestId('day-not-built')).toHaveText('Неделя ещё не сгенерирована')
    await page.getByRole('button', { name: 'Собрать неделю' }).click()
    await expect(page.getByTestId('exercise-name').first()).toBeVisible()
  })

  test('красный флаг: рекомендация, запись только после подтверждения, не блокирует', async ({ page }) => {
    const parqRows = directWrites(page, 'parq_responses')
    await page.goto('/')
    await disclaimer(page)
    await parq(page, [5])
    await expect(page.getByRole('button', { name: 'Я прочитал(а) рекомендацию' })).toBeVisible()
    expect(parqRows).toHaveLength(0)

    // Не подтвердил и ушёл: строки нет, значит экран 1 покажется снова.
    await page.reload()
    await expect(step(page, 1)).toBeVisible()
    await disclaimer(page)
    await parq(page, [5])
    await page.getByRole('button', { name: 'Я прочитал(а) рекомендацию' }).click()
    await expect(step(page, 3)).toBeVisible()
    expect(parqRows).toHaveLength(1)
    expect(parqRows[0]).toMatchObject({ has_red_flag: true, acknowledged: true })
    expect((parqRows[0] as { answers: Record<string, boolean> }).answers.q5).toBe(true)
  })

  test('мужской профиль: шага цикла нет, ограничения пишутся строками', async ({ page }) => {
    const restrictionRows = directWrites(page, 'user_restrictions')
    await page.goto('/')
    await disclaimer(page)
    await parq(page)
    await basics(page, 'male')
    await experience(page)
    await goal(page)
    await weekdays(page)
    await equipment(page, 'Дома без железа')
    await restrictions(page, { knee: 'avoid', shoulder: 'careful' })
    await expect(step(page, 9)).toHaveCount(0)
    await finishOnboarding(page)

    expect(restrictionRows).toHaveLength(1)
    const rows = restrictionRows[0] as { joint: string; severity: string }[]
    expect(rows.map((r) => `${r.joint}:${r.severity}`).sort()).toEqual(['knee:avoid', 'shoulder:careful'])
  })

  test('цикл: «Не сейчас» пишет declined, а «Да» без контрацепции — режим фаз и period_start', async ({ page }) => {
    const patches = profilePatches(page)
    await page.goto('/')
    await disclaimer(page)
    await parq(page)
    await basics(page, 'female')
    await experience(page)
    await goal(page)
    await weekdays(page)
    await equipment(page)
    await restrictions(page)
    await expect(step(page, 9)).toBeVisible()
    await page.getByLabel('Не сейчас').check()
    await next(page)
    await finishOnboarding(page)
    expect(patches.at(-1)).toEqual({
      cycle_tracking: 'off',
      cycle: { phase_mode: 'no_phases', no_phase_reason: 'declined' },
    })

    // Профиль «Да»: отдельный пользователь.
    const second = await page.context().browser()!.newContext({ timezoneId: 'Europe/Moscow', locale: 'ru-RU' })
    const p2 = await second.newPage()
    const cycleEvents = directWrites(p2, 'cycle_events')
    const patches2 = profilePatches(p2)
    await p2.goto('/')
    await disclaimer(p2)
    await parq(p2)
    await basics(p2, 'female')
    await experience(p2)
    await goal(p2)
    await weekdays(p2)
    await equipment(p2)
    await restrictions(p2)
    await p2.getByLabel('Да', { exact: true }).first().check()
    await p2.locator('input[name="contraception"][value="no"]').check()
    await p2.getByLabel('Дата начала последней менструации').fill('2026-10-01')
    await p2.getByLabel('Обычная длина цикла, дней').fill('28')
    await p2.getByRole('button', { name: 'Далее' }).click()
    await finishOnboarding(p2)
    expect(patches2.at(-1)).toEqual({
      cycle_tracking: 'manual',
      cycle: { phase_mode: 'phases', typical_cycle_length_days: 28 },
    })
    expect(cycleEvents).toHaveLength(1)
    expect(cycleEvents[0]).toMatchObject({ kind: 'period_start', occurred_on: '2026-10-01', source: 'manual' })
    await second.close()
  })
})

async function next(page: Page) {
  await page.getByRole('button', { name: 'Далее' }).click()
}
