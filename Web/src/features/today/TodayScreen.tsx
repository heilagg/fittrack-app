// Экран «Сегодня», срез 1 (SPEC §13.1): карточка дня и состав тренировки.
//
// Разметка функциональная, без визуального дизайна: он решается отдельно
// (web-domain §8). Тексты причин приходят с сервера и показываются как есть.
//
// Ветка показа — по `day.kind` (закрытый словарь §20.3). Различать
// «неделя не сгенерирована» (`cause` отсутствует) и «сегодня отдых»
// (`not_a_training_day`) обязательно: это разные состояния.

import { useQuery } from '@tanstack/react-query'
import type { ApiClient } from '../../api/client'
import { ApiError } from '../../api/client'
import type { DayOutcome, ExerciseContent } from '../../api/schemas'
import { useExerciseNames } from '../../content/useExercises'

export function TodayScreen({ api }: { api: ApiClient }) {
  const today = useQuery({ queryKey: ['today'], queryFn: () => api.getToday() })
  const names = useExerciseNames(api)

  if (today.isPending) return <p role="status">Загрузка…</p>
  if (today.isError) return <ErrorBlock error={today.error} />

  const card = today.data
  return (
    <main>
      <h1>Сегодня</h1>
      <p data-testid="today-date">{card.date}</p>
      <DayBlock day={card.day} names={names.data} />
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
