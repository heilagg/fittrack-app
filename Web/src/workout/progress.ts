// Положение в тренировке для показа: какое упражнение текущее и полоса
// сегментов. Ни веса, ни подходов не считает — только читает, что уже записано.
//
// Подходы считаются по ТЕКУЩЕМУ слагу строки (SPEC §8.4, «На вебе»): после
// замены (§13.4) подходы прежнего упражнения остаются в той же строке, и к
// новому упражнению они не относятся — ни числом, ни флагом боли.

import type { SetRow, WorkoutExercise } from '../api/schemas'

/** Подходы текущего упражнения строки, без подходов заменённого. */
export function currentSets(e: WorkoutExercise): SetRow[] {
  return e.sets.filter((s) => s.exercise_slug === e.slug)
}

/** Упражнение прекращено флагом боли (§8.4 п.1): сервер дерево не обрывает. */
export function stoppedByPain(e: WorkoutExercise): boolean {
  return currentSets(e).some((s) => s.pain_flag)
}

/** Упражнение ещё идёт: подходы остались, дерево не оборвано и боли не было. */
export function isExerciseOpen(e: WorkoutExercise): boolean {
  const start = e.decision_tree?.nodes[e.decision_tree.start]
  return currentSets(e).length < e.target_sets && !start?.terminates && !stoppedByPain(e)
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

/**
 * Сколько подходов осталось в открытых упражнениях — для подтверждения
 * «Завершить» (§13.2): закрытые болью, досрочно или выполненные не считаются.
 */
export function remainingSets(exercises: WorkoutExercise[]): number {
  return exercises.filter(isExerciseOpen).reduce((n, e) => n + e.target_sets - currentSets(e).length, 0)
}
