// Экран упражнения (SPEC §13.2), срез 3: логирование подходов.
//
// Подход отмечается в два шага (§13.2, 2026-11-09). Над подходом — цель:
// вес и `target_rep_max` повторов, счётчика повторов нет.
//   1. «Подход выполнен» — подход кончился: запоминается момент
//      (`completed_at`) и стартует таймер отдыха (§13.3). На сервер ничего не
//      уходит.
//   2. Оценка. «Легко», «Нормально», «Тяжело» — повторы равны цели; «Не смог»
//      спрашивает «Сколько повторов получилось?». Дальше — как прежде: по
//      дереву §20.9 мгновенно выбирается ветка и показывается вес следующего
//      подхода, а факт подхода уходит ОДНИМ запросом с клиентским UUID — уже с
//      оценкой, повторами и моментом из шага 1. Дописывать оценку к записанному
//      подходу нельзя: завершённый подход неизменяем (§4.3).
//
// Очереди и офлайна нет (§20.10): пока подход не подтверждён, следующий
// ввести нельзя, а обрыв показывается прямо, с кнопкой «Повторить». Повтор
// идёт с ТЕМ ЖЕ `id` — сервер применяет upsert, и второй строки не будет.
//
// Вес вводится числом (§13.2, §19.2 п.23 (в)): поле предзаполнено весом из
// дерева, и подход, совпавший с рекомендацией, — по-прежнему один тап. Лестницы
// у клиента нет: набранное число сервер округляет к ступени и возвращает
// записанный подход, и записанный вес, если он отличается, показывается
// явно. Набранный руками вес уводит состояние с дерева (§20.9): следующий вес
// тогда приходит с сервера, а не из ветки. У весового упражнения без
// известного веса (калибровка без базовой линии, §9.8) поле пустое и
// обязательное.
//
// Срез 6: флаг боли (§8.4) — отдельная кнопка, не в ряду фидбэка (§13.2).
// Подход уходит сразу, с весом и повторами на экране и без фидбэка; дальше
// экран тренировки показывает альтернативы. «Заменить» открывает замену в один
// тап (§13.4). Подходы считаются по текущему слагу (`workout/progress`).

