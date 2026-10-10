import { describe, expect, it } from 'vitest'
import { currentDay, isoWeekday, localDate, mondayOf } from './day'

describe('день клиента', () => {
  it('локальная дата берётся в зоне запроса, а не в UTC', () => {
    const moment = new Date('2026-10-12T21:30:00Z')
    expect(localDate(moment, 'Europe/Moscow')).toBe('2026-10-13') // 00:30 по Москве
    expect(localDate(moment, 'America/New_York')).toBe('2026-10-12')
    expect(localDate(moment, 'UTC')).toBe('2026-10-12')
  })

  it('currentDay несёт пару date и tz', () => {
    expect(currentDay(new Date('2026-10-12T21:30:00Z'), 'Europe/Moscow')).toEqual({
      date: '2026-10-13',
      tz: 'Europe/Moscow',
    })
  })

  it('понедельник недели и ISO-номер дня', () => {
    expect(mondayOf('2026-10-12')).toBe('2026-10-12') // понедельник
    expect(mondayOf('2026-10-18')).toBe('2026-10-12') // воскресенье
    expect(mondayOf('2026-10-19')).toBe('2026-10-19')
    expect(isoWeekday('2026-10-12')).toBe(1)
    expect(isoWeekday('2026-10-18')).toBe(7)
  })
})
