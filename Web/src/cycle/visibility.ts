// Кто видит календарь цикла (SPEC §11.6, §19.2 п.27). Решает экран, а не
// сервер: `GET /v1/cycle/calendar` отвечает в любом режиме.
//
// Виден во всех режимах с фазами при `cycle_tracking = 'manual'`: `phases` и
// режим без фаз с причиной `low_confidence` — отметка начала месячных и есть
// выход из него (§11.5). В остальных случаях в Профиле строка «Цикл выключен»;
// при `declined` — ещё и разовое предложение включить цикл.
//
// Читается СОХРАНЁННЫЙ профиль (`GET /v1/profile`): на нём и решается, какой
// экран показать. Применённый в памяти режим (§20.6) может уже уйти в
// `low_confidence` или вернуться из него — оба исхода календарь видит.

import type { Profile } from '../api/schemas'

export type CycleVisibility =
  /** Цикл не про эту пользовательницу (§5: шаг 9 только для `female`). */
  | { kind: 'none' }
  | { kind: 'calendar' }
  /** Календаря нет; `declined` — можно однократно предложить включить. */
  | { kind: 'off'; declined: boolean }

export function cycleVisibility(profile: Profile | null): CycleVisibility {
  if (profile === null || profile.sex_at_birth !== 'female') return { kind: 'none' }
  const mode = profile.cycle?.phase_mode
  const reason = profile.cycle?.no_phase_reason
  const tracked = profile.cycle_tracking === 'manual'
  if (tracked && (mode === 'phases' || reason === 'low_confidence')) return { kind: 'calendar' }
  return { kind: 'off', declined: reason === 'declined' }
}
