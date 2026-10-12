import { describe, expect, it } from 'vitest'
import type { Profile } from '../api/schemas'
import { cycleAnswersOf, cycleWrite } from '../onboarding/cycle'
import { personalPatch } from './personal'
import { levelsOf, restrictionChanges, type ActiveRestriction } from './restrictions'

describe('ограничения: снять и добавить (§14.4, resolved_at)', () => {
  const active: ActiveRestriction[] = [
    { id: 'r-knee', joint: 'knee', severity: 'avoid' },
    { id: 'r-back', joint: 'lower_back', severity: 'careful' },
  ]

  it('без изменений — ничего', () => {
    expect(restrictionChanges(active, levelsOf(active))).toEqual({ resolve: [], add: [] })
  })

  it('снятое ограничение — resolve, новых строк нет', () => {
    expect(restrictionChanges(active, { knee: 'avoid' })).toEqual({ resolve: ['r-back'], add: [] })
  })

  it('смена степени — снятие прежней строки и новая строка', () => {
    expect(restrictionChanges(active, { knee: 'careful', lower_back: 'careful' })).toEqual({
      resolve: ['r-knee'],
      add: [{ joint: 'knee', severity: 'careful' }],
    })
  })

  it('новое ограничение — только add', () => {
    expect(restrictionChanges(active, { ...levelsOf(active), wrist: 'avoid' })).toEqual({
      resolve: [],
      add: [{ joint: 'wrist', severity: 'avoid' }],
    })
  })
})

describe('личные данные: только изменённые поля', () => {
  const profile: Profile = {
    sex_at_birth: 'female', birth_year: 1994, height_cm: 168, experience_level: 'intermediate',
    goal: 'hypertrophy', days_per_week: 3, training_weekdays: [1, 3, 5], session_minutes: 60,
    cycle_tracking: 'off', is_complete: true,
  }
  const same = {
    birth_year: 1994, height_cm: 168, experience_level: 'intermediate' as const, goal: 'hypertrophy' as const,
    training_weekdays: [5, 3, 1], session_minutes: 60,
  }

  it('ничего не менялось — пустое тело, порядок дней не считается сменой', () => {
    expect(personalPatch(profile, same)).toEqual({})
  })

  it('смена цели и дней — только они, дни по порядку', () => {
    expect(personalPatch(profile, { ...same, goal: 'strength', training_weekdays: [6, 2] })).toEqual({
      goal: 'strength',
      training_weekdays: [2, 6],
    })
  })

  it('каждое поле по отдельности', () => {
    expect(personalPatch(profile, { ...same, birth_year: 1990 })).toEqual({ birth_year: 1990 })
    expect(personalPatch(profile, { ...same, height_cm: 170 })).toEqual({ height_cm: 170 })
    expect(personalPatch(profile, { ...same, experience_level: 'advanced' })).toEqual({ experience_level: 'advanced' })
    expect(personalPatch(profile, { ...same, session_minutes: 45 })).toEqual({ session_minutes: 45 })
  })
})

describe('ответы шага 9 из профиля (правка цикла)', () => {
  it('ответы → профиль → те же ответы, без даты', () => {
    for (const answers of [
      { tracking: 'no' as const },
      { tracking: 'not_now' as const },
      { tracking: 'yes' as const, contraception: 'yes' as const },
      { tracking: 'yes' as const, contraception: 'declined' as const },
      { tracking: 'yes' as const, contraception: 'no' as const, cycleLength: 30, periodLength: 4, regularity: 'variable' as const },
    ]) {
      const { patch } = cycleWrite(answers)
      const profile = { cycle_tracking: patch.cycle_tracking!, cycle: patch.cycle as { phase_mode: string } }
      expect(cycleAnswersOf(profile)).toEqual(answers)
    }
  })

  it('low_confidence — это «да, без контрацепции»', () => {
    expect(
      cycleAnswersOf({ cycle_tracking: 'manual', cycle: { phase_mode: 'no_phases', no_phase_reason: 'low_confidence' } }),
    ).toEqual({ tracking: 'yes', contraception: 'no' })
  })

  it('нет строки цикла — пустые ответы', () => {
    expect(cycleAnswersOf({ cycle_tracking: 'off' })).toEqual({})
  })
})
