// Три пресета инвентаря (SPEC §5 шаг 7, §6.6) и сборка строки из формы.
//
// Значения повторяют `EquipmentLevel` из FitContent; связь с ним — тест:
// `Contract/fixtures/equipment_preset_*.json` выгружает Swift, `presets.test.ts`
// сверяет с ними эти константы.

import type { EquipmentRow } from '../direct/equipmentRow'

export type PresetId = 'home_bodyweight' | 'home_dumbbells' | 'gym'

/** Закрытый список слагов тренажёров (§6.6). */
export const MACHINE_SLUGS = [
  'leg_press', 'leg_extension', 'leg_curl', 'hip_abduction', 'calf_raise',
  'lat_pulldown', 'seated_row', 'back_extension', 'chest_press', 'pec_deck',
  'shoulder_press', 'ab_crunch',
] as const

const range = (from: number, to: number, step: number): number[] => {
  const out: number[] = []
  for (let v = from; v <= to + 1e-9; v += step) out.push(Math.round(v * 100) / 100)
  return out
}

const EMPTY: Omit<EquipmentRow, 'name' | 'is_default'> = {
  dumbbells_kg: [],
  plates_kg: [],
  has_kettlebells: false,
  kettlebells_kg: [],
  bands: false,
  pullup_bar: false,
  step_platform: false,
  plyo_box: false,
  cable_machine: false,
  machines: [],
}

export const PRESETS: Record<PresetId, EquipmentRow> = {
  home_bodyweight: { ...EMPTY, name: 'Дома без железа', is_default: true },
  home_dumbbells: { ...EMPTY, name: 'Дома с гантелями', is_default: true, dumbbells_kg: [5, 7.5, 10, 12.5, 15, 17.5, 20] },
  gym: {
    name: 'Зал',
    is_default: true,
    dumbbells_kg: range(2.5, 50, 2.5),
    plates_kg: [1.25, 2.5, 5, 10, 15, 20],
    barbell_kg: 20,
    machine_step_kg: 2.5,
    has_kettlebells: true,
    kettlebells_kg: range(8, 32, 4),
    bands: true,
    pullup_bar: true,
    bench: 'adjustable',
    step_platform: true,
    plyo_box: true,
    cable_machine: true,
    machines: [...MACHINE_SLUGS].sort(),
  },
}

/**
 * Список чисел из поля формы: «5, 7,5; 10» → [5, 7.5, 10], по возрастанию.
 * Разделители — пробел, точка с запятой и запятая перед пробелом; запятая
 * внутри числа — десятичная.
 */
export function parseKgList(text: string): number[] {
  const values = text
    .split(/;|,(?=\s|$)|\s+/)
    .filter((t) => t !== '')
    .map((t) => Number(t.replace(',', '.')))
  if (values.some((v) => !Number.isFinite(v) || v <= 0)) throw new Error('Вес — положительное число')
  return [...new Set(values)].sort((a, b) => a - b)
}

/**
 * Строка для записи: флаг главнее своей весовой колонки (§7.5) — при снятом
 * `has_kettlebells` набор гирь пустой, как бы он ни был заполнен в форме.
 */
export function normalizeEquipment(row: EquipmentRow): EquipmentRow {
  return {
    ...row,
    kettlebells_kg: row.has_kettlebells ? [...row.kettlebells_kg].sort((a, b) => a - b) : [],
    dumbbells_kg: [...row.dumbbells_kg].sort((a, b) => a - b),
    plates_kg: [...row.plates_kg].sort((a, b) => a - b),
    machines: [...row.machines].sort(),
    is_default: true,
  }
}
