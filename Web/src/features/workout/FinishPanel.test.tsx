import { afterEach, describe, expect, it, vi } from 'vitest'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { ApiError, NetworkError, type ApiClient } from '../../api/client'
import type { FinishWorkoutResponse, LogSetResponse, Workout } from '../../api/schemas'
import { WorkoutScreen } from './WorkoutScreen'

afterEach(cleanup)

const tree = {
  start: 'n0',
  nodes: {
    n0: { weight_kg: 40, truncated: false, terminates: false, transitions: { ok: 'n0' } },
  },
}

const running: Workout = {
  id: 'w-1',
  planned_day_id: 'd-1',
  session_kind: 'lower',
  started_at: '2026-10-12T09:00:00Z',
  readiness: 1,
  is_calibration: false,
  exercises: [
    {
      id: 'we-1',
      slug: 'squat_barbell',
      order_index: 0,
      target_sets: 3,
      target_rep_min: 6,
      target_rep_max: 10,
      target_rir: 2,
      prescribed_kg: 40,
      weight_readiness: 1,
      is_calibration: false,
      decision_tree: tree,
      sets: [],
    },
  ],
}

const closed: Workout = {
  ...running,
  finished_at: '2026-10-12T09:50:00Z',
  exercises: [
    {
      ...running.exercises[0]!,
      sets: [
        {
          id: 's-1',
          exercise_slug: 'squat_barbell',
          set_index: 1,
          prescribed_kg: 40,
          prescribed_reps: 10,
          actual_kg: 40,
          actual_reps: 9,
          feedback: 'ok',
          pain_flag: false,
          pain_joints: [],
          skipped: false,
        },
      ],
    },
  ],
}

const notice = {
  code: 'plan_rebuilt' as const,
  params: { cause: { code: 'workout_completed' as const, params: {}, message: 'тренировка выполнена' } },
  message: 'План обновлён: тренировка выполнена',
}
const week = { plan: { days: [], status_lines: [] }, notice }

type Api = Pick<ApiClient, 'getWorkout' | 'getExercises' | 'finishWorkout' | 'logSet'>

function mount(overrides: Partial<Api>) {
  const api: Api = {
    getWorkout: vi.fn(async () => running),
    getExercises: vi.fn(async () => []),
    finishWorkout: vi.fn(async () => ({ workout: closed, week })),
    logSet: vi.fn(async (): Promise<LogSetResponse> => ({ decision_tree: tree })),
    ...overrides,
  }
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={['/workout/w-1']}>
        <Routes>
          <Route path="/workout/:id" element={<WorkoutScreen api={api as ApiClient} />} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  )
  return { api, client }
}

const flush = () => act(async () => {})
/** Экран загружается через react-query: ждём кнопку, а не считаем микрозадачи. */
const ready = () => waitFor(() => expect(finishButton()).toBeTruthy())
const finishButton = () => screen.getByRole('button', { name: 'Завершить тренировку' })

describe('положение в тренировке', () => {
  const second = { ...running.exercises[0]!, id: 'we-2', slug: 'pushup_bw', order_index: 1 }
  const firstDone = { ...closed.exercises[0]!, target_sets: 1 }
  const segments = () => [...document.querySelectorAll('.progress > li')].map((li) => li.getAttribute('data-state'))

  it('«Упражнение N из M» и сегменты — по первому открытому упражнению', async () => {
    mount({ getWorkout: vi.fn(async () => ({ ...running, exercises: [second, firstDone] })) })
    await ready()
    expect(screen.getByTestId('exercise-position').textContent).toBe('Упражнение 2 из 2')
    expect(segments()).toEqual(['done', 'current'])
  })

  it('всё выполнено: номера нет, все сегменты закрыты', async () => {
    mount({ getWorkout: vi.fn(async () => ({ ...running, exercises: [firstDone] })) })
    await ready()
    expect(screen.getByTestId('exercise-position').textContent).toBe('')
    expect(segments()).toEqual(['done'])
  })

  it('завершённая тренировка: верхней строки и полосы нет', async () => {
    mount({ getWorkout: vi.fn(async () => closed) })
    await waitFor(() => expect(screen.getByTestId('summary')).toBeTruthy())
    expect(screen.queryByTestId('exercise-position')).toBeNull()
    expect(segments()).toEqual([])
  })
})

