// Прямые записи в `equipment_profiles` (SPEC §20.6; web-domain §3.3).
//
// Таблицу пишет фронтенд напрямую под JWT пользователя, политики §3.2
// действуют буквально. После правки инвентаря НА СУЩЕСТВУЮЩЕЙ неделе клиент
// обязан позвать `/rebuild` с причиной `equipment_changed` и показать `notice`.
// В срезе 1 недели ещё нет, поэтому вызова здесь нет — он появляется вместе с
// экраном инвентаря (срез 5).

import { supabase } from '../auth/supabase'

/** Условно-«зальный» набор из шага 7 онбординга (§5, §6.6). */
export interface EquipmentDraft {
  name: string
  is_default: boolean
  dumbbells_kg: number[]
  plates_kg: number[]
  barbell_kg: number | null
  bands: boolean
  pullup_bar: boolean
  bench: 'flat' | 'adjustable' | null
}

export async function insertEquipmentProfile(userId: string, draft: EquipmentDraft): Promise<void> {
  const { error } = await supabase
    .from('equipment_profiles')
    .insert({ id: crypto.randomUUID(), user_id: userId, ...draft })
  if (error) throw new Error(`Не удалось записать инвентарь: ${error.message}`)
}

/** Есть ли у пользователя профиль инвентаря по умолчанию (`is_default`). */
export async function hasDefaultEquipment(): Promise<boolean> {
  const { data, error } = await supabase.from('equipment_profiles').select('id').eq('is_default', true).limit(1)
  if (error) throw new Error(`Не удалось прочитать инвентарь: ${error.message}`)
  return (data?.length ?? 0) > 0
}
