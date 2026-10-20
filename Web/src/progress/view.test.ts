import { describe, expect, it } from 'vitest'
import { lastWeeks, monthGrid, progressWindow, scaleTop } from './view'

describe('окно и раскладка прогресса (§13.7)', () => {
  it('from — наименьшее из начала окна недель и первого дня месяца', () => {
    // 2026-10-19 — понедельник: 8 недель назад — 2026-08-31, раньше 1 октября.
    expect(progressWindow('2026-10-19', 8)).toEqual({ from: '2026-08-31', to: '2026-10-19' })
    // 4 недели — 2026-09-28, всё равно раньше 1 октября.
    expect(progressWindow('2026-10-19', 4)).toEqual({ from: '2026-09-28', to: '2026-10-19' })
    // Конец месяца: окно из одной недели не дотянулось бы до 1-го.
    expect(progressWindow('2026-10-30', 4).from).toBe('2026-10-01')
  })

  it('последние N недель по дате', () => {
    const weeks = ['2026-10-12', '2026-09-28', '2026-10-05', '2026-10-19'].map((w) => ({ week_start: w }))
    expect(lastWeeks(weeks, 4).map((w) => w.week_start)).toEqual(['2026-09-28', '2026-10-05', '2026-10-12', '2026-10-19'])
  })

  it('сетка месяца с понедельника, пустые клетки — null', () => {
    const grid = monthGrid('2026-10-19')
    expect(grid[0]).toEqual([null, null, null, '2026-10-01', '2026-10-02', '2026-10-03', '2026-10-04'])
    expect(grid.flat().filter(Boolean)).toHaveLength(31)
    expect(grid.every((row) => row.length === 7)).toBe(true)
  })

  it('шкала — по наибольшему из объёма и потолка', () => {
    expect(scaleTop([3, 9], [16])).toBe(16)
    expect(scaleTop([20], [16])).toBe(20)
    expect(scaleTop([], [])).toBe(1)
  })
})
