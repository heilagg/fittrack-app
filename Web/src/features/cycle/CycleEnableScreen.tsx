// Включение цикла из Профиля (SPEC §11.6, §19.2 п.27): те же вопросы, что шаг 9
// онбординга, запись через `PATCH /v1/profile`. Если записана дата начала,
// неделя пересобирается с `cycle_event_added`, и `notice` едет в календарь.

import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Link, useNavigate } from 'react-router-dom'
import type { ApiClient } from '../../api/client'
import { cycleAnswersOf } from '../../onboarding/cycle'
import { CycleSettingsForm } from './CycleSettingsForm'

export function CycleEnableScreen({ api }: { api: ApiClient }) {
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const profile = useQuery({ queryKey: ['profile'], queryFn: () => api.getProfileIfStarted() })

  async function saved({ periodStart }: { periodStart: boolean }) {
    const week = periodStart ? await api.rebuildWeek('cycle_event_added') : null
    await queryClient.invalidateQueries()
    navigate('/cycle', { state: { notice: week?.notice?.message } })
  }

  return (
    <main>
      <Link to="/profile" className="link-back">
        Профиль
      </Link>
      <h1>Цикл</h1>
      <section aria-label="Цикл" className="exercise" data-testid="cycle-enable">
        {profile.isPending ? (
          <p role="status">Загрузка…</p>
        ) : (
          <CycleSettingsForm
            api={api}
            onSaved={saved}
            submitLabel="Сохранить"
            initial={profile.data ? cycleAnswersOf(profile.data) : {}}
          />
        )}
      </section>
    </main>
  )
}
