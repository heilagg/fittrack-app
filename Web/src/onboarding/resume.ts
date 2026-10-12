// С какого экрана продолжать онбординг (SPEC §5, «Решения по онбордингу»).
//
// Счётчика шагов нет: экран вычисляется из того, чего не хватает. Шаги 8–10 из
// данных не восстанавливаются и здесь не участвуют.

import type { Profile } from '../api/schemas'

export type ResumeStep = 1 | 3 | 4 | 5 | 6 | 7 | 'done'

/**
 * @param profile `null` — `GET /v1/profile` ответил `not_found`: онбординг не начат.
 * @param hasParq есть ли строка `parq_responses` (признак, что экран 1 пройден).
 */
export function resumeStep(profile: Profile | null, hasParq: boolean): ResumeStep {
  if (profile === null || !hasParq) return 1
  if (profile.sex_at_birth === undefined || profile.birth_year === undefined || profile.height_cm === undefined) {
    return 3
  }
  if (profile.experience_level === undefined) return 4
  if (profile.goal === undefined) return 5
  if (profile.training_weekdays === undefined) return 6
  // Четыре поля заполнены, а профиль неполон — не хватает инвентаря по умолчанию.
  if (!profile.is_complete) return 7
  return 'done'
}
