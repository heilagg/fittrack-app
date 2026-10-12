import { describe, expect, it } from 'vitest'
import type { Profile } from '../api/schemas'
import { resumeStep } from './resume'

const full: Profile = {
  sex_at_birth: 'female',
  birth_year: 1994,
  height_cm: 168,
  experience_level: 'intermediate',
  goal: 'hypertrophy',
  days_per_week: 3,
  training_weekdays: [1, 3, 5],
  session_minutes: 45,
  cycle_tracking: 'off',
  is_complete: true,
}
const without = (...keys: (keyof Profile)[]): Profile => {
  const copy: Record<string, unknown> = { ...full }
  for (const k of keys) delete copy[k]
  return copy as unknown as Profile
}

describe('с какого экрана продолжать', () => {
  it('профиля нет (not_found) — с экрана 1', () => {
    expect(resumeStep(null, false)).toBe(1)
    expect(resumeStep(null, true)).toBe(1)
  })

  it('строка профиля есть, а PAR-Q нет — снова с экрана 1', () => {
    expect(resumeStep(full, false)).toBe(1)
  })

  it('пусто любое из sex_at_birth, birth_year, height_cm — экран 3', () => {
    for (const key of ['sex_at_birth', 'birth_year', 'height_cm'] as const) {
      expect(resumeStep(without(key, 'experience_level', 'is_complete'), true)).toBe(3)
    }
  })

  it('первый незаполненный в порядке 4, 5, 6', () => {
    const open = (...keys: (keyof Profile)[]) => ({ ...without(...keys), is_complete: false })
    expect(resumeStep(open('experience_level', 'goal', 'training_weekdays', 'days_per_week'), true)).toBe(4)
    expect(resumeStep(open('goal', 'training_weekdays', 'days_per_week'), true)).toBe(5)
    expect(resumeStep(open('training_weekdays', 'days_per_week'), true)).toBe(6)
  })

  it('четыре поля заполнены, профиль неполон — экран 7 (нет инвентаря по умолчанию)', () => {
    expect(resumeStep({ ...full, is_complete: false }, true)).toBe(7)
  })

  it('полный профиль — онбординг пройден', () => {
    expect(resumeStep(full, true)).toBe('done')
  })

  it('is_complete берётся у сервера: четыре поля без флага не считаются полнотой', () => {
    expect(resumeStep({ ...full, is_complete: false }, true)).not.toBe('done')
  })
})
