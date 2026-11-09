import { expect, test, type Page } from '@playwright/test'
import { completeOnboarding, linkAfterOnboarding, startLinkedWorkout, todayIsoWeekday, trainingDays, tapFeedback, finishWorkout } from './helpers'

// «Сегодня»: календарь недели и чип типа дня против настоящих Supabase и
// Server. Онбординг ставит три дня, первый из которых сегодняшний, средний
// уровень: сетка §7.2 даёт им верх тела / низ тела / всё тело по порядку.

const NAMES = ['Верх тела', 'Низ тела', 'Всё тело']

const calendar = (page: Page) => page.getByTestId('week-calendar').locator('> li')

/** ISO-день недели даты `YYYY-MM-DD`. */
function weekdayOf(date: string): number {
  const [y, m, d] = date.split('-').map(Number) as [number, number, number]
  return ((new Date(Date.UTC(y, m - 1, d)).getUTCDay() + 6) % 7) + 1
}

test('календарь: сегодня залито, будущие дни тренировок обведены, прочие пусты; чип — тип дня', async ({ page }) => {
  await completeOnboarding(page)
  await expect(page.getByTestId('exercise-name').first()).toBeVisible()
  await expect(calendar(page)).toHaveCount(7)

  const today = todayIsoWeekday()
  const days = trainingDays()
  // Неделя пишется при чтении (§20.6); дождаться её — значит дождаться обводок.
  await expect(page.locator('[data-testid="week-calendar"] > li[data-today="true"]')).toHaveAttribute('data-status', 'planned')

  for (const li of await calendar(page).all()) {
    const date = (await li.getAttribute('data-date'))!
    const wd = weekdayOf(date)
    await expect(li).toHaveAttribute('data-today', String(wd === today))
    // Все три дня тренировок — дни этой недели: те, что раньше сегодняшнего,
    // прошли не сделанными (итог `past`) и их можно сделать сегодня (§7.1),
    // остальные запланированы.
    await expect(li).toHaveAttribute('data-status', days.includes(wd) ? (wd >= today ? 'planned' : 'missed') : 'none')
  }

  // Сетка назначает типы дням недели по порядку: тип сегодняшнего — по его месту.
  const sorted = [...days].sort((a, b) => a - b)
  await expect(page.getByTestId('session-kind')).toHaveText(NAMES[sorted.indexOf(today)]!)
  await expect(page.getByRole('alert')).toHaveCount(0)
})

test('после завершённой тренировки сегодняшний день отмечен выполненным', async ({ page }) => {
  await startLinkedWorkout(page)
  await tapFeedback(page, 'ok')
  await expect(page.getByRole('button', { name: 'Нормально' })).toBeEnabled()
  await finishWorkout(page)
  await expect(page.getByTestId('summary')).toBeVisible()
  await page.getByRole('link', { name: 'Сегодня' }).click()
  await expect(page.getByRole('heading', { name: 'Сегодня' })).toBeVisible()

  const todayLi = page.locator('[data-testid="week-calendar"] > li[data-today="true"]')
  await expect(todayLi).toHaveAttribute('data-status', 'done')
  // Имя дня — у кнопки внутри колонки: с среза 6 день нажимается (`/preview`).
  await expect(todayLi.getByRole('button')).toHaveAccessibleName(/сегодня, тренировка выполнена/)
})

test('другой день недели начинается сегодня; галочка — на сегодняшней дате, у дня плана — «выполнена» (§7.1)', async ({ page }) => {
  await linkAfterOnboarding(page)
  const today = todayIsoWeekday()
  const other = trainingDays().find((d) => d !== today)!
  const li = page.locator('[data-testid="week-calendar"] > li').nth(other - 1)
  const date = (await li.getAttribute('data-date'))!
  await li.getByRole('button').click()
  await expect(page.getByTestId('day-preview')).toHaveAttribute('data-date', date)
  const start = page.getByTestId('preview-start')
  await expect(start).toHaveText(other < today ? 'Сделать сегодня' : 'Начать сегодня')
  await start.click()
  await expect(page).toHaveURL(/\/workout\/[0-9a-f-]{36}$/)

  await tapFeedback(page, 'ok')
  await expect(page.getByTestId('log-failure')).toHaveCount(0)
  await expect(page.getByTestId('set-counter')).toContainText('Подход 2 из')
  await finishWorkout(page)
  await expect(page.getByTestId('summary')).toBeVisible()
  await page.getByRole('link', { name: 'Сегодня' }).click()

  const todayLi = page.locator('[data-testid="week-calendar"] > li[data-today="true"]')
  await expect(todayLi).toHaveAttribute('data-status', 'done')
  await expect(li).toHaveAttribute('data-status', 'moved')
  await expect(li.getByRole('button')).toHaveAccessibleName(/тренировка выполнена \d+ [а-я]+/)
  // Сегодняшний день плана остался: его можно сделать тоже (§7.1).
  await expect(page.getByRole('button', { name: 'Начать тренировку' })).toBeVisible()
})
