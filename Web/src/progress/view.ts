// Экран «Прогресс» (SPEC §13.7): окно запроса и раскладка календаря. Числа —
// с сервера; здесь только какие даты спросить и где их нарисовать.

import { addDays, mondayOf } from '../api/day'

export const WEEK_WINDOWS = [4, 8, 12] as const
export type WeekWindow = (typeof WEEK_WINDOWS)[number]
export const DEFAULT_WEEKS: WeekWindow = 8

/**
 * Окно `/v1/progress` (§20.3): `from` — наименьшее из начала окна недель и
 * первого дня месяца календаря, `to` — сегодня.
 */
export function progressWindow(today: string, weeks: WeekWindow): { from: string; to: string } {
  const weeksStart = addDays(mondayOf(today), -7 * (weeks - 1))
  const monthStart = `${today.slice(0, 8)}01`
  return { from: weeksStart < monthStart ? weeksStart : monthStart, to: today }
}

/** Недели окна — последние `weeks`, по дате начала. */
export function lastWeeks<T extends { week_start: string }>(weeks: readonly T[], count: WeekWindow): T[] {
  return [...weeks].sort((a, b) => a.week_start.localeCompare(b.week_start)).slice(-count)
}

/**
 * Сетка месяца `today`: недели с понедельника, пустые клетки — `null`.
 */
export function monthGrid(today: string): (string | null)[][] {
  const first = `${today.slice(0, 8)}01`
  const [y, m] = [Number(today.slice(0, 4)), Number(today.slice(5, 7))]
  const days = new Date(Date.UTC(y, m, 0)).getUTCDate()
  const lead = (new Date(`${first}T00:00:00Z`).getUTCDay() + 6) % 7
  const cells: (string | null)[] = [...Array(lead).fill(null)]
  for (let d = 0; d < days; d++) cells.push(addDays(first, d))
  while (cells.length % 7 !== 0) cells.push(null)
  const rows: (string | null)[][] = []
  for (let i = 0; i < cells.length; i += 7) rows.push(cells.slice(i, i + 7))
  return rows
}

/** Верх шкалы столбцов: наибольшее из объёмов и потолков групп. */
export function scaleTop(values: readonly number[], ceilings: readonly number[]): number {
  return Math.max(1, ...values, ...ceilings)
}
