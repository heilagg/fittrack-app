import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { EXPERIENCE_OPTIONS, MACHINE_LABELS, TRAINING_SPLIT_OPTIONS, equipmentLine, trainingSplitNote } from './labels'
import { MACHINE_SLUGS } from './presets'

describe('подписи (§5 шаг 4, §6.6)', () => {
  it('у каждого тренажёра закрытого списка есть русское название, и лишних нет', () => {
    expect(Object.keys(MACHINE_LABELS).sort()).toEqual([...MACHINE_SLUGS].sort())
    // Кириллица с заглавной; заглавная внутри — только имя собственное («Тренажёр Смита»).
    for (const label of Object.values(MACHINE_LABELS)) expect(label).toMatch(/^[А-ЯЁ][а-яё -]*(?: [А-ЯЁ][а-яё]+)*$/)
  })

  it('названия тренажёров совпадают с эталоном FitAPI (§6.6): две копии без проверки разошлись бы', () => {
    const reference = JSON.parse(
      readFileSync(join(__dirname, '../../../Contract/fixtures/equipment_machine_names.json'), 'utf-8'),
    ) as Record<string, string>
    expect(MACHINE_LABELS).toEqual(reference)
  })

  it('схемы тренировок — четыре значения словаря, «Авто» первым (§7.2)', () => {
    expect(TRAINING_SPLIT_OPTIONS.map((o) => o.value)).toEqual(['auto', 'full_body', 'upper_lower', 'push_pull_legs'])
    expect(TRAINING_SPLIT_OPTIONS.map((o) => o.label)).toEqual(['Авто', 'Всё тело', 'Верх и низ', 'Пуш пулл ноги'])
  })

  it('подмена схемы называется ровно в двух местах §7.2', () => {
    expect(trainingSplitNote('upper_lower', 1)).toMatch(/Всё тело/)
    expect(trainingSplitNote('push_pull_legs', 1)).toMatch(/Всё тело/)
    expect(trainingSplitNote('push_pull_legs', 2)).toMatch(/Верх тела \/ Низ тела/)
    expect(trainingSplitNote('upper_lower', 2)).toBeNull()
    expect(trainingSplitNote('full_body', 1)).toBeNull()
    expect(trainingSplitNote('auto', 1)).toBeNull()
    expect(trainingSplitNote('push_pull_legs', 3)).toBeNull()
  })

  it('строка снаряда: через запятую, пустой список — строки нет', () => {
    expect(equipmentLine(['Гантели', 'Регулируемая скамья'])).toBe('Гантели, Регулируемая скамья')
    expect(equipmentLine([])).toBeNull()
    expect(equipmentLine(undefined)).toBeNull()
  })

  it('варианты опыта — три уровня профиля, по порядку', () => {
    expect(EXPERIENCE_OPTIONS.map((o) => o.value)).toEqual(['novice', 'intermediate', 'advanced'])
  })
})
