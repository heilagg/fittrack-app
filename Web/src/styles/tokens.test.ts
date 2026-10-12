// Дизайн-токены (web-domain §8): синхронизация, контраст, правило «только токены».
//
// tokens.css генерируется из Tools/design-tokens/tokens.json и коммитится; как
// эталоны Contract/fixtures, он не должен расходиться с источником молча.

import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { flattenTokens } from '../../../Tools/design-tokens/lib/tokens.mjs'
import { renderCss } from '../../../Tools/design-tokens/targets/css.mjs'

const source: unknown = JSON.parse(readFileSync(join(__dirname, '../../../Tools/design-tokens/tokens.json'), 'utf-8'))

describe('tokens.css', () => {
  it('совпадает с выводом генератора из tokens.json', () => {
    const committed = readFileSync(join(__dirname, 'tokens.css'), 'utf-8')
    expect(committed, 'tokens.css устарел: npm run tokens').toBe(renderCss(source))
  })

  it('стек шрифтов — принятое решение: Space Grotesk, Manrope под кириллицу, sans-serif', () => {
    const committed = readFileSync(join(__dirname, 'tokens.css'), 'utf-8')
    expect(committed).toContain("--font-family-base: 'Space Grotesk', 'Manrope', sans-serif;")
  })
})

// MARK: - Контраст текста не ниже 4.5:1 (WCAG 2.x, AA)

function luminance(hex: string): number {
  const channels = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255)
  const [r, g, b] = channels.map((c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4)) as [number, number, number]
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

function contrast(a: string, b: string): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x) as [number, number]
  return (hi + 0.05) / (lo + 0.05)
}

const colors = new Map(
  flattenTokens(source)
    .filter((t) => t.type === 'color')
    .map((t) => [t.path[1]!, t.value as string]),
)

/** Каждое сочетание «текст на фоне», которое встречается в app.css. */
const TEXT_PAIRS: [string, string][] = [
  ['text', 'bg'],
  ['text', 'surface'],
  ['text', 'nav'],
  ['text-muted', 'bg'],
  ['text-muted', 'surface'],
  ['text-muted', 'nav'],
  ['accent', 'bg'],
  ['accent', 'surface'],
  ['accent', 'nav'],
  ['accent', 'accent-chip-bg'],
  ['on-accent', 'accent'],
]

describe('контраст', () => {
  it('формула совпадает с WCAG на известных парах', () => {
    expect(contrast('#000000', '#FFFFFF')).toBeCloseTo(21, 5)
    expect(contrast('#777777', '#FFFFFF')).toBeCloseTo(4.48, 2)
  })

  it.each(TEXT_PAIRS)('%s на %s — не ниже 4.5:1', (fg, bg) => {
    const ratio = contrast(colors.get(fg)!, colors.get(bg)!)
    expect(ratio, `${fg} на ${bg}: ${ratio.toFixed(2)}`).toBeGreaterThanOrEqual(4.5)
  })
})

// MARK: - Цвета и размеры только из токенов

function files(dir: string, ext: RegExp): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name)
    if (statSync(path).isDirectory()) return files(path, ext)
    return ext.test(name) ? [path] : []
  })
}

const src = join(__dirname, '..')
const COLOR_LITERAL = /#[0-9a-fA-F]{3,8}\b|\b(?:rgba?|hsla?|oklch|lab)\(/
const SIZE_LITERAL = /(?<![-\w])\d*\.?\d+(?:px|rem|em|pt|vh|vw)\b/

/** Строки CSS без комментариев. */
const cssLines = (path: string) =>
  readFileSync(path, 'utf-8')
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .split('\n')

describe('цвета и размеры только из токенов', () => {
  const sheets = files(src, /\.css$/).filter((p) => !p.endsWith('tokens.css'))

  it('рукописные стили есть', () => {
    expect(sheets.length).toBeGreaterThan(0)
  })

  it.each(sheets.map((p) => [p.slice(src.length + 1), p]))('%s: без литералов цвета и размера', (_, path) => {
    const offenders = cssLines(path).filter((line) => COLOR_LITERAL.test(line) || SIZE_LITERAL.test(line))
    expect(offenders).toEqual([])
  })

  it('компоненты без инлайн-стилей', () => {
    const offenders = files(src, /\.tsx$/).filter((p) => /\bstyle=\{/.test(readFileSync(p, 'utf-8')))
    expect(offenders).toEqual([])
  })
})
