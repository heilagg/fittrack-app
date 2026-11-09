// Календарь недели на «Сегодня» (дизайн D, web-domain §8): что рисовать в
// каждой из семи колонок. Ничего не считает по домену — читает итог дня,
// который отдал сервер (`WeekDay`, §20.3), и сравнивает даты.

import { weekDates } from '../api/day'
import type { WeekDay } from '../api/schemas'

/**
 * Состояние дня в календаре:
 *   planned — в неделе есть тренировка, которую ещё предстоит сделать;
 *   missed  — день прошёл, тренировка не сделана и не отмечена: её можно
 *             сделать сегодня (§7.1);
 *   done    — в эту дату выполнена тренировка — своя или другого дня недели
 *             (§7.1: выполнение отмечается на фактической дате);
 *   moved   — тренировка этого дня выполнена в другую дату (`performedOn`);
 *   none    — тренировки нет, она пропущена или заменена.
 * «Сегодня» — отдельный признак поверх: сегодняшний день залит всегда.
 */
export type CalendarStatus = 'planned' | 'missed' | 'done' | 'moved' | 'none'

export interface CalendarDay {
  date: string
  today: boolean
  status: CalendarStatus
  /** У `moved` — когда выполнена. */
  performedOn?: string
}

/** Итоги, после которых тренировки в этот день больше нет (§7.1, словарь §20.3). */
const CLOSED_CAUSES = new Set(['skipped', 'replaced'])

function statusOf(day: WeekDay | undefined): Pick<CalendarDay, 'status' | 'performedOn'> {
  if (!day) return { status: 'none' }
  if (day.cause?.code === 'done') {
    return day.performed_on !== undefined && day.performed_on !== day.date
      ? { status: 'moved', performedOn: day.performed_on }
      : { status: 'done' }
  }
  if (day.cause?.code === 'past') return { status: 'missed' }
  if (day.cause && CLOSED_CAUSES.has(day.cause.code)) return { status: 'none' }
  return { status: 'planned' }
}

/** Семь дней недели `weekStart`; `days` — дни из ответа недели (или пусто). */
export function calendarDays(weekStart: string, today: string, days: WeekDay[]): CalendarDay[] {
  const byDate = new Map(days.map((d) => [d.date, d]))
  // Даты фактического выполнения: галочка ставится там, где тренировка была.
  const performed = new Set(
    days.filter((d) => d.cause?.code === 'done').map((d) => d.performed_on ?? d.date),
  )
  return weekDates(weekStart).map((date) => {
    const own = statusOf(byDate.get(date))
    const status = performed.has(date) ? { status: 'done' as const } : own
    return { date, today: date === today, ...status }
  })
}
