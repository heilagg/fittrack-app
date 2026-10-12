import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import type { ApiClient } from '../../api/client'
import type { Profile } from '../../api/schemas'
import { PARQ_QUESTIONS } from '../../onboarding/parq'
import { ONBOARDING_SUMMARY } from '../../onboarding/texts'
import { OnboardingScreen } from './OnboardingScreen'

const direct = vi.hoisted(() => ({
  hasParq: vi.fn<() => Promise<boolean>>(async () => false),
  upsertParq: vi.fn<(row: Record<string, unknown>) => Promise<void>>(async () => {}),
  insertRestrictions: vi.fn<(user: string, items: unknown[]) => Promise<void>>(async () => {}),
  upsertBodyWeight: vi.fn<(user: string, kg: number, on: string) => Promise<void>>(async () => {}),
  upsertPeriodStart: vi.fn<(user: string, on: string) => Promise<void>>(async () => {}),
  insertEquipmentProfile: vi.fn<(user: string, row: Record<string, unknown>) => Promise<void>>(async () => {}),
}))
vi.mock('../../direct/onboarding', () => ({
  hasParq: direct.hasParq,
  upsertParq: direct.upsertParq,
  insertRestrictions: direct.insertRestrictions,
  upsertBodyWeight: direct.upsertBodyWeight,
  upsertPeriodStart: direct.upsertPeriodStart,
}))
vi.mock('../../direct/equipment', () => ({ insertEquipmentProfile: direct.insertEquipmentProfile }))
vi.mock('../../auth/supabase', () => ({ currentUserId: async () => 'user-1' }))

afterEach(cleanup)
beforeEach(() => {
  for (const fn of Object.values(direct)) fn.mockClear()
  direct.hasParq.mockResolvedValue(false)
})

const full: Profile = {
  sex_at_birth: 'female',
  birth_year: 1994,
  height_cm: 168,
  experience_level: 'intermediate',
  goal: 'hypertrophy',
  days_per_week: 3,
  training_weekdays: [1, 3, 5],
  session_minutes: 45,
  cycle_tracking: 'off',
  is_complete: false,
}

function mount(profile: Profile | null, overrides: Partial<Record<keyof ApiClient, unknown>> = {}) {
  const api = {
    getProfileIfStarted: vi.fn(async () => profile),
    patchProfile: vi.fn(async () => ({ ...full })),
    generateWeek: vi.fn(async () => ({ plan: { days: [], status_lines: [] } })),
    ...overrides,
  }
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={['/onboarding']}>
        <Routes>
          <Route path="/onboarding" element={<OnboardingScreen api={api as unknown as ApiClient} />} />
          <Route path="/" element={<p data-testid="home">Сегодня</p>} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  )
  return api
}

const step = (n: number) => waitFor(() => expect(screen.getByTestId(`step-${n}`)).toBeTruthy())
const click = (name: string) => fireEvent.click(screen.getByRole('button', { name }))
const answerAll = (value: 'yes' | 'no') => {
  for (let i = 1; i <= PARQ_QUESTIONS.length; i++) {
    const radios = document.getElementsByName(`q${i}`)
    fireEvent.click([...radios].find((r) => (r as HTMLInputElement).value === value)!)
  }
}

describe('вход в онбординг', () => {
  it('профиля нет (not_found): экран 1, и «Понятно» создаёт строку пустым PATCH до экрана 2', async () => {
    const api = mount(null)
    await step(1)
    expect(api.patchProfile).not.toHaveBeenCalled()
    click('Понятно')
    await step(2)
    expect(api.patchProfile).toHaveBeenCalledTimes(1)
    expect(api.patchProfile).toHaveBeenCalledWith({})
  })

  it('с экрана, вычисленного из null: нет цели — экран 5', async () => {
    direct.hasParq.mockResolvedValue(true)
    const { goal: _goal, ...noGoal } = full
    void _goal
    mount({ ...noGoal, training_weekdays: undefined, days_per_week: undefined })
    await step(5)
  })

  it('полный профиль — сразу на «Сегодня»', async () => {
    direct.hasParq.mockResolvedValue(true)
    mount({ ...full, is_complete: true })
    await waitFor(() => expect(screen.getByTestId('home')).toBeTruthy())
  })
})

