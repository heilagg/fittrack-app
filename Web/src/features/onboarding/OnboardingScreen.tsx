// Онбординг (SPEC §5, §14.1, §14.2; web-domain срез 5). Разметка функциональная.
//
// «Пошагово» на вебе — запись на сервер: шаги 3–6 и цикл уходят через
// `PATCH /v1/profile`, экраны 2, 3 (вес), 7, 8 и дата цикла — прямыми записями
// в свои таблицы (§20.6). Экран, с которого продолжать, вычисляется ОДИН раз
// при входе из того, чего не хватает (`resumeStep`); дальше шаги идут подряд.
// Шаги 8–10 из данных не восстанавливаются и показываются один раз после
// шага 7 в том же заходе.

import { useEffect, useState, type FormEvent, type ReactNode } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { useNavigate } from 'react-router-dom'
import type { ApiClient } from '../../api/client'
import { localDate, browserTimeZone } from '../../api/day'
import { currentUserId } from '../../auth/supabase'
import { insertEquipmentProfile } from '../../direct/equipment'
import type { EquipmentRow } from '../../direct/equipmentRow'
import {
  hasParq,
  insertRestrictions,
  upsertBodyWeight,
  upsertParq,
  upsertPeriodStart,
  type Joint,
  type Severity,
} from '../../direct/onboarding'
import {
  cycleWrite,
  type ContraceptionAnswer,
  type Regularity,
  type TrackingAnswer,
} from '../../onboarding/cycle'
import { buildParqRow, hasRedFlag, PARQ_QUESTIONS } from '../../onboarding/parq'
import {
  MACHINE_SLUGS,
  normalizeEquipment,
  parseKgList,
  PRESETS,
  type PresetId,
} from '../../onboarding/presets'
import { resumeStep } from '../../onboarding/resume'
import { DISCLAIMER_PENDING_LEGAL, ONBOARDING_SUMMARY, RED_FLAG_PENDING_LEGAL } from '../../onboarding/texts'
import { ErrorBlock } from '../today/TodayScreen'

type Step = 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10

/** Шаг по умолчанию после `n`: подряд, а женский цикл (9) показывается по полу. */
function nextStep(step: Step, female: boolean): Step {
  if (step === 8 && !female) return 10
  return (step + 1) as Step
}

/** Общая обёртка шага: ошибка и блокировка на время запроса. */
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

function StepFrame({ n, title, children }: { n: Step; title: string; children: ReactNode }) {
  return (
    <section aria-label={title} data-testid={`step-${n}`}>
      <h2>{title}</h2>
      {children}
    </section>
  )
}

export function OnboardingScreen({ api }: { api: ApiClient }) {
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [step, setStep] = useState<Step | null>(null)
  const [female, setFemale] = useState(false)
  const [loadError, setLoadError] = useState<unknown>(null)

  useEffect(() => {
    let cancelled = false
    ;(async () => {
      const [profile, parq] = await Promise.all([api.getProfileIfStarted(), hasParq()])
      if (cancelled) return
      const resume = resumeStep(profile, parq)
      if (resume === 'done') {
        navigate('/', { replace: true })
        return
      }
      setFemale(profile?.sex_at_birth === 'female')
      setStep(resume)
    })().catch((e: unknown) => !cancelled && setLoadError(e))
    return () => {
      cancelled = true
    }
  }, [api, navigate])

  if (loadError !== null) return <ErrorBlock error={loadError} />
  if (step === null) return <p role="status">Загрузка…</p>

  const go = (from: Step) => setStep(nextStep(from, female))
  const finishProfileStep = async () => {
    await queryClient.invalidateQueries({ queryKey: ['profile'] })
  }

  return (
    <main>
      <h1>Знакомство</h1>
      {step === 1 && <DisclaimerStep api={api} onDone={() => go(1)} />}
      {step === 2 && <ParqStep onDone={() => go(2)} />}
      {step === 3 && (
        <BasicsStep
          api={api}
          onDone={(sex) => {
            setFemale(sex === 'female')
            setStep(4)
          }}
        />
      )}
      {step === 4 && <ExperienceStep api={api} onDone={() => go(4)} />}
      {step === 5 && <GoalStep api={api} onDone={() => go(5)} />}
      {step === 6 && <WeekdaysStep api={api} onDone={() => go(6)} />}
      {step === 7 && (
        <EquipmentStep
          onDone={async () => {
            await finishProfileStep()
            go(7)
          }}
        />
      )}
      {step === 8 && <RestrictionsStep onDone={() => go(8)} />}
      {step === 9 && <CycleStep api={api} onDone={() => go(9)} />}
      {step === 10 && (
        <SummaryStep
          api={api}
          onDone={async () => {
            await queryClient.invalidateQueries({ queryKey: ['today'] })
            await finishProfileStep()
            navigate('/', { replace: true })
          }}
        />
      )}
    </main>
  )
}

