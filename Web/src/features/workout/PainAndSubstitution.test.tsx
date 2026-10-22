import '@testing-library/jest-dom/vitest'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import type { ApiClient } from '../../api/client'
import type { ExerciseAlternative, Workout, WorkoutExercise } from '../../api/schemas'
import { answer } from './logSetTesting'
import { WorkoutScreen } from './WorkoutScreen'

// Экран тренировки тянет ErrorBlock из «Сегодня», а та — supabase-js.
vi.mock('../../auth/supabase', () => ({ currentUserId: async () => 'user-1' }))

afterEach(cleanup)

const tree = {
  start: 'n0',
  nodes: {
    n0: {
      weight_kg: 40,
      truncated: false,
      terminates: false,
      transitions: {
        failed: 'n0', hard_below_min: 'n0', hard_at_or_above_min: 'n0',
        ok: 'n0', easy_below_max: 'n0', easy_at_or_above_max: 'n0',
      },
    },
  },
}

function exercise(id: string, slug: string, order: number, extra: Partial<WorkoutExercise> = {}): WorkoutExercise {
  return {
    id, slug, order_index: order, target_sets: 3, target_rep_min: 6, target_rep_max: 10, target_rir: 2,
    prescribed_kg: 40, weight_readiness: 1, is_calibration: false, weighted: true, decision_tree: tree, sets: [], ...extra,
  }
}

const workout: Workout = {
  id: 'w-1',
  session_kind: 'lower',
  started_at: '2026-10-12T09:00:00Z',
  readiness: 1,
  is_calibration: false,
  exercises: [exercise('we-1', 'squat_barbell', 0), exercise('we-2', 'lunge_db', 1)],
}

const names = [
  { slug: 'squat_barbell', name: 'Приседания' },
  { slug: 'lunge_db', name: 'Выпады' },
  { slug: 'hip_thrust_barbell', name: 'Ягодичный мост' },
].map((n) => ({
  ...n, cues: [], common_errors: [], illustration: n.slug === 'hip_thrust_barbell' ? 'catalog/exact/hip_thrust_barbell' : 'x',
  default_rest_seconds: 90, equipment_labels: n.slug === 'hip_thrust_barbell' ? ['Штанга', 'Скамья'] : [],
}))

const alternatives: ExerciseAlternative[] = [
  {
    slug: 'hip_thrust_barbell',
    reasons: [{ code: 'substitution_relieves_joint', params: { joint: 'knee', from: 'high', to: 'low' }, message: 'Меньше нагрузки на колено' }],
  },
]

function mount(overrides: Partial<ApiClient> = {}) {
  const logSet = vi.fn<ApiClient['logSet']>(answer({ decision_tree: tree }))
  const getAlternatives = vi.fn(async () => alternatives)
  const substitute = vi.fn(async () =>
    exercise('we-1', 'hip_thrust_barbell', 0, {
      substituted_from: 'squat_barbell',
      substitution_reason: 'pain',
      prescribed_kg: 50,
      target_rep_max: 12,
      decision_tree: { ...tree, nodes: { n0: { ...tree.nodes.n0, weight_kg: 50 } } },
      sets: [{
        id: 'p1', exercise_slug: 'squat_barbell', set_index: 1, prescribed_kg: 40, prescribed_reps: 10,
        actual_kg: 40, actual_reps: 9, pain_flag: true, pain_joints: ['knee'], skipped: false,
        completed_at: '2026-10-12T09:10:00Z',
      }],
    }),
  )
  const api = {
    getWorkout: async () => workout,
    getExercises: async () => names,
    logSet,
    getAlternatives,
    substitute,
    ...overrides,
  } as unknown as ApiClient
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={['/workout/w-1']}>
        <Routes>
          <Route path="/workout/:id" element={<WorkoutScreen api={api} />} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  )
  return { logSet, getAlternatives, substitute }
}

const current = () => screen.findByTestId('current-exercise')

