import { describe, expect, it } from 'vitest'
import { formatWeight, parseWeight } from './weight'

describe('ввод веса (§20.3)', () => {
  it('запятая и точка, границы включены', () => {
    expect(parseWeight('22,5')).toBe(22.5)
    expect(parseWeight(' 22.5 ')).toBe(22.5)
    expect(parseWeight('0')).toBe(0)
    expect(parseWeight('500')).toBe(500)
  })

  it('вне диапазона и не число — null, а не молчаливый ноль', () => {
    for (const text of ['', 'двадцать', '500,1', '-1', '1e2', '22,5,1', '.5', '5.']) {
      expect(parseWeight(text), text).toBeNull()
    }
  })

  it('в поле — с запятой', () => {
    expect(formatWeight(22.5)).toBe('22,5')
    expect(formatWeight(40)).toBe('40')
  })
})
