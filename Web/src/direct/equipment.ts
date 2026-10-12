// Прямые записи в `equipment_profiles` (SPEC §20.6; web-domain §3.3).
//
// Таблицу пишет фронтенд напрямую под JWT пользователя, политики §3.2
// действуют буквально. После правки инвентаря НА СУЩЕСТВУЮЩЕЙ неделе клиент
// обязан позвать `/rebuild` с причиной `equipment_changed` и показать `notice`.
// На онбординге недели ещё нет (её генерирует последний экран), поэтому вызова
// здесь нет — он появится вместе с экраном инвентаря в профиле (срез 6).

import { supabase } from '../auth/supabase'
import type { EquipmentRow } from './equipmentRow'

export async function insertEquipmentProfile(userId: string, row: EquipmentRow): Promise<void> {
  const { error } = await supabase
    .from('equipment_profiles')
    .insert({ id: crypto.randomUUID(), user_id: userId, ...row })
  if (error) throw new Error(`Не удалось записать инвентарь: ${error.message}`)
}

/** Есть ли у пользователя профиль инвентаря по умолчанию (`is_default`). */
export async function hasDefaultEquipment(): Promise<boolean> {
  const { data, error } = await supabase.from('equipment_profiles').select('id').eq('is_default', true).limit(1)
  if (error) throw new Error(`Не удалось прочитать инвентарь: ${error.message}`)
  return (data?.length ?? 0) > 0
}

/** Строка инвентаря по умолчанию с её `id` — то, что правит Профиль (срез 6). */
export async function readDefaultEquipment(): Promise<{ id: string; row: EquipmentRow } | null> {
  const { data, error } = await supabase.from('equipment_profiles').select('*').eq('is_default', true).limit(1)
  if (error) throw new Error(`Не удалось прочитать инвентарь: ${error.message}`)
  const found = (data ?? [])[0] as (EquipmentRow & { id: string; user_id: string }) | undefined
  if (!found) return null
  const { id, user_id: _user, ...row } = found
  void _user
  // Числа в `numeric[]` PostgREST отдаёт числами; null-колонки — без ключа.
  const clean = Object.fromEntries(Object.entries(row).filter(([, v]) => v !== null)) as EquipmentRow
  return { id, row: clean }
}

/**
 * Правка строки на месте. После неё вызывающий зовёт `/rebuild` с
 * `equipment_changed` и показывает `notice` (web-domain §3.3).
 */
export async function updateEquipmentProfile(id: string, row: EquipmentRow): Promise<void> {
  // Снятое поле (гриф, шаг стека, скамья) пишется `null`, иначе осталось бы старое.
  const full = { barbell_kg: null, machine_step_kg: null, bench: null, ...row }
  const { error } = await supabase.from('equipment_profiles').update(full).eq('id', id)
  if (error) throw new Error(`Не удалось записать инвентарь: ${error.message}`)
}
