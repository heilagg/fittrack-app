import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { equipmentRowSchema } from '../direct/equipmentRow'
import { normalizeEquipment, parseKgList, PRESETS, type PresetId } from './presets'

const dir = join(__dirname, '../../../Contract/fixtures')
const load = (id: PresetId) =>
  equipmentRowSchema.parse(JSON.parse(readFileSync(join(dir, `equipment_preset_${id}.json`), 'utf-8')))

describe('пресеты инвентаря', () => {
  for (const id of ['home_bodyweight', 'home_dumbbells', 'gym'] as const) {
    it(`${id} совпадает с эталоном FitContent`, () => {
      expect(PRESETS[id]).toEqual(load(id))
    })
  }

  it('флаг гирь главнее набора: при снятом has_kettlebells набор пуст', () => {
    const row = normalizeEquipment({ ...PRESETS.gym, has_kettlebells: false, kettlebells_kg: [8, 12] })
    expect(row.kettlebells_kg).toEqual([])
  })

  it('профиль по умолчанию: is_default всегда истинно', () => {
    expect(normalizeEquipment({ ...PRESETS.home_dumbbells, is_default: false }).is_default).toBe(true)
  })

  it('список весов: запятые, точки с запятой, дубликаты, порядок', () => {
    expect(parseKgList('10, 5;7,5 5')).toEqual([5, 7.5, 10])
    expect(parseKgList('5, 7.5, 10')).toEqual([5, 7.5, 10])
    expect(parseKgList('')).toEqual([])
  })

  it('вес не число или не положительный — ошибка', () => {
    expect(() => parseKgList('5, abc')).toThrow()
    expect(() => parseKgList('0')).toThrow()
  })
})
