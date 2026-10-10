// Dev-кнопка подготовки данных (web-domain §6, срез 1).
//
// Заводит то, что в срезе 5 сделает настоящий онбординг: четыре поля профиля,
// строку инвентаря по умолчанию и неделю. Это единственное место, где клиент
// создаёт данные в обход онбординга, и оно не должно попасть в продакшен:
// компонент подключается только под `import.meta.env.DEV`, а сборка вырезает
// ветку целиком (проверяется сборкой: dev-модуля в `dist` нет).
// Снимается в срезе 5.

import { useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import type { ApiClient } from '../../api/client'
import { isoWeekday } from '../../api/day'
import { supabase } from '../../auth/supabase'
import { insertEquipmentProfile } from '../../direct/equipment'
import { ErrorBlock } from '../today/TodayScreen'

/** Три тренировочных дня, первый из которых — сегодняшний, чтобы «Сегодня» дало состав. */
export function seedWeekdays(todayISO: number): number[] {
  const next = (n: number) => ((todayISO - 1 + n) % 7) + 1
  return [todayISO, next(2), next(4)].sort((a, b) => a - b)
}

export function DevSeed({ api }: { api: ApiClient }) {
  const queryClient = useQueryClient()
  const [state, setState] = useState<'idle' | 'working' | 'done'>('idle')
  const [error, setError] = useState<unknown>(null)

  async function run() {
    setState('working')
    setError(null)
    try {
      const { data } = await supabase.auth.getUser()
      if (!data.user) throw new Error('Нет сессии')
      const { date } = api.today()

      await api.patchProfile({
        sex_at_birth: 'female',
        birth_year: 1994,
        height_cm: 168,
        experience_level: 'intermediate',
        goal: 'hypertrophy',
        training_weekdays: seedWeekdays(isoWeekday(date)),
        session_minutes: 60,
        cycle_tracking: 'off',
      })
      // Профиль уже существует (внешний ключ), инвентарь пишется напрямую.
      await insertEquipmentProfile(data.user.id, {
        name: 'Зал',
        is_default: true,
        dumbbells_kg: [4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 28, 32],
        plates_kg: [1.25, 2.5, 5, 10, 20],
        barbell_kg: 20,
        bands: true,
        pullup_bar: true,
        bench: 'adjustable',
      })
      await api.generateWeek()
      await queryClient.invalidateQueries({ queryKey: ['today'] })
      setState('done')
    } catch (e) {
      setError(e)
      setState('idle')
    }
  }

  return (
    <section aria-label="Только для разработки">
      <button type="button" onClick={run} disabled={state === 'working'}>
        Подготовить тестовые данные
      </button>
      {state === 'done' && <span role="status"> Готово</span>}
      {error !== null && <ErrorBlock error={error} />}
    </section>
  )
}
