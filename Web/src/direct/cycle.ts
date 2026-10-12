// Прямые записи `cycle_events` из календаря цикла (SPEC §11.6, §20.6).
//
// Таблица — одна из шести, которые фронтенд пишет сам под RLS. После каждой
// записи вызывающий зовёт `/rebuild` с причиной `cycle_event_added` и
// показывает `notice` (web-domain §3.3): это делает `useCycleWrite`, а не
// функции здесь — они только пишут.
//
// Правится и удаляется только последнее событие (§11.6), поэтому чтение
// отдаёт два последних: само последнее и предыдущее, раньше которого его
// переносить нельзя.

import { supabase } from '../auth/supabase'
import type { CycleEventRef } from '../cycle/events'

function fail(what: string, error: { message: string }): never {
  throw new Error(`Не удалось ${what}: ${error.message}`)
}

/**
 * Последнее и предыдущее события по `occurred_on`. В один день конец идёт
 * после начала: `period_end` < `period_start` по алфавиту, поэтому вторым
 * ключом — `kind` по возрастанию.
 */
export async function latestCycleEvents(): Promise<{ latest: CycleEventRef | null; previous: CycleEventRef | null }> {
  const { data, error } = await supabase
    .from('cycle_events')
    .select('id, kind, occurred_on')
    .order('occurred_on', { ascending: false })
    .order('kind', { ascending: true })
    .limit(2)
  if (error) fail('прочитать отметки цикла', error)
  const rows = (data ?? []) as CycleEventRef[]
  return { latest: rows[0] ?? null, previous: rows[1] ?? null }
}

export async function insertCycleEvent(
  userId: string,
  kind: 'period_start' | 'period_end',
  occurredOn: string,
): Promise<void> {
  const { error } = await supabase
    .from('cycle_events')
    .insert({ id: crypto.randomUUID(), user_id: userId, kind, occurred_on: occurredOn, source: 'manual' })
  if (error) fail('записать отметку', error)
}

export async function moveCycleEvent(id: string, occurredOn: string): Promise<void> {
  const { error } = await supabase.from('cycle_events').update({ occurred_on: occurredOn }).eq('id', id)
  if (error) fail('перенести отметку', error)
}

export async function deleteCycleEvent(id: string): Promise<void> {
  const { error } = await supabase.from('cycle_events').delete().eq('id', id)
  if (error) fail('удалить отметку', error)
}
