// Запись события цикла и пересборка недели после неё (SPEC §11.6, §20.6;
// web-domain §3.3): прямая запись → `/rebuild` с `cycle_event_added` →
// `notice` наружу, чтобы экран его показал. Молчаливой пересборки нет.
//
// После записи сбрасываются все запросы, которые от событий зависят: сетка,
// карточка дня (фаза), неделя и два последних события.

import { useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import type { ApiClient } from '../../api/client'

export function useCycleWrite(api: ApiClient) {
  const queryClient = useQueryClient()
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<unknown>(null)
  const [notice, setNotice] = useState<string | null>(null)

  async function run(write: () => Promise<void>): Promise<boolean> {
    setBusy(true)
    setError(null)
    try {
      await write()
      const week = await api.rebuildWeek('cycle_event_added')
      setNotice(week?.notice?.message ?? null)
      await Promise.all(
        ['cycle-calendar', 'cycle-latest', 'today', 'week'].map((key) =>
          queryClient.invalidateQueries({ queryKey: [key] }),
        ),
      )
      return true
    } catch (e) {
      setError(e)
      return false
    } finally {
      setBusy(false)
    }
  }

  return { busy, error, notice, run }
}
