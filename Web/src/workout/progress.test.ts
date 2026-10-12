import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { workoutSchema, type WorkoutExercise } from '../api/schemas'
import { isExerciseOpen, progressSegments } from './progress'

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
