// Вопросы цикла (SPEC §5, шаг 9; §11.5): что пишет каждый ответ — `onboarding/cycle.ts`.
//
// Один компонент на два места: шаг 9 онбординга и включение цикла из Профиля
// (§11.6, «Кто видит календарь»; §19.2 п.27). Вопросы и запись у них одни и те
// же — `PATCH /v1/profile` и дата начала в `cycle_events`.

import { useState, type FormEvent } from 'react'
import type { ApiClient } from '../../api/client'
import { currentUserId } from '../../auth/supabase'
import { upsertPeriodStart } from '../../direct/onboarding'
import {
  cycleWrite,
  type ContraceptionAnswer,
  type CycleAnswers,
  type Regularity,
  type TrackingAnswer,
} from '../../onboarding/cycle'
import { ErrorBlock } from '../today/TodayScreen'

function useAction() {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<unknown>(null)
  async function run(action: () => Promise<void>) {
    setBusy(true)
    setError(null)
    try {
      await action()
    } catch (e) {
      setError(e)
    } finally {
      setBusy(false)
    }
  }
  return { busy, error, run }
}

export function CycleSettingsForm({
  api,
  onSaved,
  submitLabel = 'Далее',
  initial = {},
}: {
  api: ApiClient
  /** Текущие ответы — при правке из Профиля (`cycleAnswersOf`). */
  initial?: Partial<CycleAnswers>
  /** `periodStart` — записана ли дата начала: после неё нужен `/rebuild`, если неделя уже есть. */
  onSaved: (written: { periodStart: boolean }) => void | Promise<void>
  submitLabel?: string
}) {
  const [tracking, setTracking] = useState<TrackingAnswer | null>(initial.tracking ?? null)
  const [contraception, setContraception] = useState<ContraceptionAnswer | null>(initial.contraception ?? null)
  const [periodStart, setPeriodStart] = useState('')
  const [cycleLength, setCycleLength] = useState(initial.cycleLength === undefined ? '' : String(initial.cycleLength))
  const [periodLength, setPeriodLength] = useState(initial.periodLength === undefined ? '' : String(initial.periodLength))
  const [regularity, setRegularity] = useState<Regularity | ''>(initial.regularity ?? '')
  const [problem, setProblem] = useState<string | null>(null)
  const { busy, error, run } = useAction()

  const optionalInt = (text: string, min: number, max: number, what: string): number | undefined => {
    if (text.trim() === '') return undefined
    const v = Number(text)
    if (!Number.isInteger(v) || v < min || v > max) throw new Error(`${what}: от ${min} до ${max}`)
    return v
  }

  function submit(event: FormEvent) {
    event.preventDefault()
    if (tracking === null) return
    if (tracking === 'yes' && contraception === null) return
    let write
    try {
      const length = optionalInt(cycleLength, 15, 60, 'Длина цикла')
      const period = optionalInt(periodLength, 1, 14, 'Длительность менструации')
      write = cycleWrite({
        tracking,
        ...(contraception ? { contraception } : {}),
        ...(periodStart ? { periodStart } : {}),
        ...(length !== undefined ? { cycleLength: length } : {}),
        ...(period !== undefined ? { periodLength: period } : {}),
        ...(regularity ? { regularity } : {}),
      })
    } catch (e) {
      return setProblem(e instanceof Error ? e.message : 'Проверьте значения')
    }
    setProblem(null)
    void run(async () => {
      await api.patchProfile(write.patch)
      if (write.periodStart) await upsertPeriodStart(await currentUserId(), write.periodStart)
      await onSaved({ periodStart: write.periodStart !== undefined })
    })
  }

  const radio = <T extends string>(
    name: string,
    value: T,
    label: string,
    current: T | null,
    set: (v: T) => void,
  ) => (
    <label key={value} className="option">
      <input type="radio" name={name} value={value} checked={current === value} onChange={() => set(value)} /> {label}{' '}
    </label>
  )

  return (
    <>
      <form onSubmit={submit}>
        <fieldset>
          <legend>Отслеживаете ли вы менструальный цикл?</legend>
          {radio('tracking', 'yes' as TrackingAnswer, 'Да', tracking, setTracking)}
          {radio('tracking', 'no' as TrackingAnswer, 'Нет', tracking, setTracking)}
          {radio('tracking', 'not_now' as TrackingAnswer, 'Не сейчас', tracking, setTracking)}
        </fieldset>
        {tracking === 'yes' && (
          <>
            <fieldset>
              <legend>Принимаете ли вы гормональную контрацепцию?</legend>
              {radio('contraception', 'yes' as ContraceptionAnswer, 'Да', contraception, setContraception)}
              {radio('contraception', 'no' as ContraceptionAnswer, 'Нет', contraception, setContraception)}
              {radio('contraception', 'declined' as ContraceptionAnswer, 'Не хочу отвечать', contraception, setContraception)}
            </fieldset>
            {contraception === 'yes' && (
              <p className="notice">
                При гормональной контрацепции естественных фаз цикла нет: приложение работает без фаз и
                предлагает ежедневный чек-ин.
              </p>
            )}
            {contraception === 'no' && (
              <>
                <p className="caption">Любой из ответов ниже можно пропустить.</p>
                <p>
                  <label className="field">
                    Дата начала последней менструации{' '}
                    <input type="date" value={periodStart} onChange={(e) => setPeriodStart(e.target.value)} />
                  </label>
                </p>
                <p>
                  <label className="field">
                    Обычная длина цикла, дней{' '}
                    <input inputMode="numeric" value={cycleLength} onChange={(e) => setCycleLength(e.target.value)} />
                  </label>
                </p>
                <p>
                  <label className="field">
                    Обычная длительность менструации, дней{' '}
                    <input inputMode="numeric" value={periodLength} onChange={(e) => setPeriodLength(e.target.value)} />
                  </label>
                </p>
                <p>
                  <label className="field">
                    Регулярность{' '}
                    <select value={regularity} onChange={(e) => setRegularity(e.target.value as Regularity | '')}>
                      <option value="">—</option>
                      <option value="regular">Регулярный</option>
                      <option value="variable">Плавает</option>
                      <option value="irregular">Очень нерегулярный</option>
                    </select>
                  </label>
                </p>
              </>
            )}
          </>
        )}
        <button type="submit" className="button-primary" disabled={busy || tracking === null || (tracking === 'yes' && contraception === null)}>
          {submitLabel}
        </button>
      </form>
      {problem !== null && <p role="alert">{problem}</p>}
      {error !== null && <ErrorBlock error={error} />}
    </>
  )
}