describe('PAR-Q', () => {
  async function toParq() {
    const api = mount(null)
    await step(1)
    click('Понятно')
    await step(2)
    return api
  }

  it('«Далее» закрыт, пока не отвечены все семь вопросов', async () => {
    await toParq()
    expect((screen.getByRole('button', { name: 'Далее' }) as HTMLButtonElement).disabled).toBe(true)
    answerAll('no')
    expect((screen.getByRole('button', { name: 'Далее' }) as HTMLButtonElement).disabled).toBe(false)
  })

  it('все «нет»: строка пишется сразу, без красного флага и подтверждения', async () => {
    await toParq()
    answerAll('no')
    click('Далее')
    await step(3)
    expect(direct.upsertParq).toHaveBeenCalledTimes(1)
    expect(direct.upsertParq.mock.calls[0]![0]).toMatchObject({
      user_id: 'user-1',
      has_red_flag: false,
      acknowledged: false,
    })
  })

  it('«да» на любой вопрос: экран рекомендации, запись только после подтверждения, доступ не блокируется', async () => {
    await toParq()
    answerAll('no')
    fireEvent.click([...document.getElementsByName('q6')].find((r) => (r as HTMLInputElement).value === 'yes')!)
    click('Далее')
    expect(await screen.findByRole('button', { name: 'Я прочитал(а) рекомендацию' })).toBeTruthy()
    expect(direct.upsertParq).not.toHaveBeenCalled()
    click('Я прочитал(а) рекомендацию')
    await step(3)
    expect(direct.upsertParq.mock.calls[0]![0]).toMatchObject({ has_red_flag: true, acknowledged: true })
  })
})

