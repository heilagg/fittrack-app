// Завершение тренировки (SPEC §13.1, §20.3 `/finish`; web-domain срез 4).
//
// До завершения — кнопка «Завершить тренировку»; после — сводка. Всё, что в
// сводке числами, приходит с сервера: клиент показывает подходы из закрытого
// `Workout` и ничего не пересчитывает. Строка «План обновлён» — поле
// `week.notice` того же ответа; молчаливой пересборки быть не должно (§7.1).
//
// Очереди нет (§20.10): обрыв — явное состояние с кнопкой «Повторить», и
// повтор — то же 200 с тем же телом (в нём `notice` уже `null`).

import { useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { Link } from 'react-router-dom'
import { ApiError, NetworkError, type ApiClient } from '../../api/client'
import type { CooldownPose, ExerciseContent, FinishWorkoutResponse, Workout } from '../../api/schemas'

function failureText(error: unknown): string {
  if (error instanceof NetworkError) return 'Нет связи с сервером. Тренировка не завершена — повторите.'
  if (error instanceof ApiError) return error.message
  return error instanceof Error ? error.message : 'Не удалось завершить тренировку'
}

/** «1 подход», «3 подхода», «5 подходов». */
export function setsWord(n: number): string {
  const tens = n % 100
  const ones = n % 10
  if (tens >= 11 && tens <= 14) return `${n} подходов`
  if (ones === 1) return `${n} подход`
  if (ones >= 2 && ones <= 4) return `${n} подхода`
  return `${n} подходов`
}

export function FinishButton({
  api,
  workoutId,
  disabled,
  remainingSets,
  onFinished,
}: {
  api: ApiClient
  workoutId: string
  /** Неподтверждённый подход в пути: завершать поверх него нельзя. */
  disabled: boolean
  /** Невыполненные подходы открытых упражнений: при них «Завершить» переспрашивает (§13.2). */
  remainingSets: number
  onFinished: (result: FinishWorkoutResponse) => void
}) {
  const queryClient = useQueryClient()
  const [sending, setSending] = useState(false)
  const [failure, setFailure] = useState<unknown>(null)
  const [confirming, setConfirming] = useState(false)

  async function finish() {
    setConfirming(false)
    setSending(true)
    setFailure(null)
    try {
      const result = await api.finishWorkout(workoutId)
      // Закрытая тренировка из ответа — единственный источник «завершена»;
      // «Сегодня» перечитывается: день стал выполненным или пропущенным.
      // Ответ отдаётся наверх раньше кеша: сводка не должна мелькнуть без notice.
      onFinished(result)
      queryClient.setQueryData<Workout>(['workout', workoutId], result.workout)
      await queryClient.invalidateQueries({ queryKey: ['today'] })
    } catch (e) {
      setFailure(e)
    } finally {
      setSending(false)
    }
  }

  return (
    <div className="finish">
      {/* Видимое «Завершить» входит в доступное имя (WCAG 2.5.3). */}
      <button
        type="button"
        className="button-text"
        aria-label="Завершить тренировку"
        disabled={disabled || sending || confirming}
        onClick={() => (remainingSets > 0 ? setConfirming(true) : void finish())}
      >
        Завершить
      </button>
      {/* Отмены завершения нет — закрытая тренировка закрыта (§20.6), поэтому
          спрашиваем до, и только когда есть что терять. */}
      {confirming && (
        <div role="alertdialog" aria-label="Завершить тренировку?" data-testid="finish-confirm" className="card">
          <p>
            Осталось {setsWord(remainingSets)}. Завершить тренировку?
          </p>
          <button type="button" className="button-primary" onClick={() => void finish()}>
            Завершить
          </button>
          <button type="button" className="button-text" onClick={() => setConfirming(false)}>
            Продолжить тренировку
          </button>
        </div>
      )}
      {failure !== null && (
        <div role="alert" data-testid="finish-failure">
          <p>{failureText(failure)}</p>
          <button type="button" className="button-primary" disabled={sending} onClick={() => void finish()}>
            Повторить
          </button>
        </div>
      )}
    </div>
  )
}

export function WorkoutSummary({
  workout,
  week,
  names,
  cooldown,
}: {
  workout: Workout
  /** Ответ `/finish`; `undefined` — тренировка открыта заново, без ответа. */
  week: FinishWorkoutResponse['week']
  names: Map<string, ExerciseContent> | undefined
  /** Автозаминка из ответа `/finish` (§12.2); нет ответа или пусто — не предлагается. */
  cooldown?: CooldownPose[]
}) {
  const ordered = workout.exercises.slice().sort((a, b) => a.order_index - b.order_index)
  const done = (e: Workout['exercises'][number]) => e.sets.filter((s) => !s.skipped)
  const total = ordered.reduce((n, e) => n + done(e).length, 0)

  return (
    <section aria-label="Сводка тренировки" data-testid="summary" className="exercise">
      <h2 className="screen-title">Тренировка завершена</h2>
      {week?.notice && (
        <p data-testid="plan-notice" className="notice">
          {week.notice.message}
        </p>
      )}
      <p data-testid="summary-total" className="chip">
        {total === 0 ? 'Ни одного подхода не выполнено.' : `Выполнено подходов: ${total}`}
      </p>
      {cooldown && cooldown.length > 0 && (
        <p className="card" data-testid="cooldown-offer">
          Заминка: {cooldown.length} {cooldown.length === 1 ? 'поза' : cooldown.length < 5 ? 'позы' : 'поз'} по проработанным мышцам.{' '}
          <Link to="/stretch/cooldown" state={{ cooldown }} className="button-text">
            Начать заминку
          </Link>
        </p>
      )}
      <ol data-testid="summary-exercises" className="card rows rows--stacked">
        {ordered.map((e) => (
          <li key={e.id}>
            <span>
              <span data-testid="summary-exercise-name">{names?.get(e.slug)?.name ?? e.slug}</span>
              <span className="row-value">{`: ${done(e).length} из ${e.target_sets}`}</span>
            </span>
            {done(e).length > 0 && (
              <ul className="caption">
                {done(e).map((s) => (
                  <li key={s.id}>
                    {s.actual_kg !== undefined ? `${s.actual_kg} кг × ` : ''}
                    {s.actual_reps !== undefined ? `${s.actual_reps} повт.` : '—'}
                  </li>
                ))}
              </ul>
            )}
          </li>
        ))}
      </ol>
    </section>
  )
}
