import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { ApiClient, ApiError } from '../../api/client'
import type { Reason, TodayCard, WeekDay, WeekPlanResponse } from '../../api/schemas'
import { TodayScreen } from './TodayScreen'

// «Сегодня» тянет за собой запись событий цикла (`direct/cycle`), а с ней
// supabase-js, который без переменных среды теста не создаётся. Тесту экрана
// прямые записи не нужны.
vi.mock('../../auth/supabase', () => ({ currentUserId: async () => 'user-1' }))

afterEach(cleanup)

const card: TodayCard = {
  date: '2026-10-12',
  readiness: 1,
  cycle: { phase_mode: 'no_phases', has_anchor: false },
  day: {
    day_id: 'day-1',
    kind: 'session',
    loses_planned_volume: false,
    session: {
      day_id: 'day-1',
      estimated_seconds: 2400,
      session_kind: 'lower',
      session_kind_name: 'Низ тела',
      reasons: [],
      exercises: [
        {
          slug: 'squat_barbell',
          order_index: 0,
          target_sets: 3,
          target_rep_min: 6,
          target_rep_max: 10,
          target_rir: 2,
          weight_readiness: 1,
        },
      ],
    },
  },
  reasons: [],
}

function Where() {
  return <p data-testid="location">{useLocation().pathname}</p>
}

