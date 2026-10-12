import { describe, expect, it } from 'vitest'
import { cycleWrite } from './cycle'

describe('шаг 9: что пишет ответ', () => {
  it('«нет» — off, no_phases, user_choice; дата не пишется', () => {
    expect(cycleWrite({ tracking: 'no' })).toEqual({
      patch: { cycle_tracking: 'off', cycle: { phase_mode: 'no_phases', no_phase_reason: 'user_choice' } },
      periodStart: undefined,
    })
  })

  it('«не сейчас» — off, no_phases, declined (не user_choice)', () => {
    expect(cycleWrite({ tracking: 'not_now' }).patch).toEqual({
      cycle_tracking: 'off',
      cycle: { phase_mode: 'no_phases', no_phase_reason: 'declined' },
    })
  })

  it('«да» + контрацепция — manual, no_phases, contraception, без заявленных длин', () => {
    const w = cycleWrite({ tracking: 'yes', contraception: 'yes', cycleLength: 28, periodStart: '2026-10-01' })
    expect(w.patch).toEqual({
      cycle_tracking: 'manual',
      cycle: { phase_mode: 'no_phases', no_phase_reason: 'contraception' },
    })
    expect(w.periodStart).toBeUndefined()
  })

  it('«да» + «не хочу отвечать» про контрацепцию — declined', () => {
    expect(cycleWrite({ tracking: 'yes', contraception: 'declined' }).patch.cycle).toEqual({
      phase_mode: 'no_phases',
      no_phase_reason: 'declined',
    })
  })

  it('«да» + нет контрацепции — режим фаз, четыре ответа раскладываются по местам', () => {
    const w = cycleWrite({
      tracking: 'yes',
      contraception: 'no',
      periodStart: '2026-10-01',
      cycleLength: 28,
      periodLength: 5,
      regularity: 'variable',
    })
    expect(w.patch).toEqual({
      cycle_tracking: 'manual',
      cycle: {
        phase_mode: 'phases',
        typical_cycle_length_days: 28,
        typical_period_length_days: 5,
        declared_regularity: 'variable',
      },
    })
    expect(w.periodStart).toBe('2026-10-01')
  })

  it('все четыре ответа пропущены — режим фаз без опорной точки, без пустых полей', () => {
    const w = cycleWrite({ tracking: 'yes', contraception: 'no' })
    expect(w.patch.cycle).toEqual({ phase_mode: 'phases' })
    expect(w.periodStart).toBeUndefined()
  })
})
