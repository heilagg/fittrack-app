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
import { ApiError, NetworkError, type ApiClient } from '../../api/client'
import type { ExerciseContent, FinishWorkoutResponse, Workout } from '../../api/schemas'

function failureText(error: unknown): string {
  if (error instanceof NetworkError) return 'Нет связи с сервером. Тренировка не завершена — повторите.'
  if (error instanceof ApiError) return error.message
  return error instanceof Error ? error.message : 'Не удалось завершить тренировку'
}

export function FinishButton({
  api,
  workoutId,
  disabled,
  onFinished,
}: {
  api: ApiClient
  workoutId: string
  /** Неподтверждённый подход в пути: завершать поверх него нельзя. */
  disabled: boolean
  onFinished: (result: FinishWorkoutResponse) => void
}) {
  const queryClient = useQueryClient()
  const [sending, setSending] = useState(false)
  const [failure, setFailure] = useState<unknown>(null)

  async function finish() {
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
        disabled={disabled || sending}
        onClick={() => void finish()}
      >
        Завершить
      </button>
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
}: {
  workout: Workout
  /** Ответ `/finish`; `undefined` — тренировка открыта заново, без ответа. */
  week: FinishWorkoutResponse['week']
  names: Map<string, ExerciseContent> | undefined
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
                    {s.actual_reps ?? '—'}
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
