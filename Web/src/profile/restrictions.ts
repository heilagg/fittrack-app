// Правка ограничений из Профиля (SPEC §14.4, §20.6): что снять и что добавить.
//
// Ограничение не удаляется, а снимается: `resolved_at` (§3.1), и сервер
// читает только активные (`resolved_at is null`, §20.6). Смена степени — снятие
// прежней строки и новая строка: история того, что было, остаётся.

import type { Joint, Severity } from '../direct/onboarding'

export interface ActiveRestriction {
  id: string
  joint: Joint
  severity: Severity
}

export type Levels = Partial<Record<Joint, Severity>>

export function levelsOf(active: ActiveRestriction[]): Levels {
  return Object.fromEntries(active.map((r) => [r.joint, r.severity]))
}

export function restrictionChanges(
  active: ActiveRestriction[],
  levels: Levels,
): { resolve: string[]; add: { joint: Joint; severity: Severity }[] } {
  const resolve = active.filter((r) => levels[r.joint] !== r.severity).map((r) => r.id)
  const kept = new Set(active.filter((r) => levels[r.joint] === r.severity).map((r) => r.joint))
  const add = (Object.entries(levels) as [Joint, Severity][])
    .filter(([joint]) => !kept.has(joint))
    .map(([joint, severity]) => ({ joint, severity }))
  return { resolve, add }
}