// MARK: - 1. Дисклеймер (§14.2)

function DisclaimerStep({ api, onDone }: { api: ApiClient; onDone: () => void }) {
  const { busy, error, run } = useAction()
  return (
    <StepFrame n={1} title="Добро пожаловать">
      {/* ЖДЁТ ЮРИСТА (§14.2, §19.2 п. 5): текст по смыслу, не согласованный. */}
      {DISCLAIMER_PENDING_LEGAL.map((line) => (
        <p key={line}>{line}</p>
      ))}
      <button
        type="button"
        disabled={busy}
        onClick={() =>
          // Строка `profiles` нужна до экрана 2: parq_responses ссылается на неё
          // внешним ключом, а создаёт её только PATCH (§5).
          void run(async () => {
            await api.patchProfile({})
            onDone()
          })
        }
      >
        Понятно
      </button>
      {error !== null && <ErrorBlock error={error} />}
    </StepFrame>
  )
}

// MARK: - 2. PAR-Q (§14.1)

function ParqStep({ onDone }: { onDone: () => void }) {
  const [answers, setAnswers] = useState<(boolean | null)[]>(PARQ_QUESTIONS.map(() => null))
  const [flagged, setFlagged] = useState(false)
  const { busy, error, run } = useAction()

  const complete = answers.every((a): a is boolean => a !== null)

  async function save(acknowledged: boolean) {
    await run(async () => {
      const userId = await currentUserId()
      await upsertParq(buildParqRow(userId, answers as boolean[], acknowledged, new Date()))
      onDone()
    })
  }

  if (flagged) {
    return (
      <StepFrame n={2} title="Рекомендация">
        {/* ЖДЁТ ЮРИСТА (§14.1, §19.2 п. 5): текст по смыслу, не согласованный. */}
        {RED_FLAG_PENDING_LEGAL.map((line) => (
          <p key={line}>{line}</p>
        ))}
        <button type="button" disabled={busy} onClick={() => void save(true)}>
          Я прочитал(а) рекомендацию
        </button>
        {error !== null && <ErrorBlock error={error} />}
      </StepFrame>
    )
  }

  return (
    <StepFrame n={2} title="Вопросы о здоровье">
      <form
        onSubmit={(e: FormEvent) => {
          e.preventDefault()
          if (!complete) return
          if (hasRedFlag(answers as boolean[])) setFlagged(true)
          else void save(false)
        }}
      >
        <ol>
          {PARQ_QUESTIONS.map((question, i) => (
            <li key={i}>
              <fieldset>
                <legend>{question}</legend>
                <label>
                  <input
                    type="radio"
                    name={`q${i + 1}`}
                    value="yes"
                    checked={answers[i] === true}
                    onChange={() => setAnswers((a) => a.map((v, j) => (j === i ? true : v)))}
                  />{' '}
                  Да
                </label>{' '}
                <label>
                  <input
                    type="radio"
                    name={`q${i + 1}`}
                    value="no"
                    checked={answers[i] === false}
                    onChange={() => setAnswers((a) => a.map((v, j) => (j === i ? false : v)))}
                  />{' '}
                  Нет
                </label>
              </fieldset>
            </li>
          ))}
        </ol>
        <button type="submit" disabled={!complete || busy}>
          Далее
        </button>
      </form>
      {error !== null && <ErrorBlock error={error} />}
    </StepFrame>
  )
}

// MARK: - 3. Базовое

