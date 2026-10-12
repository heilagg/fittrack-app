// Календарь цикла (SPEC §11.6, §19.2 п.27) против настоящих Supabase и Server.
//
// Каждый тест — своя анонимная пользовательница, прошедшая онбординг с ответом
// на шаг 9. Отметки ставятся тапом по дню, как у пользовательницы; только для
// режима `low_confidence` история из четырёх начал пишется напрямую в
// `cycle_events` — так же, как её пишет клиент (§20.6), но без четырёх
// пролистываний сетки.

import { expect, test, type Page } from '@playwright/test'
import { basics, disclaimer, equipment, experience, finishOnboarding, goal, parq, restrictions, weekdays } from './helpers'

const SUPABASE = 'http://127.0.0.1:54321'
const ANON = process.env.VITE_SUPABASE_ANON_KEY ?? 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH'

/** Дата «сегодня + offset» в зоне конфига Playwright, `YYYY-MM-DD`. */
function moscow(offset = 0): string {
  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Europe/Moscow' })
  const [y, m, d] = today.split('-').map(Number) as [number, number, number]
  return new Date(Date.UTC(y, m - 1, d + offset)).toISOString().slice(0, 10)
}

type CycleAnswer =
  | { kind: 'phases'; periodStart?: string; regularity?: 'regular' | 'variable' | 'irregular' }
  | { kind: 'no' }
  | { kind: 'not_now' }
  | { kind: 'contraception' }

async function onboard(page: Page, cycle: CycleAnswer) {
  await page.goto('/')
  await disclaimer(page)
  await parq(page)
  await basics(page, 'female')
  await experience(page)
  await goal(page)
  await weekdays(page)
  await equipment(page)
  await restrictions(page)
  await expect(page.getByTestId('step-9')).toBeVisible()
  if (cycle.kind === 'no') await page.getByLabel('Нет', { exact: true }).first().check()
  if (cycle.kind === 'not_now') await page.getByLabel('Не сейчас').check()
  if (cycle.kind === 'phases' || cycle.kind === 'contraception') {
    await page.getByLabel('Да', { exact: true }).first().check()
    await page.locator(`input[name="contraception"][value="${cycle.kind === 'phases' ? 'no' : 'yes'}"]`).check()
  }
  if (cycle.kind === 'phases') {
    if (cycle.periodStart) await page.getByLabel('Дата начала последней менструации').fill(cycle.periodStart)
    if (cycle.regularity) await page.getByLabel('Регулярность').selectOption(cycle.regularity)
  }
  await page.getByRole('button', { name: 'Далее' }).click()
  await finishOnboarding(page)
}

async function openCalendar(page: Page) {
  await page.getByRole('navigation', { name: 'Разделы' }).getByRole('link', { name: 'Профиль' }).click()
  await page.getByTestId('cycle-calendar-link').click()
  await expect(page.getByTestId('cycle-month')).toBeVisible()
}

/** День сетки; если он в прошлом месяце — листает назад. */
async function day(page: Page, date: string) {
  const cell = page.locator(`.month-day[data-date="${date}"]`)
  for (let i = 0; i < 4 && (await cell.count()) === 0; i++) {
    await page.getByRole('button', { name: 'Предыдущий месяц' }).click()
    await expect(page.getByTestId('cycle-month')).toBeVisible()
  }
  return cell
}

async function openDay(page: Page, date: string) {
  await (await day(page, date)).click()
  const panel = page.getByTestId('day-panel')
  await expect(panel).toHaveAttribute('data-date', date)
  return panel
}

/** Ждёт `/rebuild` с причиной события цикла — после каждой записи он обязателен. */
function rebuildAfter(page: Page) {
  return page.waitForRequest(
    (r) => r.method() === 'POST' && r.url().includes('/rebuild') && r.postDataJSON()?.cause === 'cycle_event_added',
  )
}

