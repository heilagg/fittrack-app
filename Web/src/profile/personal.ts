// Личные данные из Профиля (срез 6): что уходит в `PATCH /v1/profile`.
// Отправляются только изменённые поля: неизменённый `goal` или
// `experience_level` не должен выглядеть сменой (§7.1, триггер пересборки).

import type { PatchProfileRequest, Profile } from '../api/schemas'

export interface PersonalDraft {
  birth_year: number
  height_cm: number
  experience_level: NonNullable<Profile['experience_level']>
  goal: NonNullable<Profile['goal']>
  training_weekdays: number[]
  session_minutes: number
}

export function personalPatch(profile: Profile, draft: PersonalDraft): PatchProfileRequest {
  const patch: PatchProfileRequest = {}
  if (draft.birth_year !== profile.birth_year) patch.birth_year = draft.birth_year
  if (draft.height_cm !== profile.height_cm) patch.height_cm = draft.height_cm
  if (draft.experience_level !== profile.experience_level) patch.experience_level = draft.experience_level
  if (draft.goal !== profile.goal) patch.goal = draft.goal
  const days = [...draft.training_weekdays].sort((a, b) => a - b)
  if (days.join(',') !== (profile.training_weekdays ?? []).join(',')) patch.training_weekdays = days
  if (draft.session_minutes !== profile.session_minutes) patch.session_minutes = draft.session_minutes
  return patch
}
