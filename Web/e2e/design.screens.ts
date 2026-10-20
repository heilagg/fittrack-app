// Скриншоты основных экранов (`npm run screens`): не тест поведения, а кадры
// для просмотра дизайна. Путь — настоящий, как в e2e; состояния обрыва сети и
// подхода «в пути» вызываются перехватом запросов в браузере.

import { expect, test, type Page } from '@playwright/test'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { cycleNo, disclaimer, trainingDays, verifyLink, tapFeedback, finishWorkout } from './helpers'

const dir = fileURLToPath(new URL('../design-screens', import.meta.url))
const shot = (page: Page, name: string) => page.screenshot({ path: join(dir, `${name}.png`), fullPage: true, animations: 'disabled' })
const step = (page: Page, n: number) => page.getByTestId(`step-${n}`)
const next = (page: Page) => page.getByRole('button', { name: 'Далее' })
const WEEKDAY_NAMES = ['Понедельник', 'Вторник', 'Среда', 'Четверг', 'Пятница', 'Суббота', 'Воскресенье']

test.setTimeout(300_000)

test('PAR-Q с красным флагом', async ({ page }) => {
  await page.goto('/')
  await disclaimer(page)
  await expect(step(page, 2)).toBeVisible()
  for (let i = 1; i <= 7; i++) await page.locator(`input[name="q${i}"][value="${i === 1 ? 'yes' : 'no'}"]`).check()
  await next(page).click()
  await expect(page.getByRole('button', { name: 'Я прочитал(а) рекомендацию' })).toBeVisible()
  await shot(page, '03-onboarding-parq-red-flag')
})

