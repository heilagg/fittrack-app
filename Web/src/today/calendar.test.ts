import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { weekDates } from '../api/day'
import { weekPlanResponseSchema, type WeekDay } from '../api/schemas'
import { calendarDays } from './calendar'

const fixture = weekPlanResponseSchema.parse(
  JSON.parse(readFileSync(join(__dirname, '../../../Contract/fixtures/week_plan_response.json'), 'utf-8')),
)
const base = fixture.plan.days[0]!

function day(date: string, cause?: string): WeekDay {
  const { cause: _drop, ...rest } = base
  void _drop
  return {
    ...rest,
    date,
    day_id: `d-${date}`,
    ...(cause ? { kind: 'not_built' as const, cause: { code: cause, params: {}, message: '' } as WeekDay['cause'] } : {}),
  }
}

describe('weekDates', () => {
  it('семь дат с понедельника, через границу месяца и года', () => {
    expect(weekDates('2026-12-28')).toEqual([
      '2026-12-28', '2026-12-29', '2026-12-30', '2026-12-31', '2027-01-01', '2027-01-02', '2027-01-03',
    ])
  })
})

describe('calendarDays', () => {
  const week = '2026-10-12'

  it('без недели: семь дат, сегодня отмечено, тренировок нет', () => {
    const days = calendarDays(week, '2026-10-14', [])
    expect(days.map((d) => d.date)).toEqual(weekDates(week))
    expect(days.map((d) => d.today)).toEqual([false, false, true, false, false, false, false])
    expect(days.every((d) => d.status === 'none')).toBe(true)
  })

  it('день из ответа недели — по своей дате, а не по позиции в массиве', () => {
    const days = calendarDays(week, '2026-10-12', [day('2026-10-16'), day('2026-10-13')])
    expect(days.map((d) => d.status)).toEqual(['none', 'planned', 'none', 'none', 'planned', 'none', 'none'])
  })

  it('выполненный — done; пропущенный и заменённый — none; прошедший — missed; начатый — planned', () => {
    const days = calendarDays(week, '2026-10-18', [
      day('2026-10-12', 'done'),
      day('2026-10-13', 'skipped'),
      day('2026-10-14', 'replaced'),
      day('2026-10-15', 'past'),
      day('2026-10-16', 'started'),
      day('2026-10-17', 'rest_override'),
    ])
    expect(days.map((d) => d.status)).toEqual(['done', 'none', 'none', 'missed', 'planned', 'planned', 'none'])
  })

  it('сегодня — признак поверх статуса: выполненный сегодня остаётся сегодняшним', () => {
    const [monday] = calendarDays(week, '2026-10-12', [day('2026-10-12', 'done')])
    expect(monday).toEqual({ date: '2026-10-12', today: true, status: 'done' })
  })

  it('тренировка, сделанная в другой день, — done на фактической дате, moved на своей (§7.1)', () => {
    const friday = { ...day('2026-10-16', 'done'), performed_on: '2026-10-14' }
    const days = calendarDays(week, '2026-10-14', [day('2026-10-14'), friday])
    expect(days[2]).toEqual({ date: '2026-10-14', today: true, status: 'done' })
    expect(days[4]).toEqual({ date: '2026-10-16', today: false, status: 'moved', performedOn: '2026-10-14' })
  })

  it('выполненный в свою дату — done без performedOn', () => {
    const own = { ...day('2026-10-13', 'done'), performed_on: '2026-10-13' }
    expect(calendarDays(week, '2026-10-14', [own])[1]).toEqual({ date: '2026-10-13', today: false, status: 'done' })
  })
})
