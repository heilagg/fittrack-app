// Положение в тренировке для показа: какое упражнение текущее и полоса
// сегментов. Ни веса, ни подходов не считает — только читает, что уже записано.

import type { WorkoutExercise } from '../api/schemas'

/** Упражнение ещё идёт: подходы остались и дерево не оборвано досрочно. */
export function isExerciseOpen(e: WorkoutExercise): boolean {
  const start = e.decision_tree?.nodes[e.decision_tree.start]
  return e.sets.length < e.target_sets && !start?.terminates
}

export type SegmentState = 'done' | 'current' | 'upcoming'

/**
 * Сегмент на каждое упражнение в порядке `ordered`: текущее — первое открытое,
 * до него и закрытые после него — выполнены.
 */
export function progressSegments(ordered: WorkoutExercise[]): SegmentState[] {
  const current = ordered.findIndex(isExerciseOpen)
  return ordered.map((e, i) => (i === current ? 'current' : isExerciseOpen(e) ? 'upcoming' : 'done'))
}
