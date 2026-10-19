// Замена упражнения (SPEC §13.4) и ветка флага боли (§8.4 п.2).
//
// Список — `GET …/alternatives` с причинами пригодности от сервера; выбор —
// `POST …/substitute`, ответ которого заменяет строку упражнения в кеше
// тренировки. Ранжирование, допуск и перенос веса — на сервере (FitCore).
//
// Флаг боли: если ни одна альтернатива не подошла, упражнение остаётся
// завершённым без замены, и тренировка идёт дальше (§8.4, «На вебе») —
// кнопка «Без замены». Замена в один тап: «Отмена» возвращает к упражнению.

import { useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import type { ApiClient } from '../../api/client'
import type { AlternativesPurpose, ExerciseContent, SubstituteRequest, Workout, WorkoutExercise } from '../../api/schemas'
import { ErrorBlock } from '../today/TodayScreen'
import { equipmentLine } from '../../onboarding/labels'
import { ExerciseThumbnail } from './Illustration'

const REASONS: { value: SubstituteRequest['reason']; label: string }[] = [
  { value: 'occupied', label: 'Занят снаряд' },
  { value: 'equipment', label: 'Нет инвентаря' },
  { value: 'user_choice', label: 'Хочу другое' },
]

export function AlternativesPanel({
  api,
  workoutId,
  exercise,
  purpose,
  names,
  onDone,
}: {
  api: ApiClient
  workoutId: string
  exercise: WorkoutExercise
  purpose: AlternativesPurpose
  names: Map<string, ExerciseContent> | undefined
  /** Закрыть панель: замена сделана, отменена или (боль) пропущена. */
  onDone: () => void
}) {
  const queryClient = useQueryClient()
  const [reason, setReason] = useState<SubstituteRequest['reason']>(purpose === 'pain' ? 'pain' : 'user_choice')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<unknown>(null)
  const alternatives = useQuery({
    queryKey: ['alternatives', workoutId, exercise.id, exercise.slug, purpose],
    queryFn: () => api.getAlternatives(workoutId, exercise.id, purpose),
  })

  async function choose(slug: string) {
    setBusy(true)
    setError(null)
    try {
      const replaced = await api.substitute(workoutId, exercise.id, slug, reason)
      queryClient.setQueryData<Workout>(['workout', workoutId], (current) =>
        current && { ...current, exercises: current.exercises.map((e) => (e.id === replaced.id ? replaced : e)) },
      )
      onDone()
    } catch (e) {
      setError(e)
    } finally {
      setBusy(false)
    }
  }

  const title = purpose === 'pain' ? 'Упражнение остановлено' : 'Замена упражнения'
  return (
    <section aria-label={title} className="exercise" data-testid="alternatives" data-purpose={purpose}>
      <h2 className="exercise-title">{title}</h2>
      {purpose === 'pain' && (
        <p data-testid="pain-recorded">Подход записан с отметкой боли. Можно заменить упражнение или идти дальше.</p>
      )}
      {purpose === 'user_choice' && (
        <fieldset>
          <legend>Почему меняем</legend>
          <div className="option-row">
            {REASONS.map((r) => (
              <label key={r.value} className="option">
                <input
                  type="radio"
                  name="substitution-reason"
                  value={r.value}
                  checked={reason === r.value}
                  onChange={() => setReason(r.value)}
                />{' '}
                {r.label}
              </label>
            ))}
          </div>
        </fieldset>
      )}
      {alternatives.isPending && <p role="status">Подбираем замену…</p>}
      {alternatives.isError && <ErrorBlock error={alternatives.error} />}
      {alternatives.data && alternatives.data.length === 0 && (
        <p className="card" data-testid="no-alternatives">
          Подходящей замены нет.
        </p>
      )}
      {alternatives.data && alternatives.data.length > 0 && (
        <ul className="rows card" aria-label="Альтернативы">
          {alternatives.data.map((alt) => (
            <li key={alt.slug} data-slug={alt.slug} className="alternative">
              <ExerciseThumbnail content={names?.get(alt.slug)} />
              <span className="alternative-text">
                <span data-testid="alternative-name">{names?.get(alt.slug)?.name ?? alt.slug}</span>
                {equipmentLine(names?.get(alt.slug)?.equipment_labels) !== null && (
                  <span className="caption" data-testid="alternative-equipment">
                    {' · '}
                    {equipmentLine(names?.get(alt.slug)?.equipment_labels)}
                  </span>
                )}
                {alt.reasons.map((r, i) => (
                  <span key={i} className="caption">
                    {' · '}
                    {r.message}
                  </span>
                ))}
              </span>
              <button type="button" className="button-text" disabled={busy} onClick={() => void choose(alt.slug)}>
                Выбрать
              </button>
            </li>
          ))}
        </ul>
      )}
      {error !== null && <ErrorBlock error={error} />}
      <button type="button" className="button-text" disabled={busy} onClick={onDone}>
        {purpose === 'pain' ? 'Без замены, дальше' : 'Отмена'}
      </button>
    </section>
  )
}
