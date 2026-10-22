// Календарь недели на «Сегодня» (дизайн D): семь колонок, день недели и число.
// Сегодня залито акцентом, запланированные — с акцентной обводкой, выполненные
// приглушены и отмечены акцентной точкой, остальные приглушены. Что считать
// каким днём — `today/calendar.ts`; здесь только разметка.

import type { CalendarDay } from '../../today/calendar'
import { formatDayHeading, formatShortDate } from '../../ui/format'

const weekday = new Intl.DateTimeFormat('ru-RU', { weekday: 'short', timeZone: 'UTC' })

function shortWeekday(date: string): string {
  const [y, m, d] = date.split('-').map(Number) as [number, number, number]
  return weekday.format(new Date(Date.UTC(y, m - 1, d)))
}

const STATUS_TEXT: Record<CalendarDay['status'], string> = {
  planned: 'запланирована тренировка',
  missed: 'тренировка не сделана, можно сделать сегодня',
  done: 'тренировка выполнена',
  moved: 'тренировка выполнена в другой день',
  none: '',
}

/** Доступное имя дня: цвет и обводка состояние не передают. */
function label(day: CalendarDay): string {
  const status = day.status === 'moved' && day.performedOn
    ? `тренировка выполнена ${formatShortDate(day.performedOn)}`
    : STATUS_TEXT[day.status]
  return [formatDayHeading(day.date), day.today ? 'сегодня' : '', status]
    .filter(Boolean)
    .join(', ')
}

/**
 * Тап по дню показывает его состав (`/preview`, срез 6); сегодня — карточка
 * дня. `selected` — день, чей состав сейчас на экране.
 */
export function WeekCalendar({
  days,
  selected,
  onSelect,
}: {
  days: CalendarDay[]
  selected?: string
  onSelect?: (date: string) => void
}) {
  return (
    <ol className="week" aria-label="Неделя" data-testid="week-calendar">
      {days.map((day) => (
        <li key={day.date} data-date={day.date} data-today={day.today} data-status={day.status}>
          <button
            type="button"
            className="week-button"
            aria-label={label(day)}
            aria-current={selected === day.date ? 'date' : undefined}
            onClick={() => onSelect?.(day.date)}
          >
            <span className="week-weekday" aria-hidden="true">
              {shortWeekday(day.date)}
            </span>
            <span className="week-day" aria-hidden="true">
              {Number(day.date.slice(8))}
            </span>
            <span className="week-dot" aria-hidden="true" />
          </button>
        </li>
      ))}
    </ol>
  )
}