function BasicsStep({ api, onDone }: { api: ApiClient; onDone: (sex: string) => void }) {
  const [sex, setSex] = useState('')
  const [birthYear, setBirthYear] = useState('')
  const [height, setHeight] = useState('')
  const [weight, setWeight] = useState('')
  const { busy, error, run } = useAction()
  const [problem, setProblem] = useState<string | null>(null)

  function submit(event: FormEvent) {
    event.preventDefault()
    const year = Number(birthYear)
    const h = Number(height.replace(',', '.'))
    const w = Number(weight.replace(',', '.'))
    const thisYear = new Date().getFullYear()
    if (!sex) return setProblem('Выберите пол при рождении')
    if (!Number.isInteger(year) || year < 1900 || year > thisYear) return setProblem('Проверьте год рождения')
    if (!(h >= 100 && h <= 250)) return setProblem('Рост — от 100 до 250 см')
    if (!(w >= 30 && w <= 400)) return setProblem('Вес — от 30 до 400 кг')
    setProblem(null)
    void run(async () => {
      const userId = await currentUserId()
      await api.patchProfile({ sex_at_birth: sex, birth_year: year, height_cm: h })
      await upsertBodyWeight(userId, w, localDate(new Date(), browserTimeZone()))
      onDone(sex)
    })
  }

  return (
    <StepFrame n={3} title="Базовое">
      <form onSubmit={submit}>
        <p>
          <label>
            Пол при рождении{' '}
            <select value={sex} onChange={(e) => setSex(e.target.value)}>
              <option value="">—</option>
              <option value="female">Женский</option>
              <option value="male">Мужской</option>
              <option value="undisclosed">Не хочу указывать</option>
            </select>
          </label>
        </p>
        <p>
          <label>
            Год рождения{' '}
            <input inputMode="numeric" value={birthYear} onChange={(e) => setBirthYear(e.target.value)} />
          </label>
        </p>
        <p>
          <label>
            Рост, см <input inputMode="decimal" value={height} onChange={(e) => setHeight(e.target.value)} />
          </label>
        </p>
        <p>
          <label>
            Вес, кг <input inputMode="decimal" value={weight} onChange={(e) => setWeight(e.target.value)} />
          </label>
        </p>
        <button type="submit" disabled={busy}>
          Далее
        </button>
      </form>
      {problem !== null && <p role="alert">{problem}</p>}
      {error !== null && <ErrorBlock error={error} />}
    </StepFrame>
  )
}

// MARK: - 4. Опыт, 5. Цель — выбор одного значения через PATCH

function ChoiceStep<T extends string>({
  n,
  title,
  question,
  options,
  save,
  onDone,
}: {
  n: Step
  title: string
  question?: string
  options: { value: T; label: string }[]
  save: (value: T) => Promise<unknown>
  onDone: () => void
}) {
  const [value, setValue] = useState<T | null>(null)
  const { busy, error, run } = useAction()
  return (
    <StepFrame n={n} title={title}>
      <form
        onSubmit={(e: FormEvent) => {
          e.preventDefault()
          if (value === null) return
          void run(async () => {
            await save(value)
            onDone()
          })
        }}
      >
        <fieldset>
          <legend>{question ?? title}</legend>
          {options.map((o) => (
            <p key={o.value}>
              <label>
                <input
                  type="radio"
                  name={`choice-${n}`}
                  value={o.value}
                  checked={value === o.value}
                  onChange={() => setValue(o.value)}
                />{' '}
                {o.label}
              </label>
            </p>
          ))}
        </fieldset>
        <button type="submit" disabled={value === null || busy}>
          Далее
        </button>
      </form>
      {error !== null && <ErrorBlock error={error} />}
    </StepFrame>
  )
}

function ExperienceStep({ api, onDone }: { api: ApiClient; onDone: () => void }) {
  return (
    <ChoiceStep
      n={4}
      title="Опыт"
      question="Знаю ли я, как выглядит правильная становая тяга?"
      options={[
        { value: 'novice', label: 'Новичок (< 6 мес)' },
        { value: 'intermediate', label: 'Средний (6 мес – 2 года)' },
        { value: 'advanced', label: 'Опытный (> 2 лет)' },
      ]}
      save={(v) => api.patchProfile({ experience_level: v })}
      onDone={onDone}
    />
  )
}

