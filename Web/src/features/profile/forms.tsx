// Формы инвентаря и ограничений (SPEC §5, шаги 7–8; §6.6, §14.4). Один
// компонент на два места: онбординг и правка из Профиля (срез 6). Запись —
// у вызывающего: на онбординге строки создаются, в Профиле правятся.

import { useState, type FormEvent } from 'react'
import type { EquipmentRow } from '../../direct/equipmentRow'
import type { Joint } from '../../direct/onboarding'
import { MACHINE_LABELS } from '../../onboarding/labels'
import type { Levels } from '../../profile/restrictions'
import { MACHINE_SLUGS, normalizeEquipment, parseKgList, PRESETS, type PresetId } from '../../onboarding/presets'
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

const PRESET_IDS: PresetId[] = ['home_bodyweight', 'home_dumbbells', 'gym']

export function EquipmentForm({
  initial,
  submitLabel,
  onSubmit,
}: {
  /** Строка для правки; без неё форма начинается с пресета «Дома без железа». */
  initial?: EquipmentRow
  submitLabel: string
  onSubmit: (row: EquipmentRow) => Promise<void>
}) {
  const [form, setForm] = useState<EquipmentRow>(initial ?? PRESETS.home_bodyweight)
  const [preset, setPreset] = useState<PresetId | null>(initial ? null : 'home_bodyweight')
  const [dumbbells, setDumbbells] = useState(initial ? initial.dumbbells_kg.join(', ') : '')
  const [plates, setPlates] = useState(initial ? initial.plates_kg.join(', ') : '')
  const [kettlebells, setKettlebells] = useState(initial ? initial.kettlebells_kg.join(', ') : '')
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
    // Правка пресетом не меняет имя и флаг строки: это та же строка.
    if (initial) row = { ...row, name: initial.name, is_default: initial.is_default }
    void run(() => onSubmit(row))
  }

  return (
    <>
      <div role="group" aria-label="Пресеты" className="presets">
        {PRESET_IDS.map((id) => (
          <button key={id} type="button" data-preset={id} aria-pressed={preset === id} onClick={() => choose(id)}>
            {PRESETS[id].name}
          </button>
        ))}
      </div>
      <form onSubmit={submit}>
        <p>
          <label className="field">
            Гантели, кг (через пробел){' '}
            <input value={dumbbells} onChange={(e) => setDumbbells(e.target.value)} />
          </label>
        </p>
        <p>
          <label className="field">
            Блины, кг (через пробел) <input value={plates} onChange={(e) => setPlates(e.target.value)} />
          </label>
        </p>
        <p>
          <label className="field">
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
          <label className="field">
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
        <p className="option-grid">
          <label className="option">
            <input type="checkbox" checked={form.has_kettlebells} onChange={(e) => set('has_kettlebells', e.target.checked)} />{' '}
            Есть гири
          </label>{' '}
          {form.has_kettlebells && (
            <label className="field">
              Гири, кг <input value={kettlebells} onChange={(e) => setKettlebells(e.target.value)} />
            </label>
          )}
        </p>
        <p className="option-grid">
          <label className="option">
            <input type="checkbox" checked={form.bands} onChange={(e) => set('bands', e.target.checked)} /> Резинки
          </label>{' '}
          <label className="option">
            <input type="checkbox" checked={form.pullup_bar} onChange={(e) => set('pullup_bar', e.target.checked)} />{' '}
            Турник
          </label>{' '}
          <label className="option">
            <input type="checkbox" checked={form.step_platform} onChange={(e) => set('step_platform', e.target.checked)} />{' '}
            Степ-платформа
          </label>{' '}
          <label className="option">
            <input type="checkbox" checked={form.plyo_box} onChange={(e) => set('plyo_box', e.target.checked)} /> Тумба
          </label>{' '}
          <label className="option">
            <input type="checkbox" checked={form.cable_machine} onChange={(e) => set('cable_machine', e.target.checked)} />{' '}
            Блочная рама
          </label>
        </p>
        <p>
          <label className="field">
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
          <div className="option-grid">
          {MACHINE_SLUGS.map((slug) => (
            <label key={slug} className="option">
              <input
                type="checkbox"
                checked={form.machines.includes(slug)}
                onChange={(e) =>
                  set('machines', e.target.checked ? [...form.machines, slug] : form.machines.filter((m) => m !== slug))
                }
              />{' '}
              {MACHINE_LABELS[slug] ?? slug}{' '}
            </label>
          ))}
          </div>
        </fieldset>
        <button type="submit" className="button-primary" disabled={busy}>
          {submitLabel}
        </button>
      </form>
      {problem !== null && <p role="alert">{problem}</p>}
      {error !== null && <ErrorBlock error={error} />}
    </>
  )
}

export const JOINTS: { joint: Joint; label: string }[] = [
  { joint: 'knee', label: 'Колено' },
  { joint: 'lower_back', label: 'Поясница' },
  { joint: 'shoulder', label: 'Плечо' },
  { joint: 'wrist', label: 'Запястье' },
  { joint: 'neck', label: 'Шея' },
  { joint: 'hip', label: 'Тазобедренный сустав' },
  { joint: 'ankle', label: 'Голеностоп' },
]

export function RestrictionsForm({
  initial = {},
  submitLabel,
  onSubmit,
}: {
  initial?: Levels
  submitLabel: string
  onSubmit: (levels: Levels) => Promise<void>
}) {
  const [levels, setLevels] = useState<Levels>(initial)
  const { busy, error, run } = useAction()
  return (
    <>
      <form
        onSubmit={(e: FormEvent) => {
          e.preventDefault()
          void run(() => onSubmit(levels))
        }}
      >
        {JOINTS.map(({ joint, label }) => (
          <p key={joint}>
            <label className="field">
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
        <button type="submit" className="button-primary" disabled={busy}>
          {submitLabel}
        </button>
      </form>
      {error !== null && <ErrorBlock error={error} />}
    </>
  )
}
