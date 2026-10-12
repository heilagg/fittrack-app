// Календарь цикла (SPEC §11.6, §20.3): месячная сетка из `GET /v1/cycle/calendar`.
//
// Всё, что на сетке, посчитал сервер: дни месячных (отмеченные, расчётные,
// прогнозные), фазу дня, оценку овуляции, ожидаемое начало и диапазон.
// Клиент раскладывает месяц по неделям и решает только, что можно сделать с
// днём: отметить начало или конец (не позже сегодня), перенести или удалить
// последнее событие. После каждой записи — `/rebuild` и `notice`
// (`useCycleWrite`).
//
// Визуальные решения — токены web-domain §8: месячные отмечены так же, как
// сегодня на календаре недели (заливка — отмеченные, обводка — расчётные,
// пунктир — прогноз), оценка овуляции — точка под числом.

import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Link, useLocation } from 'react-router-dom'
import type { ApiClient } from '../../api/client'
import type { CycleCalendar, CycleCalendarDay } from '../../api/schemas'
import { currentUserId } from '../../auth/supabase'
import { latestCycleEvents, deleteCycleEvent, insertCycleEvent, moveCycleEvent } from '../../direct/cycle'
import { canMark, canMoveTo, isEditable, MARK_LABEL, type CycleEventRef } from '../../cycle/events'
import { monthOf, monthRange, monthWeeks, shiftMonth } from '../../cycle/month'
import { cycleVisibility } from '../../cycle/visibility'
import { formatDayHeading, formatShortDate } from '../../ui/format'
import { ErrorBlock } from '../today/TodayScreen'
import { OverdueQuestion } from './OverdueQuestion'
import { PhaseCard } from './PhaseCard'
import { useCycleWrite } from './useCycleWrite'

const WEEKDAYS = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс']
const monthName = new Intl.DateTimeFormat('ru-RU', { month: 'long', year: 'numeric', timeZone: 'UTC' })
const PERIOD_TEXT: Record<string, string> = {
  marked: 'месячные',
  estimated: 'месячные, расчётный день',
  forecast: 'ожидаемые месячные',
}

function monthTitle(month: string): string {
  const [y, m] = month.split('-').map(Number) as [number, number]
  return monthName.format(new Date(Date.UTC(y, m - 1, 1)))
}

function inRange(date: string, calendar: CycleCalendar): boolean {
  const next = calendar.next_period
  return next !== undefined && date >= next.range_start && date <= next.range_end
}