function GoalStep({ api, onDone }: { api: ApiClient; onDone: () => void }) {
  return (
    <ChoiceStep
      n={5}
      title="Цель"
      options={[
        { value: 'strength', label: 'Сила' },
        { value: 'hypertrophy', label: 'Набор мышечной массы' },
        { value: 'toning', label: 'Тонус и форма' },
        { value: 'endurance', label: 'Выносливость' },
        { value: 'general', label: 'Общее здоровье' },
      ]}
      save={(v) => api.patchProfile({ goal: v })}
      onDone={onDone}
    />
  )
}

// MARK: - 6. Дни недели

const WEEKDAYS = ['Понедельник', 'Вторник', 'Среда', 'Четверг', 'Пятница', 'Суббота', 'Воскресенье']

function WeekdaysStep({ api, onDone }: { api: ApiClient; onDone: () => void }) {
  const [days, setDays] = useState<number[]>([])
  const { busy, error, run } = useAction()
  const toggle = (d: number) =>
    setDays((cur) => (cur.includes(d) ? cur.filter((x) => x !== d) : [...cur, d].sort((a, b) => a - b)))
  return (
    <StepFrame n={6} title="Дни тренировок">
      <form
        onSubmit={(e: FormEvent) => {
          e.preventDefault()
          if (days.length === 0) return
          void run(async () => {
            await api.patchProfile({ training_weekdays: days })
            onDone()
          })
        }}
      >
        <fieldset>
          <legend>В какие дни недели вы занимаетесь?</legend>
          {WEEKDAYS.map((label, i) => (
            <p key={label}>
              <label>
                <input type="checkbox" checked={days.includes(i + 1)} onChange={() => toggle(i + 1)} /> {label}
              </label>
            </p>
          ))}
        </fieldset>
        <p data-testid="days-count">Дней в неделю: {days.length}</p>
        <button type="submit" disabled={days.length === 0 || busy}>
          Далее
        </button>
      </form>
      {error !== null && <ErrorBlock error={error} />}
    </StepFrame>
  )
}

// MARK: - 7. Инвентарь

const PRESET_IDS: PresetId[] = ['home_bodyweight', 'home_dumbbells', 'gym']

