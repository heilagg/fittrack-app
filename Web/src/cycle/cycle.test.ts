import { describe, expect, it } from 'vitest'
import type { Profile } from '../api/schemas'
import { canMark, canMoveTo, isEditable } from './events'
import { monthOf, monthRange, monthWeeks, shiftMonth } from './month'
import { markEnableOfferAnswered, markOverdueAnswered, shouldAskOverdue, shouldOfferEnable, type FlagStore } from './once'
import { cycleVisibility } from './visibility'

const base: Profile = { sex_at_birth: 'female', session_minutes: 60, training_split: 'auto', cycle_tracking: 'manual', is_complete: true }
const profile = (cycle: Profile['cycle'], tracking: Profile['cycle_tracking'] = 'manual'): Profile => ({
  ...base,
  cycle_tracking: tracking,
  ...(cycle ? { cycle } : {}),
})

function memoryStore(): FlagStore & { data: Map<string, string> } {
  const data = new Map<string, string>()
  return { data, get: (k) => data.get(k) ?? null, set: (k, v) => void data.set(k, v) }
}

describe('кто видит календарь (§11.6, §19.2 п.27)', () => {
  it('режим фаз с ручным отслеживанием — календарь', () => {
    expect(cycleVisibility(profile({ phase_mode: 'phases' }))).toEqual({ kind: 'calendar' })
  })

  it('low_confidence — тоже календарь: отметка в нём и есть выход', () => {
    expect(cycleVisibility(profile({ phase_mode: 'no_phases', no_phase_reason: 'low_confidence' }))).toEqual({
      kind: 'calendar',
    })
  })

  it('контрацепция, user_choice, менопауза — выключено, без предложения', () => {
    for (const reason of ['contraception', 'user_choice', 'menopause']) {
      expect(cycleVisibility(profile({ phase_mode: 'no_phases', no_phase_reason: reason }))).toEqual({
        kind: 'off',
        declined: false,
      })
    }
  })

  it('declined — выключено с предложением включить', () => {
    expect(cycleVisibility(profile({ phase_mode: 'no_phases', no_phase_reason: 'declined' }, 'off'))).toEqual({
      kind: 'off',
      declined: true,
    })
  })

  it('cycle_tracking off — выключено даже при сохранённом режиме фаз', () => {
    expect(cycleVisibility(profile({ phase_mode: 'phases' }, 'off')).kind).toBe('off')
  })

  it('без строки cycle_profiles — выключено', () => {
    expect(cycleVisibility(profile(undefined)).kind).toBe('off')
  })

  it('мужской профиль и отсутствие профиля — ничего', () => {
    expect(cycleVisibility({ ...profile({ phase_mode: 'phases' }), sex_at_birth: 'male' })).toEqual({ kind: 'none' })
    expect(cycleVisibility(null)).toEqual({ kind: 'none' })
  })
})

describe('сетка месяца', () => {
  it('окно месяца — с первого по последний день', () => {
    expect(monthRange('2026-10')).toEqual({ from: '2026-10-01', to: '2026-10-31' })
    expect(monthRange('2026-02')).toEqual({ from: '2026-02-01', to: '2026-02-28' })
    expect(monthRange('2028-02')).toEqual({ from: '2028-02-01', to: '2028-02-29' })
  })

  it('соседние месяцы через границу года', () => {
    expect(shiftMonth('2026-12', 1)).toBe('2027-01')
    expect(shiftMonth('2026-01', -1)).toBe('2025-12')
    expect(monthOf('2026-10-12')).toBe('2026-10')
  })

  it('недели с понедельника, пустые клетки до первого числа и после последнего', () => {
    // 1 октября 2026 — четверг.
    const weeks = monthWeeks('2026-10')
    expect(weeks[0]).toEqual([null, null, null, '2026-10-01', '2026-10-02', '2026-10-03', '2026-10-04'])
    expect(weeks.every((w) => w.length === 7)).toBe(true)
    expect(weeks.flat().filter(Boolean)).toHaveLength(31)
    expect(weeks.at(-1)).toEqual(['2026-10-26', '2026-10-27', '2026-10-28', '2026-10-29', '2026-10-30', '2026-10-31', null])
  })

  it('месяц с понедельника не получает пустой первой недели', () => {
    // 1 июня 2026 — понедельник.
    expect(monthWeeks('2026-06')[0]![0]).toBe('2026-06-01')
  })
})

describe('«один раз»', () => {
  const overdue = { overdue: true, next_period: { expected: '2026-10-20' } }

  it('спрашивает при overdue, пока на эту дату не ответили', () => {
    const store = memoryStore()
    expect(shouldAskOverdue(overdue, store)).toBe(true)
    markOverdueAnswered('2026-10-20', store)
    expect(shouldAskOverdue(overdue, store)).toBe(false)
  })

  it('новая ожидаемая дата — новый вопрос', () => {
    const store = memoryStore()
    markOverdueAnswered('2026-10-20', store)
    expect(shouldAskOverdue({ overdue: true, next_period: { expected: '2026-11-17' } }, store)).toBe(true)
  })

  it('без overdue или без прогноза — не спрашивает', () => {
    const store = memoryStore()
    expect(shouldAskOverdue({ overdue: false, next_period: { expected: '2026-10-20' } }, store)).toBe(false)
    expect(shouldAskOverdue({ overdue: true, next_period: undefined }, store)).toBe(false)
  })

  it('предложение включить цикл — один раз', () => {
    const store = memoryStore()
    expect(shouldOfferEnable(store)).toBe(true)
    markEnableOfferAnswered(store)
    expect(shouldOfferEnable(store)).toBe(false)
  })

  it('недоступное хранилище не роняет экран: вопрос просто задаётся снова', () => {
    const broken: FlagStore = { get: () => null, set: () => undefined }
    markOverdueAnswered('2026-10-20', broken)
    expect(shouldAskOverdue(overdue, broken)).toBe(true)
  })
})

describe('что можно с днём', () => {
  const latest = { id: 'b', kind: 'period_start', occurred_on: '2026-10-10' }
  const previous = { id: 'a', kind: 'period_end', occurred_on: '2026-09-17' }

  it('отмечать — не позже сегодня', () => {
    expect(canMark('2026-10-12', '2026-10-12')).toBe(true)
    expect(canMark('2026-10-13', '2026-10-12')).toBe(false)
  })

  it('править — только последнее событие', () => {
    expect(isEditable('b', latest)).toBe(true)
    expect(isEditable('a', latest)).toBe(false)
    expect(isEditable('b', null)).toBe(false)
  })

  it('переносить — не в будущее и не раньше предыдущего события', () => {
    expect(canMoveTo('2026-10-11', '2026-10-12', previous)).toBe(true)
    expect(canMoveTo('2026-10-13', '2026-10-12', previous)).toBe(false)
    expect(canMoveTo('2026-09-17', '2026-10-12', previous)).toBe(false)
    expect(canMoveTo('2026-09-18', '2026-10-12', previous)).toBe(true)
    expect(canMoveTo('', '2026-10-12', previous)).toBe(false)
    expect(canMoveTo('2026-01-01', '2026-10-12', null)).toBe(true)
  })
})
