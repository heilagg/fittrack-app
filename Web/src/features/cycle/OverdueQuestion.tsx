// «Месячные уже начались?» (SPEC §11.6): по `overdue` с сервера, один раз на
// ожидаемую дату. «Да, отметить» ставит начало месячных сегодня и идёт через
// ту же запись с `/rebuild`, что и тап по дню.

import { useState } from 'react'
import type { ApiClient } from '../../api/client'
import type { CycleCalendar } from '../../api/schemas'
import { currentUserId } from '../../auth/supabase'
import { insertCycleEvent } from '../../direct/cycle'
import { browserStore, markOverdueAnswered, shouldAskOverdue, type FlagStore } from '../../cycle/once'
import { ErrorBlock } from '../today/TodayScreen'
import { useCycleWrite } from './useCycleWrite'

export function OverdueQuestion({
  api,
  calendar,
  today,
  store = browserStore,
}: {
  api: ApiClient
  calendar: CycleCalendar
  today: string
  store?: FlagStore
}) {
  const [answered, setAnswered] = useState(false)
  const { busy, error, notice, run } = useCycleWrite(api)
  const expected = calendar.next_period?.expected

  if (notice) {
    return (
      <p className="notice" data-testid="cycle-notice">
        {notice}
      </p>
    )
  }
  if (answered || expected === undefined || !shouldAskOverdue(calendar, store)) {
    return error !== null ? <ErrorBlock error={error} /> : null
  }

  function answer(started: boolean) {
    void (async () => {
      if (started) {
        const ok = await run(async () => insertCycleEvent(await currentUserId(), 'period_start', today))
        if (!ok) return
      }
      markOverdueAnswered(expected!, store)
      setAnswered(true)
    })()
  }

  return (
    <section aria-label="Месячные уже начались?" className="card" data-testid="overdue-question">
      <p>Месячные уже начались?</p>
      <div className="button-row">
        <button type="button" className="button-primary" disabled={busy} onClick={() => answer(true)}>
          Да, отметить
        </button>
        <button type="button" className="button-text" disabled={busy} onClick={() => answer(false)}>
          Ещё нет
        </button>
      </div>
      {error !== null && <ErrorBlock error={error} />}
    </section>
  )
}
