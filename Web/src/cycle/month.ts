// Раскладка месячной сетки — только календарная арифметика, без цикла: какие
// даты у месяца и где у них пустые клетки до понедельника. Что за день — фаза,
// месячные, прогноз — приходит с сервера (§11.6).

/** `YYYY-MM` месяца, в который входит `date`. */
export function monthOf(date: string): string {
  return date.slice(0, 7)
}

function utc(month: string, day: number): Date {
  const [y, m] = month.split('-').map(Number) as [number, number]
  return new Date(Date.UTC(y, m - 1, day))
}

const iso = (d: Date) => d.toISOString().slice(0, 10)

/** Первый и последний день месяца, включительно: окно запроса календаря. */
export function monthRange(month: string): { from: string; to: string } {
  // День 0 следующего месяца — последний день этого.
  const next = utc(shiftMonth(month, 1), 0)
  return { from: iso(utc(month, 1)), to: iso(next) }
}

/** Соседний месяц: `delta` −1 — предыдущий, +1 — следующий. */
export function shiftMonth(month: string, delta: number): string {
  const d = utc(month, 1)
  d.setUTCMonth(d.getUTCMonth() + delta)
  return iso(d).slice(0, 7)
}

/**
 * Недели месяца по семь клеток с понедельника; `null` — клетка вне месяца.
 * Последняя неделя дополняется пустыми клетками до семи.
 */
export function monthWeeks(month: string): (string | null)[][] {
  const first = utc(month, 1)
  const lead = (first.getUTCDay() + 6) % 7
  const cells: (string | null)[] = Array.from({ length: lead }, () => null)
  for (let d = new Date(first); d.getUTCMonth() === first.getUTCMonth(); d.setUTCDate(d.getUTCDate() + 1)) {
    cells.push(iso(d))
  }
  while (cells.length % 7 !== 0) cells.push(null)
  return Array.from({ length: cells.length / 7 }, (_, i) => cells.slice(i * 7, i * 7 + 7))
}
