import { describe, expect, it } from 'vitest'
import { formatDayHeading, formatMinutes } from './format'

describe('formatDayHeading', () => {
  it('день недели, число и месяц в родительном падеже', () => {
    expect(formatDayHeading('2026-10-12')).toBe('понедельник, 12 октября')
  })

  it('не сдвигает дату зоной браузера', () => {
    expect(formatDayHeading('2026-01-01')).toBe('четверг, 1 января')
    expect(formatDayHeading('2026-12-31')).toBe('четверг, 31 декабря')
  })
})

describe('formatMinutes', () => {
  it('округляет до минут', () => {
    expect(formatMinutes(2400)).toBe('40 мин')
    expect(formatMinutes(2430)).toBe('41 мин')
    expect(formatMinutes(2429)).toBe('40 мин')
  })

  it('меньше минуты — одна минута, а не ноль', () => {
    expect(formatMinutes(20)).toBe('1 мин')
  })
})