describe('завершение тренировки', () => {
  it('«Завершить» зовёт /finish один раз и показывает сводку со строкой «План обновлён»', async () => {
    const { api } = mount({})
    await ready()
    fireEvent.click(finishButton())
    await flush()
    expect(api.finishWorkout).toHaveBeenCalledTimes(1)
    expect(api.finishWorkout).toHaveBeenCalledWith('w-1')
    expect(screen.getByTestId('plan-notice').textContent).toBe('План обновлён: тренировка выполнена')
    expect(screen.getByTestId('workout-state').textContent).toBe('Завершена')
    expect(screen.getByTestId('summary-total').textContent).toBe('Выполнено подходов: 1')
    expect(screen.getByTestId('summary-exercises').textContent).toContain('squat_barbell: 1 из 3')
    expect(screen.queryByRole('button', { name: 'Завершить тренировку' })).toBeNull()
  })

  it('ответ без notice или без недели: сводка есть, строки «План обновлён» нет', async () => {
    mount({ finishWorkout: vi.fn(async (): Promise<FinishWorkoutResponse> => ({ workout: closed })) })
    await ready()
    fireEvent.click(finishButton())
    await flush()
    expect(screen.getByTestId('summary')).toBeTruthy()
    expect(screen.queryByTestId('plan-notice')).toBeNull()
  })

  it('обрыв: явная ошибка и «Повторить»; повтор приходит как второй вызов и завершает', async () => {
    const finishWorkout = vi
      .fn<ApiClient['finishWorkout']>()
      .mockRejectedValueOnce(new NetworkError('/v1/workouts/w-1/finish', new Error('x')))
      .mockResolvedValueOnce({ workout: closed, week: { plan: week.plan } })
    mount({ finishWorkout })
    await ready()
    fireEvent.click(finishButton())
    await flush()
    expect(screen.getByTestId('finish-failure').textContent).toContain('Нет связи')
    expect(screen.queryByTestId('summary')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Повторить' }))
    await flush()
    expect(finishWorkout).toHaveBeenCalledTimes(2)
    expect(screen.getByTestId('summary')).toBeTruthy()
    expect(screen.queryByTestId('finish-failure')).toBeNull()
  })

  it('ошибка сервера показывает message, а не details', async () => {
    mount({
      finishWorkout: vi.fn(async () => {
        throw new ApiError(422, 'date_skew', 'Часы расходятся с сервером', { sent: '2026-10-12', server: '2026-10-15' })
      }),
    })
    await ready()
    fireEvent.click(finishButton())
    await flush()
    const text = screen.getByTestId('finish-failure').textContent ?? ''
    expect(text).toContain('Часы расходятся с сервером')
    expect(text).not.toContain('2026-10-15')
  })

  it('пока подход не подтверждён сервером, завершить нельзя', async () => {
    let resolve!: (r: LogSetResponse) => void
    mount({ logSet: vi.fn(() => new Promise<LogSetResponse>((r) => (resolve = r))) })
    await ready()
    expect((finishButton() as HTMLButtonElement).disabled).toBe(false)
    fireEvent.click(document.querySelector('[data-feedback="ok"]') as HTMLElement)
    await flush()
    expect((finishButton() as HTMLButtonElement).disabled).toBe(true)
    await act(async () => resolve({ decision_tree: tree }))
    // Подтверждение приходит через кеш, а он оповещает позже ответа.
    await waitFor(() => expect((finishButton() as HTMLButtonElement).disabled).toBe(false))
  })

  it('уже завершённая тренировка открывается сразу сводкой, без кнопки', async () => {
    mount({ getWorkout: vi.fn(async () => closed) })
    await waitFor(() => expect(screen.getByTestId('summary')).toBeTruthy())
    expect(screen.queryByTestId('plan-notice')).toBeNull()
    expect(screen.queryByRole('button', { name: 'Завершить тренировку' })).toBeNull()
  })
})