test.describe('календарь цикла', () => {
  test('отметка начала месячных: запись, /rebuild, день отмечен на сетке', async ({ page }) => {
    await onboard(page, { kind: 'phases', periodStart: moscow(-20) })
    // Ноль измеренных циклов при регулярности по умолчанию — уверенность 0.3,
    // фаза называется: карточка на «Сегодня» с текстом сервера (§11.6).
    await expect(page.getByTestId('phase-card')).toBeVisible()
    await expect(page.getByTestId('phase-feeling')).not.toBeEmpty()
    await openCalendar(page)
    const target = moscow(-2)
    const panel = await openDay(page, target)
    const rebuild = rebuildAfter(page)
    await panel.getByRole('button', { name: 'Начались месячные' }).click()
    await rebuild
    await expect(await day(page, target)).toHaveAttribute('data-period', 'marked')
  })

  test('правка последнего события: перенос даты переносит отметку', async ({ page }) => {
    const first = moscow(-20)
    const moved = moscow(-19)
    await onboard(page, { kind: 'phases', periodStart: first })
    await openCalendar(page)
    const panel = await openDay(page, first)
    const row = panel.getByTestId('mark-editable')
    await row.getByLabel('Перенести на').fill(moved)
    const rebuild = rebuildAfter(page)
    await row.getByRole('button', { name: 'Перенести' }).click()
    await rebuild
    await expect(page.locator(`.month-day[data-date="${moved}"]`)).toHaveAttribute('data-period', 'marked')
    await expect(page.locator(`.month-day[data-date="${first}"]`)).toHaveAttribute('data-period', 'none')
  })

  test('старое событие только для просмотра, править можно последнее', async ({ page }) => {
    const old = moscow(-30)
    await onboard(page, { kind: 'phases', periodStart: old })
    await openCalendar(page)
    const fresh = moscow(-1)
    const panel = await openDay(page, fresh)
    const rebuild = rebuildAfter(page)
    await panel.getByRole('button', { name: 'Начались месячные' }).click()
    await rebuild
    await expect(panel.getByTestId('mark-editable')).toBeVisible()

    const oldPanel = await openDay(page, old)
    await expect(oldPanel.getByTestId('mark-readonly')).toContainText('Только просмотр')
    await expect(oldPanel.getByRole('button', { name: 'Удалить' })).toHaveCount(0)
    await expect(oldPanel.getByRole('button', { name: 'Перенести' })).toHaveCount(0)
  })

  test('режимы скрытия: «Нет», «Не сейчас» и контрацепция — «Цикл выключен»', async ({ browser }) => {
    for (const [cycle, offer] of [
      [{ kind: 'no' }, false],
      [{ kind: 'not_now' }, true],
      [{ kind: 'contraception' }, false],
    ] as [CycleAnswer, boolean][]) {
      const context = await browser.newContext({ timezoneId: 'Europe/Moscow', locale: 'ru-RU' })
      const page = await context.newPage()
      await onboard(page, cycle)
      await page.getByRole('link', { name: 'Профиль' }).click()
      await expect(page.getByTestId('cycle-off-link'), cycle.kind).toBeVisible()
      await expect(page.getByTestId('cycle-calendar-link'), cycle.kind).toHaveCount(0)
      await expect(page.getByTestId('enable-offer'), cycle.kind).toHaveCount(offer ? 1 : 0)
      if (offer) {
        // Один раз: «Не сейчас» убирает предложение и после перезагрузки.
        await page.getByRole('button', { name: 'Не сейчас' }).click()
        await page.reload()
        await expect(page.getByTestId('cycle-off-link')).toBeVisible()
        await expect(page.getByTestId('enable-offer')).toHaveCount(0)
      }
      // Прямой адрес календаря сетку не показывает.
      await page.goto('/cycle')
      await expect(page.getByText('Цикл выключен.')).toBeVisible()
      await expect(page.getByTestId('cycle-month')).toHaveCount(0)
      await context.close()
    }
  })

  test('low_confidence: календарь виден, отметка начала пишется и пересобирает неделю', async ({ page }) => {
    await onboard(page, { kind: 'phases', regularity: 'irregular' })
    // Три закрытия с низкой уверенностью (как в Server 17): 20, 45, 20 дней.
    const token = await page.evaluate(() => {
      const key = Object.keys(localStorage).find((k) => k.startsWith('sb-') && k.endsWith('-auth-token'))!
      const session = JSON.parse(localStorage.getItem(key)!) as { access_token: string; user: { id: string } }
      return { access: session.access_token, user: session.user.id }
    })
    for (const offset of [-100, -80, -35, -15]) {
      const response = await page.request.post(`${SUPABASE}/rest/v1/cycle_events`, {
        headers: { apikey: ANON, Authorization: `Bearer ${token.access}`, Prefer: 'return=minimal' },
        data: { id: crypto.randomUUID(), user_id: token.user, kind: 'period_start', occurred_on: moscow(offset), source: 'manual' },
      })
      expect(response.ok()).toBe(true)
    }
    // Пишущий путь сохраняет применённый режим (§20.6), как сделал бы клиент
    // после своей записи.
    const date = moscow(0)
    const rebuild = await page.request.post(`/v1/week-plans/${mondayOf(date)}/rebuild`, {
      headers: { Authorization: `Bearer ${token.access}` },
      data: { cause: 'cycle_event_added', date, tz: 'Europe/Moscow' },
    })
    expect(rebuild.ok()).toBe(true)
    const profile = await page.request.get('/v1/profile', { headers: { Authorization: `Bearer ${token.access}` } })
    expect((await profile.json()).cycle).toMatchObject({ phase_mode: 'no_phases', no_phase_reason: 'low_confidence' })

    await page.reload()
    await openCalendar(page)
    const panel = await openDay(page, date)
    const rebuilt = rebuildAfter(page)
    await panel.getByRole('button', { name: 'Начались месячные' }).click()
    await rebuilt
    await expect(await day(page, date)).toHaveAttribute('data-period', 'marked')
  })
})

function mondayOf(date: string): string {
  const [y, m, d] = date.split('-').map(Number) as [number, number, number]
  const utc = new Date(Date.UTC(y, m - 1, d))
  utc.setUTCDate(utc.getUTCDate() - ((utc.getUTCDay() + 6) % 7))
  return utc.toISOString().slice(0, 10)
}
