// Что можно делать с днём сетки (SPEC §11.6): отмечать — только не позже
// сегодня; править и удалять — только последнее событие, остальные только
// для просмотра.

/** Строка `cycle_events`, как её читает клиент. */
export interface CycleEventRef {
  id: string
  kind: string
  occurred_on: string
}

/** Отметка в будущем ни во что не идёт (§20.6): ставить её не даём. */
export function canMark(date: string, today: string): boolean {
  return date <= today
}

/** Правится ровно последнее по `occurred_on` событие. */
export function isEditable(markId: string, latest: CycleEventRef | null): boolean {
  return latest !== null && latest.id === markId
}

/**
 * Новая дата последнего события: не позже сегодня и не раньше предыдущего
 * события — иначе оно перестало бы быть последним и стало бы нередактируемым
 * задним числом.
 */
export function canMoveTo(date: string, today: string, previous: CycleEventRef | null): boolean {
  if (date === '' || date > today) return false
  return previous === null || date > previous.occurred_on
}

export const MARK_LABEL: Record<string, string> = {
  period_start: 'Начало месячных',
  period_end: 'Конец месячных',
  spotting: 'Мажущие выделения',
}
