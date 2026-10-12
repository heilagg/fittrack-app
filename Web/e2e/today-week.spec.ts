import { expect, test, type Page } from '@playwright/test'
import { completeOnboarding, startLinkedWorkout, todayIsoWeekday, trainingDays } from './helpers'

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
    // уже прошли (итог `past`) и не обводятся, остальные запланированы.
    await expect(li).toHaveAttribute('data-status', days.includes(wd) && wd >= today ? 'planned' : 'none')
  }

  // Сетка назначает типы дням недели по порядку: тип сегодняшнего — по его месту.
  const sorted = [...days].sort((a, b) => a - b)
  await expect(page.getByTestId('session-kind')).toHaveText(NAMES[sorted.indexOf(today)]!)
  await expect(page.getByRole('alert')).toHaveCount(0)
})

test('после завершённой тренировки сегодняшний день отмечен выполненным', async ({ page }) => {
  await startLinkedWorkout(page)
  await page.getByRole('button', { name: 'Нормально' }).click()
  await expect(page.getByRole('button', { name: 'Нормально' })).toBeEnabled()
  await page.getByRole('button', { name: 'Завершить тренировку' }).click()
  await expect(page.getByTestId('summary')).toBeVisible()
  await page.getByRole('link', { name: 'Сегодня' }).click()
  await expect(page.getByRole('heading', { name: 'Сегодня' })).toBeVisible()

  const todayLi = page.locator('[data-testid="week-calendar"] > li[data-today="true"]')
  await expect(todayLi).toHaveAttribute('data-status', 'done')
  // Имя дня — у кнопки внутри колонки: с среза 6 день нажимается (`/preview`).
  await expect(todayLi.getByRole('button')).toHaveAccessibleName(/сегодня, тренировка выполнена/)
})
