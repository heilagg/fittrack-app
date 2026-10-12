import '@testing-library/jest-dom/vitest'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import type { ApiClient } from '../../api/client'
import type { CycleCalendar, CycleCalendarDay, Profile } from '../../api/schemas'
import type { FlagStore } from '../../cycle/once'
import { CycleCalendarScreen } from './CycleCalendarScreen'
import { OverdueQuestion } from './OverdueQuestion'
import { PhaseCard } from './PhaseCard'

vi.mock('../../auth/supabase', () => ({ currentUserId: async () => 'user-1' }))
const direct = vi.hoisted(() => ({
  latestCycleEvents: vi.fn(),
  insertCycleEvent: vi.fn(async () => undefined),
  moveCycleEvent: vi.fn(async () => undefined),
  deleteCycleEvent: vi.fn(async () => undefined),
}))
vi.mock('../../direct/cycle', () => direct)

afterEach(cleanup)
beforeEach(() => {
  vi.clearAllMocks()
  direct.latestCycleEvents.mockResolvedValue({
    latest: { id: 'start-oct', kind: 'period_start', occurred_on: '2026-10-03' },
    previous: { id: 'start-sep', kind: 'period_start', occurred_on: '2026-09-05' },
  })
})

const TODAY = '2026-10-12'
const phases: CycleCalendar['phases'] = (['menstrual', 'follicular', 'ovulatory', 'luteal'] as const).map((phase) => ({
  phase,
  name: `Имя ${phase}`,
  feeling: `Самочувствие ${phase}`,
  why: `Почему ${phase}`,
  note: 'Общая строка',
}))

function day(date: string, extra: Partial<CycleCalendarDay> = {}): CycleCalendarDay {
  return { date, marks: [], ovulation_estimate: false, ...extra }
}

function october(overrides: Partial<CycleCalendar> = {}): CycleCalendar {
  const days: CycleCalendarDay[] = []
  for (let d = 1; d <= 31; d++) {
    const date = `2026-10-${String(d).padStart(2, '0')}`
    days.push(day(date))
  }
  const set = (date: string, extra: Partial<CycleCalendarDay>) => {
    const i = days.findIndex((x) => x.date === date)
    days[i] = { ...days[i]!, ...extra }
  }
  set('2026-10-03', { period: 'marked', marks: [{ id: 'start-oct', kind: 'period_start', source: 'manual' }], phase: 'menstrual', cycle_confidence: 1 })
  set('2026-10-04', { period: 'estimated', phase: 'menstrual', cycle_confidence: 1 })
  set('2026-10-12', { phase: 'follicular', cycle_confidence: 1 })
  set('2026-10-17', { phase: 'ovulatory', cycle_confidence: 1, ovulation_estimate: true })
  set('2026-10-31', { period: 'forecast' })
  return {
    from: '2026-10-01',
    to: '2026-10-31',
    cycle: { phase_mode: 'phases', has_anchor: true, phase: 'follicular', cycle_confidence: 1 },
    next_period: { expected: '2026-10-31', range_start: '2026-10-29', range_end: '2026-11-02', cycle_confidence: 1 },
    overdue: false,
    days,
    phases,
    ...overrides,
  }
}

const september: CycleCalendar = {
  ...october(),
  from: '2026-09-01',
  to: '2026-09-30',
  days: [day('2026-09-05', { period: 'marked', marks: [{ id: 'start-sep', kind: 'period_start', source: 'manual' }] })],
}

const phasesProfile: Profile = {
  sex_at_birth: 'female',
  session_minutes: 60,
  cycle_tracking: 'manual',
  is_complete: true,
  cycle: { phase_mode: 'phases' },
}

function todayOnly(calendar: CycleCalendar): CycleCalendar {
  return { ...calendar, from: TODAY, to: TODAY, days: calendar.days.filter((d) => d.date === TODAY) }
}

