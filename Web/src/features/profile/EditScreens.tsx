// Правки Профиля, срез 6: личные данные, инвентарь по умолчанию, ограничения.
// Выбор профиля инвентаря на «Начать», экспорт и удаление аккаунта — вне среза.
//
// Куда что пишется (§20.6):
//   личные данные — `PATCH /v1/profile` (только изменённые поля) и вес тела
//     прямой записью; план пересчитывает сервер, изменение приезжает `notice`
//     недели;
//   инвентарь — прямая правка строки `is_default`, затем `/rebuild` с
//     `equipment_changed` и показ `notice`;
//   ограничения — снятие (`resolved_at`) и новые строки прямой записью;
//     `/rebuild` для них причины нет (§20.3), изменение плана приезжает
//     `notice` при следующем чтении недели.

import { useState, type FormEvent } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Link } from 'react-router-dom'
import type { ApiClient } from '../../api/client'
import type { Profile } from '../../api/schemas'
import { browserTimeZone, localDate } from '../../api/day'
import { currentUserId } from '../../auth/supabase'
import { readDefaultEquipment, updateEquipmentProfile } from '../../direct/equipment'
import { upsertBodyWeight } from '../../direct/onboarding'
import { addRestrictions, latestBodyWeight, readActiveRestrictions, resolveRestrictions } from '../../direct/profile'
import { EXPERIENCE_OPTIONS, EXPERIENCE_QUESTION } from '../../onboarding/labels'
import { personalPatch } from '../../profile/personal'
import { levelsOf, restrictionChanges } from '../../profile/restrictions'
import { ErrorBlock } from '../today/TodayScreen'
import { EquipmentForm, RestrictionsForm } from './forms'

function Frame({ title, testId, children }: { title: string; testId: string; children: React.ReactNode }) {
  return (
    <main>
      <Link to="/profile" className="link-back">
        Профиль
      </Link>
      <h1>{title}</h1>
      <section aria-label={title} className="exercise" data-testid={testId}>
        {children}
      </section>
    </main>
  )
}

const refresh = (queryClient: ReturnType<typeof useQueryClient>, keys: string[]) =>
  Promise.all(keys.map((key) => queryClient.invalidateQueries({ queryKey: [key] })))

// MARK: - Личные данные

const WEEKDAYS = ['Понедельник', 'Вторник', 'Среда', 'Четверг', 'Пятница', 'Суббота', 'Воскресенье']
const LEVELS = EXPERIENCE_OPTIONS
const GOALS = [
  { value: 'strength', label: 'Сила' },
  { value: 'hypertrophy', label: 'Набор мышечной массы' },
  { value: 'toning', label: 'Тонус и форма' },
  { value: 'endurance', label: 'Выносливость' },
  { value: 'general', label: 'Общее здоровье' },
] as const

export function PersonalScreen({ api }: { api: ApiClient }) {
  const profile = useQuery({ queryKey: ['profile'], queryFn: () => api.getProfileIfStarted() })
  const weight = useQuery({ queryKey: ['body-weight'], queryFn: latestBodyWeight })
  if (profile.isPending || weight.isPending) return <p role="status">Загрузка…</p>
  if (profile.isError) return <ErrorBlock error={profile.error} />
  if (!profile.data) return <ErrorBlock error={new Error('Профиль ещё не заполнен')} />
  return (
    <Frame title="Личные данные" testId="personal">
      <PersonalForm api={api} profile={profile.data} weight={weight.data ?? null} />
    </Frame>
  )
}