function EquipmentStep({ onDone }: { onDone: () => Promise<void> }) {
  const [form, setForm] = useState<EquipmentRow>(PRESETS.home_bodyweight)
  const [preset, setPreset] = useState<PresetId>('home_bodyweight')
  const [dumbbells, setDumbbells] = useState('')
  const [plates, setPlates] = useState('')
  const [kettlebells, setKettlebells] = useState('')
  const [problem, setProblem] = useState<string | null>(null)
  const { busy, error, run } = useAction()

  function choose(id: PresetId) {
    const row = PRESETS[id]
    setPreset(id)
    setForm(row)
    setDumbbells(row.dumbbells_kg.join(', '))
    setPlates(row.plates_kg.join(', '))
    setKettlebells(row.kettlebells_kg.join(', '))
  }
  const set = <K extends keyof EquipmentRow>(key: K, value: EquipmentRow[K]) => setForm((f) => ({ ...f, [key]: value }))

  function submit(event: FormEvent) {
    event.preventDefault()
    let row: EquipmentRow
    try {
      row = normalizeEquipment({
        ...form,
        dumbbells_kg: parseKgList(dumbbells),
        plates_kg: parseKgList(plates),
        kettlebells_kg: parseKgList(kettlebells),
      })
    } catch (e) {
      return setProblem(e instanceof Error ? e.message : 'Проверьте веса')
    }
    setProblem(null)
    void run(async () => {
      await insertEquipmentProfile(await currentUserId(), row)
      await onDone()
    })
  }

  return (
    <StepFrame n={7} title="Инвентарь">
      <div role="group" aria-label="Пресеты">
        {PRESET_IDS.map((id) => (
          <button key={id} type="button" data-preset={id} aria-pressed={preset === id} onClick={() => choose(id)}>
            {PRESETS[id].name}
          </button>
        ))}
      </div>
      <form onSubmit={submit}>
        <p>
          <label>
            Гантели, кг (через пробел){' '}
            <input value={dumbbells} onChange={(e) => setDumbbells(e.target.value)} />
          </label>
        </p>
        <p>
          <label>
            Блины, кг (через пробел) <input value={plates} onChange={(e) => setPlates(e.target.value)} />
          </label>
        </p>
        <p>
          <label>
            Гриф, кг{' '}
            <input
              inputMode="decimal"
              value={form.barbell_kg ?? ''}
              onChange={(e) => {
                const v = e.target.value.trim()
                setForm((f) => {
                  const { barbell_kg: _drop, ...rest } = f
                  void _drop
                  return v === '' ? rest : { ...rest, barbell_kg: Number(v.replace(',', '.')) }
                })
              }}
            />
          </label>
        </p>
        <p>
          <label>
            Шаг стека тренажёров, кг{' '}
            <input
              inputMode="decimal"
              value={form.machine_step_kg ?? ''}
              onChange={(e) => {
                const v = e.target.value.trim()
                setForm((f) => {
                  const { machine_step_kg: _drop, ...rest } = f
                  void _drop
                  return v === '' ? rest : { ...rest, machine_step_kg: Number(v.replace(',', '.')) }
                })
              }}
            />
          </label>
        </p>
        <p>
          <label>
            <input type="checkbox" checked={form.has_kettlebells} onChange={(e) => set('has_kettlebells', e.target.checked)} />{' '}
            Есть гири
          </label>{' '}
          {form.has_kettlebells && (
            <label>
              Гири, кг <input value={kettlebells} onChange={(e) => setKettlebells(e.target.value)} />
            </label>
          )}
        </p>
        <p>
          <label>
            <input type="checkbox" checked={form.bands} onChange={(e) => set('bands', e.target.checked)} /> Резинки
          </label>{' '}
          <label>
            <input type="checkbox" checked={form.pullup_bar} onChange={(e) => set('pullup_bar', e.target.checked)} />{' '}
            Турник
          </label>{' '}
          <label>
            <input type="checkbox" checked={form.step_platform} onChange={(e) => set('step_platform', e.target.checked)} />{' '}
            Степ-платформа
          </label>{' '}
          <label>
            <input type="checkbox" checked={form.plyo_box} onChange={(e) => set('plyo_box', e.target.checked)} /> Тумба
          </label>{' '}
          <label>
            <input type="checkbox" checked={form.cable_machine} onChange={(e) => set('cable_machine', e.target.checked)} />{' '}
            Блочная рама
          </label>
        </p>
        <p>
          <label>
            Скамья{' '}
            <select
              value={form.bench ?? ''}
              onChange={(e) => {
                const v = e.target.value
                setForm((f) => {
                  const { bench: _drop, ...rest } = f
                  void _drop
                  return v === 'flat' || v === 'adjustable' ? { ...rest, bench: v } : rest
                })
              }}
            >
              <option value="">Нет</option>
              <option value="flat">Горизонтальная</option>
              <option value="adjustable">Регулируемая</option>
            </select>
          </label>
        </p>
        <fieldset>
          <legend>Тренажёры</legend>
          {MACHINE_SLUGS.map((slug) => (
            <label key={slug}>
              <input
                type="checkbox"
                checked={form.machines.includes(slug)}
                onChange={(e) =>
                  set('machines', e.target.checked ? [...form.machines, slug] : form.machines.filter((m) => m !== slug))
                }
              />{' '}
              {slug}{' '}
            </label>
          ))}
        </fieldset>
        <button type="submit" disabled={busy}>
          Сохранить инвентарь
        </button>
      </form>
      {problem !== null && <p role="alert">{problem}</p>}
      {error !== null && <ErrorBlock error={error} />}
    </StepFrame>
  )
}

// MARK: - 8. Ограничения и травмы (§14.4)

const JOINTS: { joint: Joint; label: string }[] = [
  { joint: 'knee', label: 'Колено' },
  { joint: 'lower_back', label: 'Поясница' },
  { joint: 'shoulder', label: 'Плечо' },
  { joint: 'wrist', label: 'Запястье' },
  { joint: 'neck', label: 'Шея' },
  { joint: 'hip', label: 'Тазобедренный сустав' },
  { joint: 'ankle', label: 'Голеностоп' },
]

