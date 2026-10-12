import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider, useQuery } from '@tanstack/react-query'
import { ApiError, NetworkError, type ApiClient } from '../../api/client'
import type { ExerciseContent, LogSetResponse, Workout, WorkoutExercise } from '../../api/schemas'
import { ExercisePanel } from './ExercisePanel'

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['Date', 'setInterval', 'clearInterval'] })
  vi.setSystemTime(new Date('2026-10-12T09:30:00Z'))
})
afterEach(() => {
  cleanup()
  vi.useRealTimers()
})

const tree = {
  start: 'n0',
  nodes: {
    n0: {
      weight_kg: 40,
      truncated: false,
      terminates: false,
      transitions: {
        failed: 'n1',
        hard_below_min: 'n1',
        hard_at_or_above_min: 'n0',
        ok: 'n0',
        easy_below_max: 'n0',
        easy_at_or_above_max: 'n2',
      },
    },
    n1: { weight_kg: 36, truncated: false, terminates: false, transitions: {} },
    n2: { weight_kg: 42.5, truncated: false, terminates: false, transitions: {} },
  },
}

const exercise: WorkoutExercise = {
  id: 'we-1',
  slug: 'squat_barbell',
  order_index: 0,
  target_sets: 3,
  target_rep_min: 6,
  target_rep_max: 10,
  target_rir: 2,
  prescribed_kg: 40,
  weight_readiness: 1.0,
  is_calibration: false,
  decision_tree: tree,
  sets: [],
}

const content: ExerciseContent = {
  slug: 'squat_barbell',
  name: 'Приседания со штангой',
  cues: ['Колени по линии носков'],
  common_errors: [],
  illustration: 'placeholder/lower/squat_barbell',
  default_rest_seconds: 120,
}

const nextTree: LogSetResponse = {
  decision_tree: { ...tree, nodes: { ...tree.nodes, n0: { ...tree.nodes.n0, weight_kg: 42.5 } } },
}

function workoutWith(e: WorkoutExercise): Workout {
  return {
    id: 'w-1',
    session_kind: 'lower',
    started_at: '2026-10-12T09:00:00Z',
    readiness: 1,
    is_calibration: false,
    exercises: [e],
  }
}

type LogSet = ApiClient['logSet']

function mount(logSet: LogSet, e: WorkoutExercise = exercise, c: ExerciseContent | undefined = content) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  client.setQueryData(['workout', 'w-1'], workoutWith(e))
  const api = { logSet } as unknown as ApiClient
  // Как на экране тренировки: упражнение читается из кеша, и подтверждённый
  // подход вместе с новым деревом возвращается в панель оттуда.
  function Connected() {
    const { data } = useQuery({
      queryKey: ['workout', 'w-1'],
      queryFn: () => Promise.resolve(workoutWith(e)),
      staleTime: Infinity,
    })
    const current = data?.exercises[0]
    return current ? <ExercisePanel api={api} workoutId="w-1" exercise={current} content={c} /> : null
  }
  render(
    <QueryClientProvider client={client}>
      <Connected />
    </QueryClientProvider>,
  )
  return client
}

const tap = (feedback: string) =>
  fireEvent.click(document.querySelector(`[data-feedback="${feedback}"]`) as HTMLElement)
const weight = () => screen.getByTestId('weight').textContent
const flush = () => act(async () => {})

