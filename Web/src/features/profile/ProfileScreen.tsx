// Профиль (SPEC §13.1), срез 6: правка личных данных, инвентаря по умолчанию,
// ограничений и цикла; вход в календарь цикла. Выбор профиля инвентаря на
// «Начать», экспорт и удаление аккаунта — вне среза.
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
      <ul className="rows card" aria-label="Данные">
        <li>
          <Link to="/profile/personal" data-testid="personal-link">
            Личные данные
          </Link>
        </li>
        <li>
          <Link to="/profile/equipment" data-testid="equipment-link">
            Инвентарь
          </Link>
        </li>
        <li>
          <Link to="/profile/restrictions" data-testid="restrictions-link">
            Ограничения и травмы
          </Link>
        </li>
      </ul>
      {visibility.kind !== 'none' && (
        <ul className="rows card" aria-label="Цикл">
          {visibility.kind === 'calendar' ? (
            <>
              <li>
                <Link to="/cycle" data-testid="cycle-calendar-link">
                  Календарь цикла
                </Link>
              </li>
              <li>
                <Link to="/cycle/enable" data-testid="cycle-settings-link">
                  Настройки цикла
                </Link>
              </li>
            </>
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
