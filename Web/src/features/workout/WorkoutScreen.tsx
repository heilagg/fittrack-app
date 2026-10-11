// Экран тренировки (SPEC §13.1): текущее упражнение и состав.
//
// Срез 3: логирование подходов, дерево §20.9, таймер отдыха, Wake Lock.
// Замена упражнения, флаг боли и завершение — отдельные срезы.

import { useQuery } from '@tanstack/react-query'
import { Link, useParams } from 'react-router-dom'
import type { ApiClient } from '../../api/client'
import { useExerciseNames } from '../../content/useExercises'
import { useWakeLock } from '../../workout/wakeLock'
import { ErrorBlock } from '../today/TodayScreen'
import { ExercisePanel } from './ExercisePanel'

function WakeLockNote({ enabled }: { enabled: boolean }) {
  const state = useWakeLock(enabled)
  const text: Record<typeof state, string> = {
    active: 'Экран не погаснет',
    idle: '',
    unsupported: 'Браузер не умеет удерживать экран: он может погаснуть',
    denied: 'Не удалось удержать экран: он может погаснуть',
  }
  return text[state] ? <p data-testid="wake-lock">{text[state]}</p> : null
}

export function WorkoutScreen({ api }: { api: ApiClient }) {
  const { id = '' } = useParams()
  const workout = useQuery({ queryKey: ['workout', id], queryFn: () => api.getWorkout(id) })
  const names = useExerciseNames(api)

  if (workout.isPending) return <p role="status">Загрузка…</p>
  if (workout.isError) return <ErrorBlock error={workout.error} />

  const w = workout.data
  const ordered = w.exercises.slice().sort((a, b) => a.order_index - b.order_index)
  // Текущее — первое, где подходы остались и дерево не оборвано досрочно.
  const current = ordered.find((e) => {
    const start = e.decision_tree?.nodes[e.decision_tree.start]
    return e.sets.length < e.target_sets && !start?.terminates
  })
  return (
    <main>
      <h1>Тренировка</h1>
      <p data-testid="workout-state">{w.finished_at ? 'Завершена' : 'Идёт'}</p>
      {w.is_calibration && <p>Калибровочная тренировка: веса занижены намеренно.</p>}
      <WakeLockNote enabled={!w.finished_at} />
      {current ? (
        <ExercisePanel
          key={current.id}
          api={api}
          workoutId={w.id}
          exercise={current}
          content={names.data?.get(current.slug)}
        />
      ) : (
        <p data-testid="all-sets-done">Все подходы выполнены.</p>
      )}
      <ol data-testid="workout-exercises">
        {ordered
          .map((exercise) => (
            <li key={exercise.id}>
              <span data-testid="workout-exercise-name">
                {names.data?.get(exercise.slug)?.name ?? exercise.slug}
              </span>
              {': '}
              {exercise.target_sets} × {exercise.target_rep_min}–{exercise.target_rep_max}
              {exercise.prescribed_kg !== undefined ? `, ${exercise.prescribed_kg} кг` : ''}
              {' · выполнено подходов: '}
              {exercise.sets.length}
            </li>
          ))}
      </ol>
      <p>
        <Link to="/">Сегодня</Link>
      </p>
    </main>
  )
}
