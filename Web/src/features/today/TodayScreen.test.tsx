import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { ApiClient, ApiError } from '../../api/client'
import type { TodayCard } from '../../api/schemas'
import { TodayScreen } from './TodayScreen'

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