function mount(overrides: Partial<ApiClient> = {}, profile: Profile = phasesProfile, month = october()) {
  const getCycleCalendar = vi.fn(async (from: string, to: string) =>
    from === to ? todayOnly(month) : from.startsWith('2026-09') ? september : month,
  )
  const rebuildWeek = vi.fn(async () => ({
    plan: { days: [], status_lines: [] },
    notice: { code: 'plan_rebuilt', params: {}, message: 'План обновлён' },
  }))
  const api = {
    today: () => ({ date: TODAY, tz: 'Europe/Moscow' }),
    getProfileIfStarted: async () => profile,
    getCycleCalendar,
    rebuildWeek,
    ...overrides,
  } as unknown as ApiClient
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={['/cycle']}>
        <Routes>
          <Route path="/cycle" element={<CycleCalendarScreen api={api} />} />
          <Route path="*" element={null} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  )
  return { getCycleCalendar, rebuildWeek }
}

const cell = (date: string) => screen.findByRole('button', { name: new RegExp(`, ${Number(date.slice(8))} октября`) })
async function open(date: string) {
  const button = document.querySelector(`[data-date="${date}"].month-day`) ?? (await waitFor(() => {
    const found = document.querySelector(`[data-date="${date}"].month-day`)
    if (!found) throw new Error('нет дня')
    return found
  }))
  fireEvent.click(button)
  return screen.findByTestId('day-panel')
}

describe('сетка месяца', () => {
  it('запрашивает окно месяца и раскладывает дни с состояниями сервера', async () => {
    const { getCycleCalendar } = mount()
    await screen.findByTestId('cycle-month')
    expect(getCycleCalendar).toHaveBeenCalledWith('2026-10-01', '2026-10-31')
    const at = (date: string) => document.querySelector(`[data-date="${date}"].month-day`)!
    expect(at('2026-10-03').getAttribute('data-period')).toBe('marked')
    expect(at('2026-10-04').getAttribute('data-period')).toBe('estimated')
    expect(at('2026-10-31').getAttribute('data-period')).toBe('forecast')
    expect(at('2026-10-17').getAttribute('data-ovulation')).toBe('true')
    expect(at('2026-10-12').getAttribute('data-today')).toBe('true')
    expect(at('2026-10-29').getAttribute('data-range')).toBe('true')
    expect(at('2026-10-28').getAttribute('data-range')).toBe('false')
    expect(document.querySelectorAll('.month-day')).toHaveLength(31)
  })

  it('доступное имя дня называет состояние словами', async () => {
    mount()
    expect(await cell('2026-10-17')).toHaveAccessibleName(/примерная овуляция/)
    expect(await cell('2026-10-03')).toHaveAccessibleName(/месячные/)
    expect(await cell('2026-10-12')).toHaveAccessibleName(/сегодня/)
  })

  it('ожидаемое начало и диапазон — из ответа сервера', async () => {
    mount()
    expect(await screen.findByTestId('next-period')).toHaveTextContent('31 октября')
    expect(screen.getByTestId('next-period')).toHaveTextContent('от 29 октября до 2 ноября')
  })

  it('листание месяца запрашивает соседнее окно', async () => {
    const { getCycleCalendar } = mount()
    await screen.findByTestId('cycle-month')
    fireEvent.click(screen.getByRole('button', { name: 'Предыдущий месяц' }))
    await waitFor(() => expect(getCycleCalendar).toHaveBeenCalledWith('2026-09-01', '2026-09-30'))
  })

  it('фаза сегодня с текстами из ответа', async () => {
    mount()
    const card = await screen.findByTestId('phase-card')
    expect(card).toHaveAttribute('data-phase', 'follicular')
    expect(within(card).getByText('Имя follicular')).toBeInTheDocument()
    expect(within(card).getByTestId('phase-feeling')).toHaveTextContent('Самочувствие follicular')
    expect(within(card).getByTestId('phase-why')).toHaveTextContent('Почему follicular')
  })
})