function RestrictionsStep({ onDone }: { onDone: () => void }) {
  const [levels, setLevels] = useState<Partial<Record<Joint, Severity>>>({})
  const { busy, error, run } = useAction()
  return (
    <StepFrame n={8} title="Ограничения и травмы">
      <form
        onSubmit={(e: FormEvent) => {
          e.preventDefault()
          void run(async () => {
            const items = JOINTS.flatMap(({ joint }) => {
              const severity = levels[joint]
              return severity ? [{ joint, severity }] : []
            })
            await insertRestrictions(await currentUserId(), items)
            onDone()
          })
        }}
      >
        {JOINTS.map(({ joint, label }) => (
          <p key={joint}>
            <label>
              {label}{' '}
              <select
                data-joint={joint}
                value={levels[joint] ?? ''}
                onChange={(e) => {
                  const v = e.target.value
                  setLevels((cur) => {
                    const { [joint]: _drop, ...rest } = cur
                    void _drop
                    return v === 'avoid' || v === 'careful' ? { ...rest, [joint]: v } : rest
                  })
                }}
              >
                <option value="">Нет ограничений</option>
                <option value="avoid">Избегать</option>
                <option value="careful">Осторожно</option>
              </select>
            </label>
          </p>
        ))}
        <button type="submit" disabled={busy}>
          Далее
        </button>
      </form>
      {error !== null && <ErrorBlock error={error} />}
    </StepFrame>
  )
}

// MARK: - 9. Цикл (только sex_at_birth = female)

function CycleStep({ api, onDone }: { api: ApiClient; onDone: () => void }) {
  const [tracking, setTracking] = useState<TrackingAnswer | null>(null)
  const [contraception, setContraception] = useState<ContraceptionAnswer | null>(null)
  const [periodStart, setPeriodStart] = useState('')
  const [cycleLength, setCycleLength] = useState('')
  const [periodLength, setPeriodLength] = useState('')
  const [regularity, setRegularity] = useState<Regularity | ''>('')
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
      onDone()
    })
  }

  const radio = <T extends string>(
    name: string,
    value: T,
    label: string,
    current: T | null,
    set: (v: T) => void,
  ) => (
    <label key={value}>
      <input type="radio" name={name} value={value} checked={current === value} onChange={() => set(value)} /> {label}{' '}
    </label>
  )

  return (
    <StepFrame n={9} title="Цикл">
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
              <p>
                При гормональной контрацепции естественных фаз цикла нет: приложение работает без фаз и
                предлагает ежедневный чек-ин.
              </p>
            )}
            {contraception === 'no' && (
              <>
                <p>Любой из ответов ниже можно пропустить.</p>
                <p>
                  <label>
                    Дата начала последней менструации{' '}
                    <input type="date" value={periodStart} onChange={(e) => setPeriodStart(e.target.value)} />
                  </label>
                </p>
                <p>
                  <label>
                    Обычная длина цикла, дней{' '}
                    <input inputMode="numeric" value={cycleLength} onChange={(e) => setCycleLength(e.target.value)} />
                  </label>
                </p>
                <p>
                  <label>
                    Обычная длительность менструации, дней{' '}
                    <input inputMode="numeric" value={periodLength} onChange={(e) => setPeriodLength(e.target.value)} />
                  </label>
                </p>
                <p>
                  <label>
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
        <button type="submit" disabled={busy || tracking === null || (tracking === 'yes' && contraception === null)}>
          Далее
        </button>
      </form>
      {problem !== null && <p role="alert">{problem}</p>}
      {error !== null && <ErrorBlock error={error} />}
    </StepFrame>
  )
}

// MARK: - 10. Итог

function SummaryStep({ api, onDone }: { api: ApiClient; onDone: () => Promise<void> }) {
  const { busy, error, run } = useAction()
  return (
    <StepFrame n={10} title="Готово">
      <p data-testid="onboarding-summary">{ONBOARDING_SUMMARY}</p>
      <button
        type="button"
        disabled={busy}
        onClick={() =>
          void run(async () => {
            // Неделя собирается здесь: к этому моменту профиль и инвентарь
            // полны, а ограничения и цикл уже записаны (§5).
            await api.generateWeek()
            await onDone()
          })
        }
      >
        Перейти к тренировкам
      </button>
      {error !== null && <ErrorBlock error={error} />}
    </StepFrame>
  )
}
