// Прямые записи шагов онбординга (SPEC §5, §20.6): PAR-Q, ограничения, вес
// тела, события цикла. Все четыре таблицы ссылаются на `profiles` внешним
// ключом: строка профиля создаётся пустым PATCH ДО экрана 2 (см. §5).

import { supabase } from '../auth/supabase'

function fail(what: string, error: { message: string }): never {
  throw new Error(`Не удалось записать ${what}: ${error.message}`)
}

export interface ParqRow {
  user_id: string
  answers: Record<string, boolean>
  has_red_flag: boolean
  acknowledged: boolean
  completed_at: string
}

/** Одна строка на пользователя: повторный проход PAR-Q переписывает её. */
export async function upsertParq(row: ParqRow): Promise<void> {
  const { error } = await supabase.from('parq_responses').upsert(row, { onConflict: 'user_id' })
  if (error) fail('ответы PAR-Q', error)
}

/** Есть ли строка PAR-Q: она же признак, что экран 1 пройден (§5). */
export async function hasParq(): Promise<boolean> {
  const { data, error } = await supabase.from('parq_responses').select('user_id').limit(1)
  if (error) fail('прочитать PAR-Q', error)
  return (data?.length ?? 0) > 0
}

export type Joint = 'knee' | 'lower_back' | 'shoulder' | 'wrist' | 'neck' | 'hip' | 'ankle'
export type Severity = 'avoid' | 'careful'

export async function insertRestrictions(
  userId: string,
  items: { joint: Joint; severity: Severity }[],
): Promise<void> {
  if (items.length === 0) return
  const rows = items.map((i) => ({ id: crypto.randomUUID(), user_id: userId, ...i }))
  const { error } = await supabase.from('user_restrictions').insert(rows)
  if (error) fail('ограничения', error)
}

/** Одна запись на дату (`unique (user_id, measured_on)`): повтор за день переписывает. */
export async function upsertBodyWeight(userId: string, weightKg: number, measuredOn: string): Promise<void> {
  const { error } = await supabase
    .from('body_weight_entries')
    .upsert(
      { id: crypto.randomUUID(), user_id: userId, weight_kg: weightKg, measured_on: measuredOn, source: 'manual' },
      { onConflict: 'user_id,measured_on' },
    )
  if (error) fail('вес тела', error)
}

export async function upsertPeriodStart(userId: string, occurredOn: string): Promise<void> {
  const { error } = await supabase
    .from('cycle_events')
    .upsert(
      { id: crypto.randomUUID(), user_id: userId, kind: 'period_start', occurred_on: occurredOn, source: 'manual' },
      { onConflict: 'user_id,kind,occurred_on' },
    )
  if (error) fail('начало менструации', error)
}