test('онбординг, Сегодня, привязка, тренировка, сводка, ошибка', async ({ page }) => {
  await page.goto('/')
  await expect(step(page, 1)).toBeVisible()
  await shot(page, '01-onboarding-disclaimer')
  await disclaimer(page)

  await expect(step(page, 2)).toBeVisible()
  for (let i = 1; i <= 7; i++) await page.locator(`input[name="q${i}"][value="no"]`).check()
  await shot(page, '02-onboarding-parq')
  await next(page).click()

  await expect(step(page, 3)).toBeVisible()
  await page.getByLabel('Пол при рождении').selectOption('female')
  await page.getByLabel('Год рождения').fill('1994')
  await page.getByLabel('Рост, см').fill('168')
  await page.getByLabel('Вес, кг').fill('64,5')
  await shot(page, '04-onboarding-basics')
  await next(page).click()

  await expect(step(page, 4)).toBeVisible()
  await page.getByLabel('От 6 месяцев до 2 лет').check()
  await shot(page, '05-onboarding-experience')
  await next(page).click()

  await expect(step(page, 5)).toBeVisible()
  await page.getByLabel('Набор мышечной массы').check()
  await next(page).click()

  await expect(step(page, 6)).toBeVisible()
  for (const d of trainingDays()) await page.getByLabel(WEEKDAY_NAMES[d - 1]!).check()
  await shot(page, '06-onboarding-weekdays')
  await next(page).click()

  await expect(step(page, 7)).toBeVisible()
  await page.getByRole('button', { name: 'Зал' }).click()
  await shot(page, '07-onboarding-equipment')
  await page.getByRole('button', { name: 'Сохранить инвентарь' }).click()

  await expect(step(page, 8)).toBeVisible()
  await page.locator('[data-joint="knee"]').selectOption('careful')
  await shot(page, '08-onboarding-restrictions')
  await next(page).click()

  await expect(step(page, 9)).toBeVisible()
  await page.getByLabel('Да', { exact: true }).first().check()
  await page.locator('input[name="contraception"][value="no"]').check()
  await shot(page, '09-onboarding-cycle')
  await cycleNo(page)

  await expect(step(page, 10)).toBeVisible()
  await shot(page, '10-onboarding-summary')
  await page.getByRole('button', { name: 'Перейти к тренировкам' }).click()

  await expect(page.getByTestId('exercise-name').first()).toBeVisible()
  // Календарь дорисовывается ответом недели: ждать, пока у сегодняшнего дня появится статус.
  await expect(page.locator('[data-testid="week-calendar"] > li[data-today="true"]')).toHaveAttribute(
    'data-status',
    'planned',
  )
  await shot(page, '11-today')

  const email = `screens-${Date.now()}@example.com`
  await page.getByRole('button', { name: 'Начать тренировку' }).click()
  await expect(page).toHaveURL(/\/link$/)
  await shot(page, '12-link')
  await page.getByLabel('Почта').fill(email)
  await page.getByRole('button', { name: 'Отправить ссылку' }).click()
  await expect(page.getByTestId('link-sent')).toContainText(email)
  await shot(page, '13-link-sent')
  await page.goto(await verifyLink(email))
  await page.getByRole('button', { name: 'Начать тренировку' }).click()
  await expect(page.getByTestId('current-exercise')).toBeVisible()
  await expect(page.getByTestId('weight')).toHaveText(/кг|Без веса/)
  await shot(page, '14-workout-set')

  // Подход «в пути»: ответ сервера задержан, выбранная кнопка залита.
  await page.route('**/exercises/*/sets', async (route) => {
    await new Promise((resolve) => setTimeout(resolve, 4000))
    await route.continue()
  })
  await tapFeedback(page, 'ok')
  await expect(page.getByTestId('rest-clock')).toBeVisible()
  await shot(page, '15-workout-set-pending')
  // Подтверждён: кнопки фидбэка снова доступны. Перехват снимается после
  // ответа — иначе задержанный запрос уже некому отпустить.
  await expect(page.getByRole('button', { name: 'Нормально' })).toBeEnabled({ timeout: 15_000 })
  await page.unroute('**/exercises/*/sets')
  await shot(page, '16-workout-rest')

  // Обрыв сети: подход дошёл, ответ потерян.
  await page.route('**/exercises/*/sets', async (route) => {
    await route.fetch()
    await route.abort('failed')
  })
  await tapFeedback(page, 'ok')
  await expect(page.getByTestId('log-failure')).toBeVisible()
  await shot(page, '17-workout-log-failure')
  await page.unroute('**/exercises/*/sets')
  await page.getByRole('button', { name: 'Повторить' }).click()
  await expect(page.getByTestId('log-failure')).toHaveCount(0)

  // Постановочный кадр: у калибровочной тренировки весов нет, и строка
  // «Следующий подход: N кг» законно не появляется. Вес подставляется в ответ
  // /sets в браузере, чтобы показать её вид.
  await page.route('**/exercises/*/sets', async (route) => {
    const response = await route.fetch()
    const body = (await response.json()) as { decision_tree: { nodes: Record<string, { weight_kg?: number }> } }
    for (const node of Object.values(body.decision_tree.nodes)) node.weight_kg = 14
    await route.fulfill({ response, json: body })
  })
  const normal = page.getByRole('button', { name: 'Нормально' })
  await expect(normal).toBeEnabled({ timeout: 15_000 })
  await normal.click()
  await expect(normal).toBeEnabled({ timeout: 15_000 })
  await expect(page.getByTestId('next-set')).toBeVisible()
  await shot(page, '18-workout-rest-next-set-staged')
  await page.unroute('**/exercises/*/sets')

  await finishWorkout(page)
  await expect(page.getByTestId('summary')).toBeVisible()
  await shot(page, '19-workout-summary')

  // «Сегодня» после тренировки: сегодняшний день выполнен, точка под числом.
  await page.getByRole('link', { name: 'Сегодня' }).click()
  await expect(page.locator('[data-testid="week-calendar"] > li[data-today="true"]')).toHaveAttribute(
    'data-status',
    'done',
  )
  await shot(page, '20-today-after-workout')

  await page.route('**/v1/today*', (route) => route.abort('failed'))
  await page.goto('/')
  await expect(page.getByRole('alert')).toBeVisible()
  await shot(page, '21-error-network')
})
