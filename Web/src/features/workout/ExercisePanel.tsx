// Экран упражнения (SPEC §13.2), срез 3: логирование подходов.
//
// Что здесь происходит на тап по кнопке фидбэка:
//   1. по дереву §20.9 мгновенно выбирается ветка и показывается вес
//      следующего подхода — без запроса, ради этого дерево и существует;
//   2. стартует таймер отдыха (от абсолютной метки);
//   3. факт подхода уходит на сервер ОТДЕЛЬНЫМ запросом с клиентским UUID.
//
// Очереди и офлайна нет (§20.10): пока подход не подтверждён, следующий
// ввести нельзя, а обрыв показывается прямо, с кнопкой «Повторить». Повтор
// идёт с ТЕМ ЖЕ `id` — сервер применяет upsert, и второй строки не будет.
//
// Вес правится только деревом. Ручная правка веса — отдельное решение
// (шаг «+»/«−» берётся из лестницы инвентаря, которой у клиента нет).

import { useEffect, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { ApiError, NetworkError, type ApiClient } from '../../api/client'
import type { ExerciseContent, SetRow, Workout, WorkoutExercise } from '../../api/schemas'
import { restDuration } from '../../workout/rest'
import { applyBranch, branchFor, currentStep, type Branch, type Feedback, type Step } from '../../workout/tree'
import { RestTimer } from './RestTimer'

/** Часы за функцией: обработчик событий читает время в момент тапа. */
const clock = { now: () => Date.now() }

interface Pending {
  body: Parameters<ApiClient['logSet']>[2]
  /** Что показывать как следующий подход, пока сервер не ответил. */
  next: Step
}

const FEEDBACK: { value: Feedback; label: string }[] = [
  { value: 'easy', label: 'Легко' },
  { value: 'ok', label: 'Нормально' },
  { value: 'hard', label: 'Тяжело' },
  { value: 'failed', label: 'Не смог' },
]

function failureText(error: unknown): string {
  if (error instanceof NetworkError) return 'Нет связи с сервером. Подход не записан — повторите.'
  if (error instanceof ApiError) return error.message
  return error instanceof Error ? error.message : 'Не удалось записать подход'
}

export function ExercisePanel({
  api,
  workoutId,
  exercise,
  content,
  onBusyChange,
}: {
  api: ApiClient
  workoutId: string
  exercise: WorkoutExercise
  content: ExerciseContent | undefined
  /** Подход ушёл или должен уйти, и сервер его ещё не подтвердил. */
  onBusyChange?: (busy: boolean) => void
}) {
  const queryClient = useQueryClient()
  const tree = exercise.decision_tree
  const [reps, setReps] = useState(exercise.target_rep_max)
  const [sent, setSent] = useState<Pending | null>(null)
  const [failure, setFailure] = useState<unknown>(null)
  const [sending, setSending] = useState(false)
  const [restEndAt, setRestEndAt] = useState<number | null>(null)

  // Подход «в пути» — пока его нет среди подтверждённых. Сбрасывать его
  // сразу после ответа нельзя: кеш react-query оповещает подписчиков позже, и
  // вес на мгновение откатывался бы к прежнему дереву.
  const pending = sent && !exercise.sets.some((s) => s.id === sent.body.id) ? sent : null
  const confirmed = exercise.sets.length
  const inFlight = pending ? 1 : 0
  const allDone = confirmed + inFlight >= exercise.target_sets
  const base: Step = tree ? currentStep(tree) : { kind: 'ask-server' }
  const view: Step = pending ? pending.next : base
  useEffect(() => {
    onBusyChange?.(pending !== null)
    return () => onBusyChange?.(false)
  }, [pending, onBusyChange])
  const terminated = view.kind === 'node' && view.terminates

  async function send(body: Pending['body']) {
    setSending(true)
    setFailure(null)
    try {
      const response = await api.logSet(workoutId, exercise.id, body)
      const logged: SetRow = {
        id: body.id,
        exercise_slug: exercise.slug,
        set_index: body.set_index,
        prescribed_kg: body.prescribed_kg,
        prescribed_reps: exercise.target_rep_max,
        actual_kg: body.actual_kg,
        actual_reps: body.actual_reps,
        feedback: body.feedback,
        pain_flag: false,
        pain_joints: [],
        completed_at: body.completed_at,
        skipped: false,
      }
      // Подтверждённое сервером попадает в кеш, и только оно: «записанных»
      // подходов, которых сервер не принял, на экране не бывает.
      queryClient.setQueryData<Workout>(['workout', workoutId], (current) =>
        current && {
          ...current,
          exercises: current.exercises.map((e) =>
            e.id === exercise.id
              ? { ...e, sets: [...e.sets.filter((s) => s.id !== logged.id), logged], decision_tree: response.decision_tree }
              : e,
          ),
        },
      )
      setReps(exercise.target_rep_max)
    } catch (e) {
      setFailure(e)
    } finally {
      setSending(false)
    }
  }

  function log(feedback: Feedback) {
    if (pending || sending || !tree || base.kind !== 'node') return
    const branch: Branch = branchFor(feedback, reps, exercise.target_rep_min, exercise.target_rep_max)
    const weight = base.weightKg
    const body: Pending['body'] = {
      id: crypto.randomUUID(),
      set_index: confirmed + 1,
      ...(weight !== undefined ? { prescribed_kg: weight, actual_kg: weight } : {}),
      actual_reps: reps,
      feedback,
      pain_flag: false,
      completed_at: new Date().toISOString(),
      skipped: false,
    }
    // Мгновенно: следующий вес — из дерева, до ответа сервера.
    setSent({ body, next: applyBranch(tree, base.nodeId, branch) })
    const rest = restDuration(content?.default_rest_seconds ?? 90, exercise.weight_readiness, feedback)
    setRestEndAt(clock.now() + rest * 1000)
    void send(body)
  }

  const nextSetNumber = confirmed + inFlight + 1
  const weight = view.kind === 'node' ? view.weightKg : undefined

  return (
    <section aria-label="Упражнение" className="exercise">
      <h2 data-testid="current-exercise" className="exercise-title">
        {content?.name ?? exercise.slug}
      </h2>
      {content && content.cues.length > 0 && (
        <ul aria-label="Подсказки" className="cues caption">
          {content.cues.map((cue, i) => (
            <li key={i}>{cue}</li>
          ))}
        </ul>
      )}

      {terminated ? (
        <p data-testid="exercise-terminated" className="card">
          Упражнение завершено досрочно.
        </p>
      ) : allDone ? (
        <p data-testid="exercise-done" className="card">
          Подходы выполнены.
        </p>
      ) : (
        <>
          <div className="card set-card">
            <p data-testid="set-counter" className="chip">
              Подход {nextSetNumber} из {exercise.target_sets}
            </p>
            <p data-testid="weight" className="hero">
              {view.kind === 'ask-server' ? (
                <span className="hero-text">Ждём сервер…</span>
              ) : weight !== undefined ? (
                <>
                  <span className="hero-number">{weight}</span> <span className="hero-unit">кг</span>
                </>
              ) : (
                <span className="hero-text">Без веса</span>
              )}
            </p>
            <p className="caption">
              Цель: {exercise.target_rep_min}–{exercise.target_rep_max} повторов
            </p>
            <div className="stepper" role="group" aria-label="Повторы">
              <button
                type="button"
                className="round-button"
                aria-label="Меньше повторов"
                onClick={() => setReps((r) => Math.max(1, r - 1))}
                disabled={pending !== null}
              >
                −
              </button>
              <span data-testid="reps" className="reps-value">
                {reps}
              </span>
              <button
                type="button"
                className="round-button"
                aria-label="Больше повторов"
                onClick={() => setReps((r) => r + 1)}
                disabled={pending !== null}
              >
                +
              </button>
            </div>
          </div>
          <div role="group" aria-label="Как прошёл подход" className="feedback-grid">
            {FEEDBACK.map((f) => (
              <button
                key={f.value}
                type="button"
                data-feedback={f.value}
                // Подход в пути отмечен своей кнопкой, пока сервер его не подтвердил.
                data-selected={pending?.body.feedback === f.value}
                disabled={pending !== null || sending || base.kind !== 'node'}
                onClick={() => log(f.value)}
              >
                {f.label}
              </button>
            ))}
          </div>
        </>
      )}

      {failure !== null && pending && (
        <div role="alert" data-testid="log-failure">
          <p>{failureText(failure)}</p>
          <button type="button" className="button-primary" disabled={sending} onClick={() => void send(pending.body)}>
            Повторить
          </button>
        </div>
      )}

      {restEndAt !== null && (
        <RestTimer
          key={restEndAt}
          endAt={restEndAt}
          onExtend={(seconds) => setRestEndAt((end) => (end ?? clock.now()) + seconds * 1000)}
          onSkip={() => setRestEndAt(null)}
        />
      )}
    </section>
  )
}
