import { describe, expect, it } from 'vitest'
import { EXPERIENCE_OPTIONS, MACHINE_LABELS } from './labels'
import { MACHINE_SLUGS } from './presets'

describe('подписи (§5 шаг 4, §6.6)', () => {
  it('у каждого тренажёра закрытого списка есть русское название, и лишних нет', () => {
    expect(Object.keys(MACHINE_LABELS).sort()).toEqual([...MACHINE_SLUGS].sort())
    // Кириллица с заглавной; заглавная внутри — только имя собственное («Тренажёр Смита»).
    for (const label of Object.values(MACHINE_LABELS)) expect(label).toMatch(/^[А-ЯЁ][а-яё -]*(?: [А-ЯЁ][а-яё]+)*$/)
  })

  it('варианты опыта — три уровня профиля, по порядку', () => {
    expect(EXPERIENCE_OPTIONS.map((o) => o.value)).toEqual(['novice', 'intermediate', 'advanced'])
  })
})
