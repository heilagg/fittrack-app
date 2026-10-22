import { expect, test, type Page } from '@playwright/test'
import { startLinkedWorkout, tapFeedback, finishWorkout } from './helpers'

// Срез 4: завершение тренировки. Всё — против настоящего сервера и базы.

const finish = (page: Page) => page.getByRole('button', { name: 'Завершить тренировку' })

test.describe('завершение тренировки', () => {
  test('после подхода: /finish закрывает тренировку, сводка показывает подход', async ({ page }) => {
    await startLinkedWorkout(page)
    await tapFeedback(page, 'ok')
    await expect(page.getByTestId('log-failure')).toHaveCount(0)
    await expect(page.getByTestId('set-counter')).toContainText('Подход 2 из')

    const finished = page.waitForResponse((r) => r.url().endsWith('/finish') && r.request().method() === 'POST')
    await finishWorkout(page)
    const response = await finished
    expect(response.status()).toBe(200)
    const body = (await response.json()) as { workout: { finished_at?: string }; week?: { notice?: { message: string } } }
    expect(body.workout.finished_at).toBeTruthy()

    await expect(page.getByTestId('workout-state')).toHaveText('Завершена')
    await expect(page.getByTestId('summary-total')).toHaveText('Выполнено подходов: 1')
    await expect(finish(page)).toHaveCount(0)
    // Закрытие дня без изменения состава остальных дней строки не даёт
    // (§7.1, сценарий 32b; LiveFinishTests на сервере): экран молчит тоже.
    // Ветка «notice есть» живьём недостижима на этом seed: её держит
    // Vitest на эталоне `response_finish_workout.json`.
    expect(body.week?.notice).toBeUndefined()
    await expect(page.getByTestId('plan-notice')).toHaveCount(0)

    // Перезагрузка читает закрытую тренировку с сервера: сводка без кнопки.
    await page.reload()
    await expect(page.getByTestId('summary')).toBeVisible()
    await expect(page.getByTestId('summary-total')).toHaveText('Выполнено подходов: 1')
    await expect(finish(page)).toHaveCount(0)
  })

  test('«Сегодня» после завершения: день больше не предлагает начать тренировку', async ({ page }) => {
    await startLinkedWorkout(page)
    await tapFeedback(page, 'ok')
    await expect(page.getByTestId('set-counter')).toContainText('Подход 2 из')
    await finishWorkout(page)
    await expect(page.getByTestId('summary')).toBeVisible()

    await page.getByRole('link', { name: 'Сегодня' }).click()
    await expect(page.getByRole('heading', { name: 'Сегодня' })).toBeVisible()
    await expect(page.getByRole('button', { name: 'Начать тренировку' })).toHaveCount(0)
    await expect(page.getByRole('button', { name: 'Продолжить тренировку' })).toHaveCount(0)
    await expect(page.getByTestId('day-not-built')).toBeVisible()
  })

  test('обрыв ответа /finish: повтор даёт то же завершение, а не 409', async ({ page }) => {
    await startLinkedWorkout(page)
    await tapFeedback(page, 'ok')
    await expect(page.getByTestId('set-counter')).toContainText('Подход 2 из')

    // Запрос доходит и закрывает тренировку, а ответ теряется.
    await page.route('**/finish', async (route) => {
      await route.fetch()
      await route.abort('failed')
    })
    await finishWorkout(page)
    await expect(page.getByTestId('finish-failure')).toContainText('Нет связи')
    await expect(page.getByTestId('summary')).toHaveCount(0)

    await page.unroute('**/finish')
    const repeated = page.waitForResponse((r) => r.url().endsWith('/finish'))
    await page.getByRole('button', { name: 'Повторить' }).click()
    expect((await repeated).status()).toBe(200)
    await expect(page.getByTestId('summary')).toBeVisible()
    await expect(page.getByTestId('finish-failure')).toHaveCount(0)
    // В повторе `notice` — null: строки «План обновлён» второй раз нет.
    await expect(page.getByTestId('plan-notice')).toHaveCount(0)
  })

  test('без единого подхода: тренировка закрывается, сводка говорит, что подходов нет', async ({ page }) => {
    await startLinkedWorkout(page)
    await finishWorkout(page)
    await expect(page.getByTestId('summary')).toBeVisible()
    await expect(page.getByTestId('summary-total')).toHaveText('Ни одного подхода не выполнено.')
  })
})