import { useEffect, useId, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { ApiError, NetworkError, type ApiClient } from '../../api/client'
import type { ExerciseContent, SetRow, Workout, WorkoutExercise } from '../../api/schemas'
import { equipmentLine } from '../../onboarding/labels'
import { currentSets } from '../../workout/progress'
import { HARD_EXTRA_SECONDS, restDuration } from '../../workout/rest'
import { applyBranch, branchFor, currentStep, type Branch, type Feedback, type Step } from '../../workout/tree'
import { formatWeight, parseWeight, WEIGHT_MAX_KG } from '../../workout/weight'
import { ExerciseFrames } from './Illustration'
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

/** «1 повтор», «3 повтора», «15 повторов». */
export function repsWord(n: number): string {
  const tens = n % 100
  const ones = n % 10
  if (tens >= 11 && tens <= 14) return `${n} повторов`
  if (ones === 1) return `${n} повтор`
  if (ones >= 2 && ones <= 4) return `${n} повтора`
  return `${n} повторов`
}

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
  onPain,
  onSubstitute,
}: {
  api: ApiClient
  workoutId: string
  exercise: WorkoutExercise
  content: ExerciseContent | undefined
  /** Подход ушёл или должен уйти, и сервер его ещё не подтвердил. */
  onBusyChange?: (busy: boolean) => void
  /** Подход с флагом боли подтверждён: дальше — альтернативы (§8.4 п.2). */
  onPain?: () => void
  /** Замена в один тап (§13.4). */
  onSubstitute?: () => void
}) {
  const queryClient = useQueryClient()
  const tree = exercise.decision_tree
  // Цель подхода — верх диапазона (§13.2, §20.9): ровно при нём «легко»
  // ведёт к росту, а «тяжело» оставляет как есть.
  const target = exercise.target_rep_max
  /** Момент «Подход выполнен»; `null` — подход ещё идёт. */
  const [doneAt, setDoneAt] = useState<number | null>(null)
  /** После «Не смог» — вопрос о повторах. */
  const [asking, setAsking] = useState(false)
  const [failedReps, setFailedReps] = useState('')
  const [sent, setSent] = useState<Pending | null>(null)
  const [failure, setFailure] = useState<unknown>(null)
  const [sending, setSending] = useState(false)
  const [restEndAt, setRestEndAt] = useState<number | null>(null)
  /** Набранный вес; `null` — поле следует рекомендации дерева. */
  const [typedKg, setTypedKg] = useState<string | null>(null)
  /** Записанный сервером вес, если он отличается от отправленного. */
  const [recordedNote, setRecordedNote] = useState<number | null>(null)
  const weightHint = useId()

  // Подход «в пути» — пока его нет среди подтверждённых. Сбрасывать его
  // сразу после ответа нельзя: кеш react-query оповещает подписчиков позже, и
  // вес на мгновение откатывался бы к прежнему дереву.
  const done = currentSets(exercise)
  const pending = sent && !done.some((s) => s.id === sent.body.id) ? sent : null
  const confirmed = done.length
  const inFlight = pending ? 1 : 0
  const allDone = confirmed + inFlight >= exercise.target_sets
  const base: Step = tree ? currentStep(tree) : { kind: 'ask-server' }
  const view: Step = pending ? pending.next : base
  useEffect(() => {
    onBusyChange?.(pending !== null)
    return () => onBusyChange?.(false)
  }, [pending, onBusyChange])
  const terminated = view.kind === 'node' && view.terminates
  const recommended = base.kind === 'node' ? base.weightKg : undefined
  const weightText = typedKg ?? (recommended !== undefined ? formatWeight(recommended) : '')
  const typed = exercise.weighted ? parseWeight(weightText) : null
  const weightInvalid = exercise.weighted && typed === null

  async function send(body: Pending['body']) {
    setSending(true)
    setFailure(null)
    try {
      const response = await api.logSet(workoutId, exercise.id, body)
      // Записанный подход — из ответа: вес в нём уже ступень лестницы.
      const logged: SetRow = response.set
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
      setTypedKg(null)
      setRecordedNote(
        logged.actual_kg !== undefined && logged.actual_kg !== body.actual_kg ? logged.actual_kg : null,
      )
      if (body.pain_flag) onPain?.()
    } catch (e) {
      if (e instanceof ApiError && e.code === 'set_index_taken') {
        // Подход с этим номером уже записан (другая вкладка, второе нажатие):
        // ошибки поля нет — перечитываем тренировку и показываем то, что есть.
        setSent(null)
        await queryClient.invalidateQueries({ queryKey: ['workout', workoutId] })
        return
      }
      setFailure(e)
    } finally {
      setSending(false)
    }
  }

  /** «Подход выполнен»: момент конца подхода и отдых, без записи (§13.2, §13.3). */
  function markDone() {
    if (pending || sending || base.kind !== 'node' || weightInvalid || doneAt !== null) return
    const now = clock.now()
    setDoneAt(now)
    const rest = restDuration(content?.default_rest_seconds ?? 90, exercise.weight_readiness, 'ok')
    setRestEndAt(now + rest * 1000)
  }

  /** Оценка: «Не смог» сначала спрашивает повторы, остальные пишут цель. */
  function rate(feedback: Feedback) {
    if (feedback === 'failed') {
      setAsking(true)
      return
    }
    log(feedback, target)
  }

  function log(feedback: Feedback, reps: number) {
    if (pending || sending || !tree || base.kind !== 'node' || weightInvalid || doneAt === null) return
    const branch: Branch = branchFor(feedback, reps, exercise.target_rep_min, exercise.target_rep_max)
    const body: Pending['body'] = {
      id: crypto.randomUUID(),
      set_index: confirmed + 1,
      ...(recommended !== undefined ? { prescribed_kg: recommended } : {}),
      ...(typed !== null ? { actual_kg: typed } : {}),
      actual_reps: reps,
      feedback,
      pain_flag: false,
      // Конец подхода — «Подход выполнен», а не оценка (§13.2, §20.9).
      completed_at: new Date(doneAt).toISOString(),
      skipped: false,
    }
    // Мгновенно: следующий вес — из дерева, до ответа сервера. Вес, набранный
    // мимо рекомендации, с дерева уводит (§20.9): тогда ждём сервер.
    const offTree = exercise.weighted && typed !== recommended
    setRecordedNote(null)
    setSent({ body, next: offTree ? { kind: 'ask-server' } : applyBranch(tree, base.nodeId, branch) })
    // Отдых уже идёт с «Подход выполнен»; «тяжело» добавляет свои 30 секунд.
    if (feedback === 'hard') setRestEndAt((end) => (end ?? clock.now()) + HARD_EXTRA_SECONDS * 1000)
    setDoneAt(null)
    setAsking(false)
    setFailedReps('')
    void send(body)
  }

  /**
   * Флаг боли (§8.4 п.1): подход уходит сразу, вес и повторы — как на экране,
   * без фидбэка; таймера отдыха нет — упражнение прекращено.
   */
  function pain() {
    if (pending || sending || base.kind !== 'node') return
    // О боли сообщают сразу: вес — если он набран, без него подход тоже
    // принимается (§8.4, §9.8).
    const body: Pending['body'] = {
      id: crypto.randomUUID(),
      set_index: confirmed + 1,
      ...(recommended !== undefined ? { prescribed_kg: recommended } : {}),
      ...(typed !== null ? { actual_kg: typed } : {}),
      actual_reps: target,
      pain_flag: true,
      completed_at: new Date(doneAt ?? clock.now()).toISOString(),
      skipped: false,
    }
    setRecordedNote(null)
    setSent({ body, next: base })
    setRestEndAt(null)
    setDoneAt(null)
    setAsking(false)
    void send(body)
  }

  const nextSetNumber = confirmed + inFlight + 1
  const weight = view.kind === 'node' ? view.weightKg : undefined
  const failedCount = /^\d{1,3}$/.test(failedReps.trim()) ? Number(failedReps.trim()) : null
  const failedValid = failedCount !== null && failedCount <= 100
  const blocked = pending !== null || sending || base.kind !== 'node' || weightInvalid

  return (
    <section aria-label="Упражнение" className="exercise">
      <h2 data-testid="current-exercise" className="exercise-title">
        {content?.name ?? exercise.slug}
      </h2>
      {equipmentLine(content?.equipment_labels) !== null && (
        <p className="caption" data-testid="equipment-line">
          {equipmentLine(content?.equipment_labels)}
        </p>
      )}
      <ExerciseFrames content={content} />
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
            <div className="card-header">
              <p data-testid="set-counter" className="chip">
                Подход {nextSetNumber} из {exercise.target_sets}
              </p>
              {/* Флаг боли — отдельно и мелко, никогда в ряду с «Тяжело» (§13.2). */}
              <button
                type="button"
                className="pain-button"
                data-testid="pain-button"
                disabled={pending !== null || sending || base.kind !== 'node'}
                onClick={pain}
              >
                Боль
              </button>
            </div>
            <p data-testid="weight" className="hero">
              {view.kind === 'ask-server' ? (
                <span className="hero-text">Ждём сервер…</span>
              ) : weight !== undefined ? (
                <>
                  <span className="hero-number">{weight}</span> <span className="hero-unit">кг</span>
                </>
              ) : exercise.weighted ? (
                <span className="hero-text">Введите вес</span>
              ) : (
                // Подпись — по снаряду из контента (§13.2): резинка не собственный вес.
                <span className="hero-text">
                  {content?.equipment_labels.includes('Резинка') ? 'Резинка' : 'Собственный вес'}
                </span>
              )}
            </p>
            {recordedNote !== null && (
              <p className="caption" data-testid="recorded-weight">
                Записано {formatWeight(recordedNote)} кг — ближайший вес вашего инвентаря.
              </p>
            )}
            {exercise.weighted && (
              <p>
                <label className="field">
                  Вес, кг{' '}
                  <input
                    data-testid="weight-input"
                    inputMode="decimal"
                    aria-describedby={weightHint}
                    aria-invalid={weightInvalid || undefined}
                    placeholder={recommended === undefined ? 'например 20' : undefined}
                    value={weightText}
                    disabled={pending !== null}
                    onChange={(e) => setTypedKg(e.target.value)}
                  />
                </label>
                <span id={weightHint} className="caption" data-testid="weight-hint">
                  {weightText === ''
                    ? 'Подберите рабочий вес и введите его — дальше подскажем мы.'
                    : weightInvalid
                      ? `Вес — число от 0 до ${WEIGHT_MAX_KG} кг.`
                      : 'Сохраним ближайший вес вашего инвентаря.'}
                </span>
              </p>
            )}
            <p data-testid="target" className="reps-value">
              {repsWord(target)}
            </p>
          </div>
          {doneAt === null && pending === null ? (
            // Пока подход идёт — одна кнопка на месте оценок и того же размера.
            <div className="feedback-grid">
              <button type="button" className="set-done" data-testid="set-done" disabled={blocked} onClick={markDone}>
                Подход выполнен
              </button>
            </div>
          ) : asking ? (
            <form
              className="card"
              data-testid="failed-reps"
              onSubmit={(e) => {
                e.preventDefault()
                if (failedValid) log('failed', failedCount!)
              }}
            >
              <label className="field">
                Сколько повторов получилось?{' '}
                <input
                  data-testid="failed-reps-input"
                  inputMode="numeric"
                  autoFocus
                  value={failedReps}
                  onChange={(e) => setFailedReps(e.target.value)}
                />
              </label>
              <button type="submit" className="button-primary" disabled={!failedValid || blocked}>
                Записать
              </button>
              {/* Промахнулась мимо «Не смог» — вернуться к оценкам, ничего не записав. */}
              <button type="button" className="button-text" onClick={() => setAsking(false)}>
                Другая оценка
              </button>
            </form>
          ) : (
            <div role="group" aria-label="Как прошёл подход" className="feedback-grid">
              {FEEDBACK.map((f) => (
                <button
                  key={f.value}
                  type="button"
                  data-feedback={f.value}
                  // Подход в пути отмечен своей кнопкой, пока сервер его не подтвердил.
                  data-selected={pending?.body.feedback === f.value}
                  disabled={blocked}
                  onClick={() => rate(f.value)}
                >
                  {f.label}
                </button>
              ))}
            </div>
          )}
        </>
      )}

      {!terminated && !allDone && onSubstitute && (
        <button
          type="button"
          className="button-text"
          data-testid="substitute-button"
          disabled={pending !== null || sending}
          onClick={onSubstitute}
        >
          Заменить упражнение
        </button>
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
          // До оценки следующий вес неизвестен: его даёт ветка дерева.
          nextWeightKg={terminated || allDone || doneAt !== null ? undefined : weight}
          onExtend={(seconds) => setRestEndAt((end) => (end ?? clock.now()) + seconds * 1000)}
          onSkip={() => setRestEndAt(null)}
        />
      )}
    </section>
  )
}
