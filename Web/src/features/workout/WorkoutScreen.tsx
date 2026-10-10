// Экран начатой тренировки, срез 2: состав, только чтение (SPEC §13.1).
//
// Логирование подходов, дерево §20.9 и таймер — срез 3.

import { useQuery } from '@tanstack/react-query'
import { Link, useParams } from 'react-router-dom'
import type { ApiClient } from '../../api/client'
import { useExerciseNames } from '../../content/useExercises'
import { ErrorBlock } from '../today/TodayScreen'

export function WorkoutScreen({ api }: { api: ApiClient }) {
  const { id = '' } = useParams()
  const workout = useQuery({ queryKey: ['workout', id], queryFn: () => api.getWorkout(id) })
  const names = useExerciseNames(api)

  if (workout.isPending) return <p role="status">Загрузка…</p>
  if (workout.isError) return <ErrorBlock error={workout.error} />

  const w = workout.data
  return (
    <main>
      <h1>Тренировка</h1>
      <p data-testid="workout-state">{w.finished_at ? 'Завершена' : 'Идёт'}</p>
      {w.is_calibration && <p>Калибровочная тренировка: веса занижены намеренно.</p>}
      <ol data-testid="workout-exercises">
        {w.exercises
          .slice()
          .sort((a, b) => a.order_index - b.order_index)
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
