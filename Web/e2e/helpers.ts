import { expect, type Page } from '@playwright/test'

const MAILPIT = 'http://127.0.0.1:54324'

/** Ссылка подтверждения из письма, отправленного настоящим Supabase Auth. */
export async function verifyLink(email: string): Promise<string> {
  for (let attempt = 0; attempt < 30; attempt++) {
    const found = await fetch(`${MAILPIT}/api/v1/search?query=${encodeURIComponent(`to:${email}`)}`)
    const list = (await found.json()) as { messages: { ID: string }[] }
    const first = list.messages[0]
    if (first) {
      const message = (await (await fetch(`${MAILPIT}/api/v1/message/${first.ID}`)).json()) as { HTML: string }
      const href = /href="([^"]*\/auth\/v1\/verify[^"]*)"/.exec(message.HTML)?.[1]
      if (href) return href.replaceAll('&amp;', '&')
    }
    await new Promise((resolve) => setTimeout(resolve, 500))
  }
  throw new Error(`Письмо для ${email} не пришло в Mailpit`)
}

// MARK: - Онбординг (SPEC §5): шаги как действия пользователя

const step = (page: Page, n: number) => page.getByTestId(`step-${n}`)
const next = (page: Page) => page.getByRole('button', { name: 'Далее' })

/** ISO-день недели «сегодня» в зоне, которую фиксирует конфиг Playwright. */
export function todayIsoWeekday(): number {
  const date = new Date().toLocaleDateString('en-CA', { timeZone: 'Europe/Moscow' })
  const [y, m, d] = date.split('-').map(Number) as [number, number, number]
  return ((new Date(Date.UTC(y, m - 1, d)).getUTCDay() + 6) % 7) + 1
}

/** Три дня недели, первый из которых сегодняшний: «Сегодня» собирает состав. */
export function trainingDays(): number[] {
  const t = todayIsoWeekday()
  const nextDay = (n: number) => ((t - 1 + n) % 7) + 1
  return [t, nextDay(2), nextDay(4)].sort((a, b) => a - b)
}
const WEEKDAY_NAMES = ['Понедельник', 'Вторник', 'Среда', 'Четверг', 'Пятница', 'Суббота', 'Воскресенье']

export async function disclaimer(page: Page) {
  await expect(step(page, 1)).toBeVisible()
  await page.getByRole('button', { name: 'Понятно' }).click()
}

export async function parq(page: Page, yesOn: number[] = []) {
  await expect(step(page, 2)).toBeVisible()
  for (let i = 1; i <= 7; i++) {
    await page.locator(`input[name="q${i}"][value="${yesOn.includes(i) ? 'yes' : 'no'}"]`).check()
  }
  await next(page).click()
}

export async function basics(page: Page, sex: 'female' | 'male' = 'female') {
  await expect(step(page, 3)).toBeVisible()
  await page.getByLabel('Пол при рождении').selectOption(sex)
  await page.getByLabel('Год рождения').fill('1994')
  await page.getByLabel('Рост, см').fill('168')
  await page.getByLabel('Вес, кг').fill('64,5')
  await next(page).click()
}

export async function experience(page: Page) {
  await expect(step(page, 4)).toBeVisible()
  await page.getByLabel('От 6 месяцев до 2 лет').check()
  await next(page).click()
}

export async function goal(page: Page) {
  await expect(step(page, 5)).toBeVisible()
  await page.getByLabel('Набор мышечной массы').check()
  await next(page).click()
}

export async function weekdays(page: Page) {
  await expect(step(page, 6)).toBeVisible()
  for (const d of trainingDays()) await page.getByLabel(WEEKDAY_NAMES[d - 1]!).check()
  await next(page).click()
}

export async function equipment(page: Page, preset: 'Зал' | 'Дома с гантелями' | 'Дома без железа' = 'Зал') {
  await expect(step(page, 7)).toBeVisible()
  await page.getByRole('button', { name: preset }).click()
  await page.getByRole('button', { name: 'Сохранить инвентарь' }).click()
}

export async function restrictions(page: Page, picks: Record<string, 'avoid' | 'careful'> = {}) {
  await expect(step(page, 8)).toBeVisible()
  for (const [joint, level] of Object.entries(picks)) {
    await page.locator(`[data-joint="${joint}"]`).selectOption(level)
  }
  await next(page).click()
}

export async function cycleNo(page: Page) {
  await expect(step(page, 9)).toBeVisible()
  await page.getByLabel('Нет', { exact: true }).first().check()
  await next(page).click()
}

export async function finishOnboarding(page: Page) {
  await expect(step(page, 10)).toBeVisible()
  await page.getByRole('button', { name: 'Перейти к тренировкам' }).click()
  await expect(page.getByRole('heading', { name: 'Сегодня' })).toBeVisible()
}

/** Весь онбординг от первого экрана до «Сегодня» с собранной неделей. */
export async function completeOnboarding(page: Page) {
  await page.goto('/')
  await expect(page).toHaveURL(/\/onboarding$/)
  await disclaimer(page)
  await parq(page)
  await basics(page)
  await experience(page)
  await goal(page)
  await weekdays(page)
  await equipment(page)
  await restrictions(page)
  await cycleNo(page)
  await finishOnboarding(page)
}

/**
 * Весь путь до начатой тренировки: онбординг, привязка по письму, «Начать».
 * Возвращает адрес экрана тренировки.
 */
export async function startLinkedWorkout(page: Page): Promise<string> {
  const email = `web-${Date.now()}-${Math.floor(Math.random() * 1e6)}@example.com`
  await completeOnboarding(page)
  await expect(page.getByTestId('exercise-name').first()).toBeVisible()
  await page.getByRole('button', { name: 'Начать тренировку' }).click()
  await expect(page).toHaveURL(/\/link$/)
  await page.getByLabel('Почта').fill(email)
  await page.getByRole('button', { name: 'Отправить ссылку' }).click()
  await expect(page.getByTestId('link-sent')).toContainText(email)
  await page.goto(await verifyLink(email))
  await expect(page.getByRole('heading', { name: 'Сегодня' })).toBeVisible()
  await page.getByRole('button', { name: 'Начать тренировку' }).click()
  await expect(page).toHaveURL(/\/workout\/[0-9a-f-]{36}$/)
  return page.url()
}

/**
 * Тап по кнопке фидбэка (§13.2). Весовое упражнение в калибровке без базовой
 * линии спрашивает вес первого подхода (§9.8), и кнопки до ввода закрыты:
 * пустое поле заполняется 20 кг — ступень и гантелей, и грифа посева.
 */
export async function tapFeedback(page: Page, value: 'easy' | 'ok' | 'hard' | 'failed') {
  const weight = page.getByTestId('weight-input')
  if ((await weight.count()) > 0 && (await weight.inputValue()) === '') await weight.fill('20')
  await page.locator(`[data-feedback="${value}"]`).click()
}

/**
 * «Завершить тренировку»: при невыполненных подходах экран переспрашивает
 * (§13.2) — подтверждаем. Без остатка вопроса нет, и клик один.
 */
export async function finishWorkout(page: Page) {
  await page.getByRole('button', { name: 'Завершить тренировку' }).click()
  const confirm = page.getByTestId('finish-confirm')
  if (await confirm.isVisible()) await confirm.getByRole('button', { name: 'Завершить', exact: true }).click()
}
