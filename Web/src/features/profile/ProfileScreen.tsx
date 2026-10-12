// Профиль (SPEC §13.1), срез 6: пока только вход в календарь цикла. Правки
// личных данных, инвентаря, ограничений и цикла — следующим PR.
//
// Что показать вместо календаря, решает `cycleVisibility` (§11.6, §19.2 п.27):
// календарь, строка «Цикл выключен» с переходом к включению или ничего
// (цикл не про эту пользовательницу). При `declined` — разовое предложение
// включить цикл.

import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Link, useNavigate } from 'react-router-dom'
import type { ApiClient } from '../../api/client'
import { browserStore, markEnableOfferAnswered, shouldOfferEnable, type FlagStore } from '../../cycle/once'
import { cycleVisibility } from '../../cycle/visibility'
import { ErrorBlock } from '../today/TodayScreen'

export function ProfileScreen({ api, store = browserStore }: { api: ApiClient; store?: FlagStore }) {
  const profile = useQuery({ queryKey: ['profile'], queryFn: () => api.getProfileIfStarted() })
  const navigate = useNavigate()
  const [offerAnswered, setOfferAnswered] = useState(false)

  if (profile.isPending) return <p role="status">Загрузка…</p>
  if (profile.isError) return <ErrorBlock error={profile.error} />

  const visibility = cycleVisibility(profile.data)
  const offer = visibility.kind === 'off' && visibility.declined && !offerAnswered && shouldOfferEnable(store)

  function answerOffer(enable: boolean) {
    markEnableOfferAnswered(store)
    setOfferAnswered(true)
    if (enable) navigate('/cycle/enable')
  }

  return (
    <main>
      <header className="screen-header">
        <h1>Профиль</h1>
      </header>
      {offer && (
        <section aria-label="Включить цикл" className="card" data-testid="enable-offer">
          <p>Включить отслеживание цикла?</p>
          <div className="button-row">
            <button type="button" className="button-primary" onClick={() => answerOffer(true)}>
              Включить
            </button>
            <button type="button" className="button-text" onClick={() => answerOffer(false)}>
              Не сейчас
            </button>
          </div>
        </section>
      )}
      {visibility.kind !== 'none' && (
        <ul className="rows card" aria-label="Цикл">
          {visibility.kind === 'calendar' ? (
            <li>
              <Link to="/cycle" data-testid="cycle-calendar-link">
                Календарь цикла
              </Link>
            </li>
          ) : (
            <li>
              <Link to="/cycle/enable" data-testid="cycle-off-link">
                Цикл выключен
              </Link>
              <span className="caption">Включить</span>
            </li>
          )}
        </ul>
      )}
    </main>
  )
}
