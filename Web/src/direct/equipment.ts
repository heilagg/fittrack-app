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