describe('тап по дню', () => {
  it('отметка начала: запись, затем /rebuild с cycle_event_added и показ notice', async () => {
    const { rebuildWeek } = mount()
    const panel = await open('2026-10-10')
    fireEvent.click(within(panel).getByRole('button', { name: 'Начались месячные' }))
    await waitFor(() => expect(direct.insertCycleEvent).toHaveBeenCalledWith('user-1', 'period_start', '2026-10-10'))
    await waitFor(() => expect(rebuildWeek).toHaveBeenCalledWith('cycle_event_added'))
    expect(await screen.findByTestId('cycle-notice')).toHaveTextContent('План обновлён')
    expect(direct.insertCycleEvent.mock.invocationCallOrder[0]!).toBeLessThan(rebuildWeek.mock.invocationCallOrder[0]!)
  })

  it('отметка конца пишет period_end', async () => {
    mount()
    const panel = await open('2026-10-07')
    fireEvent.click(within(panel).getByRole('button', { name: 'Закончились' }))
    await waitFor(() => expect(direct.insertCycleEvent).toHaveBeenCalledWith('user-1', 'period_end', '2026-10-07'))
  })

  it('будущий день отметить нельзя', async () => {
    mount()
    const panel = await open('2026-10-20')
    expect(within(panel).queryByRole('button', { name: 'Начались месячные' })).toBeNull()
  })

  it('уже есть начало в этот день — второе не ставится', async () => {
    mount()
    const panel = await open('2026-10-03')
    expect(within(panel).getByRole('button', { name: 'Начались месячные' })).toBeDisabled()
  })

  it('последнее событие: удалить и перенести, оба через /rebuild', async () => {
    const { rebuildWeek } = mount()
    const panel = await open('2026-10-03')
    const row = await within(panel).findByTestId('mark-editable')
    fireEvent.click(within(row).getByRole('button', { name: 'Удалить' }))
    await waitFor(() => expect(direct.deleteCycleEvent).toHaveBeenCalledWith('start-oct'))
    await waitFor(() => expect(rebuildWeek).toHaveBeenCalledTimes(1))

    fireEvent.change(within(row).getByLabelText('Перенести на'), { target: { value: '2026-10-02' } })
    fireEvent.click(within(row).getByRole('button', { name: 'Перенести' }))
    await waitFor(() => expect(direct.moveCycleEvent).toHaveBeenCalledWith('start-oct', '2026-10-02'))
    await waitFor(() => expect(rebuildWeek).toHaveBeenCalledTimes(2))
  })

  it('перенос раньше предыдущего события или в будущее заблокирован', async () => {
    mount()
    const panel = await open('2026-10-03')
    const row = await within(panel).findByTestId('mark-editable')
    const move = within(row).getByRole('button', { name: 'Перенести' })
    fireEvent.change(within(row).getByLabelText('Перенести на'), { target: { value: '2026-09-05' } })
    expect(move).toBeDisabled()
    fireEvent.change(within(row).getByLabelText('Перенести на'), { target: { value: '2026-10-13' } })
    expect(move).toBeDisabled()
  })

  it('старое событие — только просмотр, без кнопок правки', async () => {
    mount()
    await screen.findByTestId('cycle-month')
    fireEvent.click(screen.getByRole('button', { name: 'Предыдущий месяц' }))
    const panel = await open('2026-09-05')
    const row = await within(panel).findByTestId('mark-readonly')
    expect(row).toHaveTextContent('Только просмотр')
    expect(within(panel).queryByRole('button', { name: 'Удалить' })).toBeNull()
    expect(within(panel).queryByRole('button', { name: 'Перенести' })).toBeNull()
  })

  it('ошибка записи видна, /rebuild не зовётся', async () => {
    direct.insertCycleEvent.mockRejectedValueOnce(new Error('Не удалось записать отметку: RLS'))
    const { rebuildWeek } = mount()
    const panel = await open('2026-10-10')
    fireEvent.click(within(panel).getByRole('button', { name: 'Начались месячные' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('RLS')
    expect(rebuildWeek).not.toHaveBeenCalled()
  })
})

describe('режимы', () => {
  it('выключенный цикл — без сетки, с переходом к включению', async () => {
    mount({}, { ...phasesProfile, cycle_tracking: 'off', cycle: { phase_mode: 'no_phases', no_phase_reason: 'user_choice' } })
    expect(await screen.findByText('Цикл выключен.')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Включить отслеживание цикла' })).toHaveAttribute('href', '/cycle/enable')
    expect(screen.queryByTestId('cycle-month')).toBeNull()
  })

  it('low_confidence — сетка есть, отмечать можно', async () => {
    mount({}, { ...phasesProfile, cycle: { phase_mode: 'no_phases', no_phase_reason: 'low_confidence' } })
    const panel = await open('2026-10-10')
    expect(within(panel).getByRole('button', { name: 'Начались месячные' })).toBeEnabled()
  })
})

describe('карточка фазы', () => {
  it('фазы нет (ниже порога) — карточки нет', () => {
    const calendar = october()
    calendar.days = calendar.days.map((d) => (d.date === TODAY ? day(TODAY) : d))
    const { container } = render(<PhaseCard calendar={calendar} today={TODAY} />)
    expect(container).toBeEmptyDOMElement()
  })
})

describe('«Месячные уже начались?»', () => {
  function store(): FlagStore & { data: Map<string, string> } {
    const data = new Map<string, string>()
    return { data, get: (k) => data.get(k) ?? null, set: (k, v) => void data.set(k, v) }
  }
  const overdue = october({ overdue: true, next_period: { expected: '2026-10-10', range_start: '2026-10-08', range_end: '2026-10-12', cycle_confidence: 0.6 } })

  function show(flags: FlagStore, api: Partial<ApiClient> = {}) {
    const full = {
      today: () => ({ date: TODAY, tz: 'Europe/Moscow' }),
      rebuildWeek: vi.fn(async () => ({ plan: { days: [], status_lines: [] } })),
      ...api,
    } as unknown as ApiClient
    render(
      <QueryClientProvider client={new QueryClient()}>
        <OverdueQuestion api={full} calendar={overdue} today={TODAY} store={flags} />
      </QueryClientProvider>,
    )
    return full
  }

  it('«Ещё нет» — вопрос уходит и помнится на эту дату, записи нет', async () => {
    const flags = store()
    show(flags)
    fireEvent.click(screen.getByRole('button', { name: 'Ещё нет' }))
    await waitFor(() => expect(screen.queryByTestId('overdue-question')).toBeNull())
    expect([...flags.data.keys()]).toEqual(['fittrack.cycle.overdue-asked.2026-10-10'])
    expect(direct.insertCycleEvent).not.toHaveBeenCalled()
  })

  it('«Да, отметить» — начало сегодня, /rebuild, ответ запомнен', async () => {
    const flags = store()
    const api = show(flags)
    fireEvent.click(screen.getByRole('button', { name: 'Да, отметить' }))
    await waitFor(() => expect(direct.insertCycleEvent).toHaveBeenCalledWith('user-1', 'period_start', TODAY))
    await waitFor(() => expect(api.rebuildWeek).toHaveBeenCalledWith('cycle_event_added'))
    await waitFor(() => expect(flags.data.size).toBe(1))
  })

  it('уже отвечали на эту дату — не спрашивает', () => {
    const flags = store()
    flags.set('fittrack.cycle.overdue-asked.2026-10-10', '1')
    show(flags)
    expect(screen.queryByTestId('overdue-question')).toBeNull()
  })

  it('запись не удалась — ответ не запомнен, вопрос остаётся', async () => {
    direct.insertCycleEvent.mockRejectedValueOnce(new Error('сеть'))
    const flags = store()
    show(flags)
    fireEvent.click(screen.getByRole('button', { name: 'Да, отметить' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('сеть')
    expect(flags.data.size).toBe(0)
    expect(screen.getByTestId('overdue-question')).toBeInTheDocument()
  })
})
