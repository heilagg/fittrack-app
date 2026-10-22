import { afterEach, describe, expect, it, vi } from 'vitest'
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { ApiError, NetworkError, type ApiClient } from '../../api/client'
import type { FinishWorkoutResponse, LogSetResponse, Workout } from '../../api/schemas'
import { setsWord } from './FinishPanel'
import { answer, echo } from './logSetTesting'
import { WorkoutScreen } from './WorkoutScreen'

// «Сегодня» тянет за собой запись событий цикла (`direct/cycle`), а с ней
// supabase-js, который без переменных среды теста не создаётся. Тесту экрана
// прямые записи не нужны.
vi.mock('../../auth/supabase', () => ({ currentUserId: async () => 'user-1' }))

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
      weighted: true,
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
    finishWorkout: vi.fn(async () => ({ workout: closed, week, cooldown: [{ pose: 'pigeon_pose', seconds: 45 }] })),
    logSet: vi.fn(answer({ decision_tree: tree })),
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
/** «Завершить» с невыполненными подходами переспрашивает (§13.2): подтверждаем. */
const finish = () => {
  fireEvent.click(finishButton())
  const confirm = screen.queryByTestId('finish-confirm')
  if (confirm) fireEvent.click(within(confirm).getByRole('button', { name: 'Завершить' }))
}

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

  it('два открытых: текущее — первое по порядку', async () => {
    mount({ getWorkout: vi.fn(async () => ({ ...running, exercises: [second, running.exercises[0]!] })) })
    await ready()
    expect(screen.getByTestId('exercise-position').textContent).toBe('Упражнение 1 из 2')
    expect(screen.getByTestId('current-exercise').textContent).toBe('squat_barbell')
    expect(segments()).toEqual(['current', 'upcoming'])
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
    finish()
    await flush()
    expect(api.finishWorkout).toHaveBeenCalledTimes(1)
    expect(api.finishWorkout).toHaveBeenCalledWith('w-1')
    expect(screen.getByTestId('plan-notice').textContent).toBe('План обновлён: тренировка выполнена')
    expect(screen.getByTestId('workout-state').textContent).toBe('Завершена')
    expect(screen.getByTestId('summary-total').textContent).toBe('Выполнено подходов: 1')
    expect(screen.getByTestId('summary-exercises').textContent).toContain('squat_barbell: 1 из 3')
    expect(screen.queryByRole('button', { name: 'Завершить тренировку' })).toBeNull()
    // Заминка из ответа (§12.2): предложение со ссылкой в проигрыватель.
    expect(screen.getByTestId('cooldown-offer').textContent).toContain('1 поза')
    expect(screen.getByRole('link', { name: 'Начать заминку' }).getAttribute('href')).toBe('/stretch/cooldown')
  })

  it('ответ без notice или без недели: сводка есть, строки «План обновлён» нет', async () => {
    mount({ finishWorkout: vi.fn(async (): Promise<FinishWorkoutResponse> => ({ workout: closed, cooldown: [] })) })
    await ready()
    finish()
    await flush()
    expect(screen.getByTestId('summary')).toBeTruthy()
    expect(screen.queryByTestId('plan-notice')).toBeNull()
    expect(screen.queryByTestId('cooldown-offer')).toBeNull()
  })

  it('обрыв: явная ошибка и «Повторить»; повтор приходит как второй вызов и завершает', async () => {
    const finishWorkout = vi
      .fn<ApiClient['finishWorkout']>()
      .mockRejectedValueOnce(new NetworkError('/v1/workouts/w-1/finish', new Error('x')))
      .mockResolvedValueOnce({ workout: closed, week: { plan: week.plan }, cooldown: [] })
    mount({ finishWorkout })
    await ready()
    finish()
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
    finish()
    await flush()
    const text = screen.getByTestId('finish-failure').textContent ?? ''
    expect(text).toContain('Часы расходятся с сервером')
    expect(text).not.toContain('2026-10-15')
  })

  it('пока подход не подтверждён сервером, завершить нельзя', async () => {
    let resolve!: (r: LogSetResponse) => void
    const { api } = mount({ logSet: vi.fn(() => new Promise<LogSetResponse>((r) => (resolve = r))) })
    await ready()
    expect((finishButton() as HTMLButtonElement).disabled).toBe(false)
    fireEvent.click(document.querySelector('[data-feedback="ok"]') as HTMLElement)
    await flush()
    expect((finishButton() as HTMLButtonElement).disabled).toBe(true)
    await act(async () => resolve(echo({ decision_tree: tree }, api.logSet as unknown as Parameters<typeof echo>[1])))
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

describe('подтверждение «Завершить» (§13.2) и экран после завершения', () => {
  it('остались подходы — «Завершить» переспрашивает; «Продолжить» не завершает', async () => {
    const { api } = mount({})
    await ready()
    fireEvent.click(finishButton())
    const confirm = screen.getByTestId('finish-confirm')
    expect(confirm.textContent).toContain('Осталось 3 подхода. Завершить тренировку?')
    fireEvent.click(within(confirm).getByRole('button', { name: 'Продолжить тренировку' }))
    expect(screen.queryByTestId('finish-confirm')).toBeNull()
    expect(api.finishWorkout).not.toHaveBeenCalled()
    fireEvent.click(finishButton())
    fireEvent.click(within(screen.getByTestId('finish-confirm')).getByRole('button', { name: 'Завершить' }))
    await flush()
    expect(api.finishWorkout).toHaveBeenCalledTimes(1)
  })

  it('подходов не осталось — завершение сразу, без вопроса', async () => {
    const done = { ...closed.exercises[0]!, target_sets: 1 }
    const { api } = mount({ getWorkout: vi.fn(async () => ({ ...running, exercises: [done] })) })
    await ready()
    fireEvent.click(finishButton())
    expect(screen.queryByTestId('finish-confirm')).toBeNull()
    await flush()
    expect(api.finishWorkout).toHaveBeenCalledTimes(1)
  })

  it('после завершения: без плашки калибровки, без второго списка состава, повторы — «повт.»', async () => {
    const calibrating = { ...closed, is_calibration: true }
    mount({ getWorkout: vi.fn(async () => calibrating) })
    await waitFor(() => expect(screen.getByTestId('summary')).toBeTruthy())
    expect(screen.queryByTestId('calibration-chip')).toBeNull()
    expect(screen.queryByTestId('workout-exercises')).toBeNull()
    expect(screen.getByTestId('summary-exercises').textContent).toContain('40 кг × 9 повт.')
    expect(screen.queryByTestId('wake-lock')).toBeNull()
  })

  it('до завершения плашка калибровки и состав на месте', async () => {
    mount({ getWorkout: vi.fn(async () => ({ ...running, is_calibration: true })) })
    await ready()
    expect(screen.getByTestId('calibration-chip')).toBeTruthy()
    expect(screen.getByTestId('workout-exercises')).toBeTruthy()
  })
})

describe('склонение «подходов»', () => {
  it('1, 2–4, 5–20, 11–14, 21', () => {
    expect([1, 2, 4, 5, 11, 12, 14, 21, 22, 25, 101, 111].map(setsWord)).toEqual([
      '1 подход', '2 подхода', '4 подхода', '5 подходов', '11 подходов', '12 подходов', '14 подходов',
      '21 подход', '22 подхода', '25 подходов', '101 подход', '111 подходов',
    ])
  })
})
