// Строка `equipment_profiles` (SPEC §3.1) без `id` и `user_id`. Отдельный модуль
// без supabase-js: схему читают тесты и чистые функции онбординга.

import { z } from 'zod'

/** Строка `equipment_profiles` без `id` и `user_id` (§3.1). Ключи — колонки. */
export const equipmentRowSchema = z.object({
  name: z.string(),
  is_default: z.boolean(),
  dumbbells_kg: z.array(z.number()),
  plates_kg: z.array(z.number()),
  barbell_kg: z.number().optional(),
  machine_step_kg: z.number().optional(),
  has_kettlebells: z.boolean(),
  kettlebells_kg: z.array(z.number()),
  bands: z.boolean(),
  pullup_bar: z.boolean(),
  bench: z.enum(['flat', 'adjustable']).optional(),
  step_platform: z.boolean(),
  plyo_box: z.boolean(),
  cable_machine: z.boolean(),
  machines: z.array(z.string()),
})
export type EquipmentRow = z.infer<typeof equipmentRowSchema>