describe('шаги после PAR-Q', () => {
  it('шаг 3: PATCH трёх полей и вес прямой записью', async () => {
    direct.hasParq.mockResolvedValue(true)
    const api = mount({ session_minutes: 45, cycle_tracking: 'off', is_complete: false })
    await step(3)
    fireEvent.change(screen.getByLabelText('Пол при рождении'), { target: { value: 'male' } })
    expect(screen.getByLabelText('Год рождения').getAttribute('placeholder')).toBe('ГГГГ, например 2005')
    fireEvent.change(screen.getByLabelText('Год рождения'), { target: { value: '1990' } })
    fireEvent.change(screen.getByLabelText('Рост, см'), { target: { value: '180' } })
    fireEvent.change(screen.getByLabelText('Вес, кг'), { target: { value: '82,5' } })
    click('Далее')
    await step(4)
    expect(api.patchProfile).toHaveBeenCalledWith({ sex_at_birth: 'male', birth_year: 1990, height_cm: 180 })
    expect(direct.upsertBodyWeight).toHaveBeenCalledWith('user-1', 82.5, expect.stringMatching(/^\d{4}-\d{2}-\d{2}$/))
  })

  it('шаг 4: подписи с порогами из §5 и вопрос про становую тягу', async () => {
    direct.hasParq.mockResolvedValue(true)
    const { experience_level: _e, goal: _g, training_weekdays: _t, days_per_week: _d, ...rest } = full
    void [_e, _g, _t, _d]
    mount(rest)
    await step(4)
    expect(screen.getByText('Как давно вы занимаетесь в зале?')).toBeTruthy()
    expect((screen.getByLabelText('Меньше 6 месяцев') as HTMLInputElement).value).toBe('novice')
    expect((screen.getByLabelText('От 6 месяцев до 2 лет') as HTMLInputElement).value).toBe('intermediate')
    expect((screen.getByLabelText('Больше 2 лет') as HTMLInputElement).value).toBe('advanced')
  })

  it('шаг 6: дни недели уходят набором, количество выводится из него', async () => {
    direct.hasParq.mockResolvedValue(true)
    const { training_weekdays: _t, days_per_week: _d, ...rest } = full
    void [_t, _d]
    const api = mount(rest)
    await step(6)
    fireEvent.click(screen.getByLabelText('Среда'))
    fireEvent.click(screen.getByLabelText('Понедельник'))
    expect(screen.getByTestId('days-count').textContent).toBe('Дней в неделю: 2')
    click('Далее')
    await step(7)
    expect(api.patchProfile).toHaveBeenCalledWith({ training_weekdays: [1, 3] })
  })

  it('шаг 7: пресет «Зал» записывает строку по умолчанию; затем шаг 8', async () => {
    direct.hasParq.mockResolvedValue(true)
    mount(full)
    await step(7)
    click('Зал')
    click('Сохранить инвентарь')
    await step(8)
    expect(direct.insertEquipmentProfile).toHaveBeenCalledTimes(1)
    const [userId, row] = direct.insertEquipmentProfile.mock.calls[0]!
    expect(userId).toBe('user-1')
    expect(row).toMatchObject({ name: 'Зал', is_default: true, barbell_kg: 20, bench: 'adjustable' })
  })

  it('шаг 7: гири сняты — набор гирь не уходит, как бы ни был заполнен', async () => {
    direct.hasParq.mockResolvedValue(true)
    mount(full)
    await step(7)
    click('Зал')
    fireEvent.click(screen.getByLabelText('Есть гири'))
    click('Сохранить инвентарь')
    await step(8)
    const row = direct.insertEquipmentProfile.mock.calls[0]![1]
    expect(row).toMatchObject({ has_kettlebells: false, kettlebells_kg: [] })
  })

  it('шаг 8: ограничения пишутся прямой записью; без выбора — ничего лишнего', async () => {
    direct.hasParq.mockResolvedValue(true)
    mount({ ...full, sex_at_birth: 'male' })
    await step(7)
    click('Дома без железа')
    click('Сохранить инвентарь')
    await step(8)
    fireEvent.change(document.querySelector('[data-joint="knee"]')!, { target: { value: 'avoid' } })
    fireEvent.change(document.querySelector('[data-joint="shoulder"]')!, { target: { value: 'careful' } })
    click('Далее')
    await step(10)
    expect(direct.insertRestrictions).toHaveBeenCalledWith('user-1', [
      { joint: 'knee', severity: 'avoid' },
      { joint: 'shoulder', severity: 'careful' },
    ])
  })

  it('шаг 9 пропускается, если пол не женский: после 8 сразу итог', async () => {
    direct.hasParq.mockResolvedValue(true)
    mount({ ...full, sex_at_birth: 'male' })
    await step(7)
    click('Сохранить инвентарь')
    await step(8)
    click('Далее')
    await step(10)
    expect(screen.queryByTestId('step-9')).toBeNull()
  })

  it('шаг 9: «Не сейчас» пишет declined и ничего в cycle_events', async () => {
    direct.hasParq.mockResolvedValue(true)
    const api = mount(full)
    await step(7)
    click('Сохранить инвентарь')
    await step(8)
    click('Далее')
    await step(9)
    fireEvent.click(screen.getByLabelText('Не сейчас'))
    click('Далее')
    await step(10)
    expect(api.patchProfile).toHaveBeenCalledWith({
      cycle_tracking: 'off',
      cycle: { phase_mode: 'no_phases', no_phase_reason: 'declined' },
    })
    expect(direct.upsertPeriodStart).not.toHaveBeenCalled()
  })

  it('шаг 9: «Да» без контрацепции пишет режим фаз и дату как period_start', async () => {
    direct.hasParq.mockResolvedValue(true)
    const api = mount(full)
    await step(7)
    click('Сохранить инвентарь')
    await step(8)
    click('Далее')
    await step(9)
    fireEvent.click(screen.getByLabelText('Да', { selector: 'input[name="tracking"]' }))
    fireEvent.click(screen.getByLabelText('Нет', { selector: 'input[name="contraception"]' }))
    fireEvent.change(screen.getByLabelText('Дата начала последней менструации'), { target: { value: '2026-10-01' } })
    fireEvent.change(screen.getByLabelText('Обычная длина цикла, дней'), { target: { value: '28' } })
    click('Далее')
    await step(10)
    expect(api.patchProfile).toHaveBeenCalledWith({
      cycle_tracking: 'manual',
      cycle: { phase_mode: 'phases', typical_cycle_length_days: 28 },
    })
    expect(direct.upsertPeriodStart).toHaveBeenCalledWith('user-1', '2026-10-01')
  })

  it('шаг 10: итог дословно, затем генерация недели и переход на «Сегодня»', async () => {
    direct.hasParq.mockResolvedValue(true)
    const api = mount({ ...full, sex_at_birth: 'male' })
    await step(7)
    click('Сохранить инвентарь')
    await step(8)
    click('Далее')
    await step(10)
    expect(screen.getByTestId('onboarding-summary').textContent).toBe(ONBOARDING_SUMMARY)
    expect(api.generateWeek).not.toHaveBeenCalled()
    click('Перейти к тренировкам')
    await waitFor(() => expect(screen.getByTestId('home')).toBeTruthy())
    expect(api.generateWeek).toHaveBeenCalledTimes(1)
  })
})