function PersonalForm({ api, profile, weight }: { api: ApiClient; profile: Profile; weight: number | null }) {
  const queryClient = useQueryClient()
  const [birthYear, setBirthYear] = useState(String(profile.birth_year ?? ''))
  const [height, setHeight] = useState(String(profile.height_cm ?? ''))
  const [bodyWeight, setBodyWeight] = useState(weight === null ? '' : String(weight))
  const [level, setLevel] = useState(profile.experience_level ?? 'novice')
  const [goal, setGoal] = useState(profile.goal ?? 'general')
  const [days, setDays] = useState<number[]>(profile.training_weekdays ?? [])
  const [minutes, setMinutes] = useState(String(profile.session_minutes))
  const [problem, setProblem] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<unknown>(null)
  const [saved, setSaved] = useState(false)

  function submit(event: FormEvent) {
    event.preventDefault()
    const year = Number(birthYear)
    const h = Number(height.replace(',', '.'))
    const w = bodyWeight.trim() === '' ? null : Number(bodyWeight.replace(',', '.'))
    const m = Number(minutes)
    const thisYear = new Date().getFullYear()
    // Пределы — те же, что у шага 3 онбординга.
    if (!Number.isInteger(year) || year < 1900 || year > thisYear) return setProblem('Проверьте год рождения')
    if (!(h >= 100 && h <= 250)) return setProblem('Рост — от 100 до 250 см')
    if (w !== null && !(w >= 30 && w <= 400)) return setProblem('Вес — от 30 до 400 кг')
    if (days.length === 0) return setProblem('Выберите хотя бы один день')
    if (!Number.isInteger(m) || m <= 0) return setProblem('Длительность — целое число минут')
    setProblem(null)
    setBusy(true)
    setError(null)
    setSaved(false)
    void (async () => {
      try {
        const patch = personalPatch(profile, {
          birth_year: year, height_cm: h, experience_level: level, goal, training_weekdays: days, session_minutes: m,
        })
        if (Object.keys(patch).length > 0) await api.patchProfile(patch)
        if (w !== null && w !== weight) {
          await upsertBodyWeight(await currentUserId(), w, localDate(new Date(), browserTimeZone()))
        }
        await refresh(queryClient, ['profile', 'body-weight', 'today', 'week'])
        setSaved(true)
      } catch (e) {
        setError(e)
      } finally {
        setBusy(false)
      }
    })()
  }

  const toggle = (d: number) => setDays((cur) => (cur.includes(d) ? cur.filter((x) => x !== d) : [...cur, d]))
  return (
    <>
      <form onSubmit={submit}>
        <p>
          <label className="field">
            Год рождения <input inputMode="numeric" value={birthYear} onChange={(e) => setBirthYear(e.target.value)} />
          </label>
        </p>
        <p>
          <label className="field">
            Рост, см <input inputMode="decimal" value={height} onChange={(e) => setHeight(e.target.value)} />
          </label>
        </p>
        <p>
          <label className="field">
            Вес, кг <input inputMode="decimal" value={bodyWeight} onChange={(e) => setBodyWeight(e.target.value)} />
          </label>
        </p>
        <p>
          <label className="field">
            {EXPERIENCE_QUESTION}{' '}
            <select value={level} onChange={(e) => setLevel(e.target.value as typeof level)}>
              {LEVELS.map((l) => (
                <option key={l.value} value={l.value}>
                  {l.label}
                </option>
              ))}
            </select>
          </label>
        </p>
        <p>
          <label className="field">
            Цель{' '}
            <select value={goal} onChange={(e) => setGoal(e.target.value as typeof goal)}>
              {GOALS.map((g) => (
                <option key={g.value} value={g.value}>
                  {g.label}
                </option>
              ))}
            </select>
          </label>
        </p>
        <fieldset>
          <legend>Дни тренировок</legend>
          {WEEKDAYS.map((label, i) => (
            <p key={label}>
              <label className="option">
                <input type="checkbox" checked={days.includes(i + 1)} onChange={() => toggle(i + 1)} /> {label}
              </label>
            </p>
          ))}
          <p className="caption">Новые дни вступят в силу со следующей недели.</p>
        </fieldset>
        <p>
          <label className="field">
            Длительность тренировки, мин{' '}
            <input inputMode="numeric" value={minutes} onChange={(e) => setMinutes(e.target.value)} />
          </label>
        </p>
        <button type="submit" className="button-primary" disabled={busy}>
          Сохранить
        </button>
      </form>
      {saved && <p className="notice" data-testid="personal-saved">Сохранено</p>}
      {problem !== null && <p role="alert">{problem}</p>}
      {error !== null && <ErrorBlock error={error} />}
    </>
  )
}

// MARK: - Инвентарь

export function EquipmentScreen({ api }: { api: ApiClient }) {
  const queryClient = useQueryClient()
  const current = useQuery({ queryKey: ['equipment-default'], queryFn: readDefaultEquipment })
  const [notice, setNotice] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)
  if (current.isPending) return <p role="status">Загрузка…</p>
  if (current.isError) return <ErrorBlock error={current.error} />
  if (!current.data) return <ErrorBlock error={new Error('Инвентаря по умолчанию нет')} />
  const { id, row } = current.data
  return (
    <Frame title="Инвентарь" testId="equipment">
      <EquipmentForm
        key={id}
        initial={row}
        submitLabel="Сохранить инвентарь"
        onSubmit={async (next) => {
          setSaved(false)
          await updateEquipmentProfile(id, next)
          const week = await api.rebuildWeek('equipment_changed')
          setNotice(week?.notice?.message ?? null)
          await refresh(queryClient, ['equipment-default', 'today', 'week'])
          setSaved(true)
        }}
      />
      {saved && (
        <p className="notice" data-testid="equipment-saved">
          {notice ?? 'Сохранено'}
        </p>
      )}
    </Frame>
  )
}

// MARK: - Ограничения

export function RestrictionsScreen() {
  const queryClient = useQueryClient()
  const active = useQuery({ queryKey: ['restrictions'], queryFn: readActiveRestrictions })
  const [saved, setSaved] = useState(false)
  if (active.isPending) return <p role="status">Загрузка…</p>
  if (active.isError) return <ErrorBlock error={active.error} />
  const rows = active.data
  return (
    <Frame title="Ограничения и травмы" testId="restrictions">
      <RestrictionsForm
        key={rows.map((r) => r.id).join(',')}
        initial={levelsOf(rows)}
        submitLabel="Сохранить"
        onSubmit={async (levels) => {
          setSaved(false)
          const { resolve, add } = restrictionChanges(rows, levels)
          await resolveRestrictions(resolve)
          await addRestrictions(await currentUserId(), add)
          await refresh(queryClient, ['restrictions', 'today', 'week'])
          setSaved(true)
        }}
      />
      {saved && <p className="notice" data-testid="restrictions-saved">Сохранено</p>}
    </Frame>
  )
}
