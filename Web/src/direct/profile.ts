// Прямые записи правки Профиля (срез 6; SPEC §20.6): ограничения и вес тела.
// Инвентарь — `direct/equipment.ts`, цикл — `direct/cycle.ts`.

import { supabase } from '../auth/supabase'
import type { ActiveRestriction } from '../profile/restrictions'
import type { Joint, Severity } from './onboarding'

function fail(what: string, error: { message: string }): never {
  throw new Error(`Не удалось ${what}: ${error.message}`)
}

/** Активные ограничения: снятые (`resolved_at`) сервер не читает, и мы тоже. */
export async function readActiveRestrictions(): Promise<ActiveRestriction[]> {
  const { data, error } = await supabase
    .from('user_restrictions')
    .select('id, joint, severity')
    .is('resolved_at', null)
  if (error) fail('прочитать ограничения', error)
  return (data ?? []) as ActiveRestriction[]
}

export async function resolveRestrictions(ids: string[], at: Date = new Date()): Promise<void> {
  if (ids.length === 0) return
  const { error } = await supabase.from('user_restrictions').update({ resolved_at: at.toISOString() }).in('id', ids)
  if (error) fail('снять ограничения', error)
}

export async function addRestrictions(userId: string, items: { joint: Joint; severity: Severity }[]): Promise<void> {
  if (items.length === 0) return
  const rows = items.map((i) => ({ id: crypto.randomUUID(), user_id: userId, ...i }))
  const { error } = await supabase.from('user_restrictions').insert(rows)
  if (error) fail('записать ограничения', error)
}

/** Последний записанный вес тела или `null`. */
export async function latestBodyWeight(): Promise<number | null> {
  const { data, error } = await supabase
    .from('body_weight_entries')
    .select('weight_kg')
    .order('measured_on', { ascending: false })
    .limit(1)
  if (error) fail('прочитать вес', error)
  const value = (data ?? [])[0] as { weight_kg: number | string } | undefined
  return value ? Number(value.weight_kg) : null
}
