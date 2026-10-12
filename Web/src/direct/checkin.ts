// Прямая запись `daily_checkins` (SPEC §10, §11.4, §20.6): чек-ин и оверрайд
// дня. Одна строка на дату (`unique (user_id, checkin_date)`).
//
// Не upsert с новым `id`: при конфликте PostgREST обновил бы и первичный
// ключ. Поэтому строка дня читается, и дальше — update по её `id` либо insert.
//
// `/rebuild` после записи не зовётся: причин у него две (§20.3), и чек-ин с
// оверрайдом сервер наблюдает сам — следующее чтение карточки и недели
// посчитано уже с ними, а изменение плана приезжает `notice` недели.

import { supabase } from '../auth/supabase'

export type Override = 'push' | 'ease' | 'rest'

export interface Checkin {
  energy?: number | null
  soreness?: number | null
  sleep_quality?: number | null
  stress?: number | null
  override?: Override | null
}

function fail(what: string, error: { message: string }): never {
  throw new Error(`Не удалось ${what}: ${error.message}`)
}

export async function readCheckin(date: string): Promise<(Checkin & { id: string }) | null> {
  const { data, error } = await supabase
    .from('daily_checkins')
    .select('id, energy, soreness, sleep_quality, stress, override')
    .eq('checkin_date', date)
    .limit(1)
  if (error) fail('прочитать чек-ин', error)
  return ((data ?? [])[0] as (Checkin & { id: string }) | undefined) ?? null
}

/** Пишет только переданные поля: чек-ин не стирает оверрайд, и наоборот. */
export async function saveCheckin(userId: string, date: string, fields: Checkin): Promise<void> {
  const existing = await readCheckin(date)
  const { error } = existing
    ? await supabase.from('daily_checkins').update(fields).eq('id', existing.id)
    : await supabase
        .from('daily_checkins')
        .insert({ id: crypto.randomUUID(), user_id: userId, checkin_date: date, ...fields })
  if (error) fail('записать чек-ин', error)
}
