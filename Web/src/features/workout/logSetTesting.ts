// Ответ `POST …/sets` в тестах (§20.3): дерево и записанный подход. Подход
// повторяет тело запроса — сервер пишет тот же `id`, — а вес можно подменить,
// чтобы проверить округление к ступени.

import type { ApiClient } from '../../api/client'
import type { LogSetResponse, SetRow } from '../../api/schemas'

type LogSet = ApiClient['logSet']
type Body = Parameters<LogSet>[2]

export function recordedSet(body: Body, overrides: Partial<SetRow> = {}): SetRow {
  return {
    id: body.id,
    exercise_slug: 'squat_barbell',
    set_index: body.set_index,
    ...(body.prescribed_kg !== undefined ? { prescribed_kg: body.prescribed_kg } : {}),
    prescribed_reps: 10,
    ...(body.actual_kg !== undefined ? { actual_kg: body.actual_kg } : {}),
    ...(body.actual_reps !== undefined ? { actual_reps: body.actual_reps } : {}),
    ...(body.feedback !== undefined ? { feedback: body.feedback } : {}),
    pain_flag: body.pain_flag,
    pain_joints: [],
    completed_at: body.completed_at,
    skipped: body.skipped,
    ...overrides,
  }
}

/** Мок `logSet`, отвечающий деревом и записанным подходом из тела. */
export function answer(
  response: Pick<LogSetResponse, 'decision_tree'>,
  overrides: (body: Body) => Partial<SetRow> = () => ({}),
): LogSet {
  return async (_workout, _exercise, body) => ({ ...response, set: recordedSet(body, overrides(body)) })
}

/** Ответ на последний вызов мока — для отложенного `resolve`. */
export function echo(response: Pick<LogSetResponse, 'decision_tree'>, logSet: { mock: { calls: Parameters<LogSet>[] } }): LogSetResponse {
  const body = logSet.mock.calls.at(-1)![2]
  return { ...response, set: recordedSet(body) }
}
