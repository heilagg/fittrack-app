import { describe, expect, it } from 'vitest'
import { birthYearProblem, bodyWeightProblem, heightProblem, sessionMinutesProblem } from './ranges'

const now = new Date('2026-10-20T12:00:00Z')

describe('диапазоны профиля (§20.3)', () => {
  it('год рождения — от 1936 до текущего минус 14, границы включены', () => {
    expect(birthYearProblem(1936, now)).toBeNull()
    expect(birthYearProblem(2012, now)).toBeNull()
    expect(birthYearProblem(1935, now)).toBe('Год рождения — от 1936 до 2012')
    expect(birthYearProblem(2013, now)).not.toBeNull()
    expect(birthYearProblem(1990.5, now)).not.toBeNull()
  })

  it('рост 100–250, вес тела 20–300, минуты 10–180', () => {
    expect(heightProblem(100)).toBeNull()
    expect(heightProblem(250)).toBeNull()
    expect(heightProblem(99.9)).not.toBeNull()
    expect(heightProblem(250.1)).not.toBeNull()
    expect(bodyWeightProblem(20)).toBeNull()
    expect(bodyWeightProblem(300)).toBeNull()
    expect(bodyWeightProblem(19.9)).toBe('Вес — от 20 до 300 кг')
    expect(bodyWeightProblem(300.1)).not.toBeNull()
    expect(sessionMinutesProblem(10)).toBeNull()
    expect(sessionMinutesProblem(180)).toBeNull()
    expect(sessionMinutesProblem(9)).toBe('Длительность — от 10 до 180 минут')
    expect(sessionMinutesProblem(181)).not.toBeNull()
    expect(sessionMinutesProblem(45.5)).not.toBeNull()
  })

  it('не число — ошибка, а не молчаливое значение', () => {
    expect(heightProblem(Number.NaN)).not.toBeNull()
    expect(bodyWeightProblem(Number.NaN)).not.toBeNull()
    expect(sessionMinutesProblem(Number.NaN)).not.toBeNull()
    expect(birthYearProblem(Number.NaN, now)).not.toBeNull()
  })
})
