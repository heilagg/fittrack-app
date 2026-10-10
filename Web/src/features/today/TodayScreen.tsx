// Экран «Сегодня», срез 1 (SPEC §13.1): карточка дня и состав тренировки.
//
// Разметка функциональная, без визуального дизайна: он решается отдельно
// (web-domain §8). Тексты причин приходят с сервера и показываются как есть.
//
// Ветка показа — по `day.kind` (закрытый словарь §20.3). Различать
// «неделя не сгенерирована» (`cause` отсутствует) и «сегодня отдых»
// (`not_a_training_day`) обязательно: это разные состояния.

import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useNavigate } from 'react-router-dom'
import type { ApiClient } from '../../api/client'
import { ApiError } from '../../api/client'
import type { DayOutcome, ExerciseContent } from '../../api/schemas'
import { useExerciseNames } from '../../content/useExercises'

export function TodayScreen({ api }: { api: ApiClient }) {
  const today = useQuery({ queryKey: ['today'], queryFn: () => api.getToday() })
  const names = useExerciseNames(api)
  const navigate = useNavigate()
  const [startError, setStartError] = useState<unknown>(null)
  const [starting, setStarting] = useState(false)

  // «Начать» (SPEC §20.5): сервер сам решает, привязан ли аккаунт, — правило не
  // дублируется в интерфейсе. Различимое поведение по коду, а не по тексту:
  //   unlinked_account → экран привязки;
  //   day_not_planned с id идущей тренировки → она же (повтор с другим
  //   инвентарём или закрытый день), доехать до неё можно отсюда.
  async function start(dayId: string) {
    setStarting(true)
    setStartError(null)
    try {
      const workout = await api.startWorkout(dayId)
      navigate(`/workout/${workout.id}`)
    } catch (e) {
      if (e instanceof ApiError && e.code === 'unlinked_account') {
        navigate('/link')
      } else if (e instanceof ApiError && e.code === 'day_not_planned' && typeof e.details.workout_id === 'string') {
        navigate(`/workout/${e.details.workout_id}`)
      } else {
        setStartError(e)
      }
    } finally {
      setStarting(false)
    }
  }

  if (today.isPending) return <p role="status">Загрузка…</p>
  if (today.isError) return <ErrorBlock error={today.error} />

  const card = today.data
  return (
    <main>
      <h1>Сегодня</h1>
      <p data-testid="today-date">{card.date}</p>
      <DayBlock day={card.day} names={names.data} />
      {card.day.kind === 'session' && card.day.day_id !== undefined && (
        <button type="button" disabled={starting} onClick={() => start(card.day.day_id!)}>
          Начать тренировку
        </button>
      )}
      {/* День уже начат: `POST /v1/workouts` идемпотентен по дню (§20.3) и отдаёт
          ту же тренировку, так что «продолжить» — тот же вызов, без отдельного
          пути «дай тренировку по дню», которого в §20.3 нет. */}
      {card.day.kind === 'not_built' &&
        card.day.cause?.code === 'started' &&
        card.day.day_id !== undefined && (
          <button type="button" disabled={starting} onClick={() => start(card.day.day_id!)}>
            Продолжить тренировку
          </button>
        )}
      {startError !== null && <ErrorBlock error={startError} />}
      {card.reasons.length > 0 && (
        <ul aria-label="Статус недели">
          {card.reasons.map((reason, i) => (
            <li key={i}>{reason.message}</li>
          ))}
        </ul>
      )}
    </main>
  )
}

function DayBlock({ day, names }: { day: DayOutcome; names: Map<string, ExerciseContent> | undefined }) {
  switch (day.kind) {
    case 'session': {
      const session = day.session
      if (!session) return <p>Состав тренировки недоступен</p>
      return (
        <section aria-label="Тренировка">
          <h2>Тренировка</h2>
          <ol data-testid="session-exercises">
            {session.exercises.map((exercise) => (
              <li key={exercise.slug}>
                <span data-testid="exercise-name">{names?.get(exercise.slug)?.name ?? exercise.slug}</span>
                {': '}
                {exercise.target_sets} × {exercise.target_rep_min}–{exercise.target_rep_max}
                {exercise.prescribed_kg !== undefined ? `, ${exercise.prescribed_kg} кг` : ''}
              </li>
            ))}
          </ol>
          {session.reasons.map((reason, i) => (
            <p key={i}>{reason.message}</p>
          ))}
        </section>
      )
    }
    case 'not_built':
      return (
        <p data-testid="day-not-built">
          {day.cause ? day.cause.message : 'Неделя ещё не сгенерирована'}
        </p>
      )
    case 'stretching':
    case 'vector_missing':
    case 'generator_disabled':
      return <p data-testid={`day-${day.kind}`}>{day.cause?.message ?? day.kind}</p>
  }
}

export function ErrorBlock({ error }: { error: unknown }) {
  // `details` пользовательнице не показывается никогда; `message` — по умолчанию.
  if (error instanceof ApiError) {
    return (
      <p role="alert" data-code={error.code}>
        {error.message}
      </p>
    )
  }
  return <p role="alert">{error instanceof Error ? error.message : 'Неизвестная ошибка'}</p>
}
