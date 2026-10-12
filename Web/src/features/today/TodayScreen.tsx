// Экран «Сегодня», срез 1 (SPEC §13.1): карточка дня и состав тренировки.
//
// Визуальные решения — токены web-domain §8. Тексты причин приходят с сервера
// и показываются как есть.
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
import { mondayOf } from '../../api/day'
import { useExerciseNames } from '../../content/useExercises'
import { calendarDays } from '../../today/calendar'
import { formatDayHeading, formatMinutes } from '../../ui/format'
import { WeekCalendar } from './WeekCalendar'

export function TodayScreen({ api }: { api: ApiClient }) {
  const today = useQuery({ queryKey: ['today'], queryFn: () => api.getToday() })
  // Неделя для календаря — от даты карточки, а не от часов браузера: «сегодня»
  // у карточки и у календаря обязано быть одним днём.
  const weekStart = today.data ? mondayOf(today.data.date) : null
  const week = useQuery({
    queryKey: ['week', weekStart],
    queryFn: () => api.getWeekPlan(weekStart!),
    enabled: weekStart !== null,
  })
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

  async function buildWeek() {
    setStarting(true)
    setStartError(null)
    try {
      await api.generateWeek()
      await Promise.all([today.refetch(), week.refetch()])
    } catch (e) {
      setStartError(e)
    } finally {
      setStarting(false)
    }
  }

  if (today.isPending) return <p role="status">Загрузка…</p>
  if (today.isError) return <ErrorBlock error={today.error} />

  const card = today.data
  return (
    <main>
      <header className="screen-header">
        <p className="eyebrow">
          <time data-testid="today-date" dateTime={card.date}>
            {formatDayHeading(card.date)}
          </time>
        </p>
        <h1>Сегодня</h1>
      </header>
      <WeekCalendar days={calendarDays(mondayOf(card.date), card.date, week.data?.plan.days ?? [])} />
      {/* Чтение недели сверяет план со снимком (§20.6): «План обновлён» из
          этого ответа показывается здесь, иначе он потерялся бы молча (§7.1). */}
      {week.data?.notice && (
        <p className="notice" data-testid="week-notice">
          {week.data.notice.message}
        </p>
      )}
      {week.isError && <ErrorBlock error={week.error} />}
      <DayBlock day={card.day} names={names.data} />
      {card.day.kind === 'session' && card.day.day_id !== undefined && (
        <button type="button" className="button-primary" disabled={starting} onClick={() => start(card.day.day_id!)}>
          Начать тренировку
        </button>
      )}
      {/* День уже начат: `POST /v1/workouts` идемпотентен по дню (§20.3) и отдаёт
          ту же тренировку, так что «продолжить» — тот же вызов, без отдельного
          пути «дай тренировку по дню», которого в §20.3 нет. */}
      {card.day.kind === 'not_built' &&
        card.day.cause?.code === 'started' &&
        card.day.day_id !== undefined && (
          <button type="button" className="button-primary" disabled={starting} onClick={() => start(card.day.day_id!)}>
            Продолжить тренировку
          </button>
        )}
      {/* Недели нет (ключ `cause` отсутствует): онбординг, прерванный после
          инвентаря, оставляет профиль полным, а неделю генерирует его
          последний экран. Явная кнопка вместо тихой генерации на чтении. */}
      {card.day.kind === 'not_built' && card.day.cause === undefined && (
        <button type="button" className="button-primary" disabled={starting} onClick={() => void buildWeek()}>
          Собрать неделю
        </button>
      )}
      {startError !== null && <ErrorBlock error={startError} />}
      {card.reasons.length > 0 && (
        <ul aria-label="Статус недели" className="caption">
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
        <section aria-label="Тренировка" className="card">
          <div className="card-header">
            <h2 className="chip" data-testid="session-kind">
              {session.session_kind_name}
            </h2>
            <span className="caption" data-testid="session-duration">
              {formatMinutes(session.estimated_seconds)}
            </span>
          </div>
          <ol data-testid="session-exercises" className="rows">
            {session.exercises.map((exercise) => (
              <li key={exercise.slug}>
                <span data-testid="exercise-name">{names?.get(exercise.slug)?.name ?? exercise.slug}</span>
                <span className="row-value">
                  {exercise.target_sets} × {exercise.target_rep_min}–{exercise.target_rep_max}
                  {exercise.prescribed_kg !== undefined && (
                    <>
                      {' · '}
                      <span className="row-weight">{exercise.prescribed_kg} кг</span>
                    </>
                  )}
                </span>
              </li>
            ))}
          </ol>
          {session.reasons.map((reason, i) => (
            <p key={i} className="caption">
              {reason.message}
            </p>
          ))}
        </section>
      )
    }
    case 'not_built':
      return (
        <p data-testid="day-not-built" className="card">
          {day.cause ? day.cause.message : 'Неделя ещё не сгенерирована'}
        </p>
      )
    case 'stretching':
    case 'vector_missing':
    case 'generator_disabled':
      return <p data-testid={`day-${day.kind}`} className="card">{day.cause?.message ?? day.kind}</p>
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
