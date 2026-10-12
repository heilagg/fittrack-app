// Ежедневный чек-ин и оверрайд дня (SPEC §10, §11.4, §13.1): сворачиваемый
// чек-ин из четырёх шкал 1–5 и три кнопки оверрайда.
//
// Пишется прямо в `daily_checkins` (§20.6). Карточка дня и неделя после записи
// перечитываются: готовность и план считает сервер, «План обновлён» приезжает
// `notice` недели. Повторный тап по выбранному оверрайду его снимает —
// последнее нажатие и есть ответ дня (§11.4).

import { useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { currentUserId } from '../../auth/supabase'
import { readCheckin, saveCheckin, type Checkin, type Override } from '../../direct/checkin'
import { ErrorBlock } from './TodayScreen'

// У энергии и сна 5 — хорошо, у болезненности и стресса 5 — плохо (§10):
// концы шкалы подписаны, иначе направление не угадать.
const SCALES: { key: 'energy' | 'soreness' | 'sleep_quality' | 'stress'; label: string; ends: string }[] = [
  { key: 'energy', label: 'Энергия', ends: '1 — мало сил, 5 — много' },
  { key: 'soreness', label: 'Болезненность мышц', ends: '1 — нет, 5 — сильная' },
  { key: 'sleep_quality', label: 'Сон', ends: '1 — плохо, 5 — отлично' },
  { key: 'stress', label: 'Стресс', ends: '1 — нет, 5 — сильный' },
]

const OVERRIDES: { value: Override; label: string }[] = [
  { value: 'push', label: 'Чувствую себя отлично' },
  { value: 'ease', label: 'Тяжёлый день' },
  { value: 'rest', label: 'Не сегодня' },
]

export function CheckinCard({ date }: { date: string }) {
  const queryClient = useQueryClient()
  const stored = useQuery({ queryKey: ['checkin', date], queryFn: () => readCheckin(date) })
  const [draft, setDraft] = useState<Checkin>({})
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<unknown>(null)
  const [saved, setSaved] = useState(false)

  async function write(fields: Checkin) {
    setBusy(true)
    setError(null)
    setSaved(false)
    try {
      await saveCheckin(await currentUserId(), date, fields)
      await Promise.all(['checkin', 'today', 'week'].map((key) => queryClient.invalidateQueries({ queryKey: [key] })))
      return true
    } catch (e) {
      setError(e)
      return false
    } finally {
      setBusy(false)
    }
  }

  const current = stored.data ?? null
  const value = (key: (typeof SCALES)[number]['key']) => draft[key] ?? current?.[key] ?? null
  const override = current?.override ?? null

  return (
    <section aria-label="Самочувствие" className="card" data-testid="checkin">
      <div role="group" aria-label="Оверрайд дня" className="option-grid">
        {OVERRIDES.map((o) => (
          <button
            key={o.value}
            type="button"
            data-override={o.value}
            aria-pressed={override === o.value}
            disabled={busy || stored.isPending}
            onClick={() => void write({ override: override === o.value ? null : o.value })}
          >
            {o.label}
          </button>
        ))}
      </div>
      <details>
        <summary>Чек-ин</summary>
        <form
          onSubmit={(e) => {
            e.preventDefault()
            void write(draft).then((ok) => {
              if (ok) {
                setDraft({})
                setSaved(true)
              }
            })
          }}
        >
          {SCALES.map((scale) => (
            <fieldset key={scale.key}>
              <legend>{scale.label}</legend>
              <p className="caption">{scale.ends}</p>
              <div className="option-row">
                {[1, 2, 3, 4, 5].map((n) => (
                  <label key={n} className="option">
                    <input
                      type="radio"
                      name={scale.key}
                      value={n}
                      checked={value(scale.key) === n}
                      onChange={() => setDraft((d) => ({ ...d, [scale.key]: n }))}
                    />{' '}
                    {n}
                  </label>
                ))}
              </div>
            </fieldset>
          ))}
          <button type="submit" className="button-primary" disabled={busy || Object.keys(draft).length === 0}>
            Сохранить чек-ин
          </button>
        </form>
        {saved && <p className="caption" data-testid="checkin-saved">Чек-ин сохранён</p>}
      </details>
      {error !== null && <ErrorBlock error={error} />}
    </section>
  )
}
