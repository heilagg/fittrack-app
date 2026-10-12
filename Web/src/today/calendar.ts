// Календарь недели на «Сегодня» (дизайн D, web-domain §8): что рисовать в
// каждой из семи колонок. Ничего не считает по домену — читает итог дня,
// который отдал сервер (`WeekDay`, §20.3), и сравнивает даты.

import { weekDates } from '../api/day'
import type { WeekDay } from '../api/schemas'

/**
 * Состояние дня в календаре:
 *   planned — в неделе есть тренировка, которую ещё предстоит сделать;
 *   done    — день выполнен;
 *   none    — тренировки нет, она в прошлом без отметки, пропущена или заменена.
 * «Сегодня» — отдельный признак поверх: сегодняшний день залит всегда.
 */
export type CalendarStatus = 'planned' | 'done' | 'none'

export interface CalendarDay {
  date: string
  today: boolean
  status: CalendarStatus
}

/** Итоги, после которых тренировки в этот день больше нет (§7.1, словарь §20.3). */
const CLOSED_CAUSES = new Set(['skipped', 'replaced', 'past'])

function statusOf(day: WeekDay | undefined): CalendarStatus {
  if (!day) return 'none'
  if (day.cause?.code === 'done') return 'done'
  if (day.cause && CLOSED_CAUSES.has(day.cause.code)) return 'none'
  return 'planned'
}

/** Семь дней недели `weekStart`; `days` — дни из ответа недели (или пусто). */
export function calendarDays(weekStart: string, today: string, days: WeekDay[]): CalendarDay[] {
  const byDate = new Map(days.map((d) => [d.date, d]))
  return weekDates(weekStart).map((date) => ({ date, today: date === today, status: statusOf(byDate.get(date)) }))
}