describe('экран упражнения', () => {
  it('до первого подхода: вес из корня дерева, повторы — верх диапазона, подход 1 из 3', () => {
    mount(vi.fn())
    expect(weight()).toBe('40 кг')
    expect(screen.getByTestId('reps').textContent).toBe('10')
    expect(screen.getByTestId('set-counter').textContent).toBe('Подход 1 из 3')
    expect(screen.getByTestId('current-exercise').textContent).toBe('Приседания со штангой')
  })

  it('тап: тело подхода — клиентский UUID, set_index с 1, вес дерева, повторы, фидбэк', async () => {
    const logSet = vi.fn<LogSet>(async () => nextTree)
    mount(logSet)
    tap('ok')
    await flush()
    expect(logSet).toHaveBeenCalledTimes(1)
    const [workoutId, exerciseId, body] = logSet.mock.calls[0]!
    expect([workoutId, exerciseId]).toEqual(['w-1', 'we-1'])
    expect(body.id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
    expect(body).toMatchObject({
      set_index: 1,
      prescribed_kg: 40,
      actual_kg: 40,
      actual_reps: 10,
      feedback: 'ok',
      pain_flag: false,
      skipped: false,
      completed_at: '2026-10-12T09:30:00.000Z',
    })
  })

  it('следующий вес показывается МГНОВЕННО, до ответа сервера', async () => {
    let resolve!: (r: LogSetResponse) => void
    const logSet = vi.fn<LogSet>(() => new Promise((r) => (resolve = r)))
    mount(logSet)
    tap('easy') // 10 повторов при rep_max 10 → easy_at_or_above_max
    expect(weight()).toBe('42.5 кг')
    expect(screen.getByTestId('set-counter').textContent).toBe('Подход 2 из 3')
    await act(async () => resolve(nextTree))
    expect(weight()).toBe('42.5 кг') // ответ сервера согласован с показанным
  })

  it('подход в пути отмечает свою кнопку фидбэка, подтверждённый — снимает отметку', async () => {
    let resolve!: (r: LogSetResponse) => void
    const logSet = vi.fn<LogSet>(() => new Promise((r) => (resolve = r)))
    mount(logSet)
    const selected = () =>
      [...document.querySelectorAll('[data-selected="true"]')].map((b) => b.getAttribute('data-feedback'))
    expect(selected()).toEqual([])
    tap('hard')
    expect(selected()).toEqual(['hard'])
    await act(async () => resolve(nextTree))
    await waitFor(() => expect(selected()).toEqual([]))
  })

  it('«легко» ниже верха диапазона вес не поднимает (повторы входят предикатом)', async () => {
    const logSet = vi.fn<LogSet>(() => new Promise(() => {}))
    mount(logSet)
    fireEvent.click(screen.getByLabelText('Меньше повторов')) // 9 < 10
    tap('easy')
    expect(weight()).toBe('40 кг')
    expect(logSet.mock.calls[0]![2].actual_reps).toBe(9)
  })

  it('«не смог» уводит вес вниз по дереву', () => {
    mount(vi.fn<LogSet>(() => new Promise(() => {})))
    tap('failed')
    expect(weight()).toBe('36 кг')
  })

  it('пока подход не подтверждён, следующий ввести нельзя: очереди нет', () => {
    const logSet = vi.fn<LogSet>(() => new Promise(() => {}))
    mount(logSet)
    tap('ok')
    tap('hard')
    expect(logSet).toHaveBeenCalledTimes(1)
    expect((document.querySelector('[data-feedback="ok"]') as HTMLButtonElement).disabled).toBe(true)
  })

  it('обрыв сети показан, подход не засчитан; повтор идёт с ТЕМ ЖЕ id', async () => {
    const logSet = vi
      .fn<LogSet>()
      .mockRejectedValueOnce(new NetworkError('/v1/x', new TypeError('network')))
      .mockResolvedValueOnce(nextTree)
    const client = mount(logSet)
    tap('ok')
    await flush()

    expect(screen.getByRole('alert').textContent).toContain('Нет связи')
    const cached = client.getQueryData<Workout>(['workout', 'w-1'])!
    expect(cached.exercises[0]!.sets).toHaveLength(0) // не записано — не показано

    fireEvent.click(screen.getByRole('button', { name: 'Повторить' }))
    await flush()
    expect(logSet).toHaveBeenCalledTimes(2)
    expect(logSet.mock.calls[1]![2].id).toBe(logSet.mock.calls[0]![2].id)
    expect(logSet.mock.calls[1]![2]).toEqual(logSet.mock.calls[0]![2])
    expect(screen.queryByRole('alert')).toBeNull()
    expect(client.getQueryData<Workout>(['workout', 'w-1'])!.exercises[0]!.sets).toHaveLength(1)
  })

  it('ошибка сервера показывает его формулировку', async () => {
    const logSet = vi.fn<LogSet>().mockRejectedValue(new ApiError(409, 'workout_finished', 'Тренировка уже завершена'))
    mount(logSet)
    tap('ok')
    await flush()
    expect(screen.getByRole('alert').textContent).toContain('Тренировка уже завершена')
  })

  it('подтверждённый подход попадает в кеш с новым деревом, номер подхода растёт', async () => {
    const client = mount(vi.fn<LogSet>(async () => nextTree))
    tap('ok')
    await flush()
    const cached = client.getQueryData<Workout>(['workout', 'w-1'])!.exercises[0]!
    expect(cached.sets).toHaveLength(1)
    expect(cached.sets[0]).toMatchObject({ set_index: 1, actual_reps: 10, feedback: 'ok', prescribed_kg: 40 })
    expect(cached.decision_tree).toEqual(nextTree.decision_tree)
  })

  it('упражнение без веса: в теле нет ни prescribed_kg, ни actual_kg', async () => {
    const bodyweight: WorkoutExercise = {
      ...exercise,
      slug: 'pushup_bw',
      prescribed_kg: undefined,
      decision_tree: {
        start: 'n0',
        nodes: {
          n0: { truncated: false, terminates: false, transitions: { ok: 'n0', failed: 'n1' } },
          n1: { truncated: false, terminates: false, transitions: {} },
        },
      },
    }
    const logSet = vi.fn<LogSet>(async () => ({ decision_tree: bodyweight.decision_tree! }))
    mount(logSet, bodyweight)
    expect(weight()).toBe('Без веса')
    tap('ok')
    await flush()
    const body = logSet.mock.calls[0]![2]
    expect('prescribed_kg' in body).toBe(false)
    expect('actual_kg' in body).toBe(false)
  })

  it('дерево с узлом terminates — упражнение завершено досрочно', () => {
    mount(vi.fn(), {
      ...exercise,
      decision_tree: { start: 'n0', nodes: { n0: { truncated: false, terminates: true, transitions: {} } } },
    })
    expect(screen.getByTestId('exercise-terminated')).toBeTruthy()
    expect(document.querySelector('[data-feedback]')).toBeNull()
  })

  it('все подходы выполнены — кнопок фидбэка нет', () => {
    mount(vi.fn(), {
      ...exercise,
      sets: [1, 2, 3].map((i) => ({
        id: `s${i}`,
        exercise_slug: 'squat_barbell',
        set_index: i,
        prescribed_reps: 10,
        pain_flag: false,
        pain_joints: [],
        skipped: false,
      })),
    })
    expect(screen.getByTestId('exercise-done')).toBeTruthy()
    expect(document.querySelector('[data-feedback]')).toBeNull()
  })
})

describe('таймер отдыха после подхода', () => {
  it('120 с по умолчанию упражнения при готовности 1.0', async () => {
    mount(vi.fn<LogSet>(async () => nextTree))
    tap('ok')
    await flush()
    expect(screen.getByTestId('rest-clock').textContent).toBe('Отдых 2:00')
  })

  it('«тяжело» прибавляет 30 секунд', async () => {
    mount(vi.fn<LogSet>(async () => nextTree))
    tap('hard')
    await flush()
    expect(screen.getByTestId('rest-clock').textContent).toBe('Отдых 2:30')
  })

  it('низкая готовность удлиняет отдых на 20%', async () => {
    mount(vi.fn<LogSet>(async () => nextTree), { ...exercise, weight_readiness: 0.85 })
    tap('ok')
    await flush()
    expect(screen.getByTestId('rest-clock').textContent).toBe('Отдых 2:24')
  })

  it('«+30 сек» сдвигает метку, «Пропустить» убирает таймер', async () => {
    mount(vi.fn<LogSet>(async () => nextTree))
    tap('ok')
    await flush()
    fireEvent.click(screen.getByRole('button', { name: '+30 сек' }))
    await flush()
    expect(screen.getByTestId('rest-clock').textContent).toBe('Отдых 2:30')
    fireEvent.click(screen.getByRole('button', { name: 'Пропустить' }))
    expect(screen.queryByTestId('rest-clock')).toBeNull()
  })

  it('отсчёт идёт от метки: после «заморозки» на минуту остаётся минута', async () => {
    mount(vi.fn<LogSet>(async () => nextTree))
    tap('ok')
    await flush()
    await act(async () => {
      vi.setSystemTime(new Date('2026-10-12T09:31:00Z')) // минута без тиков
      vi.advanceTimersByTime(250)
    })
    await waitFor(() => expect(screen.getByTestId('rest-clock').textContent).toBe('Отдых 1:00'))
  })

  it('таймер не блокирует ввод: кнопки фидбэка доступны во время отдыха', async () => {
    mount(vi.fn<LogSet>(async () => nextTree))
    tap('ok')
    await flush()
    expect(screen.getByTestId('rest-clock')).toBeTruthy()
    // Подтверждение доходит до панели через кеш, а он оповещает позже ответа.
    await waitFor(() =>
      expect((document.querySelector('[data-feedback="ok"]') as HTMLButtonElement).disabled).toBe(false),
    )
  })
})