function mount(overrides: Partial<ApiClient>) {
  const api = {
    getToday: async () => card,
    getExercises: async () => [],
    getWeekPlan: async () => null,
    today: () => ({ date: '2026-10-12', tz: 'Europe/Moscow' }),
    ...overrides,
  } as unknown as ApiClient
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={['/']}>
        <Where />
        <Routes>
          <Route path="/" element={<TodayScreen api={api} />} />
          <Route path="*" element={null} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

const press = async () => fireEvent.click(await screen.findByRole('button', { name: 'Начать тренировку' }))
const at = () => screen.getByTestId('location').textContent

describe('«Начать» на экране «Сегодня»', () => {
  it('успех — переход на экран тренировки', async () => {
    const startWorkout = vi.fn(async () => ({ id: 'w-1' }))
    mount({ startWorkout: startWorkout as unknown as ApiClient['startWorkout'] })
    await press()
    await waitFor(() => expect(at()).toBe('/workout/w-1'))
    expect(startWorkout).toHaveBeenCalledWith('day-1')
  })

  it('unlinked_account — экран привязки, а не ошибка', async () => {
    mount({
      startWorkout: (async () => {
        throw new ApiError(403, 'unlinked_account', 'Привяжите аккаунт')
      }) as unknown as ApiClient['startWorkout'],
    })
    await press()
    await waitFor(() => expect(at()).toBe('/link'))
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it('day_not_planned с workout_id — идущая тренировка', async () => {
    mount({
      startWorkout: (async () => {
        throw new ApiError(409, 'day_not_planned', 'Этот день уже закрыт', { workout_id: 'w-9' })
      }) as unknown as ApiClient['startWorkout'],
    })
    await press()
    await waitFor(() => expect(at()).toBe('/workout/w-9'))
  })

  it('прочая ошибка показывается и остаётся на экране', async () => {
    mount({
      startWorkout: (async () => {
        throw new ApiError(422, 'date_skew', 'Проверьте часы', { server: '2026-10-10' })
      }) as unknown as ApiClient['startWorkout'],
    })
    await press()
    expect((await screen.findByRole('alert')).textContent).toBe('Проверьте часы')
    expect(at()).toBe('/')
  })

  it('день уже начат — «Продолжить» зовёт тот же старт и ведёт в тренировку', async () => {
    const startWorkout = vi.fn(async () => ({ id: 'w-1' }))
    mount({
      startWorkout: startWorkout as unknown as ApiClient['startWorkout'],
      getToday: async () => ({
        ...card,
        day: {
          day_id: 'day-1',
          kind: 'not_built' as const,
          loses_planned_volume: false,
          cause: { code: 'started' as const, params: {}, message: 'День уже начат' },
        },
      }),
    })
    expect(screen.queryByRole('button', { name: 'Начать тренировку' })).toBeNull()
    fireEvent.click(await screen.findByRole('button', { name: 'Продолжить тренировку' }))
    await waitFor(() => expect(at()).toBe('/workout/w-1'))
    expect(startWorkout).toHaveBeenCalledWith('day-1')
  })

  it('закрытый день (done) — не «Продолжить», хотя строка плана есть', async () => {
    mount({
      getToday: async () => ({
        ...card,
        day: {
          day_id: 'day-1',
          kind: 'not_built' as const,
          loses_planned_volume: false,
          cause: { code: 'done' as const, params: {}, message: 'Тренировка выполнена' },
        },
      }),
    })
    await screen.findByTestId('day-not-built')
    expect(screen.queryByRole('button', { name: /тренировку/ })).toBeNull()
  })

  it('кнопки нет, когда у дня нет строки плана', async () => {
    mount({
      getToday: async () => ({
        ...card,
        day: { kind: 'not_built' as const, loses_planned_volume: false },
      }),
    })
    await screen.findByTestId('day-not-built')
    expect(screen.queryByRole('button', { name: 'Начать тренировку' })).toBeNull()
  })
})

describe('неделя не сгенерирована', () => {
  const notBuilt: TodayCard = { ...card, day: { kind: 'not_built', loses_planned_volume: false } }

  it('кнопка «Собрать неделю» зовёт генерацию и перечитывает карточку', async () => {
    let built = false
    const generateWeek = vi.fn(async () => {
      built = true
      return { plan: { days: [], status_lines: [] } }
    })
    mount({
      getToday: (async () => (built ? card : notBuilt)) as ApiClient['getToday'],
      generateWeek: generateWeek as unknown as ApiClient['generateWeek'],
    })
    fireEvent.click(await screen.findByRole('button', { name: 'Собрать неделю' }))
    await screen.findByRole('button', { name: 'Начать тренировку' })
    expect(generateWeek).toHaveBeenCalledTimes(1)
  })

  it('день отдыха (есть cause) кнопки «Собрать неделю» не получает', async () => {
    const rest: TodayCard = {
      ...card,
      day: {
        kind: 'not_built',
        loses_planned_volume: false,
        cause: { code: 'not_a_training_day', params: {}, message: 'Сегодня отдых' },
      },
    }
    mount({ getToday: (async () => rest) as ApiClient['getToday'] })
    await screen.findByTestId('day-not-built')
    expect(screen.queryByRole('button', { name: 'Собрать неделю' })).toBeNull()
  })
})

describe('календарь недели и тип дня', () => {
  const weekDay = (date: string, extra: Partial<WeekDay> = {}): WeekDay => ({
    date,
    day_id: `d-${date}`,
    session_kind: 'upper',
    session_kind_name: 'Верх тела',
    kind: 'session',
    loses_planned_volume: false,
    ...extra,
  })
  const week = (days: WeekDay[], notice?: Reason): WeekPlanResponse => ({
    plan: { days, status_lines: [] },
    ...(notice ? { notice } : {}),
  })
  const states = () =>
    [...document.querySelectorAll('[data-testid="week-calendar"] > li')].map(
      (li) => `${li.getAttribute('data-status')}${li.getAttribute('data-today') === 'true' ? '*' : ''}`,
    )

  it('чип — название типа дня, которое отдал сервер', async () => {
    mount({})
    expect((await screen.findByTestId('session-kind')).textContent).toBe('Низ тела')
  })

  it('неделя запрашивается с понедельника даты карточки, дни — по своим датам', async () => {
    const getWeekPlan = vi.fn(async () =>
      week([weekDay('2026-10-19'), weekDay('2026-10-21'), weekDay('2026-10-23', {
        kind: 'not_built',
        cause: { code: 'done', params: {}, message: 'День выполнен' },
      })]),
    )
    // Карточка — на неделю позже часов браузера (`today()` в mount — 12-е):
    // неделя обязана считаться от даты карточки.
    mount({ getToday: async () => ({ ...card, date: '2026-10-21' }), getWeekPlan })
    await waitFor(() => expect(states()).toEqual(['planned', 'none', 'planned*', 'none', 'done', 'none', 'none']))
    expect(getWeekPlan).toHaveBeenCalledWith('2026-10-19')
    expect(screen.getByRole('listitem', { name: /21 октября, сегодня, запланирована тренировка/ })).toBeTruthy()
    expect(screen.getByRole('listitem', { name: /23 октября, тренировка выполнена/ })).toBeTruthy()
  })

  it('«План обновлён» из ответа недели показывается', async () => {
    const notice = { code: 'plan_changed', params: {}, message: 'План обновлён' } as Reason
    mount({ getWeekPlan: async () => week([weekDay('2026-10-12')], notice) })
    expect((await screen.findByTestId('week-notice')).textContent).toBe('План обновлён')
  })

  it('недели нет — семь дат, сегодня залито, тренировок нет; ошибки нет', async () => {
    mount({ getWeekPlan: async () => null })
    await waitFor(() => expect(states()).toEqual(['none*', 'none', 'none', 'none', 'none', 'none', 'none']))
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it('ошибка недели видна, а карточка дня остаётся', async () => {
    mount({
      getWeekPlan: async () => {
        throw new ApiError(503, 'jwks_unavailable', 'Сервис недоступен, повторите')
      },
    })
    expect((await screen.findByRole('alert')).textContent).toBe('Сервис недоступен, повторите')
    expect(screen.getByRole('button', { name: 'Начать тренировку' })).toBeTruthy()
  })
})

describe('фаза цикла на «Сегодня»', () => {
  const calendar = {
    from: '2026-10-12',
    to: '2026-10-12',
    cycle: { phase_mode: 'phases', has_anchor: true, phase: 'follicular', cycle_confidence: 1 },
    overdue: false,
    days: [{ date: '2026-10-12', marks: [], phase: 'follicular', cycle_confidence: 1, ovulation_estimate: false }],
    phases: [{ phase: 'follicular', name: 'После месячных', feeling: 'Сил больше', why: 'Эстроген', note: 'Общая' }],
  }
  const profile = (cycle: object, tracking = 'manual') => ({
    sex_at_birth: 'female', session_minutes: 60, cycle_tracking: tracking, is_complete: true, cycle,
  })

  it('режим фаз — карточка фазы с текстом сервера, окно — один сегодняшний день', async () => {
    const getCycleCalendar = vi.fn(async () => calendar)
    mount({
      getProfileIfStarted: (async () => profile({ phase_mode: 'phases' })) as unknown as ApiClient['getProfileIfStarted'],
      getCycleCalendar: getCycleCalendar as unknown as ApiClient['getCycleCalendar'],
    })
    expect((await screen.findByTestId('phase-feeling')).textContent).toBe('Сил больше')
    expect(getCycleCalendar).toHaveBeenCalledWith('2026-10-12', '2026-10-12')
  })

  it('цикл выключен — календарь не запрашивается, карточки нет', async () => {
    const getCycleCalendar = vi.fn(async () => calendar)
    mount({
      getProfileIfStarted: (async () =>
        profile({ phase_mode: 'no_phases', no_phase_reason: 'contraception' })) as unknown as ApiClient['getProfileIfStarted'],
      getCycleCalendar: getCycleCalendar as unknown as ApiClient['getCycleCalendar'],
    })
    await screen.findByTestId('session-kind')
    expect(screen.queryByTestId('phase-card')).toBeNull()
    expect(getCycleCalendar).not.toHaveBeenCalled()
  })
})