describe('флаг боли (§8.4)', () => {
  it('подход уходит сразу: pain_flag, вес и повторы с экрана, без фидбэка', async () => {
    const { logSet } = mount()
    expect(await current()).toHaveTextContent('Приседания')
    expect(screen.getByTestId('illustration-placeholder')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Меньше повторов' }))
    fireEvent.click(screen.getByTestId('pain-button'))
    await waitFor(() => expect(logSet).toHaveBeenCalledTimes(1))
    const [workoutId, exerciseId, body] = logSet.mock.calls[0]!
    expect([workoutId, exerciseId]).toEqual(['w-1', 'we-1'])
    expect(body).toMatchObject({ set_index: 1, prescribed_kg: 40, actual_kg: 40, actual_reps: 9, pain_flag: true, skipped: false })
    expect(body.feedback).toBeUndefined()
  })

  it('после подхода — альтернативы с purpose=pain на том же упражнении', async () => {
    const { getAlternatives } = mount()
    await current()
    fireEvent.click(screen.getByTestId('pain-button'))
    const panel = await screen.findByTestId('alternatives')
    expect(panel).toHaveAttribute('data-purpose', 'pain')
    await waitFor(() => expect(getAlternatives).toHaveBeenCalledWith('w-1', 'we-1', 'pain'))
    expect(await within(panel).findByText('Ягодичный мост')).toBeInTheDocument()
    expect(within(panel).getByText(/Меньше нагрузки на колено/)).toBeInTheDocument()
    expect(within(panel).getByTestId('thumbnail')).toHaveAttribute('src', '/illustrations/hip_thrust_barbell/start.jpg')
    // Подпись снаряда у альтернативы (§13.4, §6.6): смена снаряда видна до тапа.
    expect(within(panel).getByTestId('alternative-equipment')).toHaveTextContent('Штанга, Скамья')
  })

  it('выбор замены: reason=pain, новое упражнение с подходом 1 из 3', async () => {
    const { substitute } = mount()
    await current()
    fireEvent.click(screen.getByTestId('pain-button'))
    const panel = await screen.findByTestId('alternatives')
    fireEvent.click(await within(panel).findByRole('button', { name: 'Выбрать' }))
    await waitFor(() => expect(substitute).toHaveBeenCalledWith('w-1', 'we-1', 'hip_thrust_barbell', 'pain'))
    expect(await current()).toHaveTextContent('Ягодичный мост')
    // Подход прежнего упражнения к новому не относится.
    expect(screen.getByTestId('set-counter')).toHaveTextContent('Подход 1 из 3')
    expect(screen.getByTestId('weight')).toHaveTextContent('50')
  })

  it('«Без замены» — упражнение завершено, тренировка идёт к следующему', async () => {
    const { substitute } = mount()
    await current()
    fireEvent.click(screen.getByTestId('pain-button'))
    const panel = await screen.findByTestId('alternatives')
    fireEvent.click(within(panel).getByRole('button', { name: 'Без замены, дальше' }))
    expect(await current()).toHaveTextContent('Выпады')
    expect(substitute).not.toHaveBeenCalled()
  })

  it('альтернатив нет — так и сказано, «Без замены» ведёт дальше', async () => {
    mount({ getAlternatives: (async () => []) as unknown as ApiClient['getAlternatives'] })
    await current()
    fireEvent.click(screen.getByTestId('pain-button'))
    expect(await screen.findByTestId('no-alternatives')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Без замены, дальше' }))
    expect(await current()).toHaveTextContent('Выпады')
  })

  it('флаг боли не в ряду фидбэка', async () => {
    mount()
    await current()
    const row = screen.getByRole('group', { name: 'Как прошёл подход' })
    expect(within(row).queryByTestId('pain-button')).toBeNull()
  })
})

describe('замена в один тап (§13.4)', () => {
  it('«Заменить упражнение» — альтернативы user_choice, причина выбирается', async () => {
    const { getAlternatives, substitute } = mount()
    await current()
    // Повторы, введённые для прежнего упражнения, к новому не переезжают.
    fireEvent.click(screen.getByRole('button', { name: 'Меньше повторов' }))
    expect(screen.getByTestId('reps')).toHaveTextContent('9')
    fireEvent.click(screen.getByTestId('substitute-button'))
    const panel = await screen.findByTestId('alternatives')
    expect(panel).toHaveAttribute('data-purpose', 'user_choice')
    await waitFor(() => expect(getAlternatives).toHaveBeenCalledWith('w-1', 'we-1', 'user_choice'))
    fireEvent.click(within(panel).getByLabelText('Занят снаряд'))
    fireEvent.click(await within(panel).findByRole('button', { name: 'Выбрать' }))
    await waitFor(() => expect(substitute).toHaveBeenCalledWith('w-1', 'we-1', 'hip_thrust_barbell', 'occupied'))
    expect(await current()).toHaveTextContent('Ягодичный мост')
    expect(screen.getByTestId('reps')).toHaveTextContent('12')
  })

  it('«Отмена» возвращает к тому же упражнению без записи', async () => {
    const { substitute, logSet } = mount()
    await current()
    fireEvent.click(screen.getByTestId('substitute-button'))
    fireEvent.click(await screen.findByRole('button', { name: 'Отмена' }))
    expect(await current()).toHaveTextContent('Приседания')
    expect(substitute).not.toHaveBeenCalled()
    expect(logSet).not.toHaveBeenCalled()
  })

  it('ошибка замены видна, панель остаётся', async () => {
    mount({ substitute: (async () => { throw new Error('Нет связи') }) as unknown as ApiClient['substitute'] })
    await current()
    fireEvent.click(screen.getByTestId('substitute-button'))
    const panel = await screen.findByTestId('alternatives')
    fireEvent.click(await within(panel).findByRole('button', { name: 'Выбрать' }))
    expect(await within(panel).findByRole('alert')).toHaveTextContent('Нет связи')
  })
})
