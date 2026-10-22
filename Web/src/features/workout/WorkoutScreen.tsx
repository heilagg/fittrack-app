// Экран тренировки (SPEC §13.1): текущее упражнение и состав.
//
// Срез 3: логирование подходов, дерево §20.9, таймер отдыха, Wake Lock.
// Срез 4: завершение и сводка. Срез 6: замена упражнения (§13.4) и флаг боли
// (§8.4). Панель альтернатив живёт здесь, а не в упражнении: после подхода с
// болью упражнение закрыто, и текущим стало бы следующее — панель обязана
// остаться на том, где болело.

import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Link, useParams } from 'react-router-dom'
import type { ApiClient } from '../../api/client'
import type { FinishWorkoutResponse } from '../../api/schemas'
import { useExerciseNames } from '../../content/useExercises'
import { currentSets, isExerciseOpen, progressSegments, remainingSets } from '../../workout/progress'
import { useWakeLock } from '../../workout/wakeLock'
import { ErrorBlock } from '../today/TodayScreen'
import { AlternativesPanel } from './AlternativesPanel'
import { ExercisePanel } from './ExercisePanel'
import { FinishButton, WorkoutSummary } from './FinishPanel'

function WakeLockNote({ enabled }: { enabled: boolean }) {
  const state = useWakeLock(enabled)
  const text: Record<typeof state, string> = {
    active: 'Экран не погаснет',
    idle: '',
    unsupported: 'Браузер не умеет удерживать экран: он может погаснуть',
    denied: 'Не удалось удержать экран: он может погаснуть',
  }
  return text[state] ? (
    <p data-testid="wake-lock" className="caption">
      {text[state]}
    </p>
  ) : null
}

export function WorkoutScreen({ api }: { api: ApiClient }) {
  const { id = '' } = useParams()
  const workout = useQuery({ queryKey: ['workout', id], queryFn: () => api.getWorkout(id) })
  const names = useExerciseNames(api)
  const [finished, setFinished] = useState<FinishWorkoutResponse | null>(null)
  const [busy, setBusy] = useState(false)
  const [swap, setSwap] = useState<{ exerciseId: string; purpose: 'pain' | 'user_choice' } | null>(null)

  if (workout.isPending) return <p role="status">Загрузка…</p>
  if (workout.isError) return <ErrorBlock error={workout.error} />

  const w = workout.data
  const isFinished = w.finished_at !== undefined
  const ordered = w.exercises.slice().sort((a, b) => a.order_index - b.order_index)
  // Текущее — первое, где подходы остались и дерево не оборвано досрочно.
  const current = ordered.find(isExerciseOpen)
  const swapping = swap ? ordered.find((e) => e.id === swap.exerciseId) : undefined
  const shown = swapping ?? current
  const position = shown ? ordered.indexOf(shown) + 1 : null
  return (
    <main>
      <h1 className="visually-hidden">Тренировка</h1>
      <p data-testid="workout-state" className="visually-hidden">
        {isFinished ? 'Завершена' : 'Идёт'}
      </p>
      {!isFinished && (
        <>
          <div className="top-bar">
            <span className="caption" data-testid="exercise-position">
              {position !== null && `Упражнение ${position} из ${ordered.length}`}
            </span>
            <FinishButton api={api} workoutId={w.id} disabled={busy} remainingSets={remainingSets(ordered)}
              onFinished={setFinished} />
          </div>
          <ol className="progress" aria-hidden="true">
            {progressSegments(ordered).map((state, i) => (
              <li key={ordered[i]!.id} data-state={state} />
            ))}
          </ol>
        </>
      )}
      {/* После завершения плашка ни о чём: сводка уже говорит, что сделано. */}
      {w.is_calibration && !isFinished && (
        <p className="chip" data-testid="calibration-chip">
          Калибровочная тренировка: веса занижены намеренно.
        </p>
      )}
      <WakeLockNote enabled={!isFinished} />
      {isFinished ? (
        <WorkoutSummary workout={w} week={finished?.week} names={names.data} cooldown={finished?.cooldown} />
      ) : swap && swapping ? (
        <AlternativesPanel
          key={`${swapping.id}:${swapping.slug}`}
          api={api}
          workoutId={w.id}
          exercise={swapping}
          purpose={swap.purpose}
          names={names.data}
          onDone={() => setSwap(null)}
        />
      ) : current ? (
        <ExercisePanel
          // Замена меняет слаг той же строки: новое упражнение — новое состояние экрана.
          key={`${current.id}:${current.slug}`}
          api={api}
          workoutId={w.id}
          exercise={current}
          content={names.data?.get(current.slug)}
          onBusyChange={setBusy}
          onPain={() => setSwap({ exerciseId: current.id, purpose: 'pain' })}
          onSubstitute={() => setSwap({ exerciseId: current.id, purpose: 'user_choice' })}
        />
      ) : (
        <p data-testid="all-sets-done" className="card">
          Все подходы выполнены.
        </p>
      )}
      {/* После завершения состав показывает сводка — второй список был бы повтором. */}
      {!isFinished && (
      <section aria-label="Состав тренировки" className="card">
        <ol data-testid="workout-exercises" className="rows rows--stacked">
          {ordered.map((exercise) => (
            <li key={exercise.id}>
              <span data-testid="workout-exercise-name">{names.data?.get(exercise.slug)?.name ?? exercise.slug}</span>
              <span className="caption">
                {exercise.target_sets} × {exercise.target_rep_min}–{exercise.target_rep_max}
                {exercise.prescribed_kg !== undefined ? `, ${exercise.prescribed_kg} кг` : ''}
                {' · выполнено подходов: '}
                {currentSets(exercise).length}
              </span>
            </li>
          ))}
        </ol>
      </section>
      )}
      <p>
        <Link to="/" className="link-back">
          Сегодня
        </Link>
      </p>
    </main>
  )
}
