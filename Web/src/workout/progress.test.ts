import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { workoutSchema, type WorkoutExercise } from '../api/schemas'
import { currentSets, isExerciseOpen, progressSegments, stoppedByPain } from './progress'

const fixture = workoutSchema.parse(
  JSON.parse(readFileSync(join(__dirname, '../../../Contract/fixtures/workout_in_progress.json'), 'utf-8')),
)
const base = fixture.exercises[0]!
const set = base.sets[0]!

/** Упражнение с `done` подходами из `target`. */
function exercise(done: number, target = 3, terminates = false): WorkoutExercise {
  return {
    ...base,
    target_sets: target,
    sets: Array.from({ length: done }, (_, i) => ({ ...set, id: `s${i}`, set_index: i + 1 })),
    decision_tree: { start: 'n0', nodes: { n0: { truncated: false, terminates, transitions: {} } } },
  } as WorkoutExercise
}

describe('isExerciseOpen', () => {
  it('открыто, пока подходы остались', () => {
    expect(isExerciseOpen(exercise(0))).toBe(true)
    expect(isExerciseOpen(exercise(2))).toBe(true)
    expect(isExerciseOpen(exercise(3))).toBe(false)
  })

  it('досрочное завершение закрывает упражнение', () => {
    expect(isExerciseOpen(exercise(1, 3, true))).toBe(false)
  })

  it('без дерева решает только число подходов', () => {
    expect(isExerciseOpen({ ...exercise(1), decision_tree: undefined } as WorkoutExercise)).toBe(true)
  })
})

describe('текущий слаг и флаг боли (§8.4, «На вебе»)', () => {
  it('подход с флагом боли закрывает упражнение, даже если подходы остались', () => {
    const e = exercise(1)
    e.sets[0] = { ...e.sets[0]!, pain_flag: true }
    expect(stoppedByPain(e)).toBe(true)
    expect(isExerciseOpen(e)).toBe(false)
  })

  it('после замены подходы прежнего слага не считаются и не закрывают новое упражнение', () => {
    const e = exercise(3)
    e.sets = e.sets.map((s) => ({ ...s, exercise_slug: 'squat_barbell', pain_flag: true }))
    expect(currentSets(e)).toHaveLength(0)
    expect(stoppedByPain(e)).toBe(false)
    expect(isExerciseOpen(e)).toBe(true)
  })

  it('подходы нового слага считаются как обычно', () => {
    const e = exercise(2)
    e.sets.push({ ...set, id: 'old', exercise_slug: 'squat_barbell' })
    expect(currentSets(e)).toHaveLength(2)
    expect(isExerciseOpen(e)).toBe(true)
  })
})

describe('progressSegments', () => {
  it('выполненные, текущее и оставшиеся', () => {
    expect(progressSegments([exercise(3), exercise(1), exercise(0)])).toEqual(['done', 'current', 'upcoming'])
  })

  it('текущее — первое открытое, а не первое после выполненных', () => {
    expect(progressSegments([exercise(0), exercise(3), exercise(0)])).toEqual(['current', 'done', 'upcoming'])
  })

  it('всё выполнено — текущего нет', () => {
    expect(progressSegments([exercise(3), exercise(2, 3, true)])).toEqual(['done', 'done'])
  })
})