export function CycleCalendarScreen({ api }: { api: ApiClient }) {
  const today = api.today().date
  const location = useLocation()
  const [month, setMonth] = useState(monthOf(today))
  const [selected, setSelected] = useState<string | null>(null)
  const range = monthRange(month)

  const profile = useQuery({ queryKey: ['profile'], queryFn: () => api.getProfileIfStarted() })
  const calendar = useQuery({
    queryKey: ['cycle-calendar', range.from, range.to],
    queryFn: () => api.getCycleCalendar(range.from, range.to),
  })
  // Сегодняшний день отдельным окном: фаза и вопрос «уже начались?» не
  // зависят от того, какой месяц открыт.
  const todayCalendar = useQuery({
    queryKey: ['cycle-calendar', today, today],
    queryFn: () => api.getCycleCalendar(today, today),
  })
  const latest = useQuery({ queryKey: ['cycle-latest'], queryFn: latestCycleEvents })
  const write = useCycleWrite(api)
  const arrivedNotice = (location.state as { notice?: string } | null)?.notice ?? null

  if (profile.isPending || calendar.isPending) return <p role="status">Загрузка…</p>
  if (profile.isError) return <ErrorBlock error={profile.error} />
  if (calendar.isError) return <ErrorBlock error={calendar.error} />

  if (cycleVisibility(profile.data).kind !== 'calendar') {
    return (
      <main>
        <Link to="/profile" className="link-back">
          Профиль
        </Link>
        <h1>Календарь цикла</h1>
        <p className="card">Цикл выключен.</p>
        <Link to="/cycle/enable" className="button-primary">
          Включить отслеживание цикла
        </Link>
      </main>
    )
  }

  const grid = calendar.data
  const byDate = new Map(grid.days.map((d) => [d.date, d]))
  const notice = write.notice ?? arrivedNotice

  return (
    <main>
      <Link to="/profile" className="link-back">
        Профиль
      </Link>
      <header className="screen-header">
        <h1>Календарь цикла</h1>
      </header>

      {todayCalendar.data && (
        <>
          <OverdueQuestion api={api} calendar={todayCalendar.data} today={today} />
          <PhaseCard calendar={todayCalendar.data} today={today} />
        </>
      )}

      {notice && (
        <p className="notice" data-testid="cycle-notice">
          {notice}
        </p>
      )}

      {grid.next_period && (
        <p data-testid="next-period">
          Ожидаемое начало месячных: {formatShortDate(grid.next_period.expected)}
          <span className="caption">
            {' '}
            (от {formatShortDate(grid.next_period.range_start)} до {formatShortDate(grid.next_period.range_end)})
          </span>
        </p>
      )}

      <nav className="month-nav" aria-label="Месяц">
        <button type="button" className="round-button" aria-label="Предыдущий месяц" onClick={() => setMonth(shiftMonth(month, -1))}>
          ‹
        </button>
        <h2 data-testid="month-title">{monthTitle(month)}</h2>
        <button type="button" className="round-button" aria-label="Следующий месяц" onClick={() => setMonth(shiftMonth(month, 1))}>
          ›
        </button>
      </nav>

      <table className="month" data-testid="cycle-month">
        <thead>
          <tr>
            {WEEKDAYS.map((w) => (
              <th key={w} scope="col">
                {w}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {monthWeeks(month).map((week, i) => (
            <tr key={i}>
              {week.map((date, j) => (
                <td key={date ?? `blank-${j}`}>
                  {date && (
                    <DayCell
                      date={date}
                      day={byDate.get(date)}
                      today={date === today}
                      ranged={inRange(date, grid)}
                      selected={date === selected}
                      onSelect={() => setSelected(date)}
                    />
                  )}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>

      <ul className="legend caption" aria-label="Обозначения">
        <li data-legend="marked">Месячные</li>
        <li data-legend="estimated">Расчётные дни</li>
        <li data-legend="forecast">Ожидаемые</li>
        <li data-legend="ovulation">Примерная овуляция</li>
      </ul>

      {selected && (
        <DayPanel
          date={selected}
          day={byDate.get(selected)}
          today={today}
          latest={latest.data?.latest ?? null}
          previous={latest.data?.previous ?? null}
          busy={write.busy}
          onWrite={(action) => void write.run(action)}
        />
      )}
      {write.error !== null && <ErrorBlock error={write.error} />}
    </main>
  )
}

function DayCell({
  date,
  day,
  today,
  ranged,
  selected,
  onSelect,
}: {
  date: string
  day: CycleCalendarDay | undefined
  today: boolean
  ranged: boolean
  selected: boolean
  onSelect: () => void
}) {
  const label = [
    formatDayHeading(date),
    today ? 'сегодня' : '',
    day?.period ? PERIOD_TEXT[day.period] : '',
    ranged ? 'в диапазоне ожидаемого начала' : '',
    day?.ovulation_estimate ? 'примерная овуляция' : '',
  ]
    .filter(Boolean)
    .join(', ')
  return (
    <button
      type="button"
      className="month-day"
      data-date={date}
      data-today={today}
      data-period={day?.period ?? 'none'}
      data-phase={day?.phase ?? 'none'}
      data-range={ranged}
      data-ovulation={day?.ovulation_estimate ?? false}
      aria-pressed={selected}
      aria-label={label}
      onClick={onSelect}
    >
      <span className="month-number">{Number(date.slice(8))}</span>
      <span className="month-dot" aria-hidden="true" />
    </button>
  )
}

function DayPanel({
  date,
  day,
  today,
  latest,
  previous,
  busy,
  onWrite,
}: {
  date: string
  day: CycleCalendarDay | undefined
  today: string
  latest: CycleEventRef | null
  previous: CycleEventRef | null
  busy: boolean
  onWrite: (action: () => Promise<void>) => void
}) {
  const [moveTo, setMoveTo] = useState('')
  const marks = day?.marks ?? []
  const has = (kind: string) => marks.some((m) => m.kind === kind)
  const markable = canMark(date, today)

  return (
    <section aria-label={`День ${formatDayHeading(date)}`} className="card" data-testid="day-panel" data-date={date}>
      <h2>{formatDayHeading(date)}</h2>
      {marks.length > 0 && (
        <ul className="rows">
          {marks.map((mark) =>
            isEditable(mark.id, latest) ? (
              <li key={mark.id} data-testid="mark-editable" data-kind={mark.kind}>
                <span>{MARK_LABEL[mark.kind] ?? mark.kind}</span>
                <span className="row-value">
                  <label className="field">
                    Перенести на{' '}
                    <input type="date" max={today} value={moveTo} onChange={(e) => setMoveTo(e.target.value)} />
                  </label>
                  <button
                    type="button"
                    className="button-text"
                    disabled={busy || !canMoveTo(moveTo, today, previous)}
                    onClick={() => onWrite(() => moveCycleEvent(mark.id, moveTo))}
                  >
                    Перенести
                  </button>
                  <button
                    type="button"
                    className="button-text"
                    disabled={busy}
                    onClick={() => onWrite(() => deleteCycleEvent(mark.id))}
                  >
                    Удалить
                  </button>
                </span>
              </li>
            ) : (
              <li key={mark.id} data-testid="mark-readonly" data-kind={mark.kind}>
                <span>{MARK_LABEL[mark.kind] ?? mark.kind}</span>
                <span className="caption">Только просмотр: править можно последнюю отметку</span>
              </li>
            ),
          )}
        </ul>
      )}
      {markable ? (
        <div className="button-row">
          <button
            type="button"
            className="button-primary"
            disabled={busy || has('period_start')}
            onClick={() => onWrite(async () => insertCycleEvent(await currentUserId(), 'period_start', date))}
          >
            Начались месячные
          </button>
          <button
            type="button"
            className="button-text"
            disabled={busy || has('period_end')}
            onClick={() => onWrite(async () => insertCycleEvent(await currentUserId(), 'period_end', date))}
          >
            Закончились
          </button>
        </div>
      ) : (
        <p className="caption">Отметить можно только сегодняшний или прошедший день.</p>
      )}
    </section>
  )
}
